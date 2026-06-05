import Foundation
import Testing
@testable import acode

@Test func test_anthropic_request_body() throws {
    let toolSchema = ToolSchema(
        name: "read_file",
        description: "Read a file.",
        parameters: Schema.object(
            ["path": (type: "string", description: "File path.")],
            required: ["path"]
        )
    )

    let body = AnthropicProvider.makeRequestBody(
        system: "You are a terminal coding agent.",
        messages: [.user("Read README.md")],
        tools: [toolSchema],
        model: "claude-test-model"
    )

    // Top-level keys present.
    #expect(body["model"] as? String == "claude-test-model")
    #expect(body["max_tokens"] as? Int == 4096)
    #expect(body["system"] as? String == "You are a terminal coding agent.")
    #expect(body["messages"] != nil)
    #expect(body["tools"] != nil)

    // tools[0].input_schema is the full object envelope.
    let tools = try #require(body["tools"] as? [[String: Any]])
    let first = try #require(tools.first)
    let inputSchema = try #require(first["input_schema"] as? [String: Any])
    #expect(inputSchema["type"] as? String == "object")
    #expect(inputSchema["properties"] != nil)
    #expect(inputSchema["required"] != nil)

    // Body must serialize to JSON cleanly.
    #expect(JSONSerialization.isValidJSONObject(body))
}
