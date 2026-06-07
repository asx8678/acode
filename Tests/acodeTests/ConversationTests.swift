import Foundation
import Testing
@testable import acode

// MARK: - Helpers

private func toolCall(_ id: String) -> ToolCall {
    ToolCall(id: id, name: "read_file", arguments: .object(["path": .string("/tmp/\(id).txt")]))
}

private func toolResult(_ id: String, output: String = "ok") -> ToolResult {
    ToolResult(callID: id, output: output, isError: false)
}

/// Asserts the tool-call/tool-result pairing invariant (B2) holds.
private func assertPairsIntact(_ messages: [Message]) {
    for (index, message) in messages.enumerated() {
        switch message {
        case .assistant(_, let calls) where !calls.isEmpty:
            // Must be followed by matching tool results.
            guard index + 1 < messages.count,
                case .toolResults(let results) = messages[index + 1]
            else {
                Issue.record("assistant tool_use without following tool_results")
                return
            }
            let callIDs = Set(calls.map(\.id))
            let resultIDs = Set(results.map(\.callID))
            #expect(!callIDs.isDisjoint(with: resultIDs))

        case .toolResults(let results):
            // Must be preceded by matching assistant tool calls.
            guard index > 0,
                case .assistant(_, let calls) = messages[index - 1],
                !calls.isEmpty
            else {
                Issue.record("tool_results without preceding tool_use")
                return
            }
            let callIDs = Set(calls.map(\.id))
            let resultIDs = Set(results.map(\.callID))
            #expect(!callIDs.isDisjoint(with: resultIDs))

        default:
            break
        }
    }
}

// MARK: - Tests

@Test func test_compaction_keeps_pairs() {
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        var convo = Conversation()
        let turns = Int.random(in: 1...12, using: &rng)
        for t in 0..<turns {
            switch Int.random(in: 0...2, using: &rng) {
            case 0:
                convo.append(.user(String(repeating: "u", count: Int.random(in: 1...400, using: &rng))))
            default:
                // Paired assistant tool_use + tool_results.
                let id = "call-\(t)"
                convo.append(.assistant(
                    text: String(repeating: "a", count: Int.random(in: 0...200, using: &rng)),
                    toolCalls: [toolCall(id)]
                ))
                convo.append(.toolResults([
                    toolResult(id, output: String(repeating: "r", count: Int.random(in: 1...400, using: &rng)))
                ]))
            }
        }

        let window = Int.random(in: 10...120, using: &rng)
        let result = convo.compacted(for: window)
        assertPairsIntact(result)
    }
}

@Test func test_compaction_fits_budget() {
    var convo = Conversation()
    for i in 0..<40 {
        convo.append(.user("message \(i): " + String(repeating: "x", count: 200)))
    }

    let window = 100
    let result = convo.compacted(for: window)
    let total = result.reduce(0) { $0 + $1.tokenEstimate }
    #expect(total <= window)
    #expect(!result.isEmpty)
}

@Test func test_compaction_single_oversized() {
    var convo = Conversation()
    convo.append(.user(String(repeating: "z", count: 100_000)))

    let window = 50
    let result = convo.compacted(for: window)
    #expect(result.count >= 1)
    // The single message was truncated to fit the reserve bound.
    let total = result.reduce(0) { $0 + $1.tokenEstimate }
    #expect(total <= window)
}

@Test func test_compaction_never_empties_on_oversized_tool_result() {
    // A tool result larger than the window must not be split from its
    // tool_use partner and dropped, which would leave an empty message list.
    var convo = Conversation()
    convo.append(.user("do a thing"))
    convo.append(.assistant(text: "", toolCalls: [toolCall("c1")]))
    convo.append(.toolResults([toolResult("c1", output: String(repeating: "r", count: 100_000))]))

    let window = 10  // forces step 4 with a single oversized pair
    let result = convo.compacted(for: window)
    #expect(!result.isEmpty)
    assertPairsIntact(result)
}

// MARK: - Serialization (P1)

@Test func test_message_codable_roundtrip() throws {
    // User message
    let userMsg = Message.user("hello world")
    let userData = try JSONEncoder().encode(userMsg)
    let userDecoded = try JSONDecoder().decode(Message.self, from: userData)
    #expect(userDecoded == userMsg)

    // Assistant message with tool calls
    let toolCall = ToolCall(id: "call_1", name: "read_file", arguments: .object(["path": .string("/tmp/test.txt")]))
    let asstMsg = Message.assistant(text: "Let me read that file.", toolCalls: [toolCall])
    let asstData = try JSONEncoder().encode(asstMsg)
    let asstDecoded = try JSONDecoder().decode(Message.self, from: asstData)
    #expect(asstDecoded == asstMsg)

    // Tool results
    let results = [ToolResult(callID: "call_1", output: "file contents here", isError: false)]
    let toolMsg = Message.toolResults(results)
    let toolData = try JSONEncoder().encode(toolMsg)
    let toolDecoded = try JSONDecoder().decode(Message.self, from: toolData)
    #expect(toolDecoded == toolMsg)
}

@Test func test_conversation_codable_roundtrip() throws {
    var convo = Conversation()
    convo.append(.user("read /tmp/test.txt"))
    convo.append(.assistant(
        text: "I'll read it.",
        toolCalls: [ToolCall(id: "c1", name: "read_file", arguments: .object(["path": .string("/tmp/test.txt")]))]
    ))
    convo.append(.toolResults([ToolResult(callID: "c1", output: "hello", isError: false)]))
    convo.append(.assistant(text: "The file contains 'hello'.", toolCalls: []))

    let data = try JSONEncoder().encode(convo)
    let decoded = try JSONDecoder().decode(Conversation.self, from: data)
    #expect(decoded.messages.count == 4)
    // Verify B2: tool-call/tool-result pairing preserved
    // Message 1 is assistant with toolCalls, message 2 should be toolResults
    if case .assistant(_, let calls) = decoded.messages[1] {
        #expect(calls.first?.id == "c1")
    } else {
        Issue.record("Expected assistant message at index 1")
    }
    if case .toolResults(let results) = decoded.messages[2] {
        #expect(results.first?.callID == "c1")
    } else {
        Issue.record("Expected toolResults at index 2")
    }
}

// MARK: - Session serialization (P1: swift-be0.1)

@Test func test_session_save_load() throws {
    var convo = Conversation()
    convo.append(.user("test message"))
    convo.append(.assistant(text: "response", toolCalls: []))

    let session = Session(
        id: "test-session-1",
        title: "Test Session",
        model: "claude-sonnet-4-5",
        createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: Date(timeIntervalSince1970: 2000),
        conversation: convo
    )

    // Default memberwise init stamps the current schema version.
    #expect(session.version == Session.currentVersion)

    let data = try Session.encoder().encode(session)
    let decoded = try Session.decoder().decode(Session.self, from: data)

    #expect(decoded.id == "test-session-1")
    #expect(decoded.title == "Test Session")
    #expect(decoded.model == "claude-sonnet-4-5")
    #expect(decoded.version == Session.currentVersion)
    #expect(decoded.createdAt == session.createdAt)
    #expect(decoded.updatedAt == session.updatedAt)
    #expect(decoded.conversation.messages.count == 2)
}

@Test func test_session_encoder_uses_iso8601_dates() throws {
    // The on-disk format must be human-readable + stable across runs.
    let session = Session(
        id: "iso-check",
        title: nil,
        model: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
        conversation: Conversation()
    )

    let data = try Session.encoder().encode(session)
    let json = String(decoding: data, as: UTF8.self)

    // ISO 8601 with the Z suffix is what `.iso8601` produces.
    #expect(json.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    #expect(json.contains("\"updatedAt\" : \"2023-11-14T22:21:40Z\""))
    // Sorted + pretty output for diff-friendly on-disk files.
    #expect(json.contains("\n"))
    #expect(json.contains("\"conversation\""))
}

@Test func test_session_decoder_is_forward_compatible_without_version() throws {
    // A pre-versioned hand-rolled file must still decode to currentVersion
    // (B2-compatible: this is what older binaries wrote).
    let legacyJSON = """
    {
      "id": "legacy-1",
      "title": "no version key",
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-01-02T00:00:00Z",
      "conversation": { "messages": [] }
    }
    """

    let decoded = try Session.decoder().decode(Session.self, from: Data(legacyJSON.utf8))
    #expect(decoded.id == "legacy-1")
    #expect(decoded.title == "no version key")
    #expect(decoded.version == Session.currentVersion)
    #expect(decoded.conversation.messages.isEmpty)
}

@Test func test_session_roundtrip_preserves_b2_pairing() throws {
    // Hard test of the B2 invariant: an assistant tool_use immediately
    // followed by its .toolResults must survive a full Session encode→decode
    // round-trip in the same order, with the same call IDs.
    let call = ToolCall(
        id: "call_b2",
        name: "read_file",
        arguments: .object(["path": .string("/tmp/b2.txt")])
    )
    var convo = Conversation()
    convo.append(.user("read the file"))
    convo.append(.assistant(text: "Reading now.", toolCalls: [call]))
    convo.append(.toolResults([
        ToolResult(callID: "call_b2", output: "file contents", isError: false)
    ]))
    convo.append(.assistant(text: "It contains 'file contents'.", toolCalls: []))

    let session = Session(
        id: "b2-roundtrip",
        title: "B2 pairing",
        model: "claude-sonnet-4-5",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_999),
        conversation: convo
    )

    let data = try Session.encoder().encode(session)
    let decoded = try Session.decoder().decode(Session.self, from: data)

    // Order preserved.
    #expect(decoded.conversation.messages.count == 4)
    // Tool_use at index 1, tool_results at index 2 — unchanged.
    guard case .assistant(_, let calls) = decoded.conversation.messages[1] else {
        Issue.record("Expected assistant tool_use at index 1")
        return
    }
    #expect(calls.first?.id == "call_b2")

    guard case .toolResults(let results) = decoded.conversation.messages[2] else {
        Issue.record("Expected toolResults at index 2")
        return
    }
    #expect(results.first?.callID == "call_b2")
    #expect(results.first?.output == "file contents")

    // Pairing invariant check.
    assertPairsIntact(decoded.conversation.messages)
}

@Test func test_session_roundtrip_preserves_4message_fidelity() throws {
    // Round-trip fidelity acceptance (swift-be0.5, clause 1): a Session
    // whose conversation is the canonical four-message shape — a user
    // turn, an assistant turn carrying tool calls, the tool results
    // for those calls (B2 pair), and a SECOND user turn trailing the
    // pair — must survive an encode→decode round-trip as a single
    // byte-stable, value-equal record.
    //
    // The existing `test_session_roundtrip_preserves_b2_pairing`
    // covers the B2 pair + a final assistant, but stops short of a
    // trailing user turn and does not assert Equatable or
    // byte-stability. This test fills that exact gap.
    let callA = ToolCall(
        id: "call_fid_a",
        name: "read_file",
        arguments: .object(["path": .string("/tmp/fid-a.txt")])
    )
    let callB = ToolCall(
        id: "call_fid_b",
        name: "read_file",
        arguments: .object(["path": .string("/tmp/fid-b.txt")])
    )
    var convo = Conversation()
    convo.append(.user("read both files"))
    convo.append(.assistant(
        text: "Reading both files now.",
        toolCalls: [callA, callB]
    ))
    convo.append(.toolResults([
        ToolResult(callID: "call_fid_a", output: "contents of A", isError: false),
        ToolResult(callID: "call_fid_b", output: "contents of B", isError: false),
    ]))
    convo.append(.user("now summarize"))

    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let updated = Date(timeIntervalSince1970: 1_700_000_500)
    let session = Session(
        id: "fidelity-4msg",
        title: "four-message fidelity",
        model: "claude-sonnet-4-5",
        createdAt: created,
        updatedAt: updated,
        conversation: convo
    )

    // Encode.
    let encoded = try Session.encoder().encode(session)

    // Decode.
    let decoded = try Session.decoder().decode(Session.self, from: encoded)

    // Value-equal: every field round-trips. Field-by-field because
    // Session/Conversation are not currently Equatable — widening
    // their protocol list here would also change the error surface
    // of the (already-broken-under-Xcode) AgentSessionSeamTests,
    // which is out of scope for this bead. If a future bead adds
    // `Equatable` to both types, this collapses to a single
    // `decoded == session` line.
    #expect(decoded.id == session.id)
    #expect(decoded.title == session.title)
    #expect(decoded.model == session.model)
    #expect(decoded.version == session.version)
    #expect(decoded.createdAt == session.createdAt)
    #expect(decoded.updatedAt == session.updatedAt)
    #expect(decoded.conversation.messages == session.conversation.messages)

    // Order preserved end-to-end, including the trailing user turn
    // that distinguishes this case from the existing B2 test.
    #expect(decoded.conversation.messages.count == 4)
    guard case .user(let msg0) = decoded.conversation.messages[0] else {
        Issue.record("Expected .user at index 0")
        return
    }
    #expect(msg0 == "read both files")
    guard case .assistant(_, let midCalls) = decoded.conversation.messages[1] else {
        Issue.record("Expected .assistant(toolCalls:) at index 1")
        return
    }
    #expect(midCalls.map(\.id) == ["call_fid_a", "call_fid_b"])
    guard case .toolResults(let midResults) = decoded.conversation.messages[2] else {
        Issue.record("Expected .toolResults at index 2")
        return
    }
    #expect(Set(midResults.map(\.callID)) == ["call_fid_a", "call_fid_b"])
    guard case .user(let msg3) = decoded.conversation.messages[3] else {
        Issue.record("Expected second .user at index 3 (the trailing user turn)")
        return
    }
    #expect(msg3 == "now summarize")

    // B2 pair intact.
    assertPairsIntact(decoded.conversation.messages)

    // Byte-stable: re-encoding the decoded Session must produce the
    // exact same bytes. The encoder uses .iso8601 + .sortedKeys +
    // .prettyPrinted so the output is deterministic; if a future
    // change introduces nondeterminism (e.g. dictionary-key ordering
    // leakage from a custom JSONValue encoder), this catches it.
    let reencoded = try Session.encoder().encode(decoded)
    #expect(reencoded == encoded)
}
