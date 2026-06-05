import Foundation
import Testing
@testable import acode

/// A test double that replays a scripted sequence of stream events in order.
final class FakeProvider: LLMProvider {
    let contextWindow: Int
    private let script: [StreamEvent]

    init(script: [StreamEvent], contextWindow: Int = 200_000) {
        self.script = script
        self.contextWindow = contextWindow
    }

    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Test func test_fake_provider_stream() async throws {
    let scriptedCall = ToolCall(id: "call-1", name: "read_file", arguments: .object([:]))
    let provider = FakeProvider(script: [
        .textDelta("hello"),
        .toolCall(scriptedCall),
        .done(stop: "end_turn", usage: Usage(input: 10, output: 5))
    ])

    var received: [StreamEvent] = []
    let stream = try await provider.stream(system: "", messages: [], tools: [], model: nil)
    for try await event in stream {
        received.append(event)
    }

    #expect(received.count == 3)
    guard case .textDelta(let text) = received[0] else {
        Issue.record("Expected textDelta first.")
        return
    }
    #expect(text == "hello")
    guard case .toolCall(let call) = received[1] else {
        Issue.record("Expected toolCall second.")
        return
    }
    #expect(call.id == "call-1")
    guard case .done(let stop, let usage) = received[2] else {
        Issue.record("Expected done last.")
        return
    }
    #expect(stop == "end_turn")
    #expect(usage.input == 10)
    #expect(usage.output == 5)
}
