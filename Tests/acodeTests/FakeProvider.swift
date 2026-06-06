import Foundation
import Testing
@testable import acode

/// A test double that replays scripted stream events.
///
/// Three modes: a single script, a queue of per-call scripts (consumed in
/// order), or a repeating script yielded on every call (for the step-limit test).
nonisolated final class FakeProvider: LLMProvider, @unchecked Sendable {
    let contextWindow: Int
    private let lock = NSLock()
    private var queue: [[StreamEvent]]
    private let repeatScript: [StreamEvent]?
    private var _capturedMessages: [Message] = []

    /// The `messages` passed to the most recent `stream(...)` call.
    var capturedMessages: [Message] { lock.withLock { _capturedMessages } }

    /// Single-script mode (yielded once).
    init(script: [StreamEvent], contextWindow: Int = 200_000) {
        self.queue = [script]
        self.repeatScript = nil
        self.contextWindow = contextWindow
    }

    /// Queue mode: each `stream(...)` call consumes the next script in order.
    init(scripts: [[StreamEvent]], contextWindow: Int = 200_000) {
        self.queue = scripts
        self.repeatScript = nil
        self.contextWindow = contextWindow
    }

    /// Repeat mode: the same script is yielded on every call.
    init(repeating: [StreamEvent], contextWindow: Int = 200_000) {
        self.queue = []
        self.repeatScript = repeating
        self.contextWindow = contextWindow
    }

    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let next: [StreamEvent] = lock.withLock {
            _capturedMessages = messages
            if let repeatScript {
                return repeatScript
            } else if !queue.isEmpty {
                return queue.removeFirst()
            } else {
                return []
            }
        }
        return AsyncThrowingStream { continuation in
            for event in next {
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
