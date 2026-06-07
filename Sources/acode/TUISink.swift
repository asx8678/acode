import Foundation
import AcodeCore

// MARK: - TUISink

/// `RenderSink` that posts every event into the MVU `Msg` stream. The
/// `Agent` owns one of these; the `TUIApp` loop owns the stream and
/// the screen renderer. This is the bridge from "agent speaks the line
/// protocol" to "model mutates, view repaints."
///
/// **Why the post target is re-targetable**: the constructor order in
/// `Acode.runTUISession` is "build sink → build agent (with sink) →
/// build TUIApp → TUIApp.run() creates the stream." The sink must be
/// fully constructed before the agent, but it can't have its post
/// target until the stream exists. A setter (called by `TUIApp.run()`
/// before any other code runs) bridges the gap.
///
/// Marked `nonisolated` because the package default-isolation is
/// MainActor; we want every method to be callable from the agent
/// (which hops between actors) and from the read loop (off-main).
nonisolated final class TUISink: RenderSink, @unchecked Sendable {
    private let postLock = NSLock()
    /// `nil` until `TUIApp.run()` wires it. All `post` calls are
    /// silently dropped while nil (which only happens in tests, never
    /// in production — `TUIApp.run` always sets it before yielding
    /// any `Msg`).
    private var postClosure: (@Sendable (Msg) -> Void)?

    /// Optional shared approval policy. When set, `approve` short-
    /// circuits to `true` for tools that match the policy. Mirrors
    /// `Renderer.policy`.
    private weak var approvalPolicy: ApprovalPolicy?

    /// Continuations parked while the user decides. Keyed by `ToolCall.id`.
    /// The loop calls `resolveApproval(id:approved:)` to resume one.
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]

    init(approvalPolicy: ApprovalPolicy? = nil) {
        self.approvalPolicy = approvalPolicy
    }

    /// Wires (or rewires) the post target. Called by `TUIApp.run`
    /// exactly once, before the first `Msg` is yielded.
    func setPost(_ p: @escaping @Sendable (Msg) -> Void) {
        postLock.lock(); defer { postLock.unlock() }
        self.postClosure = p
    }

    /// Updates the policy reference. The loop calls this once it
    /// finishes constructing the policy + agent so `approve` checks
    /// the latest state. (P3's `always` decision also flows through
    /// here indirectly — the loop calls `policy.allowAlways(name)`
    /// and then `resolveApproval`.)
    func setApprovalPolicy(_ policy: ApprovalPolicy) {
        postLock.lock(); defer { postLock.unlock() }
        self.approvalPolicy = policy
    }

    /// Resumes a parked approval continuation. Called by `TUIApp` on
    /// `.resolveApproval(_)` effects. Idempotent: a second call for
    /// the same id is a no-op (the continuation is removed on first
    /// resume).
    func resolveApproval(callID: String, approved: Bool) {
        postLock.lock()
        let cont = pendingApprovals.removeValue(forKey: callID)
        postLock.unlock()
        cont?.resume(returning: approved)
    }

    private nonisolated func post(_ msg: Msg) {
        postLock.lock()
        let closure = postClosure
        postLock.unlock()
        closure?(msg)
    }

    /// Snapshots the approval policy reference under `postLock` and
    /// returns it. Sync helper so the async `approve(_:)` can use
    /// the lock without tripping Swift 6's "NSLock from async
    /// context" rejection. The returned value is the same weak ref
    /// the caller would have read lock-free; the snapshot is the
    /// correct race-free version.
    private nonisolated func snapshotPolicy() -> ApprovalPolicy? {
        postLock.lock()
        defer { postLock.unlock() }
        return approvalPolicy
    }

    // MARK: - RenderSink (P0 contract)

    nonisolated func banner() {
        // The TUI renders its own welcome line on first frame; the
        // banner is for the line-mode `Renderer` only.
    }

    nonisolated func streamText(_ s: String) {
        post(.streamDelta(s))
    }

    nonisolated func endAssistant() {
        post(.assistantEnd)
    }

    nonisolated func usage(_ u: Usage) {
        post(.usage(u))
    }

    nonisolated func phase(_ p: String) {
        post(.phase(p, round: 1))
    }

    nonisolated func toolStart(_ c: ToolCall) {
        post(.toolStart(c))
    }

    nonisolated func toolEnd(_ c: ToolCall, _ r: ToolResult) {
        // The `set_tasks` tool's output is the new task list. The
        // model owns the canonical state, so we parse + post it as
        // a dedicated `Msg.setTasks` before the generic `.toolEnd`
        // (which appends the card to the transcript).
        if c.name == "set_tasks" {
            if let items = Self.parseTaskItems(from: r.output) {
                post(.setTasks(items))
            }
        }
        post(.toolEnd(c, r))
    }

    /// Parses a `set_tasks` tool result into `[TaskItem]`. The tool
    /// returns the echoed JSON array; we wrap it in `{"tasks": ...}`
    /// for the `JSONSerialization` round-trip. Returns `nil` on parse
    /// failure (the row simply doesn't update — no error to the user).
    private nonisolated static func parseTaskItems(from output: String) -> [TaskItem]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept either the bare array form (what the tool actually
        // emits) or the `{"tasks": [...]}` envelope (defensive — in
        // case a future change wraps it).
        guard let data = trimmed.data(using: .utf8) else { return nil }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap(Self.parseTaskItem)
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["tasks"] as? [[String: Any]] {
            return arr.compactMap(Self.parseTaskItem)
        }
        return nil
    }

    private nonisolated static func parseTaskItem(_ dict: [String: Any]) -> TaskItem? {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        let state: TaskState
        switch (dict["state"] as? String ?? "pending").lowercased() {
        case "done":    state = .done
        case "running": state = .running
        case "failed":  state = .failed
        default:        state = .pending
        }
        return TaskItem(title: title, state: state)
    }

    nonisolated func verboseLog(_ message: String) {
        // TUI mode ignores verbose logs. The HUD shows status info
        // instead; verbose goes to stderr in line mode.
        _ = message
    }

    /// Approval gate. Short-circuits to `true` if the shared
    /// `ApprovalPolicy` already approves `c`. Otherwise parks a
    /// continuation, posts `.approvalRequest(c)`, and waits for
    /// `TUIApp` to call `resolveApproval(callID:approved:)` after the
    /// user presses `y`/`n`/`a` (or a timeout — not implemented in P3).
    nonisolated func approve(_ c: ToolCall) async -> Bool {
        // Policy check first. The weak reference is mutated under
        // `postLock` (see `setApprovalPolicy`) so we have to snapshot
        // it under the same lock for genuine race-freedom — the agent
        // can call `approve` from any actor; a lock-free read could
        // observe a stale or in-flight `nil` mid-write. After the
        // snapshot we can safely call `shouldAutoApprove` outside
        // the lock.
        //
        // Swift 6 strict concurrency note: `NSLock.lock()` isn't
        // callable from an `async` context. We extract the snapshot
        // into a sync `nonisolated` helper (which CAN use the lock)
        // and call it from here.
        let policy = self.snapshotPolicy()
        if let policy = policy,
           policy.shouldAutoApprove(c.name, command: c.arguments["command"]?.stringValue) {
            return true
        }
        // Park + post + wait. The continuation resumes on the loop's
        // `resolveApproval(callID:approved:)` call.
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            postLock.lock()
            pendingApprovals[c.id] = cont
            postLock.unlock()
            post(.approvalRequest(c))
        }
    }
}
