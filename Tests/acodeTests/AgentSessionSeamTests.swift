import Foundation
import Testing
@testable import acode

// MARK: - Agent seam (Step 0: history getter + restore writer)

@MainActor
@Test func test_agent_history_round_trip() async throws {
    // A round-trip: agent.run() → reads back via `history` →
    // restores via `restore(_:)` → reads back via `history` again
    // must yield the same messages. This is the foundational
    // invariant of the session-persistence seam: save/load must be
    // transparent to the conversation.
    let provider = FakeProvider(script: [
        .textDelta("hi back"),
        .done(stop: "end_turn", usage: Usage())
    ])
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let agent = Agent(
        profile: .generalist,
        provider: provider,
        tools: ToolRegistry(),
        renderer: renderer
    )

    _ = try? await agent.run("hi")
    let after = agent.history.messages
    #expect(after.count == 2)
    guard case .user(let userText) = after[0] else {
        Issue.record("Expected first message to be .user; got \(after[0])")
        return
    }
    #expect(userText == "hi")
    guard case .assistant(let assistantText, let calls) = after[1] else {
        Issue.record("Expected second message to be .assistant; got \(after[1])")
        return
    }
    #expect(assistantText == "hi back")
    #expect(calls.isEmpty)

    // Build a fresh agent; restore the history; check it matches.
    let second = FakeProvider(script: [
        .textDelta("hi back"),
        .done(stop: "end_turn", usage: Usage())
    ])
    let freshRenderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let freshAgent = Agent(
        profile: .generalist,
        provider: second,
        tools: ToolRegistry(),
        renderer: freshRenderer
    )
    #expect(freshAgent.history.messages.isEmpty)

    freshAgent.restore(agent.history)
    #expect(freshAgent.history.messages == agent.history.messages)
    #expect(freshAgent.history.messages.count == 2)
}

@MainActor
@Test func test_agent_restore_replaces_previous_history() async throws {
    // `restore(_:)` is a *replacement*, not an append. After
    // restoring, the agent's history is the new one — the old
    // messages must be gone. This is the contract the `/resume`
    // and `--resume` paths depend on.
    let provider = FakeProvider(script: [
        .textDelta("first"),
        .done(stop: "end_turn", usage: Usage())
    ])
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let agent = Agent(
        profile: .generalist,
        provider: provider,
        tools: ToolRegistry(),
        renderer: renderer
    )
    _ = try? await agent.run("turn one")
    #expect(agent.history.messages.count == 2)

    // Build a different conversation and restore it.
    var newHistory = Conversation()
    newHistory.append(.user("turn two"))
    newHistory.append(.assistant(text: "second", toolCalls: []))
    agent.restore(newHistory)
    #expect(agent.history.messages.count == 2)
    guard case .user(let t) = agent.history.messages[0] else {
        Issue.record("Expected restored history's first message to be .user(\"turn two\")")
        return
    }
    #expect(t == "turn two")
}

@MainActor
@Test func test_agent_history_is_value_typed() async throws {
    // `history` returns a value copy, not a live alias. Mutating
    // the returned value must not affect the agent's internal
    // state — callers (the JSON encoder for `/save`) need that
    // guarantee to avoid accidental mid-run mutation.
    let provider = FakeProvider(script: [
        .textDelta("ok"),
        .done(stop: "end_turn", usage: Usage())
    ])
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let agent = Agent(
        profile: .generalist,
        provider: provider,
        tools: ToolRegistry(),
        renderer: renderer
    )
    _ = try? await agent.run("x")
    #expect(agent.history.messages.count == 2)

    var snapshot = agent.history
    let before = snapshot.messages.count
    snapshot.append(.user("mutated-the-snapshot"))
    #expect(snapshot.messages.count == before + 1)
    // The agent's live history is unchanged.
    #expect(agent.history.messages.count == 2)
}

// MARK: - /save → /resume cycle through a real SessionStore

@MainActor
@Test func test_save_resume_cycle_preserves_b2_pairing() async throws {
    // The B2 invariant: every assistant tool_use is followed by
    // a matching .toolResults, and vice versa. A `/save` →
    // `/resume` cycle through the disk store must preserve this
    // (B2 is the contract the loaded model relies on; the
    // provider APIs reject an unpaired tool_use).
    let (store, dir): (SessionStore, URL) = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("acode-cycle-\(UUID().uuidString)")
        return (SessionStore(baseDir: d), d)
    }()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Build a session with a multi-tool-call assistant turn.
    let callA = ToolCall(id: "callA", name: "read_file", arguments: .object(["path": .string("/tmp/a")]))
    let callB = ToolCall(id: "callB", name: "read_file", arguments: .object(["path": .string("/tmp/b")]))
    var convo = Conversation()
    convo.append(.user("read both"))
    convo.append(.assistant(text: "Reading both files.", toolCalls: [callA, callB]))
    convo.append(.toolResults([
        ToolResult(callID: "callA", output: "contents of a", isError: false),
        ToolResult(callID: "callB", output: "contents of b", isError: false),
    ]))
    convo.append(.assistant(text: "Done.", toolCalls: []))

    let session = Session(
        id: "cycle-1",
        title: "paired turn",
        model: "claude-sonnet-4-5",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        conversation: convo
    )
    #expect(store.save(session))

    // Resume (load from disk).
    guard let loaded = store.load(id: "cycle-1") else {
        Issue.record("Expected cycle-1 to load after save")
        return
    }

    // The seeded history is what `agent.restore(_:)` would be
    // called with. Confirm the B2 invariant holds.
    let messages = loaded.conversation.messages
    #expect(messages.count == 4)
    guard case .assistant(_, let calls) = messages[1] else {
        Issue.record("Expected assistant tool_use at index 1")
        return
    }
    #expect(calls.map(\.id) == ["callA", "callB"])
    guard case .toolResults(let results) = messages[2] else {
        Issue.record("Expected .toolResults at index 2")
        return
    }
    let resultIDs = Set(results.map(\.callID))
    #expect(resultIDs == ["callA", "callB"])

    // Round-trip into a fresh agent and run another turn — the
    // new turn's `stream(...)` must see the unpaired structure
    // intact (the second-stream captured messages should mirror
    // what was loaded).
    let provider = FakeProvider(script: [
        .textDelta("ack"),
        .done(stop: "end_turn", usage: Usage())
    ])
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let agent = Agent(
        profile: .generalist,
        provider: provider,
        tools: ToolRegistry(),
        renderer: renderer
    )
    agent.restore(loaded.conversation)
    _ = try? await agent.run("next turn")

    // Provider saw the loaded 4 messages + the new turn's user
    // message that `Agent.run` appends before the first stream
    // call. The new assistant turn is appended to the agent's
    // conversation AFTER the stream call returns, so it's not in
    // the captured set — the script is one-shot and the agent
    // returns on the first iteration.
    //
    // The agent's stream() call is the single source of truth
    // for what the provider actually saw: the loaded 4
    // messages were sent verbatim (B2 intact) and the new
    // "next turn" user was appended on top.
    #expect(provider.capturedMessages.count == 5)
    // The first 4 are the loaded ones. Wrap the slice in `Array(...)`
    // so the comparison targets `[Message]` (the slice's
    // `ArraySlice<Message>` doesn't match `[Message]`'s `==`).
    #expect(Array(provider.capturedMessages[0...3]) == loaded.conversation.messages)
    // The 5th is the new "next turn" user message.
    guard case .user(let newUser) = provider.capturedMessages[4] else {
        Issue.record("Expected new .user at index 4")
        return
    }
    #expect(newUser == "next turn")
}
