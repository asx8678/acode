import Foundation
import Testing
@testable import acode

/// Records whether it ran, for loop assertions.
private nonisolated final class RanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var didRun: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct RecordingTool: Tool {
    let flag: RanFlag
    let requiresApproval = false

    static var schema: ToolSchema {
        ToolSchema(name: "record", description: "Records that it ran.", parameters: .object([:]))
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        flag.mark()
        return ToolOutput(output: "recorded")
    }
}

@MainActor
private func makeAgent(provider: any LLMProvider, flag: RanFlag) -> Agent {
    var registry = ToolRegistry()
    registry.register(RecordingTool(flag: flag))
    let renderer = Renderer(color: false, autoApprove: true, verbose: false)
    return Agent(profile: .generalist, provider: provider, tools: registry, renderer: renderer)
}

@MainActor
@Test func test_loop_tool_then_answer() async throws {
    let flag = RanFlag()
    let call = ToolCall(id: "c1", name: "record", arguments: .object([:]))
    let provider = FakeProvider(scripts: [
        [.toolCall(call), .done(stop: "tool_use", usage: Usage())],
        [.textDelta("final answer"), .done(stop: "end_turn", usage: Usage())]
    ])

    let agent = makeAgent(provider: provider, flag: flag)
    let answer = try await agent.run("do the thing")

    #expect(flag.didRun == true)
    #expect(answer == "final answer")
}

/// Thread-safe attempt counter for retry tests.
private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Retries, failing with 503 until the third attempt then succeeding.
/// `nonisolated` so the retried closure isn't main-actor-isolated.
private nonisolated func retryFailingTwice(_ counter: Counter) async throws -> String {
    try await connectWithRetry(max: 3) {
        let attempt = counter.increment()
        if attempt < 3 {
            throw AnthropicError.httpStatus(503)
        }
        return "ok"
    }
}

/// Retries while always throwing `CancellationError` (must not retry).
private nonisolated func retryAlwaysCancelling() async throws -> String {
    try await connectWithRetry(max: 3) {
        throw CancellationError()
    }
}

/// Retries while always throwing a non-retryable 400 (must fail fast).
private nonisolated func retryNonRetryable(_ counter: Counter) async throws -> String {
    try await connectWithRetry(max: 3) {
        _ = counter.increment()
        throw AnthropicError.httpStatus(400)
    }
}

@Test func test_retry_succeeds_after_failures() async throws {
    let counter = Counter()
    let result = try await retryFailingTwice(counter)
    #expect(result == "ok")
    #expect(counter.count == 3)
}

@Test func test_retry_passes_cancellation() async throws {
    let task = Task { try await retryAlwaysCancelling() }
    task.cancel()
    var thrown: Error?
    do {
        _ = try await task.value
    } catch {
        thrown = error
    }
    #expect(thrown is CancellationError)
}

@Test func test_retry_fails_fast_on_non_retryable_status() async {
    let counter = Counter()
    var thrown: Error?
    do {
        _ = try await retryNonRetryable(counter)
    } catch {
        thrown = error
    }
    #expect(thrown is AnthropicError)
    #expect(counter.count == 1)
}

@MainActor
@Test func test_loop_step_limit() async {
    let flag = RanFlag()
    let call = ToolCall(id: "c1", name: "record", arguments: .object([:]))
    let provider = FakeProvider(repeating: [.toolCall(call), .done(stop: "tool_use", usage: Usage())])

    let agent = makeAgent(provider: provider, flag: flag)
    await #expect(throws: AgentError.self) {
        _ = try await agent.run("loop forever")
    }
}
