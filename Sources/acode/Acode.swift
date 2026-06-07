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

    mutating func run() async throws {
        // `--tui` (with no `-p` prompt) enters the alternate-screen TUI.
        // The TUI is gated on a real TTY; pipes/CI always fall through to
        // line mode (the TUI's raw-mode would just hang there).
        if tui, prompt == nil {
            let isTTY = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
            if isTTY {
                await Self.runTUISession(model: model, yes: yes, verbose: verbose, agents: agents)
                return
            }
        }

        // No prompt: enter the interactive REPL.
        guard let prompt else {
            await Self.runREPL(model: model, yes: yes, verbose: verbose, agents: agents)
            return
        }

        // One-shot: the provider throws `missingAPIKey` when a key is required,
        // so configuration is left to the provider (local providers need none).
        if !agents.isEmpty {
            _ = try await Self.executeOrchestrated(prompt: prompt, model: model, yes: yes, verbose: verbose, agents: agents)
        } else {
            _ = try await Self.executeOneShot(prompt: prompt, model: model, yes: yes, verbose: verbose)
        }
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
    private static func runREPL(model: String?, yes: Bool, verbose: Bool, agents: [String]) async {
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
                    print("Commands: /help, /clear, /quit, /model [name], /plan <task>, /auto [on|off], /allow <cmd>, /approvals [save]. Prefix ! to run a shell command; anything else is a task.")
                case "clear":
                    agent.reset()
                    print("Conversation history cleared.")
                case "quit":
                    break loop
                default:
                    if command == "plan" || command.hasPrefix("plan ") {
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
    private static func runTUISession(model: String?, yes: Bool, verbose: Bool, agents: [String]) async {
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

        // Pricing is read once at startup so the HUD's cost widget doesn't
        // pay the table-lookup cost on every frame.
        let pricing = PricingTable.pricing(for: resolvedModel)

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
        var initial = TUIModel(
            status: Status(
                model: resolvedModel,
                cwd: cwd,
                branch: branch,
                contextWindow: provider.contextWindow
            ),
            startup: true
        )
        initial.transcript.append(.notice("acode \(version) — type /help for commands. Ctrl-C cancels a turn; Ctrl-D quits."))

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
        let commandHandler = CommandHandler(
            agent: agent,
            resolvedModel: resolvedModel,
            makeProvider: { makeProvider(model: $0, cfg: cfg) },
            tools: tools,
            sink: sink,
            profiles: orchestratorProfiles(agents: agents, cfg: cfg),
            policy: policy,
            app: tuiApp
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
        verbose: Bool
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
        return try await runOneShot(prompt: prompt, provider: provider, tools: tools, renderer: renderer)
    }

    /// Builds the runtime and runs one prompt through the multi-agent
    /// orchestrator. Used when `--agents` is specified.
    @MainActor
    private static func executeOrchestrated(
        prompt: String,
        model: String?,
        yes: Bool,
        verbose: Bool,
        agents: [String]
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
