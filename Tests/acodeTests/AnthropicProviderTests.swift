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
    #expect(body["max_tokens"] as? Int == 8192)
    let systemBlocks = try #require(body["system"] as? [[String: Any]])
    #expect(systemBlocks.first?["text"] as? String == "You are a terminal coding agent.")
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

@Test func test_request_has_cache_control() throws {
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

    // System is an array of content blocks; the last carries a cache breakpoint.
    let systemBlocks = try #require(body["system"] as? [[String: Any]])
    let lastSystem = try #require(systemBlocks.last)
    let systemCache = try #require(lastSystem["cache_control"] as? [String: Any])
    #expect(systemCache["type"] as? String == "ephemeral")

    // The last tool carries a cache breakpoint.
    let tools = try #require(body["tools"] as? [[String: Any]])
    let lastTool = try #require(tools.last)
    let toolCache = try #require(lastTool["cache_control"] as? [String: Any])
    #expect(toolCache["type"] as? String == "ephemeral")

    // Still valid JSON.
    #expect(JSONSerialization.isValidJSONObject(body))
}
