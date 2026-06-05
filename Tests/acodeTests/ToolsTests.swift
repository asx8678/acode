import Foundation
import Testing
@testable import acode

private struct ToolA: Tool {
    var requiresApproval = false
    static var schema: ToolSchema {
        ToolSchema(name: "a", description: "Tool A.", parameters: .object([:]))
    }
    func run(_ args: JSONValue) async -> ToolOutput { ToolOutput(output: "a-ran") }
}

private struct ToolB: Tool {
    var requiresApproval = false
    static var schema: ToolSchema {
        ToolSchema(name: "b", description: "Tool B.", parameters: .object([:]))
    }
    func run(_ args: JSONValue) async -> ToolOutput { ToolOutput(output: "b-ran") }
}

private struct ApprovalTool: Tool {
    var requiresApproval = true
    static var schema: ToolSchema {
        ToolSchema(name: "danger", description: "Needs approval.", parameters: .object([:]))
    }
    func run(_ args: JSONValue) async -> ToolOutput { ToolOutput(output: "danger-ran") }
}

@Test func test_registry_allowlist() {
    var registry = ToolRegistry()
    registry.register(ToolA())
    registry.register(ToolB())

    let allowed = registry.schemas(allowed: ["a"])
    #expect(allowed.count == 1)
    #expect(allowed.first?.name == "a")

    let all = registry.schemas(allowed: nil)
    #expect(Set(all.map(\.name)) == ["a", "b"])
}

@Test func test_registry_execute() async {
    var registry = ToolRegistry()
    registry.register(ToolA())
    registry.register(ApprovalTool())

    // (1) Unknown tool name -> isError.
    let unknown = await registry.execute(
        ToolCall(id: "u1", name: "missing", arguments: .object([:])),
        approve: { _ in true }
    )
    #expect(unknown.isError == true)
    #expect(unknown.callID == "u1")

    // (2) requiresApproval && approve == false -> denied.
    let denied = await registry.execute(
        ToolCall(id: "d1", name: "danger", arguments: .object([:])),
        approve: { _ in false }
    )
    #expect(denied.isError == true)
    #expect(denied.output == "User denied this action.")

    // (3) Stub tool executed with approval -> success, callID stamped.
    let ok = await registry.execute(
        ToolCall(id: "ok1", name: "a", arguments: .object([:])),
        approve: { _ in true }
    )
    #expect(ok.isError == false)
    #expect(ok.callID == "ok1")
    #expect(ok.output == "a-ran")
}
