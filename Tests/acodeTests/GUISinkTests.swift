import Foundation
import Testing
@testable import acode

/// Phase 0 de-risk spike: end-to-end proof that the **real** `Agent` can
/// be driven through the new `GUISink: RenderSink` into an `@Observable
/// ChatStore`, with **zero engine edits**.
///
/// Mirrors the runtime wiring that `SpikeWindow.start()` constructs,
/// minus the `NSWindow` + `NSHostingView`. The deterministic
/// `StubProvider` replays the same script the GUI uses. We:
///   1. Start `agent.run("hello")` on a background task.
///   2. Poll the store until `pendingApproval` is set (the agent
///      reached the tool call and parked the continuation).
///   3. Resolve the approval through the sink.
///   4. Await the agent task.
///   5. Assert the store accumulated the expected transcript.
///
/// This is the same code path a real GUI turn would take; if it works
/// here, the SwiftUI buttons-only surface is just a view over this
/// data. The test runs in the test bundle (no NSApp, no window), so
/// it's a pure seam proof.
@MainActor
@Suite(.serialized)
struct GUISinkSmokeTests {
    @Test func spike_runs_real_agent_through_gui_sink() async throws {
        // Mirror the spike's boot wiring exactly. No NSWindow —
        // everything below is engine + sink + store.
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

        // Run the turn. The agent will stream text, then issue a
        // run_shell call and park the approval continuation. We
        // resolve it from a sibling task.
        //
        // Mirrors the SwiftUI `ContentView.submit()` path: the view
        // calls `store.appendUser(text)` BEFORE invoking
        // `agent.run(text)`. The user entry is a UI concern; the
        // engine appends to its own `Conversation` separately.
        store.appendUser("hello")
        let agentTask = Task { @MainActor in
            try await agent.run("hello")
        }

        // Poll the store on the main actor. The provider yields
        // deltas with a 120ms gap, so the agent reaches the
        // approval gate in well under a second. We give it 5s as a
        // generous CI-bound.
        let approvalDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.pendingApproval == nil {
            if ContinuousClock.now >= approvalDeadline {
                Issue.record("Agent never reached approval gate; store.entries=\(store.entries.count)")
                agentTask.cancel()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Snapshot the partial state. By the time the agent is
        // parked at `approve`, it has already emitted the tool
        // call's `.toolStart` AND called `endAssistant` (which
        // commits the streamed deltas to a single `.assistant`
        // entry and clears `streamingText`). So we expect:
        //   * one .user entry (added above)
        //   * one .toolCall entry (the run_shell call)
        //   * one .usage entry (the turn's usage)
        //   * one .assistant entry (the committed streamed text)
        //   * NO live streaming text (it was committed at
        //     endAssistant, which runs before tool execution)
        let partialEntries = store.entries
        let userCount = partialEntries.filter {
            if case .user = $0.kind { return true } else { return false }
        }.count
        let assistantCount = partialEntries.filter {
            if case .assistant = $0.kind { return true } else { return false }
        }.count
        let toolCallCount = partialEntries.filter {
            if case .toolCall(let name, _) = $0.kind { return name == "run_shell" }
            else { return false }
        }.count
        #expect(userCount == 1, "expected one .user entry, got \(userCount)")
        #expect(assistantCount == 1, "expected one committed .assistant entry, got \(assistantCount)")
        #expect(toolCallCount == 1, "expected one run_shell tool call entry, got \(toolCallCount)")
        #expect(store.streamingText.isEmpty, "streaming text was committed at endAssistant; expected empty buffer")
        #expect(store.pendingApproval?.name == "run_shell")

        // The agent is parked inside the sink's `withCheckedContinuation`.
        // Resolve it as the SwiftUI Approve button would.
        if let pending = store.pendingApproval {
            sink.resolveApproval(callID: pending.id, approved: true)
            store.clearApproval()
        }

        // Await the agent turn. It should: run the tool (echo), get
        // the result, loop back, stream the final text, and return.
        let answer = try await agentTask.value
        #expect(answer.contains("Done!"), "expected final answer text, got \(answer)")

        // Final transcript sanity: the tool result landed, both
        // streaming texts were committed, and a usage entry exists.
        let finalEntries = store.entries
        let toolResultCount = finalEntries.filter {
            if case .toolResult(let name, _, _) = $0.kind { return name == "run_shell" }
            else { return false }
        }.count
        let finalAssistantCount = finalEntries.filter {
            if case .assistant = $0.kind { return true } else { return false }
        }.count
        let usageCount = finalEntries.filter {
            if case .usage = $0.kind { return true } else { return false }
        }.count

        #expect(toolResultCount == 1, "expected one run_shell tool result entry")
        #expect(finalAssistantCount >= 1, "expected at least one committed .assistant entry")
        #expect(usageCount >= 1, "expected at least one .usage entry")
        #expect(store.pendingApproval == nil, "approval should be cleared")
        #expect(store.isStreaming == false, "streaming should be off after turn end")
    }

    @Test func spike_deny_blocks_tool_and_agent_continues() async throws {
        // Same wiring, but the user denies the tool call. The agent
        // should still loop (with a "User denied" tool result) and
        // emit a final text from the second script.
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

        let agentTask = Task { @MainActor in
            try await agent.run("hello")
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.pendingApproval == nil {
            if ContinuousClock.now >= deadline {
                Issue.record("Agent never reached approval gate")
                agentTask.cancel()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // User entry is a view-side concern; mirror the view's
        // submit handler so the post-deny transcript reflects what a
        // real GUI turn would produce.
        store.appendUser("hello (deny)")

        if let pending = store.pendingApproval {
            sink.resolveApproval(callID: pending.id, approved: false)
            store.clearApproval()
        }

        let answer = try await agentTask.value
        #expect(answer.contains("Done!"))

        // The tool result should be the denial message.
        let denial = store.entries.first {
            if case .toolResult(_, let output, let isError) = $0.kind {
                return isError && output.contains("denied")
            }
            return false
        }
        #expect(denial != nil, "expected a 'denied' tool result entry")
    }
}
