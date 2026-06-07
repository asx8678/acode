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

    init(
        agent: Agent,
        resolvedModel: String,
        makeProvider: @escaping @MainActor (String) -> any LLMProvider,
        tools: ToolRegistry,
        sink: TUISink,
        profiles: (planner: AgentProfile, coder: AgentProfile, reviewer: AgentProfile),
        policy: ApprovalPolicy,
        app: TUIApp
    ) {
        self.agent = agent
        self.resolvedModel = resolvedModel
        self.makeProvider = makeProvider
        self.tools = tools
        self.sink = sink
        self.profiles = profiles
        self.policy = policy
        self.app = app
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

        case "quit", "q", "exit":
            return SlashResult(quit: true)

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

        default:
            return SlashResult(notice: "Unknown command: /\(verb). Type /help.", message: nil)
        }
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
      /quit              exit the TUI
      /model [name]      show or switch the active model
      /plan <task>       run the multi-agent planner → coder → reviewer
      /theme <name>      switch palette (e.g. /theme dark)
      /auto [on|off]     show or toggle blanket auto-approve
      /allow <prefix>    add a shell command prefix to the auto-allow list
      /approvals [save]  show or persist the approval policy

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
