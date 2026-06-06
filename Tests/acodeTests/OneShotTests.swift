import Foundation
import Testing
@testable import acode

@MainActor
@Test func test_oneshot_reads_file_then_answers() async throws {
    // Create a temp file under ProjectJail.root, since read_file is jailed.
    let name = "acode-oneshot-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    let body = "acode is a terminal coding agent."
    try body.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let call = ToolCall(
        id: "c1",
        name: "read_file",
        arguments: .object(["path": .string(name)])
    )
    let provider = FakeProvider(scripts: [
        [.toolCall(call), .done(stop: "tool_use", usage: Usage())],
        [.textDelta("It is a terminal coding agent."), .done(stop: "end_turn", usage: Usage())]
    ])

    var tools = ToolRegistry()
    registerStandardTools(&tools)
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))

    let answer = try await runOneShot(
        prompt: "read \(name) and tell me what it does",
        provider: provider,
        tools: tools,
        renderer: renderer
    )

    #expect(answer == "It is a terminal coding agent.")
}
