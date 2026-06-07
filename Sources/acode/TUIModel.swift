import Foundation

// MARK: - InputState

/// The text input buffer with a grapheme-cluster cursor. **Pure data +
/// pure operations** — no I/O, no `Date`, no `Terminal`. The reducer
/// uses these methods directly.
struct InputState: Sendable, Equatable {
    /// Full text content. Stored as a String; grapheme count is
    /// `text.count` (Swift's String.count counts user-perceived
    /// grapheme clusters when iterating, but here we use it as a
    /// cursor index — see `cursorToIndex`).
    var text: String = ""
    /// Cursor position in grapheme-cluster units. 0 = before the first
    /// grapheme, `graphemeCount` = after the last.
    var cursor: Int = 0

    /// Inserts `s` at the cursor position.
    mutating func insert(_ s: String) {
        guard !s.isEmpty else { return }
        let idx = cursorToIndex(cursor)
        text.insert(contentsOf: s, at: idx)
        cursor += graphemeCount(of: s)
    }

    /// Deletes the grapheme immediately before the cursor.
    mutating func backspace() {
        guard cursor > 0 else { return }
        let start = cursorToIndex(cursor - 1)
        let end = cursorToIndex(cursor)
        text.removeSubrange(start..<end)
        cursor -= 1
    }

    /// Deletes the grapheme at the cursor (forward delete).
    mutating func deleteForward() {
        let start = cursorToIndex(cursor)
        let end = cursorToIndex(cursor + 1)
        guard start < end else { return }
        text.removeSubrange(start..<end)
    }

    mutating func moveLeft()  { cursor = max(0, cursor - 1) }
    mutating func moveRight() { cursor = min(graphemeCount, cursor + 1) }
    mutating func moveHome()  { cursor = 0 }
    mutating func moveEnd()   { cursor = graphemeCount }

    /// Truncates the text at the cursor (kill-to-end, ^K in readline).
    /// Cursor stays in place; anything to its right is discarded.
    mutating func killToEnd() {
        let cut = cursorToIndex(cursor)
        text = String(text[..<cut])
    }

    /// Number of grapheme clusters in the buffer. Uses `String.count` as
    /// an approximation — for the P2 demo (ASCII + occasional emoji) this
    /// is correct; P5 will swap in a proper grapheme segmenter if needed.
    var graphemeCount: Int {
        text.count
    }

    // MARK: - Index translation

    /// Converts a grapheme-cluster offset to a `String.Index`. Swift's
    /// String.Index isn't grapheme-positioned by default, so we walk
    /// forward `n` graphemes from `text.startIndex`.
    private func cursorToIndex(_ n: Int) -> String.Index {
        var i = text.startIndex
        var remaining = n
        while remaining > 0 && i < text.endIndex {
            i = text.index(after: i)
            remaining -= 1
        }
        return i
    }

    private func graphemeCount(of s: String) -> Int {
        s.count
    }
}

// MARK: - Status

/// Top-of-screen static info. Token counts live in `Metrics` to keep
/// the rolling/statics split clear; the HUD reads from both.
struct Status: Sendable, Equatable {
    var model: String
    var cwd: String
    var branch: String?
    var contextWindow: Int
    // P5 wordmark metadata.
    /// Release version (e.g. "0.1.0") shown next to the wordmark.
    var wordmarkVersion: String = "0.1.0"
    /// Provider endpoint (e.g. "anthropic", "openai", "local") shown
    /// on the third wordmark line. `wordmark` uses this as the
    /// canonical "where the model lives" label.
    var endpoint: String = "anthropic"
}

// MARK: - Activity

enum Activity: Sendable, Equatable {
    case idle
    case thinking
    case runningTool(name: String)
    case awaitingApproval
}

// MARK: - Transcript items

enum TranscriptItem: Sendable, Equatable {
    case user(String)
    case assistant(text: String)
    case tool(ToolView)
    case phase(String)
    case notice(String)
    case error(String)
    /// Direct shell invocation from the user's `!<cmd>` input. The
    /// reducer appends this when the loop posts a `.shellEnd` Msg
    /// (H3 in `CommandHandler` — `!` shell passthrough parity with
    /// line mode). `output` is the combined stdout+stderr; `isError`
    /// is the exit-status-derived flag. Rendered as a `╭ … ╰` box
    /// similar to a tool card, but without a name (the command is
    /// the headline) and without an expanded state.
    case shell(command: String, output: String, isError: Bool)
}

struct ToolView: Sendable, Equatable {
    var name: String
    var summary: String
    var output: String
    var status: ToolStatus
    var expanded: Bool
    /// swift-be0.7 #6: the originating `ToolCall.id`. `nil` for
    /// tools that started before this field was added (legacy
    /// view rows from a pre-fix-up build) or for tools whose
    /// `id` was empty at start. The transcript rebuild
    /// (`transcriptItems(from:)`) uses this to match results
    /// to the *correct* running call when the model emits
    /// multiple / parallel tool calls. The live `.toolEnd`
    /// reducer uses this for the same reason: matching on
    /// name+status alone was wrong when the same tool was
    /// invoked twice in one turn (the latest one always
    /// won, which shuffled output across the wrong cards).
    var callID: String? = nil
    /// Wall-clock stamp of when the tool started. Set by the **loop**
    /// (not the reducer — the reducer is pure). `nil` until the loop
    /// stamps it; the view falls back to "…" when missing.
    var startedAt: Double?
    /// Wall-clock stamp of when the tool finished (only set for
    /// terminal statuses; running tools have this nil).
    var endedAt: Double?
}

enum ToolStatus: Sendable, Equatable {
    case running
    case ok
    case error
}

// MARK: - TUIModel

struct TUIModel: Sendable {
    var transcript: [TranscriptItem] = []
    var input: InputState = InputState()
    var status: Status
    var activity: Activity = .idle
    /// `0` = pinned to bottom (follow). `> 0` = number of rows scrolled
    /// up from the bottom.
    var scroll: Int = 0
    var history: [String] = []
    var historyIdx: Int? = nil
    var pendingApproval: ToolCall? = nil
    /// Monotonically incrementing frame counter. Driven by `.tick` msgs.
    /// **Pure** — set by the reducer only, no `Date`.
    var tick: Int = 0
    var metrics: Metrics = Metrics()
    /// Snapshot of the input text saved when the user starts recalling
    /// history with ↑. Restored when they return to the present with ↓.
    var savedDraft: String = ""
    /// The current in-session todo list. Populated by the model
    /// (via the `set_tasks` tool routed through `TUISink.toolEnd`)
    /// and by the orchestrator's phase stream (Planner/Coder/Reviewer).
    var tasks: [TaskItem] = []
    /// Whether the task row is visible. Toggled by `^T`.
    var tasksVisible: Bool = true
    // MARK: Palette (U4.1)
    /// The command palette overlay. When `open == true`, the input box
    /// is replaced by the palette and the regular `input` is stashed
    /// in `inputBackup`. Closing the palette restores it.
    var palette: PaletteState = PaletteState()
    // MARK: Toasts (EPIC §2.8)
    /// An in-flight toast. `nil` = no toast visible. The loop is the
    /// only writer; the reducer never sees `Date`.
    var toast: Toast? = nil
    // MARK: Orchestrator timeline (EPIC §2.6)
    /// Phases streamed by the orchestrator (via `.phase` Msgs). The
    /// timeline widget reads this list; auto-cleared on a new turn
    /// so it doesn't linger between runs.
    var phases: [Phase] = []
    /// The current orchestrator round (1-based). Drives the round
    /// progress display in the timeline.
    var phaseRound: Int = 0
    // MARK: Startup wordmark (EPIC §2.1)
    /// `true` while the cyan→violet gradient wordmark should be
    /// animating at the top of the screen. Flipped to `false` by the
    /// reducer on the user's first keystroke / first submit, OR by
    /// the loop when the sweep completes (whichever comes first).
    var startup: Bool = true
    // MARK: Layout memo (M4)
    /// Last-known terminal width in cells. Updated on every `.resize`
    /// message. Used by the click-to-expand hit-test to compute real
    /// wrapped row counts (the previous version assumed 1 row per
    /// item, which mis-targeted on long output and on narrow
    /// terminals). 0 means "not set yet"; the click handler falls
    /// back to 80 in that case.
    var lastCols: Int = 0
}

/// The command palette's open/closed state. Open means: input box is
/// replaced by the palette, keystrokes go to the palette's own
/// buffer, the `filtered` list shows the fuzzy match for `query`.
struct PaletteState: Sendable, Equatable {
    var open: Bool = false
    var query: String = ""
    /// Index into `filtered` of the currently-highlighted row.
    var selection: Int = 0
    /// Cached filtered list (recomputed on every query change by the
    /// reducer). The view never calls `fuzzy` directly — it always
    /// reads from here.
    var filtered: [Command] = allCommands
    /// The input that was in the box when the palette opened. The
    /// palette starts in a "prefilled" state by *appending* to the
    /// existing input, so closing with Esc gives the user back what
    /// they had. The first char of an empty input is `/`, so the
    /// palette query begins as `""` and the filtered list is the
    /// full set.
    var inputBackup: InputState = InputState()
}

/// An in-flight toast (EPIC §2.8). Set by the loop on a notable
/// event (e.g. `/session save` → " session saved"); rendered in the
/// bottom-right corner. Auto-fades after `kToastLifetime` seconds.
struct Toast: Sendable, Equatable {
    var text: String
    /// Monotonic tick at which the toast appeared. The render uses
    /// `(now - bornAt) / kToastLifetime` to compute the fade.
    var bornTick: Int
    static let kToastLifetime: Double = 2.0  // seconds
}

// MARK: - Msg

enum Msg: Sendable {
    case key(KeyEvent)
    case streamDelta(String)
    case assistantEnd
    case phase(String, round: Int)
    case toolStart(ToolCall)
    case toolEnd(ToolCall, ToolResult)
    case approvalRequest(ToolCall)
    case usage(Usage)
    case resize(TermSize)
    case tick
    /// Replaces the current todo list. Posted by `TUISink.toolEnd`
    /// when the `set_tasks` tool returns.
    case setTasks([TaskItem])
    /// Toggles the task row's visibility. Bound to `^T` in `updateKey`.
    case toggleTasks
    /// Appends a `.error` transcript item. Posted by the loop when a
    /// background task (currently only the orchestrator) throws a
    /// non-`CancellationError` failure — see L2 in `CommandHandler`.
    case error(String)
    /// Result of a `!` shell passthrough. The loop calls
    /// `RunShellTool.execute` off the reducer; this Msg carries the
    /// output back so the reducer can append a `.shell` transcript
    /// item. See H3 in `CommandHandler` for the rationale.
    case shellEnd(command: String, output: String, isError: Bool)
    /// Updates `Status.branch`. Posted by the slow branch-refresh
    /// timer in `TUIApp.startBranchRefreshTimer` every 30s, or
    /// immediately on a fast-path update. The reducer is a
    /// pure assignment; the next frame picks up the new value.
    case branchRefresh(String?)
    /// Replaces the live transcript with a freshly-built set of
    /// items (typically derived from a resumed `Conversation`) and,
    /// optionally, updates the displayed model id. Posted by
    /// `TUIApp.replaceTranscript` from the `/resume` slash path
    /// (and from `--resume`/`--continue` startup). The reducer is
    /// a pure assignment; the next frame paints the new history.
    case replaceTranscript([TranscriptItem], model: String?)
}

// MARK: - Effect

/// The user's verdict on a pending approval. `always` persists the
/// decision for the rest of the session via `ApprovalPolicy.allowAlways`
/// (applied by the loop, not the reducer).
enum ApprovalDecision: Sendable, Equatable {
    case yes
    case no
    case always
}

enum Effect: Sendable {
    case submitTask(String)
    case resolveApproval(ApprovalDecision)
    case cancelTurn
    case quit
    /// Run a slash command. The loop dispatches to `CommandHandler`;
    /// the reducer never sees the result — it goes back into the loop
    /// as a notice/toast and (for `/plan`) an async orchestrator run.
    case runSlash(String)
    /// Run the orchestrator. The loop calls `CommandHandler.runOrchestrator`.
    case runOrchestrator(task: String)
    /// Set a toast. The loop applies the wall-clock stamp and
    /// dismisses the toast after its lifetime.
    case showToast(String)
    /// Run a shell command via `RunShellTool.execute` (no model
    /// round-trip) and append its output as a `.shell` transcript
    /// item. Issued when the user types `!<command>` at the prompt —
    /// mirrors line-mode `Acode.swift:299-300` (`!` is a real shell
    /// shortcut in line mode; the TUI previously collapsed it into a
    /// model task, which routed the shell call through the LLM — a
    /// regression of line-mode behavior).
    case runShell(command: String)
}

// MARK: - update (PURE)

/// The reducer. **No I/O, no `Date`, no `Terminal`.** Takes `model` by
/// `inout` and returns zero or more effects for the loop to interpret.
/// All branches are total over `Msg` and `KeyEvent` so the compiler
/// catches missing cases.
func update(_ m: inout TUIModel, _ msg: Msg) -> [Effect] {
    switch msg {
    case .key(let key):
        return updateKey(&m, key)

    case .streamDelta(let s):
        // Append to the last assistant item, creating one if needed so
        // the first delta of a turn still has a target.
        if case .assistant(let text) = m.transcript.last {
            m.transcript[m.transcript.count - 1] = .assistant(text: text + s)
        } else {
            m.transcript.append(.assistant(text: s))
        }
        return []

    case .assistantEnd:
        // Nothing structural to mark; the streaming flag would be on a
        // future `assistant(text, streaming)` variant. For now the
        // presence of an `.assistant` item implies "rendered."
        return []

    case .phase(let p, let round):
        m.transcript.append(.phase(p))
        m.phaseRound = round
        // (Note: TranscriptItem.phase takes a single String and
        // doesn't carry the round; the round is surfaced via the
        // `phaseRound` field on the model for the timeline widget.)
        // Auto-populate the task row + timeline from orchestrator
        // Auto-populate the task row + timeline from orchestrator
        // phase strings. The current orchestrator emits phases like
        // "Planning…", "Coding…", "Reviewing…". We map them to a
        // tiny checklist so the user can see at-a-glance where the
        // run is, and also append to `m.phases` for the timeline
        // widget.
        updateTasksFromPhase(&m, p)
        appendPhaseFromString(&m, p)
        return []

    case .toolStart(let call):
        m.transcript.append(.tool(ToolView(
            name: call.name,
            summary: ToolView.summary(for: call),
            output: "",
            status: .running,
            expanded: false,
            // swift-be0.7 #6: stamp the originating call id so
            // `.toolEnd` can match results to the *correct* row
            // when the model emits multiple / parallel tool
            // calls (matching by name was wrong in that case).
            callID: call.id
        )))
        m.activity = .runningTool(name: call.name)
        return []

    case .toolEnd(let call, let r):
        // swift-be0.7 #6: match the result to the running row
        // whose `callID` matches the result's `callID`. Falling
        // back to the latest running row with the same name
        // preserves the historical behavior for older `ToolView`
        // rows that don't carry a `callID` (pre-fix-up builds,
        // hand-rolled fixtures, and the reduced race where two
        // distinct calls share an empty id).
        let byID: Int? = m.transcript.lastIndex(where: {
            if case .tool(let tv) = $0, tv.callID == call.id, tv.status == .running {
                return true
            }
            return false
        })
        let byName: Int? = m.transcript.lastIndex(where: {
            if case .tool(let tv) = $0, tv.callID == nil, tv.name == call.name, tv.status == .running {
                return true
            }
            return false
        })
        if let idx = byID ?? byName {
            if case .tool(var tv) = m.transcript[idx] {
                tv.output = r.output
                tv.status = r.isError ? .error : .ok
                m.transcript[idx] = .tool(tv)
            }
        }
        // Activity falls back to thinking if a turn is still in flight;
        // the loop will set it to .idle on assistantEnd.
        return []

    case .approvalRequest(let call):
        m.pendingApproval = call
        m.activity = .awaitingApproval
        return []

    case .setTasks(let items):
        // The model owns the list — replace, don't merge. The model
        // is expected to send the full desired list every time.
        m.tasks = items
        // Surface the row the first time the model populates it.
        if !items.isEmpty { m.tasksVisible = true }
        return []

    case .toggleTasks:
        m.tasksVisible.toggle()
        return []

    case .error(let message):
        // Background-task failure (currently only the orchestrator
        // throws this; see L2 in `CommandHandler`). Append a
        // `.error` transcript row so the user sees a red line in
        // place of the previous silent no-op.
        m.transcript.append(.error(message))
        return []

    case .shellEnd(let command, let output, let isError):
        // H3: result of a `!<cmd>` direct shell invocation. Append
        // a transcript card so the user can scroll back through
        // every shell call (and its output) made during the session.
        m.transcript.append(.shell(command: command, output: output, isError: isError))
        m.activity = .idle
        return []

    case .branchRefresh(let branch):
        // Slow timer in `TUIApp` re-detects the active branch and
        // posts the new value. Pure assignment — the next
        // `renderFrame` paints the updated HUD / wordmark.
        m.status.branch = branch
        return []

    case .replaceTranscript(let items, let model):
        // swift-be0.3: `/resume` and `--resume`/`--continue` land
        // here. Replace the visible transcript with the items
        // built from a loaded `Conversation` (so the user can
        // scroll back through the resumed history) and reset the
        // per-turn chrome that should NOT carry over (pending
        // approvals, in-flight orchestrator timeline, scroll pin).
        // A loaded session with a saved model also re-aligns the
        // status model id (and therefore the HUD/wordmark).
        m.transcript = items
        m.activity = .idle
        m.pendingApproval = nil
        m.phases = []
        m.phaseRound = 0
        m.scroll = 0
        if let model = model { m.status.model = model }
        // Dismiss the startup wordmark; the user is mid-session.
        m.startup = false
        return []

    case .usage(let u):
        m.metrics.inTokens += u.input
        m.metrics.outTokens += u.output
        // First-delta timestamp: the loop sets `firstDeltaAt` on turn
        // start, but if the first event we see is a usage chunk (no
        // deltas yet), fall back to "the first sample" so tokPerSec
        // is still meaningful.
        if m.metrics.firstDeltaAt == nil, m.tick > 0 {
            m.metrics.firstDeltaAt = Double(m.tick)
        }
        return []

    case .resize(let size):
        // The size is in the Msg itself; the loop passes it to
        // `renderFrame` on the next render. We do, however, memo
        // the width for the click-to-expand hit-test (M4: the
        // previous version had no width info and assumed 1 row
        // per item, which mis-targeted on wrapped output and on
        // narrow terminals).
        m.lastCols = size.cols
        return []

    case .tick:
        m.tick &+= 1
        // Auto-dismiss the startup wordmark once the gradient sweep
        // has completed. The sweep is 90 frames at 60 Hz ≈ 1.5 s;
        // the loop's frame-timer carve-out will then idle the timer
        // to 0% CPU. Without this, an idle TUI keeps the 60 Hz
        // timer spinning forever (the spec is explicit: 0% CPU at
        // rest is a non-negotiable invariant).
        if m.startup && m.tick >= 90 {
            m.startup = false
        }
        return []
    }
}

// MARK: - Phase appender (timeline widget input)

/// Appends to `m.phases` if `p` looks like a canonical orchestrator
/// phase. The timeline renders whatever's in here. A custom
/// `phase("Compiling…")` won't be appended — same heuristic as the
/// task-row mapper.
private func appendPhaseFromString(_ m: inout TUIModel, _ p: String) {
    let lower = p.lowercased()
    let label: String
    if lower.contains("planning") { label = "Planning" }
    else if lower.contains("coding") || lower.contains("implement") { label = "Coding" }
    else if lower.contains("reviewing") || lower.contains("review") { label = "Reviewing" }
    else { return }
    // Promote the previous running phase to done.
    if let i = m.phases.lastIndex(where: { $0.state == .running }) {
        m.phases[i].state = .done
    }
    // If we already have a phase with this label, just flip it to
    // running; otherwise append. This makes idempotent re-entries
    // safe (the orchestrator currently re-emits each phase per
    // round).
    if let i = m.phases.firstIndex(where: { $0.name == label }) {
        m.phases[i].state = .running
    } else {
        m.phases.append(Phase(name: label, state: .running))
    }
}

// MARK: - Key dispatch

private func updateKey(_ m: inout TUIModel, _ key: KeyEvent) -> [Effect] {
    // Palette-open state swallows all regular input keys.
    if m.palette.open {
        return updatePaletteKey(&m, key)
    }

    // Mouse wheel: page the transcript (U4.2). Click: toggle the
    // expanded state of the tool row under the click position. The
    // hit-test is a one-row scan over the tool transcript; row/col
    // are 0-based. We don't bother hit-testing the input box or the
    // palette — those have their own keyboard story.
    switch key {
    case .scrollUp:
        m.scroll += 1
        return []
    case .scrollDown:
        m.scroll = max(0, m.scroll - 1)
        return []
    case .click(let row, _):
        m.startup = false
        // The view hands us a row/col in cells; we don't need col
        // (the click is on the leftmost tool-row column), but we do
        // need the current terminal width so the hit-test can call
        // `wrap` to count the actual rendered rows of every item.
        // The model doesn't store the width (the loop owns it), so
        // we fall back to a safe default of 80 if not set yet. (P4
        // spec: an uninitialized width is a transient — the loop
        // posts the first `.resize` on start-up before any click
        // could land.)
        let cols = (m.lastCols > 0) ? m.lastCols : 80
        toggleToolExpandedAt(row: row, cols: cols, in: &m)
        return []
    default:
        break
    }

    // Approval-pending state swallows all non-decision keys.
    if m.pendingApproval != nil {
        switch key {
        case .char("y"), .char("Y"), .enter:
            m.pendingApproval = nil
            m.activity = .idle
            return [.resolveApproval(.yes)]
        case .char("n"), .char("N"), .esc:
            m.pendingApproval = nil
            m.activity = .idle
            return [.resolveApproval(.no)]
        case .char("a"), .char("A"):
            m.pendingApproval = nil
            m.activity = .idle
            return [.resolveApproval(.always)]
        case .ctrl(let c) where c == "c":
            m.pendingApproval = nil
            m.activity = .idle
            return [.resolveApproval(.no), .cancelTurn]
        default:
            return []  // ignore everything else
        }
    }

    // Activity-aware key handling. While a turn is in flight, ^C cancels
    // the turn (not the app). When idle, ^C quits.
    switch key {
    case .char(let c):
        // `/` on an empty input opens the palette (U4.1). Anywhere
        // else it's a normal character.
        if c == "/" && m.input.text.isEmpty {
            m.palette = PaletteState(
                open: true,
                query: "",
                selection: 0,
                filtered: allCommands,
                inputBackup: m.input
            )
            m.startup = false
            return []
        }
        m.input.insert(String(c))
        m.startup = false
        return []

    case .enter:
        let text = m.input.text
        guard !text.isEmpty else { return [] }
        m.history.append(text)
        m.historyIdx = nil
        m.savedDraft = ""
        m.input.text = ""
        m.input.cursor = 0
        m.transcript.append(.user(text))
        // First user input dismisses the startup wordmark.
        m.startup = false
        // Slash commands: route to the loop, which runs
        // `CommandHandler`. The reducer never executes side effects.
        if text.hasPrefix("/") {
            // Reset per-turn state so the timeline / tasks don't leak
            // from a prior turn.
            m.phases = []
            m.phaseRound = 0
            m.activity = .thinking
            return [.runSlash(text)]
        }
        // H3: `!command` runs a shell command directly via
        // `RunShellTool.execute` (no model round-trip), matching
        // line-mode `Acode.swift:299-300`. The loop runs the call
        // off-main and posts back a `.shellEnd` Msg so the reducer
        // can append a transcript card. The old behavior collapsed
        // `!` into `.submitTask` — that routed the command through
        // the LLM as a chat message, which is both slower and
        // brain-fidelity-wrong (the model would narrate the command
        // instead of executing it).
        if text.hasPrefix("!") {
            // Only honor a single LEADING `!`; embedded `!` in a
            // message is just text (e.g. `explain !important tags`
            // must NOT shell-execute). Mirrors line-mode
            // (`Acode.swift` uses `trimmed.hasPrefix("!")`).
            // Trim trailing whitespace from the command; the
            // executor's first arg is the entire tail.
            let cmd = text.dropFirst()
                .trimmingCharacters(in: .whitespaces)
            if cmd.isEmpty {
                // `!` alone with no command is a usage error —
                // match line mode's "Prefix ! to run a shell
                // command" help line by emitting a transcript
                // notice and falling back to a normal task.
                m.activity = .thinking
                return [
                    .submitTask(text),
                    .showToast("Usage: !<shell command>")
                ]
            }
            m.activity = .thinking
            return [.runShell(command: cmd)]
        }
        m.activity = .thinking
        return [.submitTask(text)]

    case .backspace:
        m.input.backspace()
        return []

    case .left:
        m.input.moveLeft()
        return []

    case .right:
        m.input.moveRight()
        return []

    case .home:
        m.input.moveHome()
        return []

    case .end:
        m.input.moveEnd()
        return []

    case .up:
        m.startup = false
        guard !m.history.isEmpty else { return [] }
        if m.historyIdx == nil {
            m.savedDraft = m.input.text
            m.historyIdx = m.history.count - 1
        } else if let idx = m.historyIdx, idx > 0 {
            m.historyIdx = idx - 1
        }
        if let idx = m.historyIdx {
            m.input.text = m.history[idx]
            m.input.cursor = m.input.graphemeCount
        }
        return []

    case .down:
        m.startup = false
        guard let idx = m.historyIdx else { return [] }
        if idx < m.history.count - 1 {
            // Bump the index FIRST, then read from the new index.
            // The previous version read `m.history[idx]` after
            // setting `m.historyIdx = idx + 1`, so the second
            // ↓ press after the first showed the same entry as
            // the first (one step behind).
            m.historyIdx = idx + 1
            m.input.text = m.history[m.historyIdx!]
            m.input.cursor = m.input.graphemeCount
        } else {
            // Past the newest entry: restore the saved draft and
            // clear the history index so the next ↑ starts a fresh
            // recall.
            m.historyIdx = nil
            m.input.text = m.savedDraft
            m.input.cursor = m.input.graphemeCount
        }
        return []

    case .pageUp:
        m.scroll += 1
        return []

    case .pageDown:
        m.scroll = max(0, m.scroll - 1)
        return []

    case .ctrl(let c) where c == "c":
        if m.activity != .idle {
            return [.cancelTurn]
        }
        return [.quit]

    case .ctrl(let c) where c == "d":
        if m.input.text.isEmpty { return [.quit] }
        return []

    case .ctrl(let c) where c == "a":
        m.input.moveHome()
        return []

    case .ctrl(let c) where c == "e":
        m.input.moveEnd()
        return []

    case .ctrl(let c) where c == "k":
        m.input.killToEnd()
        return []

    case .ctrl(let c) where c == "u":
        m.input.text = ""
        m.input.cursor = 0
        return []

    case .ctrl(let c) where c == "l":
        // Redraw — the loop interprets this as a ScreenRenderer invalidate.
        // We don't have a dedicated Msg for it; the loop can just re-render.
        return []

    case .ctrl(let c) where c == "t":
        // ^T toggles the task row. The reducer mutates the flag
        // directly here (rather than returning a "toggle" effect) so
        // the keystroke is self-contained — the loop doesn't have to
        // interpret it.
        m.tasksVisible.toggle()
        return []

    case .ctrl:
        // Unbound Ctrl chords (^B, ^G, ^J, ^N, ^O, ^P, ^Q, ^R, ^V, ^W,
        // ^X, ^Y, ^Z) are reserved for future waves. Silently drop.
        return []

    case .scrollUp, .scrollDown, .click:
        // Mouse was already handled at the top of `updateKey`; this
        // path is a no-op safety net (e.g. the user clicked on the
        // input box while it had focus).
        return []

    case .esc:
        return []

    case .tab:
        // Completion comes in P4
        return []

    case .paste(let s):
        m.input.insert(s)
        return []

    case .unknown:
        return []
    }
}

// MARK: - ToolView helpers

extension ToolView {
    /// Build a one-line summary of a tool call for the transcript.
    /// Falls back to the raw call id if neither `command` nor `path`
    /// is present (custom tools).
    static func summary(for call: ToolCall) -> String {
        if let cmd = call.arguments["command"]?.stringValue {
            return "shell: \(truncate(cmd, to: 80))"
        }
        if let path = call.arguments["path"]?.stringValue {
            return "path: \(path)"
        }
        return "id: \(call.id)"
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

// MARK: - Conversation → transcript rebuild (swift-be0.3)
//
// `Agent.history` is the source of truth for a resumed session; the
// TUI's visible transcript is a separate model. To make `/resume`
// (and `--resume`/`--continue` startup) actually useful we rebuild
// the transcript from the loaded `Conversation` so the user can
// scroll back through what happened. The mapping is lossy by
// design — phases/notices/errors are not persisted — but covers
// everything the user actually wrote or the model produced.

/// Maps a `Conversation` to a flat `[TranscriptItem]` suitable for
/// `TUIApp.replaceTranscript`. Pure, value-typed, dependency-free
/// (no terminal/theme/etc.) so it can be unit-tested against an
/// arbitrary `Conversation` and reused by the `--resume` boot path
/// without driving the MVU loop.
///
/// Mapping rules:
/// - `.user(text)` → `.user(text)`
/// - `.assistant(text, toolCalls)` →
///   - if `text` non-empty, a `.assistant(text)` row first
///   - then one `.tool(ToolView)` row per tool call (initially
///     `.running`; subsequent `.toolResults` will fill in the
///     output and flip the status to `.ok`/`.error`)
/// - `.toolResults(results)` → fills the most recent still-`.running`
///   tool row(s) with `output` and `status`. Extra results beyond
///   the running set (defensive — should not happen in well-formed
///   data) are dropped.
func transcriptItems(from conversation: Conversation) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    for message in conversation.messages {
        switch message {
        case .user(let text):
            items.append(.user(text))

        case .assistant(let text, let toolCalls):
            // Skip wholly-empty assistant rows the same way the live
            // reducer would (see Agent.run: an empty assistant
            // message is never persisted to history). A loaded
            // session that was hand-edited with one is rendered as
            // a single space so the user sees a placeholder rather
            // than a missing turn.
            if !text.isEmpty {
                items.append(.assistant(text: text))
            }
            for call in toolCalls {
                items.append(.tool(ToolView(
                    name: call.name,
                    summary: ToolView.summary(for: call),
                    output: "",
                    status: .running,
                    expanded: false,
                    // swift-be0.7 #6: carry the originating call
                    // id so the `.toolResults` branch above
                    // can match the correct result to the
                    // correct row (see the long comment
                    // there).
                    callID: call.id,
                    startedAt: nil,
                    endedAt: nil
                )))
            }

        case .toolResults(let results):
            // swift-be0.7 #6: match each result to the running
            // row whose `callID` matches the result's
            // `callID`. The previous implementation matched
            // results to the *latest* running row regardless
            // of which call the result was for, which
            // shuffled output across the wrong tool cards
            // when the model emitted multiple / parallel
            // tool_use in one turn.
            //
            // Two layers of fallback preserve the historical
            // behavior for any pre-fix-up row that doesn't
            // carry a `callID`:
            //   1. exact match by `callID`
            //   2. latest running row whose name matches
            //      the result (defensive — for malformed /
            //      hand-rolled conversations)
            for result in results {
                let byID: Int? = items.lastIndex(where: {
                    if case .tool(let tv) = $0, tv.callID == result.callID, tv.status == .running {
                        return true
                    }
                    return false
                })
                let byName: Int? = items.lastIndex(where: {
                    if case .tool(let tv) = $0, tv.callID == nil, tv.name != "", tv.status == .running {
                        return true
                    }
                    return false
                })
                if let idx = byID ?? byName {
                    if case .tool(var tv) = items[idx] {
                        tv.output = result.output
                        tv.status = result.isError ? .error : .ok
                        items[idx] = .tool(tv)
                    }
                }
            }
        }
    }
    return items
}

// MARK: - Phase → task mapping (U3.3)

/// The three phases the current orchestrator emits (see
/// `Orchestrator.run`). We map them to a small fixed checklist so the
/// task row populates automatically during an orchestrated turn. A
/// single-agent turn emits none of these, so the row stays empty
/// unless the model itself calls `set_tasks`.
private enum OrchestratorPhase: String {
    case planning = "Planning"
    case coding = "Coding"
    case reviewing = "Reviewing"
    case unknown = ""
}

/// Reads `p`, looks for an `OrchestratorPhase` token, and updates
/// `m.tasks` accordingly. No-op for unknown phases so a custom
/// `phase("Compiling…")` doesn't surprise the row.
private func updateTasksFromPhase(_ m: inout TUIModel, _ p: String) {
    let lower = p.lowercased()
    let detected: OrchestratorPhase
    if lower.contains("planning") { detected = .planning }
    else if lower.contains("coding") || lower.contains("implement") { detected = .coding }
    else if lower.contains("reviewing") || lower.contains("review") { detected = .reviewing }
    else { detected = .unknown }
    guard detected != .unknown else { return }

    // Build the 3-item checklist; preserve the existing one if the
    // model populated it (don't clobber set_tasks).
    if !m.tasks.isEmpty { return }

    let order: [OrchestratorPhase] = [.planning, .coding, .reviewing]
    let labels: [OrchestratorPhase: String] = [
        .planning:  "Plan the change",
        .coding:    "Implement the plan",
        .reviewing: "Review the diff"
    ]
    let activeIdx = order.firstIndex(of: detected) ?? 0
    m.tasks = order.enumerated().map { i, phase in
        let state: TaskState
        if i < activeIdx      { state = .done }
        else if i == activeIdx { state = .running }
        else                  { state = .pending }
        return TaskItem(title: labels[phase] ?? "", state: state)
    }
    m.tasksVisible = true
}

// MARK: - Palette key handler

/// Routes a key event while the palette is open. The palette has its
/// own buffer (the `query` field); the rest of the model is frozen.
/// Pure function of the model + the event.
private func updatePaletteKey(_ m: inout TUIModel, _ key: KeyEvent) -> [Effect] {
    switch key {
    case .char(let c):
        m.palette.query.append(c)
        m.palette.filtered = fuzzy(m.palette.query)
        m.palette.selection = 0
        return []
    case .backspace:
        if !m.palette.query.isEmpty { m.palette.query.removeLast() }
        m.palette.filtered = fuzzy(m.palette.query)
        m.palette.selection = 0
        return []
    case .esc:
        // Close + restore the original input.
        m.input = m.palette.inputBackup
        m.palette = PaletteState()
        return []
    case .up:
        if !m.palette.filtered.isEmpty {
            m.palette.selection = (m.palette.selection - 1 + m.palette.filtered.count)
                % m.palette.filtered.count
        }
        return []
    case .down:
        if !m.palette.filtered.isEmpty {
            m.palette.selection = (m.palette.selection + 1) % m.palette.filtered.count
        }
        return []
    case .enter:
        // Execute the selected command by emitting it as text. The
        // next iteration of the loop will see it as a regular Enter
        // on a `/cmd` line and route through `.runSlash`.
        let selected = m.palette.filtered[m.palette.selection].name
        m.input = InputState()
        m.input.text = selected
        m.input.cursor = selected.count
        m.palette = PaletteState()
        m.transcript.append(.user(selected))
        m.history.append(selected)
        m.activity = .thinking
        return [.runSlash(selected)]
    case .ctrl(let c) where c == "c":
        // Cancel the palette; restore the input. (We don't
        // propagate ^C to the turn because there's no turn.)
        m.input = m.palette.inputBackup
        m.palette = PaletteState()
        return []
    case .ctrl(let c) where c == "d":
        // Same as Esc: close without executing.
        m.input = m.palette.inputBackup
        m.palette = PaletteState()
        return []
    default:
        return []
    }
}

// MARK: - Tool click-to-expand (U4.2)

/// Toggles `expanded` on the tool view whose rendered line sits at
/// `row`. Walks the transcript in display order (same order the
/// renderer uses) and counts visual rows using the **same** `wrap`
/// helper the view uses, so the row→item mapping is accurate on
/// narrow terminals and on long wrapped output.
///
/// The previous version assumed 1 row per item, which mis-targeted
/// on long output (the second of two tools in a turn was always
/// hit instead of the first) and on 40×12 terminals (where every
/// transcript row wraps to 2+ visual lines). With real wrap math
/// and the memoized `cols` from the most recent resize, the
/// hit-test now lands on the right tool at every terminal size.
private func toggleToolExpandedAt(row: Int, cols: Int, in m: inout TUIModel) {
    // Walk the transcript; for each item, count the rows it would
    // actually render at the current terminal width and check if
    // the click falls in that range. The first tool whose display
    // range covers `row` is toggled.
    var rowCursor = 0
    for (idx, item) in m.transcript.enumerated() {
        let rowCount = renderedRowCount(for: item, cols: cols)
        if case .tool = item, row >= rowCursor, row < rowCursor + rowCount {
            // Toggle the matched tool. We toggle regardless of
            // which sub-row of the tool body was clicked — the
            // spec says "click to expand" applies to the whole
            // tool card, not just the headline.
            if case .tool(var tv) = m.transcript[idx] {
                tv.expanded.toggle()
                m.transcript[idx] = .tool(tv)
            }
            return
        }
        rowCursor += rowCount
    }
}

/// How many visual rows `item` would occupy in the transcript, at
/// the given terminal width. Uses the same `wrap` helper the view
/// uses (so the hit-test stays in lockstep with the render). Pure
/// function; safe to call from the reducer.
private func renderedRowCount(for item: TranscriptItem, cols: Int) -> Int {
    // The tool's own `renderToolView` builds headline + (optional)
    // expanded body. We mirror its shape here:
    //   - Headline: 1 row, possibly wrapped if name + summary is long.
    //     (For the headline we use a minimal string the view would
    //     produce: the symbol + name + summary. `wrap` is conservative
    //     on the input length — a long summary may wrap to 2 rows,
    //     which is what we want for the hit-test.)
    //   - Body: when expanded, the wrapped output. We call the same
    //     `wrap` helper the view calls.
    // The wrap budget (`cols`) is the raw terminal width; the view
    // subtracts 2 from `cols` for the 2-space indent. We don't
    // bother with that fudge here — the headline row's wrap is
    // worst-case and a 2-cell slop is well within hit-test
    // tolerance (the next item's start row is unaffected).
    let w = max(20, cols)
    switch item {
    case .tool(let tv):
        // Headline: symbol + name + summary + timer. The exact
        // string the view prints is not exposed; a generous lower
        // bound is `1 row` for the typical case, but a long
        // summary can wrap. We feed a representative string to
        // `wrap` and count. The connector (`╭ `, `├ `, `╰ `) is
        // part of the wrap budget, but `toggleToolExpandedAt`
        // doesn't know the per-tool connector (the run is computed
        // in the renderer). For hit-test purposes, +1 cell slop
        // is fine — the headline rarely wraps unless the
        // summary is unusually long.
        let headline = "  \(tv.name) — \(tv.summary) 0s"
        var rows = max(1, wrap(headline, cols: w).count)
        if tv.expanded && !tv.output.isEmpty {
            rows += max(1, wrap(tv.output, cols: max(20, w - 2)).count)
        }
        return rows
    case .shell(_, let output, _):
        // H3: shell passthrough rows. The view always renders the
        // full output (no expand/collapse) plus a 1-row headline
        // showing `!cmd`. We count the wrapped output; the
        // headline is always 1 row. The 2-cell indent is the
        // view's; mirroring it here keeps the click hit-test
        // aligned with the rendered body.
        let body = output.isEmpty ? 0 : max(1, wrap(output, cols: max(20, w - 2)).count)
        return 1 + body
    case .user(let s):
        return max(1, wrap("▸ " + s, cols: w).count)
    case .assistant(let s):
        return max(1, wrap("• " + s, cols: w).count)
    case .phase(let s):
        return max(1, wrap("⟳ " + s, cols: w).count)
    case .notice(let s):
        return max(1, wrap("ⓘ " + s, cols: w).count)
    case .error(let s):
        return max(1, wrap(s, cols: w).count)
    }
}
