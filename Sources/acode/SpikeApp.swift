import AppKit
import Foundation
import Observation
import SwiftUI
import AcodeCore

// MARK: - ChatStore

/// `@MainActor`-isolated, `@Observable` model the SwiftUI view binds to.
/// `GUISink` writes into it from any actor; the view reads from
/// `@MainActor`; SwiftUI repaints on every observed-property write.
///
/// `streamingText` + `isStreaming` model the in-flight assistant reply
/// (the SwiftUI view shows them as a single growing text block). At
/// `endAssistant`, the streamed text is committed to a single `Entry`
/// and `streamingText` resets — same pattern as how the TUI commits
/// the current delta buffer on `.assistantEnd`.
///
/// `pendingApproval` holds the `ToolCall` whose continuation is parked
/// in the `GUISink`. The view renders an `ApprovalCard` when this is
/// non-nil; the card's Approve/Deny buttons call
/// `sink.resolveApproval(callID:approved:)` and clear
/// `pendingApproval`.
@Observable
@MainActor
final class ChatStore {
    /// A single entry in the transcript. Identifiable for SwiftUI's
    /// `ForEach`; `id` is a fresh UUID per append so re-rendering the
    /// same logical content (e.g. the same tool name) doesn't collapse
    /// rows.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        enum Kind: Equatable {
            case notice(String)
            case user(String)
            case assistant(String)
            case toolCall(name: String, arguments: JSONValue)
            case toolResult(name: String, output: String, isError: Bool)
            case usage(input: Int, output: Int)
        }
    }

    /// Transcript entries in append order. The view's `ForEach` walks
    /// this; `streamingText` is rendered as a separate live row above
    /// the last committed entry while `isStreaming` is true.
    var entries: [Entry] = []
    /// The in-flight assistant text. Appended to by `streamText`
    /// deltas; committed to an `.assistant` entry on `endAssistant`.
    var streamingText: String = ""
    /// True between the first delta of a turn and `endAssistant`. Used
    /// by the view to render the live streaming row and to disable the
    /// input field.
    var isStreaming: Bool = false
    /// The tool call whose approval continuation is currently parked in
    /// the `GUISink`. Non-nil means the view should show an
    /// `ApprovalCard`.
    var pendingApproval: ToolCall?
    /// Free-form status line for the HUD ("idle", "running…", etc.).
    var statusLine: String = "ready"
    /// Number of completed turns this session. Useful for the stub
    /// driver to know when to stop.
    var turnCount: Int = 0

    // MARK: - Mutators (called by GUISink on the main actor)

    func appendNotice(_ s: String) {
        entries.append(Entry(kind: .notice(s)))
    }

    func appendUser(_ s: String) {
        entries.append(Entry(kind: .user(s)))
    }

    func appendToolCall(_ c: ToolCall) {
        entries.append(Entry(kind: .toolCall(name: c.name, arguments: c.arguments)))
    }

    func appendToolResult(_ c: ToolCall, _ r: ToolResult) {
        entries.append(Entry(kind: .toolResult(name: c.name, output: r.output, isError: r.isError)))
    }

    func appendUsage(_ u: Usage) {
        entries.append(Entry(kind: .usage(input: u.input, output: u.output)))
    }

    /// Records a streaming delta. Resets the streaming text on the
    /// first delta of a turn (defensive — `beginStreaming` is the
    /// canonical reset, but a stray `streamText` after a non-stream
    /// event shouldn't append to a stale buffer).
    func appendDelta(_ s: String) {
        if !isStreaming { beginStreaming() }
        streamingText += s
    }

    /// Begins a new streaming turn. Resets the buffer and flips the
    /// flag. Called by the view's submit handler before the agent runs.
    func beginStreaming() {
        streamingText = ""
        isStreaming = true
    }

    /// Commits the in-flight streaming text as a single `.assistant`
    /// entry and resets the buffer.
    func endStreaming() {
        if !streamingText.isEmpty {
            entries.append(Entry(kind: .assistant(streamingText)))
        }
        streamingText = ""
        isStreaming = false
    }

    /// Publishes a pending approval request from the `GUISink`. Called
    /// AFTER the continuation is parked in the sink, so the view can
    /// safely render the buttons and call back into
    /// `sink.resolveApproval`.
    func requestApproval(_ c: ToolCall) {
        pendingApproval = c
    }

    /// Clears the pending approval (called by the view after a
    /// button resolves it).
    func clearApproval() {
        pendingApproval = nil
    }

    /// Increments the turn counter and updates the HUD status line.
    func endTurn() {
        turnCount += 1
        statusLine = "ready · \(turnCount) turn\(turnCount == 1 ? "" : "s") completed"
    }
}

// MARK: - ContentView

/// The minimal SwiftUI view. A scrolling transcript, an inline
/// approval card, and an input bar.
///
/// `@Bindable` gives SwiftUI a binding into the `@Observable` store's
/// `$input` projection. The view holds a strong reference to the
/// `agent` and `sink` so it can submit turns and resolve approvals.
///
/// **Why a strong `agent` reference (not a closure)**: `Agent` is a
/// `@MainActor` class; the view is on `@MainActor`; passing the
/// reference is the simplest possible seam. SwiftUI's value-type view
/// holds a reference type, which is fine — the view's `body` is still
/// cheap to recompute (no view-graph mutation), and the reference
/// outlives every body invalidation because the store is held by the
/// `SpikeWindow` for the process's lifetime.
struct ContentView: View {
    @Bindable var store: ChatStore
    let sink: GUISink
    let agent: Agent
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // HUD: status line, turn count
            HStack {
                Text(store.statusLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Phase 0 spike")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.entries) { entry in
                            EntryRow(entry: entry)
                                .id(entry.id)
                        }
                        // The live streaming row. The "streaming" id
                        // is the scroll target while deltas arrive.
                        if store.isStreaming || !store.streamingText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Text("assistant")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 72, alignment: .trailing)
                                Text(store.streamingText)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id("streaming")
                        }
                        // Sentinel row — always at the bottom — so the
                        // auto-scroll lands below the last visible
                        // content even on tiny windows.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: store.entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: store.streamingText) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            // Approval card. Inline above the input bar so the user
            // sees both the tool's arguments and the action buttons
            // at the same time.
            if let pending = store.pendingApproval {
                ApprovalCard(call: pending) { approved in
                    sink.resolveApproval(callID: pending.id, approved: approved)
                    store.clearApproval()
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                TextField(
                    "Type a prompt and press Return…",
                    text: $input,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(submit)
                .disabled(store.isStreaming)

                Button("Send", action: submit)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.isStreaming || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            store.appendNotice("acode GUI spike — deterministic stub provider. Type a prompt and press Return.")
        }
    }

    /// Submits the input as a turn. The agent is `@MainActor`, so
    /// `try await agent.run(text)` runs on the main actor; the
    /// `await` suspension points (provider stream consumption,
    /// `withCheckedContinuation` in `GUISink.approve`) let
    /// `NSApp.run()` interleave window events between them.
    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isStreaming else { return }
        input = ""
        store.appendUser(text)
        store.beginStreaming()
        store.statusLine = "thinking…"
        Task { @MainActor in
            do {
                _ = try await agent.run(text)
            } catch is CancellationError {
                store.appendNotice("cancelled.")
            } catch {
                store.appendNotice("Error: \(error)")
            }
            store.endStreaming()
            store.endTurn()
        }
    }
}

// MARK: - EntryRow

/// Renders one transcript entry. Rounded card with a role tag, a
/// monospaced body, and a colour cue per kind.
///
/// The view is intentionally dumb — every formatting decision is
/// hard-coded so the spike is easy to scan for proof, not for
/// production polish.
struct EntryRow: View {
    let entry: ChatStore.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(roleLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(roleColor)
                .frame(width: 72, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                bodyContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var roleLabel: String {
        switch entry.kind {
        case .notice: return "·"
        case .user: return "you"
        case .assistant: return "assistant"
        case .toolCall: return "tool →"
        case .toolResult: return "tool ←"
        case .usage: return "usage"
        }
    }

    private var roleColor: Color {
        switch entry.kind {
        case .notice: return .secondary
        case .user: return .blue
        case .assistant: return .green
        case .toolCall: return .orange
        case .toolResult: return .orange
        case .usage: return .secondary
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch entry.kind {
        case .notice(let s):
            Text(s)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .italic()
                .textSelection(.enabled)
        case .user(let s):
            Text(s)
                .font(.body)
                .textSelection(.enabled)
        case .assistant(let s):
            Text(s)
                .font(.body)
                .textSelection(.enabled)
        case .toolCall(let name, let args):
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                if case .object(let dict) = args, !dict.isEmpty {
                    Text(argsDescription(dict))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        case .toolResult(let name, let output, let isError):
            VStack(alignment: .leading, spacing: 2) {
                Text(name + (isError ? "  " : "  "))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isError ? .red : .green)
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
        case .usage(let input, let output):
            Text("\(input) in / \(output) out")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// Renders a small `key=value` summary of a tool's arguments.
    private func argsDescription(_ dict: [String: JSONValue]) -> String {
        dict.sorted(by: { $0.key < $1.key })
            .map { key, value in
                let v: String
                switch value {
                case .string(let s): v = "\"\(s)\""
                case .number(let n): v = String(n)
                case .bool(let b): v = String(b)
                case .null: v = "null"
                default: v = "…"
                }
                return "\(key)=\(v)"
            }
            .joined(separator: "  ")
    }
}

// MARK: - ApprovalCard

/// The inline approval affordance. Shows the tool name + a one-line
/// summary of its arguments, then two buttons: Approve (default
/// action, ⏎) and Deny (esc).
///
/// The action closure is supplied by the view; it dispatches into the
/// `GUISink.resolveApproval(callID:approved:)` and clears the store's
/// `pendingApproval`.
struct ApprovalCard: View {
    let call: ToolCall
    let onDecision: (Bool) -> Void
    @FocusState private var approveFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Tool wants to run: \(call.name)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            if case .object(let dict) = call.arguments {
                ForEach(dict.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    Text("\(key): \(renderJSON(value))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                Button("Approve") { onDecision(true) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                Button("Deny") { onDecision(false) }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func renderJSON(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array(let arr): return "[\(arr.map(renderJSON).joined(separator: ", "))]"
        case .object(let dict):
            return "{ " + dict.sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \(renderJSON($0.value))" }
                .joined(separator: ", ") + " }"
        }
    }
}

// MARK: - StubProvider

/// Deterministic `LLMProvider` for the spike. No network, no API keys,
/// no randomness. Replays a queue of `[[StreamEvent]]` scripts; each
/// `stream(...)` call consumes the next script in order. The
/// `AsyncThrowingStream` producer runs on a **detached** task that
/// sleeps between yields, so the main actor is free to repaint
/// SwiftUI between deltas.
///
/// Two scripts by default:
/// 1. **First turn**: streams text + emits one `run_shell` tool call
///    that the user must approve. The agent will then loop.
/// 2. **Second turn**: streams the final text and `.done`s. The agent
///    returns and the turn ends.
///
/// Exceeding the queue returns an empty stream (the agent will see no
/// `textDelta` and no `toolCall`, and the empty-assistant guard will
/// skip persisting that turn — see `Agent.run`).
nonisolated final class StubProvider: LLMProvider, @unchecked Sendable {
    let contextWindow: Int = 200_000
    private let lock = NSLock()
    private var queue: [[StreamEvent]]

    init(scripts: [[StreamEvent]]) {
        self.queue = scripts
    }

    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let next: [StreamEvent] = lock.withLock {
            guard !queue.isEmpty else { return [] }
            return queue.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            // Detached so the sleep between deltas does not block the
            // main run loop. The `for try await` in `Agent.run`
            // resumes on the main actor and reads the next yielded
            // event between sleeps.
            Task.detached {
                for event in next {
                    continuation.yield(event)
                    // Visible streaming cadence. Long enough that
                    // the user can see text grow, short enough that
                    // the spike doesn't drag.
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                continuation.finish()
            }
        }
    }

    /// The canned scripts for the spike. Public so the AppKit boot
    /// path can pass it to the provider's init.
    static func spikeScripts() -> [[StreamEvent]] {
        let toolCall = ToolCall(
            id: "stub-call-1",
            name: "run_shell",
            arguments: .object([
                "command": .string("echo hello from the acode GUI spike")
            ])
        )
        return [
            // Turn 1: stream some intro text, then issue the tool call.
            [
                .textDelta("I'll "),
                .textDelta("run "),
                .textDelta("a "),
                .textDelta("shell "),
                .textDelta("command "),
                .textDelta("for "),
                .textDelta("you.\n"),
                .toolCall(toolCall),
                .done(stop: "tool_use", usage: Usage(input: 12, output: 24))
            ],
            // Turn 2: after the user approves and the tool runs, the
            // agent loops back and gets this script. Streams a final
            // answer, then ends the turn.
            [
                .textDelta("Done! "),
                .textDelta("The "),
                .textDelta("command "),
                .textDelta("ran "),
                .textDelta("successfully "),
                .textDelta("and "),
                .textDelta("echoed "),
                .textDelta("its "),
                .textDelta("greeting."),
                .done(stop: "end_turn", usage: Usage(input: 32, output: 16))
            ]
        ]
    }
}

// MARK: - SpikeWindow

/// AppKit bootstrap for the spike. Builds the store, sink, agent,
/// stub provider, and an `NSWindow` hosting the SwiftUI view, then
/// runs `NSApplication`.
///
/// This intentionally bypasses SwiftUI's `@main App` lifecycle
/// because the existing `Acode` command is itself `@main struct
/// Acode: AsyncParsableCommand`. Two `@main`s in one module is a
/// compile error; the AppKit interop path is the smallest possible
/// "host a SwiftUI view in a CLI" shim.
///
/// **Bootstrap order matters**:
/// 1. Construct the `ChatStore` (it's `@MainActor`, so we must be
///    on the main actor — `static start()` is `@MainActor`).
/// 2. Build the `GUISink` first (the agent needs a `RenderSink`).
/// 3. Build the `Agent` (the view needs a reference to submit
///    turns).
/// 4. Build the SwiftUI view, wrap in `NSHostingView`, install in an
///    `NSWindow`.
/// 5. `setActivationPolicy(.regular)` so the process becomes a
///    foreground app (Dock icon, focus, menu bar).
/// 6. `NSApp.run()` — blocks until the user closes the window.
///
/// The agent is held by the `ContentView` (and transitively by the
/// store's identity graph), so it lives for the process's lifetime.
/// No background task is needed at boot — the agent only runs when
/// the user submits a turn from the view.
@MainActor
enum SpikeWindow {
    static func start() {
        let store = ChatStore()
        let policy = ApprovalPolicy(autoApproveAll: false)
        let sink = GUISink(store: store, approvalPolicy: policy)
        let provider = StubProvider(scripts: StubProvider.spikeScripts())

        var tools = ToolRegistry()
        registerStandardTools(&tools)

        let agent = Agent(
            profile: .generalist,
            provider: provider,
            tools: tools,
            renderer: sink
        )

        let rootView = ContentView(store: store, sink: sink, agent: agent)
        let hosting = NSHostingView(rootView: rootView)
        // Auto-resizing: the hosting view tracks its parent frame.
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "acode — Phase 0 GUI spike"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        // Close button → quit. The spike has a single window; closing
        // it should terminate the process. (A real GUI would gate
        // this on a "quit when last window closes" preference, but
        // for a single-window spike, terminate is the right call.)
        window.delegate = WindowTerminator.shared
        window.makeKeyAndOrderFront(nil)

        let app = NSApplication.shared
        // `.regular` so we get a Dock icon + menu bar + focus.
        // `.accessory` would make it a background agent — wrong for
        // a spike the user is meant to interact with.
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        // Blocks until `NSApp.terminate(_:)` is called (or the user
        // closes the only window and the terminator delegate calls
        // `NSApp.terminate(nil)`).
        app.run()
    }
}

/// Tiny `NSWindowDelegate` that calls `NSApp.terminate(nil)` when the
/// last window closes. Held as a `.shared` singleton because
/// `NSWindow.delegate` is `weak` and the window itself doesn't retain
/// the delegate — without a strong reference, the delegate would be
/// deallocated immediately and the closure wouldn't fire.
///
/// The single-window nature of the spike makes "last window close"
/// equivalent to "quit". A real multi-window GUI would track an
/// open-window count and only terminate on `applicationShouldTerminateAfterLastWindowClosed`.
@MainActor
private final class WindowTerminator: NSObject, NSWindowDelegate, @unchecked Sendable {
    static let shared = WindowTerminator()
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
