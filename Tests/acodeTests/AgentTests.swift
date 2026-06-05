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
