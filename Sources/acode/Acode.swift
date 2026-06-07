import ArgumentParser
import Foundation

/// Runs a single one-shot turn through the agent loop and returns the answer.
///
/// Factored out as a network-free testable seam; `run()` calls it.
func runOneShot(
    prompt: String,
    provider: any LLMProvider,
    tools: ToolRegistry,
    renderer: any RenderSink,
    profile: AgentProfile = .generalist
) async throws -> String {
    let agent = Agent(profile: profile, provider: provider, tools: tools, renderer: renderer)
    return try await agent.run(prompt)
}

/// A routed line of REPL input.
nonisolated enum Input {
    case slash(String)
    case shell(String)
    case task(String)
}

/// Routes a REPL line: leading `/` -> slash, leading `!` -> shell, else task.
/// Only the single leading marker is stripped; task keeps the full text.
nonisolated func route(_ s: String) -> Input {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("/") {
        return .slash(String(trimmed.dropFirst()))
    }
    if trimmed.hasPrefix("!") {
        return .shell(String(trimmed.dropFirst()))
    }
    return .task(s)
}

/// Runs `work` in a child task while SIGINT cancels just that task, so Ctrl-C
/// interrupts the current turn and returns to the prompt without killing the
/// process. Reused by the M5 orchestrator.
@MainActor
func runCancellable(_ work: @escaping () async throws -> Void, renderer: any RenderSink) async {
    let task = Task { try await work() }

    // Suppress default termination and route SIGINT to task cancellation.
    let previous = signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { task.cancel() }
    source.resume()
    defer {
        source.cancel()
        signal(SIGINT, previous)
    }

    do {
        try await task.value
    } catch is CancellationError {
        renderer.endAssistant()
        print("Cancelled.")
    } catch {
        renderer.endAssistant()
        print("Error: \(error)")
    }
}

/// Entry point for the acode terminal coding agent.
///
/// Supports one-shot mode (`-p`), an interactive REPL, and the alternate-screen
/// TUI (`--tui`).
@main
struct Acode: AsyncParsableCommand {
    @Option(name: .shortAndLong) var model: String?
    @Option(parsing: .upToNextOption) var agents: [String] = []
    @Flag(name: .long) var yes: Bool = false
    @Option(name: .shortAndLong) var prompt: String?
    @Flag(name: .long) var verbose: Bool = false
    /// Opt into the alternate-screen TUI. The default is the line-mode REPL
    /// (and one-shot mode is unchanged). Non-TTY runs (pipes, CI) always
    /// fall through to line mode regardless of this flag.
    @Flag(name: .long) var tui: Bool = false
    /// swift-be0.4: resume the most recently saved session at
    /// startup. Mutually exclusive with `--resume`; if both are
    /// passed, `--resume` wins (it is more specific). The field
    /// name is `continueLast` because `continue` is a Swift
    /// keyword; the user-facing flag is `--continue`.
    @Flag(name: .customLong("continue")) var continueLast: Bool = false
    /// swift-be0.4: resume a specific session at startup. Accepts
    /// a UUID, a unique UUID prefix, an exact title, or a unique
    /// title prefix — same resolution as `/resume <name>` (see
    /// `resolveSession(idOrPrefix:store:)`). Mutually exclusive
    /// with `--continue`; if both are passed, `--resume` wins.
    @Option(name: .customLong("resume")) var resume: String?

    /// The acode release version, surfaced in the startup banner.
    nonisolated static let version = "0.1.0"

    /// Human-readable name for the active provider, used in verbose logs.
    private nonisolated static func providerName(_ provider: any LLMProvider) -> String {
        if let openAI = provider as? OpenAIProvider {
            if openAI.baseURL == defaultOpenAIBaseURL {
                return "OpenAI"
            }
            // Show the host for custom endpoints (DeepSeek, local, etc.)
            if let host = URL(string: openAI.baseURL)?.host {
                return host
            }
            return "Custom"
        }
        return "Anthropic"
    }

    @MainActor
    mutating func run() async throws {
        // swift-be0.4: resolve any `--resume` / `--continue` into a
        // concrete `Session` (or fail fast). `--resume` takes
        // precedence over `--continue` because it is more specific.
        // The resolution is non-fatal on miss: we just log and
        // continue with no session so the user gets the regular
        // startup path with a "no such session" notice.
        let startupSession: Session? = try Self.resolveStartupSession(
            resume: resume,
            continueLast: continueLast
        )

        // `--tui` (with no `-p` prompt) enters the alternate-screen TUI.
        // The TUI is gated on a real TTY; pipes/CI always fall through to
        // line mode (the TUI's raw-mode would just hang there).
        if tui, prompt == nil {
            let isTTY = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
            if isTTY {
                await Self.runTUISession(
                    model: model,
                    yes: yes,
                    verbose: verbose,
                    agents: agents,
                    startupSession: startupSession
                )
                return
            }
        }

        // No prompt: enter the interactive REPL.
        guard let prompt else {
            await Self.runREPL(
                model: model,
                yes: yes,
                verbose: verbose,
                agents: agents,
                startupSession: startupSession
            )
            return
        }

        // One-shot: the provider throws `missingAPIKey` when a key is required,
        // so configuration is left to the provider (local providers need none).
        if !agents.isEmpty {
            _ = try await Self.executeOrchestrated(
                prompt: prompt,
                model: model,
                yes: yes,
                verbose: verbose,
                agents: agents,
                startupSession: startupSession
            )
        } else {
            _ = try await Self.executeOneShot(
                prompt: prompt,
                model: model,
                yes: yes,
                verbose: verbose,
                startupSession: startupSession
            )
        }
    }

    /// Resolves the startup session from `--resume` / `--continue`.
    /// Returns `nil` if neither is set, if the requested session is
    /// not found, or if the requested session is ambiguous. In all
    /// non-error cases the caller continues with no session (and
    /// either a notice for `--resume` miss, or a silent fallback
    /// for `--continue` miss so the command can be a no-op).
    ///
    /// Errors that crash early are limited to the
    /// genuinely-broken-args cases (empty `--resume ""`); those
    /// are user mistakes we want to surface, not silently ignore.
    ///
    /// MainActor-isolated because `SessionStore` is itself
    /// MainActor-isolated (file I/O lives on the main actor in
    /// the Wave A design).
    @MainActor
    private static func resolveStartupSession(
        resume: String?,
        continueLast: Bool
    ) throws -> Session? {
        // Precedence: --resume > --continue. If both are given,
        // --resume wins (it is more specific).
        if let resumeArg = resume?.trimmingCharacters(in: .whitespaces), !resumeArg.isEmpty {
            switch resolveSession(idOrPrefix: resumeArg, store: SessionStore.default) {
            case .found(let s):
                let shortID = String(s.id.prefix(8))
                FileHandle.standardError.write(Data(
                    "Resumed \(shortID): \(s.title ?? "(untitled)") — \(s.conversation.messages.count) messages.\n".utf8
                ))
                return s
            case .notFound:
                // Soft-fail: print a notice and continue with no
                // session. We don't `throw` because a missing
                // session shouldn't kill the process — the user
                // can still run a one-shot or interactive turn
                // from scratch.
                FileHandle.standardError.write(Data(
                    "warning: no session matched \"\(resumeArg)\". Try --resume with a different prefix.\n".utf8
                ))
                return nil
            case .ambiguous(let matches):
                let heads = matches.prefix(3).map { String($0.id.prefix(8)) }
                let more = matches.count > 3 ? " (and \(matches.count - 3) more)" : ""
                FileHandle.standardError.write(Data(
                    "warning: \"\(resumeArg)\" matched \(matches.count) sessions: \(heads.joined(separator: ", "))\(more). Use a longer prefix.\n".utf8
                ))
                return nil
            }
        }
        if continueLast {
            if let recent = SessionStore.default.mostRecent() {
                let shortID = String(recent.id.prefix(8))
                FileHandle.standardError.write(Data(
                    "Resumed \(shortID): \(recent.title ?? "(untitled)") — \(recent.conversation.messages.count) messages.\n".utf8
                ))
                return recent
            } else {
                // --continue with no saved sessions is a soft no-op.
                FileHandle.standardError.write(Data(
                    "warning: --continue: no saved sessions; starting fresh.\n".utf8
                ))
                return nil
            }
        }
        return nil
    }

    /// Maps an agent name string to a profile.
    @MainActor
    private static func profile(for name: String) -> AgentProfile {
        switch name.lowercased() {
        case "plan", "planner": return .planner
        case "code", "coder": return .coder
        case "review", "reviewer": return .reviewer
        default: return .generalist
        }
    }

    /// Builds the (planner, coder, reviewer) profile triple from the `--agents`
    /// list, filling unspecified slots with the standard defaults and applying
    /// any per-role model overrides from config. An empty list yields the full
    /// default triple.
    @MainActor
    private static func orchestratorProfiles(
        agents: [String],
        cfg: Config
    ) -> (planner: AgentProfile, coder: AgentProfile, reviewer: AgentProfile) {
        let base: (AgentProfile, AgentProfile, AgentProfile)
        if agents.count >= 3 {
            base = (profile(for: agents[0]), profile(for: agents[1]), profile(for: agents[2]))
        } else if agents.count == 2 {
            base = (profile(for: agents[0]), profile(for: agents[1]), .reviewer)
        } else if agents.count == 1 {
            base = (profile(for: agents[0]), .coder, .reviewer)
        } else {
            base = (.planner, .coder, .reviewer)
        }
        return (
            applyRoleModel(base.0, roleModels: cfg.roleModels),
            applyRoleModel(base.1, roleModels: cfg.roleModels),
            applyRoleModel(base.2, roleModels: cfg.roleModels)
        )
    }

    /// The interactive read-eval-print loop. Slash and shell commands work
    /// without an API key; only model turns require one.
    @MainActor
    private static func runREPL(
        model: String?,
        yes: Bool,
        verbose: Bool,
        agents: [String],
        startupSession: Session? = nil
    ) async {
        print("acode \(version)")

        let cfg = Config.load(verbose: verbose)
        var tools = ToolRegistry()
        registerStandardTools(&tools)
        var resolvedModel = model ?? cfg.defaultModel ?? defaultAnthropicModel
        let provider = makeProvider(model: model, cfg: cfg)
        let color = Renderer.colorEnabled(
            isTTY: isatty(STDOUT_FILENO) != 0,
            noColor: ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        )
        let policy = ApprovalPolicy(
            autoApproveAll: yes || (cfg.autoApprove ?? false),
            alwaysAllowed: Set(cfg.autoApproveTools ?? []),
            allowedShellPrefixes: cfg.autoApproveShell ?? []
        )
        let renderer = Renderer(color: color, verbose: verbose, policy: policy)
        renderer.verboseLog("Model: \(resolvedModel)")
        renderer.verboseLog("Provider: \(providerName(provider))")
        let agent = Agent(profile: .generalist, provider: provider, tools: tools, renderer: renderer)
        // swift-be0.3: session persistence. `currentSession` is the
        // in-place update target for `/save` and the auto-save on
        // `/quit`; nil until the first save or until `--resume` /
        // `--continue` seeds it. `sessionStore` is the on-disk
        // backend (`~/.config/acode/sessions` by default; can be
        // overridden via the testable init).
        let sessionStore = SessionStore.default
        var currentSession: Session? = startupSession
        // swift-be0.4: seed the agent with the loaded history.
        // This has to happen BEFORE the first readLine (otherwise
        // the first user turn would think it's a fresh
        // conversation).
        if let session = startupSession {
            agent.restore(session.conversation)
            if let savedModel = session.model, !savedModel.isEmpty, savedModel != resolvedModel {
                let newProvider = makeProvider(model: savedModel, cfg: cfg)
                agent.switchProvider(newProvider)
                resolvedModel = savedModel
            }
            let shortID = String(session.id.prefix(8))
            print("Resumed \(shortID): \(session.title ?? "(untitled)") — \(session.conversation.messages.count) messages.")
        }

        loop: while true {
            print("> ", terminator: "")
            guard let line = readLine() else {
                print("")
                break
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            switch route(line) {
            case .slash(let command):
                switch command {
                case "help":
                    print("Commands: /help, /clear, /quit, /model [name], /plan <task>, /auto [on|off], /allow <cmd>, /approvals [save], /save [name], /resume [name|last], /sessions. Prefix ! to run a shell command; anything else is a task.")
                case "clear":
                    agent.reset()
                    print("Conversation history cleared.")
                case "sessions":
                    Self.handleLineModeSessionsList(sessionStore: sessionStore)
                case "quit":
                    // swift-be0.3: auto-save the live history (or
                    // the loaded session) before exiting. The save
                    // and quit are not atomic, but `SessionStore.save`
                    // uses an atomic write under the hood, so a
                    // crash between the save and the break just
                    // leaves the user with a slightly stale file.
                    if !agent.history.messages.isEmpty {
                        Self.handleLineModeSave(
                            args: currentSession?.title ?? "",
                            agent: agent,
                            sessionStore: sessionStore,
                            resolvedModel: resolvedModel,
                            currentSession: &currentSession
                        )
                    }
                    break loop
                default:
                    // Verb-with-argument verbs (`save`, `resume`)
                    // match both `verb` and `verb <args>`. The bare
                    // forms were already handled above; here we
                    // catch the argful form. Same pattern as the
                    // other verb-with-arg slash commands
                    // (`/plan`, `/auto`, `/allow`, `/approvals`).
                    if command == "save" || command.hasPrefix("save ") {
                        let args = command == "save"
                            ? ""
                            : String(command.dropFirst("save".count))
                                .trimmingCharacters(in: .whitespaces)
                        Self.handleLineModeSave(
                            args: args,
                            agent: agent,
                            sessionStore: sessionStore,
                            resolvedModel: resolvedModel,
                            currentSession: &currentSession
                        )
                    } else if command == "resume" || command.hasPrefix("resume ") {
                        let args = command == "resume"
                            ? ""
                            : String(command.dropFirst("resume".count))
                                .trimmingCharacters(in: .whitespaces)
                        await Self.handleLineModeResume(
                            args: args,
                            agent: agent,
                            sessionStore: sessionStore,
                            cfg: cfg,
                            resolvedModel: &resolvedModel,
                            currentSession: &currentSession
                        )
                    } else if command == "plan" || command.hasPrefix("plan ") {
                        let task = command.dropFirst("plan".count).trimmingCharacters(in: .whitespaces)
                        if task.isEmpty {
                            print("Usage: /plan <task description>")
                        } else {
                            let orchestrator = Orchestrator()
                            let planProfiles = orchestratorProfiles(agents: agents, cfg: cfg)
                            // Snapshot the model name so the closure captures a
                            // `let` (Sendable) rather than the `var resolvedModel`
                            // that `/model` reassigns — Swift 6.3 strict
                            // concurrency flags a `var` capture in a sending
                            // `@MainActor` closure. Semantics preserved: the
                            // closure is created fresh on each `/plan` call.
                            let fallbackModel = resolvedModel
                            await runCancellable({
                                let result = try await orchestrator.run(
                                    task: task,
                                    provider: provider,
                                    tools: tools,
                                    renderer: renderer,
                                    profiles: planProfiles,
                                    providerForProfile: { p in makeProvider(model: p.model ?? fallbackModel, cfg: cfg) }
                                )
                                print(result)
                            }, renderer: renderer)
                        }
                    } else if command == "auto" || command.hasPrefix("auto ") {
                        let arg = command.dropFirst("auto".count).trimmingCharacters(in: .whitespaces).lowercased()
                        switch arg {
                        case "":
                            print(policy.describe())
                        case "on":
                            policy.setAutoApproveAll(true)
                            print("Auto-approve-all is now on.")
                        case "off":
                            policy.setAutoApproveAll(false)
                            print("Auto-approve-all is now off.")
                        default:
                            print("Usage: /auto [on|off]")
                        }
                    } else if command == "allow" || command.hasPrefix("allow ") {
                        let prefix = command.dropFirst("allow".count).trimmingCharacters(in: .whitespaces)
                        if prefix.isEmpty {
                            print("Usage: /allow <command prefix> (e.g. /allow git push)")
                        } else {
                            policy.allowShellPrefix(prefix)
                            print("Shell commands matching \"\(prefix)\" will be auto-approved this session.")
                        }
                    } else if command == "approvals" || command.hasPrefix("approvals ") {
                        let arg = command.dropFirst("approvals".count).trimmingCharacters(in: .whitespaces).lowercased()
                        switch arg {
                        case "":
                            print(policy.describe())
                        case "save":
                            let snap = policy.snapshot()
                            let path = ("~/.config/acode/config.json" as NSString).expandingTildeInPath
                            let url = URL(fileURLWithPath: path)
                            let ok = saveApprovals(
                                autoApprove: snap.autoApproveAll,
                                autoApproveTools: snap.alwaysAllowed,
                                autoApproveShell: snap.allowedShellPrefixes,
                                to: url
                            )
                            if ok {
                                print("Saved approvals to \(path):")
                                print("  \(policy.describe())")
                            } else {
                                print("Error: failed to save approvals to \(path).")
                            }
                        default:
                            print("Usage: /approvals [save]")
                        }
                    } else if command == "model" || command.hasPrefix("model ") {
                        let name = command.dropFirst("model".count).trimmingCharacters(in: .whitespaces)
                        if name.isEmpty {
                            print("Current model: \(resolvedModel).")
                        } else {
                            let newProvider = makeProvider(model: name, cfg: cfg)
                            agent.switchProvider(newProvider)
                            resolvedModel = name
                            renderer.verboseLog("Provider: \(providerName(newProvider))")
                            print("Model switched to \(name).")
                        }
                    } else {
                        print("Unknown command: /\(command)")
                    }
                }

            case .shell(let command):
                let result = await RunShellTool.execute(command: command, timeout: 60)
                print(result.output)

            case .task(let text):
                await runCancellable({ try await agent.run(text) }, renderer: renderer)
            }
        }
    }

    // MARK: - Line-mode session commands (swift-be0.3)
    //
    // The TUI equivalents live on `CommandHandler`; these are
    // the line-mode versions. Shared logic (title derivation,
    // id-prefix resolution) lives in `SessionResolve.swift` so
    // both surfaces resolve the same way.

    /// `/save [name]` (and the auto-save on `/quit`).
    /// `args` is the trimmed trailing argument (everything after
    /// `save` in the slash verb); empty means "derive a title".
    /// On success, sets `currentSession` to the saved session so
    /// subsequent `/save` calls update the same file in place.
    @MainActor
    private static func handleLineModeSave(
        args: String,
        agent: Agent,
        sessionStore: SessionStore,
        resolvedModel: String,
        currentSession: inout Session?
    ) {
        let nameArg: String? = args.isEmpty ? nil : args
        let history = agent.history
        let title = nameArg ?? deriveSessionTitle(from: history)
        let now = Date()
        let session: Session
        if var existing = currentSession {
            existing.conversation = history
            existing.updatedAt = now
            if let nameArg = nameArg { existing.title = nameArg }
            session = existing
        } else {
            var fresh = Session.new(title: title, model: resolvedModel)
            fresh.conversation = history
            fresh.updatedAt = now
            session = fresh
        }
        if sessionStore.save(session) {
            currentSession = session
            let shortID = String(session.id.prefix(8))
            print("Saved session \(shortID): \(session.title ?? "(untitled)") — \(session.conversation.messages.count) messages.")
        } else {
            print("Error: failed to save session to \(sessionStore.baseDir.path).")
        }
    }

    /// `/resume [name|last]`. Resolves the target session, calls
    /// `agent.restore(...)`, and (if the session has a saved
    /// model) realigns the active model by calling
    /// `makeProvider` + `agent.switchProvider` and updating
    /// `resolvedModel`. The local `provider` is left alone —
    /// `/model` already follows the same pattern (it updates
    /// the agent + the local `resolvedModel`, not the captured
    /// `provider` const used by `/plan`).
    @MainActor
    private static func handleLineModeResume(
        args: String,
        agent: Agent,
        sessionStore: SessionStore,
        cfg: Config,
        resolvedModel: inout String,
        currentSession: inout Session?
    ) async {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            print("Usage: /resume <name|id-prefix|last>")
            return
        }
        let resolution: SessionResolution
        if trimmed.lowercased() == "last" {
            if let recent = sessionStore.mostRecent() {
                resolution = .found(recent)
            } else {
                print("No saved sessions to resume. Use /save to create one.")
                return
            }
        } else {
            resolution = resolveSession(idOrPrefix: trimmed, store: sessionStore)
        }
        switch resolution {
        case .notFound:
            print("No session matched \"\(trimmed)\". Try /sessions to list.")
        case .ambiguous(let matches):
            let heads = matches.prefix(3).map { String($0.id.prefix(8)) }
            let more = matches.count > 3 ? " (and \(matches.count - 3) more)" : ""
            print("Ambiguous: \"\(trimmed)\" matched \(matches.count) sessions: \(heads.joined(separator: ", "))\(more). Use a longer prefix or /sessions.")
        case .found(let session):
            agent.restore(session.conversation)
            if let savedModel = session.model, savedModel != resolvedModel {
                let newProvider = makeProvider(model: savedModel, cfg: cfg)
                agent.switchProvider(newProvider)
                resolvedModel = savedModel
                print("Model switched to \(savedModel).")
            }
            currentSession = session
            let shortID = String(session.id.prefix(8))
            let count = session.conversation.messages.count
            print("Resumed \(shortID): \(session.title ?? "(untitled)") — \(count) messages.")
        }
    }

    /// `/sessions`. Compact one-line-per-session listing,
    /// newest first. Mirrors the TUI's `/sessions` notice.
    @MainActor
    private static func handleLineModeSessionsList(sessionStore: SessionStore) {
        let sessions = sessionStore.list()
        guard !sessions.isEmpty else {
            print("No saved sessions. Use /save to create one.")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        print("Saved sessions (newest first):")
        for s in sessions {
            let shortID = String(s.id.prefix(8))
            let title = s.title ?? "(untitled)"
            let model = s.model ?? "—"
            let count = s.conversation.messages.count
            let date = formatter.string(from: s.updatedAt)
            print("  \(shortID)  \(title)  [\(model)]  \(count) msg  \(date)")
        }
    }

    /// Boots the alternate-screen TUI.
    ///
    /// Wires the same building blocks `runREPL` does (config, tools, agent,
    /// shared `ApprovalPolicy`) plus the TUI-specific pieces (the sink, the
    /// command handler, the `Terminal` handle, the `Capabilities`). The
    /// TUIApp loop owns the screen and the user input from there.
    ///
    /// Falls back to a helpful stderr message and exits cleanly if the
    /// terminal refuses raw mode (very rare on a TTY; the only real-world
    /// trigger is the user piping stdin to `--tui`, which `run()` already
    /// guards against).
    @MainActor
    private static func runTUISession(
        model: String?,
        yes: Bool,
        verbose: Bool,
        agents: [String],
        startupSession: Session? = nil
    ) async {
        let cfg = Config.load(verbose: verbose)
        var tools = ToolRegistry()
        registerStandardTools(&tools)
        // The `set_tasks` tool is the only new registration the TUI adds.
        // It is safe to always register (it has no side effects and is
        // non-destructive — the model owns the list, the tool just echoes
        // it back as JSON for the sink to parse).
        tools.register(SetTasksTool())
        let resolvedModel = model ?? cfg.defaultModel ?? defaultAnthropicModel
        let provider = makeProvider(model: model, cfg: cfg)
        let policy = ApprovalPolicy(
            autoApproveAll: yes || (cfg.autoApprove ?? false),
            alwaysAllowed: Set(cfg.autoApproveTools ?? []),
            allowedShellPrefixes: cfg.autoApproveShell ?? []
        )
        if verbose {
            FileHandle.standardError.write(Data("Model: \(resolvedModel)\nProvider: \(providerName(provider))\n".utf8))
        }

        // Open the terminal first so a failure (raw-mode denied, no TTY)
        // doesn't leave dangling agent/sink objects behind. `Terminal` is
        // its own exception path: it restores on `deinit`/`atexit`/signal.
        let terminal: Terminal
        do {
            terminal = try Terminal()
        } catch {
            FileHandle.standardError.write(Data("error: --tui requires a real TTY (terminal init failed: \(error))\n".utf8))
            return
        }

        // The TUI needs its own `TUISink` (the post target is wired up
        // inside `TUIApp.run` after the AsyncStream is created). The sink
        // must be constructed BEFORE the agent — `Agent.init` takes the
        // sink by reference and starts posting into it on the first
        // model event.
        let sink = TUISink(approvalPolicy: policy)

        // The shared model id has to be a `let` because the orchestrator
        // closure captures it for a sending `@MainActor` (Swift 6.3 strict
        // concurrency: capturing a `var` in a sending closure is rejected).
        let agent = Agent(profile: .generalist, provider: provider, tools: tools, renderer: sink)
        // swift-be0.4: when `--resume`/`--continue` lands a
        // session before the loop starts, seed the agent with
        // the loaded history. The agent's `restore(_:)` is the
        // write side of the seam added in swift-be0.3 step 0.
        // The visible TUI transcript is also seeded from the
        // conversation further down (initial model
        // construction), since `tuiApp.replaceTranscript` posts
        // a Msg that wouldn't land until the loop is up.
        if let session = startupSession {
            agent.restore(session.conversation)
        }
        // The model id shown in the HUD/wordmark has to match
        // the session's saved model, not the CLI's `--model`
        // flag — `--resume`/`--continue` are "use what the
        // session used". We re-derive the `let resolvedModel`
        // above into `startupResolvedModel` and switch the
        // agent's provider so a `/model` after a resume reports
        // the session's model.
        let startupResolvedModel: String
        if let savedModel = startupSession?.model, !savedModel.isEmpty {
            startupResolvedModel = savedModel
        } else {
            startupResolvedModel = resolvedModel
        }
        if let session = startupSession,
           let savedModel = session.model,
           !savedModel.isEmpty,
           savedModel != startupResolvedModel {
            let newProvider = makeProvider(model: savedModel, cfg: cfg)
            agent.switchProvider(newProvider)
        }

        // Pricing is read once at startup so the HUD's cost widget doesn't
        // pay the table-lookup cost on every frame.
        let pricing = PricingTable.pricing(for: startupResolvedModel)

        // Detect terminal capabilities from env. Capabilities.detect is a
        // pure function of the environment — it does NOT query the live
        // terminal (deferred; the P1 spec says it reserves the handle).
        let env = ProcessInfo.processInfo.environment
        let caps = Capabilities.detect(env: env, term: terminal)

        // Build the initial model. `Status` carries the model name, the
        // cwd, and (best-effort) the active branch. The initial transcript
        // starts with a `notice` so the user sees something other than an
        // empty screen on first paint. We use a `var` here so the
        // transcript is mutable.
        let cwd = FileManager.default.currentDirectoryPath
        // Detect the active branch ONCE at startup so the wordmark and
        // HUD can show it without shelling out per frame. Detection is
        // best-effort: `detectGitBranch` returns nil for detached
        // HEADs and non-repo directories. The loop can refresh this
        // later via the slow timer (see `branchRefreshTask` below).
        let branch = detectGitBranch(cwd: cwd)
        // `provider.contextWindow` is owned by the provider that
        // the agent will actually use (which may have been
        // switched above when a startup session re-aligned the
        // model). We query the agent's current provider here so
        // the HUD's context bar reflects the live limit, not the
        // CLI-flag model.
        let agentProviderContextWindow: Int = {
            // The agent holds a non-public `provider`; the only
            // public surface is `contextWindow` on the provider
            // we just built. We re-resolve via the same factory
            // path we used for the switch so the limit is the
            // one the agent is using, not a stale read.
            return (startupSession?.model.flatMap { savedModel in
                let p = makeProvider(model: savedModel, cfg: cfg)
                return p.contextWindow
            }) ?? provider.contextWindow
        }()
        var initial = TUIModel(
            status: Status(
                model: startupResolvedModel,
                cwd: cwd,
                branch: branch,
                contextWindow: agentProviderContextWindow
            ),
            startup: true
        )
        // Seed the visible transcript with the loaded history
        // when `--resume`/`--continue` lands a session before
        // the loop starts. The same `transcriptItems(from:)`
        // mapper used by the in-loop `/resume` path keeps the
        // two surfaces in parity. A small "Resumed" notice is
        // prepended so the user knows the visible history
        // came from a save, not the current session.
        if let session = startupSession {
            let items = transcriptItems(from: session.conversation)
            initial.transcript.append(.notice(
                "Resumed session \(String(session.id.prefix(8))): \(session.title ?? "(untitled)") — \(session.conversation.messages.count) messages."
            ))
            initial.transcript.append(contentsOf: items)
            // Dismiss the startup wordmark; the user is mid-session.
            initial.startup = false
        } else {
            initial.transcript.append(.notice("acode \(version) — type /help for commands. Ctrl-C cancels a turn; Ctrl-D quits."))
        }

        // Construct the loop's main object. The init builds no I/O; the
        // `run()` method wires the AsyncStream, the SIGWINCH source, and
        // the read loop.
        let tuiApp = TUIApp(
            agent: agent,
            sink: sink,
            terminal: terminal,
            model: initial,
            caps: caps,
            pricing: pricing
        )

        // Build the slash dispatcher. The closure captures `agent`,
        // `resolvedModel`, `makeProvider` (as a `@MainActor` factory),
        // `tools`, `sink`, and `policy`. The TUI app is set as the
        // command handler's weak target for `/theme`.
        //
        // swift-be0.3 + swift-be0.4: thread the session store
        // (and the optional pre-loaded session) so `/save`,
        // `/resume`, `/sessions`, auto-save on `/quit`, and
        // the `--resume`/`--continue` boot path all work in
        // the TUI. `currentSession` is set by `Acode.run()`
        // when `--resume`/`--continue` lands a session before
        // the loop starts; nil for a fresh launch.
        let commandHandler = CommandHandler(
            agent: agent,
            resolvedModel: resolvedModel,
            makeProvider: { makeProvider(model: $0, cfg: cfg) },
            tools: tools,
            sink: sink,
            profiles: orchestratorProfiles(agents: agents, cfg: cfg),
            policy: policy,
            app: tuiApp,
            sessionStore: SessionStore.default,
            currentSession: startupSession
        )
        tuiApp.setCommandHandler(commandHandler)
        tuiApp.setApprovalPolicy(policy)

        await tuiApp.run()
    }

    /// Builds the runtime and runs one prompt. MainActor-isolated so the
    /// MainActor-default helpers (Config, registry, Agent) compose cleanly.
    @MainActor
    private static func executeOneShot(
        prompt: String,
        model: String?,
        yes: Bool,
        verbose: Bool,
        startupSession: Session? = nil
    ) async throws -> String {
        let cfg = Config.load(verbose: verbose)
        var tools = ToolRegistry()
        registerStandardTools(&tools)
        let resolvedModel = model ?? cfg.defaultModel ?? defaultAnthropicModel
        let provider = makeProvider(model: model, cfg: cfg)
        let color = Renderer.colorEnabled(
            isTTY: isatty(STDOUT_FILENO) != 0,
            noColor: ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        )
        let policy = ApprovalPolicy(
            autoApproveAll: yes || (cfg.autoApprove ?? false),
            alwaysAllowed: Set(cfg.autoApproveTools ?? []),
            allowedShellPrefixes: cfg.autoApproveShell ?? []
        )
        let renderer = Renderer(color: color, verbose: verbose, policy: policy)
        renderer.verboseLog("Model: \(resolvedModel)")
        renderer.verboseLog("Provider: \(providerName(provider))")
        // swift-be0.4: one-shot + --resume/--continue. We can't
        // re-use `runOneShot` (which builds a fresh `Agent` with
        // no history), so we build the agent here, restore the
        // history, run, and (if a session was loaded) persist
        // the updated history back so the continuation is
        // durable.
        let agent = Agent(profile: .generalist, provider: provider, tools: tools, renderer: renderer)
        var effectiveResolvedModel = resolvedModel
        if let session = startupSession {
            agent.restore(session.conversation)
            if let savedModel = session.model, !savedModel.isEmpty, savedModel != effectiveResolvedModel {
                let newProvider = makeProvider(model: savedModel, cfg: cfg)
                agent.switchProvider(newProvider)
                effectiveResolvedModel = savedModel
                renderer.verboseLog("Provider: \(providerName(newProvider))")
            }
        }
        let result = try await agent.run(prompt)
        // Persist the updated conversation back to the same
        // session. For an empty-history `--continue` with no
        // pre-existing sessions, there's nothing to update;
        // for a `--resume <id>`, we update in place. This is
        // the "one-shot continuation" guarantee from
        // swift-be0.4.
        if var session = startupSession {
            session.conversation = agent.history
            session.updatedAt = Date()
            // If the model id changed mid-run (the model could
            // theoretically switch via tools in the future),
            // update it. For now this is a no-op.
            SessionStore.default.save(session)
        }
        return result
    }

    /// Builds the runtime and runs one prompt through the multi-agent
    /// orchestrator. Used when `--agents` is specified.
    @MainActor
    private static func executeOrchestrated(
        prompt: String,
        model: String?,
        yes: Bool,
        verbose: Bool,
        agents: [String],
        startupSession: Session? = nil
    ) async throws -> String {
        let cfg = Config.load(verbose: verbose)
        var tools = ToolRegistry()
        registerStandardTools(&tools)
        let resolvedModel = model ?? cfg.defaultModel ?? defaultAnthropicModel
        let provider = makeProvider(model: model, cfg: cfg)
        let color = Renderer.colorEnabled(
            isTTY: isatty(STDOUT_FILENO) != 0,
            noColor: ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        )
        let policy = ApprovalPolicy(
            autoApproveAll: yes || (cfg.autoApprove ?? false),
            alwaysAllowed: Set(cfg.autoApproveTools ?? []),
            allowedShellPrefixes: cfg.autoApproveShell ?? []
        )
        let renderer = Renderer(color: color, verbose: verbose, policy: policy)
        renderer.verboseLog("Model: \(resolvedModel)")
        renderer.verboseLog("Provider: \(providerName(provider))")

        // Map agent names to profiles. Unknown names default to generalist.
        let finalProfiles = orchestratorProfiles(agents: agents, cfg: cfg)

        let orchestrator = Orchestrator()
        return try await orchestrator.run(
            task: prompt,
            provider: provider,
            tools: tools,
            renderer: renderer,
            profiles: finalProfiles,
            // Resolve a provider per role so a role's model override can target a
            // different provider than the top-level default. Roles without an
            // override fall back to the CLI/config model.
            providerForProfile: { profile in makeProvider(model: profile.model ?? model, cfg: cfg) }
        )
    }

    /// Applies a per-role model override from `Config.roleModels` to a profile.
    private static func applyRoleModel(_ profile: AgentProfile, roleModels: [String: String]?) -> AgentProfile {
        guard let roleModels, let model = roleModels[profile.name] else { return profile }
        return AgentProfile(name: profile.name, identity: profile.identity, rules: profile.rules, tools: profile.tools, model: model)
    }
}
