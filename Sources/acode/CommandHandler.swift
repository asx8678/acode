import Foundation

// MARK: - SlashResult

/// Outcome of a synchronous slash command (e.g. `/help`, `/clear`, `/quit`).
/// Async commands (`/plan`) return immediately; the orchestrator drives the
/// heavy lifting on a child task and feeds updates back through the sink.
struct SlashResult: Sendable, Equatable {
    /// Optional line to append to the transcript as a `notice` (cyan ⓘ).
    var notice: String?
    /// Optional transient toast (bottom-right corner). When set, the loop
    /// stamps `bornTick` and fades after `Toast.kToastLifetime`.
    var message: String?
    /// True when the user wants to leave the TUI (e.g. `/quit`). The loop
    /// breaks on the next render tick so a final frame can paint.
    var quit: Bool = false

    static let none = SlashResult()
}

// MARK: - CommandHandler

/// Slash-command dispatch + multi-agent orchestrator bridge.
///
/// The MVU reducer is pure; it cannot run a command or kick off a long-running
/// orchestrator run. The reducer emits a `Effect.runSlash(text)` (or
/// `Effect.runOrchestrator(task:)`), and the loop calls into `CommandHandler`
/// to do the work. The result is either a `SlashResult` (sync command), a
/// note that an orchestrator has been started, or a no-op.
///
/// `CommandHandler` is `@MainActor` because it mutates `agent` (`/model`,
/// `/clear`) and constructs the orchestrator (`/plan`). It is created by
/// `Acode.runTUISession` with the live agent + provider + tools.
@MainActor
final class CommandHandler {
    /// The live agent — receives `/model` (provider switch) and `/clear`
    /// (history reset) directly.
    private let agent: Agent
    /// Shared model id. `var` so `/model <name>` can update it in
    /// place (H2: prior version was `let` and `/model` therefore
    /// printed the original model after a switch). The `/plan`
    /// closure still snapshots the current value into a `let`
    /// before dispatch, so the sending-@MainActor capture rule
    /// is preserved.
    private var resolvedModel: String
    /// Provider factory used by `/model` and the orchestrator's per-role
    /// resolver. Re-derives the provider from a model name string.
    private let makeProvider: @MainActor (String) -> any LLMProvider
    /// The full tool registry.
    private let tools: ToolRegistry
    /// The TUISink so the orchestrator can drive the MVU stream.
    private let sink: TUISink
    /// Profiles for the three orchestrator roles. Config-overridable.
    private let profiles: (planner: AgentProfile, coder: AgentProfile, reviewer: AgentProfile)
    /// The shared approval policy; `/auto` and `/allow` mutate it.
    private let policy: ApprovalPolicy
    /// The TUI app — `/theme` calls `setTheme` so the next frame picks up
    /// the new palette without bouncing through the model.
    private weak var app: TUIApp?
    /// The session store for `/save`, `/resume`, `/sessions`, and
    /// auto-save on `/quit`. Injected so the dispatch path stays
    /// network-free; production wires the default store, tests can
    /// point at a temp dir.
    private let sessionStore: SessionStore
    /// The currently-loaded session, if any. Set by `/resume` (and
    /// by `--resume`/`--continue` startup). Used as the in-place
    /// update target for `/save` and the auto-save on `/quit`.
    private var currentSession: Session?

    init(
        agent: Agent,
        resolvedModel: String,
        makeProvider: @escaping @MainActor (String) -> any LLMProvider,
        tools: ToolRegistry,
        sink: TUISink,
        profiles: (planner: AgentProfile, coder: AgentProfile, reviewer: AgentProfile),
        policy: ApprovalPolicy,
        app: TUIApp,
        sessionStore: SessionStore = SessionStore.default,
        currentSession: Session? = nil
    ) {
        self.agent = agent
        self.resolvedModel = resolvedModel
        self.makeProvider = makeProvider
        self.tools = tools
        self.sink = sink
        self.profiles = profiles
        self.policy = policy
        self.app = app
        self.sessionStore = sessionStore
        self.currentSession = currentSession
    }

    // MARK: - Sync slash dispatch

    /// Dispatches a `/`-prefixed command (the leading `/` is included) to
    /// the right handler. Returns a `SlashResult` describing what the loop
    /// should do (notice/toast/quit). The async `/plan` is handled here too
    /// — it returns immediately so the loop can spin up the orchestrator
    /// turn on a child task (see `runOrchestrator`).
    func run(slashCommand text: String) -> SlashResult {
        // Strip the leading `/` so we can switch on the verb.
        let body = text.hasPrefix("/") ? String(text.dropFirst()) : text
        // Pull off the verb (first word). Trailing args stay in `args`.
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map(String.init) ?? ""
        let args = parts.count > 1 ? String(parts[1]) : ""

        switch verb {
        case "help", "h", "?":
            return SlashResult(
                notice: Self.helpText,
                message: nil
            )

        case "clear":
            agent.reset()
            return SlashResult(
                notice: "Conversation history cleared.",
                message: nil
            )

        case "model":
            if args.isEmpty {
                return SlashResult(
                    notice: "Current model: \(resolvedModel).",
                    message: nil
                )
            } else {
                let newProvider = makeProvider(args)
                agent.switchProvider(newProvider)
                // Mirror line-mode `Acode.swift:288-291` — update the
                // cached model id so a bare `/model` after a switch
                // reports the *new* model, not the startup one. H2 fix.
                resolvedModel = args
                return SlashResult(
                    notice: "Model switched to \(args).",
                    message: nil
                )
            }

        case "auto":
            switch args.trimmingCharacters(in: .whitespaces).lowercased() {
            case "":
                return SlashResult(notice: policy.describe(), message: nil)
            case "on":
                policy.setAutoApproveAll(true)
                return SlashResult(notice: "Auto-approve-all is now on.", message: nil)
            case "off":
                policy.setAutoApproveAll(false)
                return SlashResult(notice: "Auto-approve-all is now off.", message: nil)
            default:
                return SlashResult(notice: "Usage: /auto [on|off]", message: nil)
            }

        case "allow":
            if args.isEmpty {
                return SlashResult(notice: "Usage: /allow <command prefix> (e.g. /allow git push)", message: nil)
            } else {
                policy.allowShellPrefix(args)
                return SlashResult(
                    notice: "Shell commands matching \"\(args)\" will be auto-approved this session.",
                    message: nil
                )
            }

        case "approvals":
            switch args.trimmingCharacters(in: .whitespaces).lowercased() {
            case "":
                return SlashResult(notice: policy.describe(), message: nil)
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
                    return SlashResult(
                        notice: "Saved approvals to \(path):\n  \(policy.describe())",
                        message: "Approvals saved"
                    )
                } else {
                    return SlashResult(notice: "Error: failed to save approvals to \(path).", message: nil)
                }
            default:
                return SlashResult(notice: "Usage: /approvals [save]", message: nil)
            }

        case "theme":
            if args.isEmpty {
                return SlashResult(
                    notice: "Current theme: \(app?.currentTheme.name ?? "dark"). Usage: /theme <name>",
                    message: nil
                )
            } else if let next = Theme.named(args) {
                app?.setTheme(next)
                return SlashResult(message: "Theme → \(next.name)")
            } else {
                return SlashResult(
                    notice: "Unknown theme \"\(args)\". Available: \(Theme.all.map(\.name).joined(separator: ", "))",
                    message: nil
                )
            }

        case "save":
            return handleSave(args: args)

        case "resume":
            return handleResume(args: args)

        case "sessions":
            return handleSessionsList()

        case "plan":
            // The orchestrator is async; the loop dispatches the actual
            // turn on a child task AFTER `run(slashCommand:)` returns
            // (see `TUIApp.handleEffect` `.runSlash`). We just return
            // a SlashResult here so the slash verb is visually treated
            // as a slash command. H1 fix: a bare `/plan` with no task
            // description used to be a silent no-op — mirror line-mode
            // `Acode.swift:206-208` and surface a usage notice.
            if args.trimmingCharacters(in: .whitespaces).isEmpty {
                return SlashResult(
                    notice: "Usage: /plan <task description>",
                    message: nil
                )
            }
            return SlashResult()

        case "quit", "q", "exit":
            // Auto-save current session (or the live history, if no
            // session is loaded) before the loop exits. Mirrors
            // line-mode `Acode.swift:runREPL` (see the /quit branch
            // there). The actual break is owned by the loop on
            // `result.quit == true`; this branch just returns the
            // right SlashResult. The auto-save runs here so the
            // /quit notice accurately reports the save outcome.
            return handleQuit()

        default:
            return SlashResult(notice: "Unknown command: /\(verb). Type /help.", message: nil)
        }
    }

    // MARK: - Session commands (swift-be0.3)

    /// Handles `/save [name]`. Builds a `Session` from the current
    /// `agent.history` (verbatim — no compaction) and the
    /// `resolvedModel`, then saves it to the store. If a session
    /// is already loaded (`currentSession != nil`), update it
    /// in place; otherwise create a new one. The name (if
    /// given) replaces the existing title; otherwise the title
    /// is derived from the first user message (or a timestamp).
    private func handleSave(args: String) -> SlashResult {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        let nameArg = trimmed.isEmpty ? nil : trimmed

        let history = agent.history

        // swift-be0.7 #9: refuse to save an empty conversation.
        // A `/save` against a fresh agent (or after `/clear`)
        // used to write a 0-message session file, which then
        // showed up in `/sessions` as a noise row and — worse
        // — a candidate for `/resume` whose load was a no-op
        // (the user resumed into a blank screen and had to
        // figure out why). The user clearly didn't mean to
        // save nothing. Surface a notice and skip the write.
        if history.messages.isEmpty {
            return SlashResult(
                notice: "Nothing to save: conversation is empty. Send a message or /resume a session first.",
                message: nil
            )
        }

        let title = nameArg ?? deriveSessionTitle(from: history)
        let now = Date()

        let session: Session
        if var existing = currentSession {
            // Update in place: replace conversation, bump updatedAt,
            // and overwrite the title if the user named it explicitly.
            existing.conversation = history
            existing.updatedAt = now
            if let nameArg = nameArg { existing.title = nameArg }
            session = existing
        } else {
            // Fresh session: stamp the model at the moment of save.
            // Build the empty shell, then overwrite the conversation
            // (and the title — the user might have passed a name
            // overriding the derivation) and updatedAt.
            var fresh = Session.new(title: title, model: resolvedModel)
            fresh.conversation = history
            fresh.updatedAt = now
            session = fresh
        }

        if sessionStore.save(session) {
            currentSession = session
            let shortID = String(session.id.prefix(8))
            return SlashResult(
                notice: "Saved session \(shortID): \(session.title ?? "(untitled)") — \(session.conversation.messages.count) messages.",
                message: "Session saved"
            )
        } else {
            return SlashResult(
                notice: "Error: failed to save session to \(sessionStore.baseDir.path).",
                message: nil
            )
        }
    }

    /// Handles `/resume [name|last]`. Resolves the target session
    /// (exact id, id prefix, exact title, or title prefix; `last`
    /// short-circuits to the newest session), restores it into
    /// the agent, rebuilds the visible transcript, and (if the
    /// session has a saved model) realigns the active model. The
    /// full history is the source of truth — the user can scroll
    /// back through every loaded turn.
    private func handleResume(args: String) -> SlashResult {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return SlashResult(
                notice: "Usage: /resume <name|id-prefix|last>",
                message: nil
            )
        }

        // `last` short-circuits the resolution table — this is the
        // documented one-word shortcut for the most recent session.
        let resolution: SessionResolution
        if trimmed.lowercased() == "last" {
            if let recent = sessionStore.mostRecent() {
                resolution = .found(recent)
            } else {
                return SlashResult(
                    notice: "No saved sessions to resume. Use /save to create one.",
                    message: nil
                )
            }
        } else {
            resolution = resolveSession(idOrPrefix: trimmed, store: sessionStore)
        }

        switch resolution {
        case .notFound:
            return SlashResult(
                notice: "No session matched \"\(trimmed)\". Try /sessions to list.",
                message: nil
            )

        case .ambiguous(let matches):
            // Disambiguate by id prefix. Listing them in the
            // transcript is too noisy; cap at 3 and add a hint
            // pointing the user at /sessions.
            let heads = matches.prefix(3).map { String($0.id.prefix(8)) }
            let more = matches.count > 3 ? " (and \(matches.count - 3) more)" : ""
            return SlashResult(
                notice: "Ambiguous: \"\(trimmed)\" matched \(matches.count) sessions: \(heads.joined(separator: ", "))\(more). Use a longer prefix or /sessions.",
                message: nil
            )

        case .found(let session):
            // Apply the seam: restore history on the agent, realign
            // the model (if the session has one), and rebuild the
            // visible transcript from the loaded conversation.
            // Mirrors the line-mode `Acode.runREPL` /resume branch
            // so the two surfaces stay in parity.
            agent.restore(session.conversation)
            let rebuilt = transcriptItems(from: session.conversation)
            var newModel: String? = nil
            if let savedModel = session.model, savedModel != resolvedModel {
                let newProvider = makeProvider(savedModel)
                agent.switchProvider(newProvider)
                resolvedModel = savedModel
                newModel = savedModel
            }
            // swift-be0.7 #3: prepend the "Resumed" notice INTO
            // the items passed to `replaceTranscript`, so the
            // notice survives the replace (previously it was
            // returned via `SlashResult.notice` and overwritten
            // one frame later by `applySlashResult` appending
            // it to a model that was then itself replaced by
            // the resume path). Mirrors the boot-time path in
            // `Acode.runTUISession`.
            //
            // swift-be0.7 #4: cancel any in-flight turn FIRST
            // so the resume doesn't trample a model that's
            // mid-stream. The `.runShell` effect handler
            // already does this; `.runSlash` did not.
            let shortID = String(session.id.prefix(8))
            let title = session.title ?? "(untitled)"
            let count = session.conversation.messages.count
            let noticeText = "Resumed \(shortID): \(title) — \(count) messages."
            var items: [TranscriptItem] = [.notice(noticeText)]
            items.append(contentsOf: rebuilt)
            app?.replaceTranscript(items, model: newModel)
            currentSession = session

            // Still return a toast (the visible "Session resumed"
            // pill — that's a separate channel from the
            // transcript notice and won't be overwritten), and
            // skip the `notice:` so we don't double-paint the
            // same line. The toast is the only ephemeral
            // feedback for the resume.
            return SlashResult(
                notice: nil,
                message: "Session resumed"
            )
        }
    }

    /// Handles `/sessions`. Prints a compact table of every
    /// session in the store, sorted newest first. Empty store
    /// gets a "No saved sessions" notice (a toast would imply
    /// success on an empty result, which is the wrong tone for
    /// a list command).
    private func handleSessionsList() -> SlashResult {
        let sessions = sessionStore.list()
        guard !sessions.isEmpty else {
            return SlashResult(
                notice: "No saved sessions. Use /save to create one.",
                message: nil
            )
        }
        var lines: [String] = ["Saved sessions (newest first):"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        for s in sessions {
            let shortID = String(s.id.prefix(8))
            let title = s.title ?? "(untitled)"
            let model = s.model ?? "—"
            let count = s.conversation.messages.count
            let date = formatter.string(from: s.updatedAt)
            lines.append("  \(shortID)  \(title)  [\(model)]  \(count) msg  \(date)")
        }
        return SlashResult(
            notice: lines.joined(separator: "\n"),
            message: nil
        )
    }

    /// Handles `/quit`. Auto-saves the live history (or updates
    /// the loaded session in place) before the loop exits, then
    /// returns `quit: true` so the loop breaks on its next tick.
    /// Mirrors line-mode `Acode.runREPL` (see /quit branch).
    private func handleQuit() -> SlashResult {
        // Auto-save. If we have a current session, update it; if
        // the history is non-empty, create one. Empty history
        // means there is nothing to save and we just quit.
        let history = agent.history
        let hasHistory = !history.messages.isEmpty
        if hasHistory {
            // Re-use the save path so the title derivation,
            // store call, and currentSession update all run
            // through the same code as `/save`. Pass the
            // existing title if we have one (don't overwrite
            // it just because /quit fired).
            let args = (currentSession?.title ?? "")
            let saveResult = handleSave(args: args)
            if let notice = saveResult.notice {
                return SlashResult(
                    notice: notice + "\nQuitting.",
                    message: saveResult.message,
                    quit: true
                )
            }
        }
        return SlashResult(quit: true)
    }

    // MARK: - Orchestrator

    /// Runs the multi-agent orchestrator on a child task. The orchestrator
    /// posts `phase(...)` via the shared `TUISink`, which the MVU stream
    /// consumes and renders. Cancellation is via the existing turn-task
    /// pattern (Ctrl-C cancels the in-flight orchestrator).
    ///
    /// L2 fix: the prior implementation used `try?` which swallowed
    /// *all* errors, including non-cancellation failures (provider
    /// crash, schema rejection, etc.). The function is now `throws`,
    /// and the caller in `TUIApp.startOrchestratorTurn` distinguishes
    /// `CancellationError` (silent — the supersede-guard there is the
    /// authoritative handler) from any other error (posted as a
    /// `.error` Msg so the user sees a transcript row, mirroring
    /// line-mode `Acode.swift:231-232` "Error: \(error)").
    func runOrchestrator(task: String) async throws {
        let orchestrator = Orchestrator()
        let fallbackModel = resolvedModel
        _ = try await orchestrator.run(
            task: task,
            provider: self.makeProvider(fallbackModel),
            tools: self.tools,
            renderer: self.sink,
            profiles: self.profiles,
            providerForProfile: { p in
                self.makeProvider(p.model ?? fallbackModel)
            }
        )
    }

    // MARK: - help text

    private static let helpText = """
    Commands:
      /help              show this help
      /clear             clear conversation history
      /quit              exit the TUI (auto-saves if there's history)
      /model [name]      show or switch the active model
      /plan <task>       run the multi-agent planner → coder → reviewer
      /theme <name>      switch palette (e.g. /theme dark)
      /auto [on|off]     show or toggle blanket auto-approve
      /allow <prefix>    add a shell command prefix to the auto-allow list
      /approvals [save]  show or persist the approval policy
      /save [name]       save the current conversation as a session
      /resume [name|last] resume a saved session (name, id prefix, or `last`)
      /sessions          list saved sessions (newest first)

    Aliases: /h, /? → /help · /q, /exit → /quit

    Keys:
      Enter  submit
      ^C     cancel the current turn (or quit when idle)
      ^D     quit on an empty input
      ^T     toggle the task row
      ↑/↓    recall history / palette navigation
      PageUp/Down  scroll the transcript
      /      open the slash command palette
    """
}
