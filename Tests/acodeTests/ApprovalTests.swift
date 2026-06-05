import Foundation
import Testing
@testable import acode

@Test func test_execute_denied_blocks() async throws {
    let name = "acode-denied-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = "before TARGET after"
    try original.write(to: url, atomically: true, encoding: .utf8)

    var registry = ToolRegistry()
    registry.register(EditFileTool())

    let call = ToolCall(
        id: "deny-1",
        name: "edit_file",
        arguments: .object([
            "path": .string(name),
            "old_str": .string("TARGET"),
            "new_str": .string("CHANGED")
        ])
    )
    let result = await registry.execute(call, approve: { _ in false })

    #expect(result.isError == true)
    #expect(result.output == "User denied this action.")
    // File must be untouched.
    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after == original)
}

@Test func test_execute_approved_runs() async throws {
    let name = "acode-approved-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: url) }
    try "before TARGET after".write(to: url, atomically: true, encoding: .utf8)

    var registry = ToolRegistry()
    registry.register(EditFileTool())

    let call = ToolCall(
        id: "approve-1",
        name: "edit_file",
        arguments: .object([
            "path": .string(name),
            "old_str": .string("TARGET"),
            "new_str": .string("CHANGED")
        ])
    )
    let result = await registry.execute(call, approve: { _ in true })

    #expect(result.isError == false)
    #expect(result.callID == "approve-1")
    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after == "before CHANGED after")
}
