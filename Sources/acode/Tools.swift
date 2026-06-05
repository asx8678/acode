import Foundation

/// The result of running a tool, before it is stamped with a call id.
struct ToolOutput: Sendable {
    var output: String
    var isError = false
    var summary = ""
}

/// A capability the model can invoke. `run` must not throw (invariant B3);
/// failures are reported via `ToolOutput.isError`.
protocol Tool: Sendable {
    static var schema: ToolSchema { get }
    var requiresApproval: Bool { get }
    func run(_ args: JSONValue) async -> ToolOutput
}

/// A collection of registered tools, keyed by schema name.
struct ToolRegistry {
    private var tools: [String: any Tool] = [:]

    /// Registers a tool under its `schema.name` (later registrations overwrite).
    mutating func register(_ t: any Tool) {
        tools[type(of: t).schema.name] = t
    }

    /// The schemas of all tools, or only those whose name is in `allowed`.
    func schemas(allowed: Set<String>?) -> [ToolSchema] {
        tools.values
            .map { type(of: $0).schema }
            .filter { allowed == nil || allowed?.contains($0.name) == true }
    }

    /// Executes a tool call, honoring approval and error semantics.
    func execute(_ call: ToolCall, approve: (ToolCall) -> Bool) async -> ToolResult {
        guard let tool = tools[call.name] else {
            return ToolResult(
                callID: call.id,
                output: "Unknown tool: \(call.name).",
                isError: true
            )
        }
        if tool.requiresApproval && !approve(call) {
            return ToolResult(
                callID: call.id,
                output: "User denied this action.",
                isError: true
            )
        }
        let result = await tool.run(call.arguments)
        return ToolResult(callID: call.id, output: result.output, isError: result.isError)
    }
}

/// Builds JSON-Schema fragments for tool parameter declarations.
enum Schema {
    /// Builds a `{"type":"object","properties":{...},"required":[...]}` envelope.
    static func object(
        _ props: [String: (type: String, description: String)],
        required: [String]
    ) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for (name, spec) in props {
            properties[name] = .object([
                "type": .string(spec.type),
                "description": .string(spec.description)
            ])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) })
        ])
    }
}
