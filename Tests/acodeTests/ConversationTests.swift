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
