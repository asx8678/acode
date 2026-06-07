import Foundation
import AcodeCore

// MARK: - GUISink

/// `RenderSink` that forwards every agent event into a `@MainActor`-isolated
/// `ChatStore` for a SwiftUI view to bind to.
///
/// The structural twin of `TUISink`: same `nonisolated + @unchecked Sendable`
/// shape, same `pendingApprovals` dict + lock pattern for the `approve`
/// continuation, same `setApprovalPolicy` slot for short-circuit
/// auto-approvals. The only meaningful difference is the post target — the
/// TUI sink pushes `Msg` values into an MVU `AsyncStream`; this sink pushes
/// store mutations onto the main actor via `Task { @MainActor in … }`.
///
/// `nonisolated` for the same reason as `TUISink`: the package's default
/// isolation is `MainActor`, the `RenderSink` protocol requires `Sendable`
/// (so the methods must be callable from any actor), and the agent hops
/// between actors while running.
///
/// **Why a detached `Task` instead of `DispatchQueue.main.async`**: under
/// Swift 6 strict concurrency, an unstructured `Task { @MainActor in … }`
/// is the canonical way to hop into `MainActor` isolation from a
/// non-isolated context. The captured store is `@MainActor`-typed, so the
/// closure compiles only when the body runs on the main actor. Events
/// arrive in submission order on the main run loop, which is what SwiftUI
/// repaints.
nonisolated final class GUISink: RenderSink, @unchecked Sendable {
    private let store: ChatStore
    private let storeLock = NSLock()
    /// Continuations parked while the SwiftUI user decides. Keyed by
    /// `ToolCall.id`. The view's Approve/Deny buttons call
    /// `resolveApproval(callID:approved:)` to resume one. Mirrors
    /// `TUISink.pendingApprovals` exactly (lock + dict + remove-on-resume).
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]
    /// Optional shared approval policy. When set, `approve` short-circuits
    /// to `true` for tools the policy already approves. Mirrors
    /// `TUISink.approvalPolicy`.
    private weak var approvalPolicy: ApprovalPolicy?

    init(store: ChatStore, approvalPolicy: ApprovalPolicy? = nil) {
        self.store = store
        self.approvalPolicy = approvalPolicy
    }

    /// Updates the policy reference. Wired by the spike boot path after
    /// the `ApprovalPolicy` is constructed so the policy the sink checks
    /// is the same one the rest of the runtime sees.
    func setApprovalPolicy(_ policy: ApprovalPolicy) {
        storeLock.lock(); defer { storeLock.unlock() }
        self.approvalPolicy = policy
    }

    /// Resumes a parked approval continuation. Called by the SwiftUI
    /// `ApprovalCard` buttons. Idempotent: a second call for the same id
    /// is a no-op (the continuation is removed on first resume). Same
    /// semantics as `TUISink.resolveApproval`.
    func resolveApproval(callID: String, approved: Bool) {
        storeLock.lock()
        let cont = pendingApprovals.removeValue(forKey: callID)
        storeLock.unlock()
        cont?.resume(returning: approved)
    }

    /// Snapshots the approval policy reference under `storeLock` and
    /// returns it. Sync helper so the async `approve(_:)` can use the
    /// lock without tripping Swift 6's "NSLock from async context"
    /// rejection. The returned value is the same weak ref the caller
    /// would have read lock-free; the snapshot is the correct race-free
    /// version. (Identical pattern to `TUISink.snapshotPolicy`.)
    private nonisolated func snapshotPolicy() -> ApprovalPolicy? {
        storeLock.lock()
        defer { storeLock.unlock() }
        return approvalPolicy
    }

    /// Dispatches `apply` onto the main actor. All `RenderSink` event
    /// handlers funnel through this so the store is only ever mutated
    /// from `@MainActor` isolation. Cheap; non-async; safe from any
    /// thread.
    private nonisolated func hopToMain(_ apply: @escaping @MainActor @Sendable (ChatStore) -> Void) {
        Task { @MainActor [store] in
            apply(store)
        }
    }

    // MARK: - RenderSink (P0 contract)

    nonisolated func banner() {
        // The SwiftUI view renders its own welcome notice on appear.
    }

    nonisolated func streamText(_ s: String) {
        hopToMain { store in
            // `appendDelta` mutates `streamingText` and flips `isStreaming`.
            // No coalescing yet — that's a Phase 2 concern (per-tick
            // batching). 120ms between deltas in the stub is well below
            // SwiftUI's repaint cadence; even tight Anthropic streams
            // should be fine for a spike.
            store.appendDelta(s)
        }
    }

    nonisolated func endAssistant() {
        hopToMain { store in
            store.endStreaming()
        }
    }

    nonisolated func usage(_ u: Usage) {
        hopToMain { store in
            store.appendUsage(u)
        }
    }

    nonisolated func phase(_ p: String) {
        // SwiftUI spike ignores orchestrator phases; the transcript
        // notice is enough for a proof. (Future: a dedicated `Phase`
        // entry on the store, parallel to `TUIModel.phases`.)
        _ = p
    }

    nonisolated func toolStart(_ c: ToolCall) {
        hopToMain { store in
            store.appendToolCall(c)
        }
    }

    nonisolated func toolEnd(_ c: ToolCall, _ r: ToolResult) {
        hopToMain { store in
            store.appendToolResult(c, r)
        }
    }

    nonisolated func verboseLog(_ message: String) {
        // GUI mode ignores verbose logs. The HUD/status line carries
        // status info; verbose goes to stderr in line mode (and the
        // GUI doesn't have a stderr pane yet).
        _ = message
    }

    /// Approval gate. Short-circuits to `true` if the shared
    /// `ApprovalPolicy` already approves `c`. Otherwise parks a
    /// continuation under `storeLock`, posts the pending approval to
    /// the store, and waits for the SwiftUI view to call
    /// `resolveApproval(callID:approved:)` after the user taps
    /// Approve or Deny.
    ///
    /// **Race-freedom note**: the `pendingApprovals` dict is mutated
    /// under `storeLock` (this method) and under the same lock
    /// (`resolveApproval`). The store update is dispatched to the main
    /// actor *after* the continuation is parked, so the SwiftUI view
    /// can never observe `pendingApproval == nil` for a continuation
    /// that's already been registered. The order matters: park first,
    /// then publish.
    nonisolated func approve(_ c: ToolCall) async -> Bool {
        let policy = self.snapshotPolicy()
        if let policy = policy,
           policy.shouldAutoApprove(c.name, command: c.arguments["command"]?.stringValue) {
            return true
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            storeLock.lock()
            pendingApprovals[c.id] = cont
            storeLock.unlock()
            // Publish AFTER the continuation is parked, so the view's
            // button can never call `resolveApproval` for a continuation
            // we haven't stored yet.
            hopToMain { store in
                store.requestApproval(c)
            }
        }
    }
}
