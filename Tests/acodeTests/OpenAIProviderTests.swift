import Foundation
import Testing
@testable import acode

@Test func test_openai_request_body() throws {
    let toolSchema = ToolSchema(
        name: "read_file",
        description: "Read a file.",
        parameters: Schema.object(
            ["path": (type: "string", description: "File path.")],
            required: ["path"]
        )
    )

    // MARK: Responses API shape

    let responsesBody = OpenAIProvider.makeResponsesRequestBody(
        system: "You are a terminal coding agent.",
        messages: [.user("Read README.md")],
        tools: [toolSchema],
        model: "gpt-test-model"
    )

    #expect(responsesBody["model"] as? String == "gpt-test-model")
    #expect(responsesBody["stream"] as? Bool == true)

    let input = try #require(responsesBody["input"] as? [[String: Any]])
    #expect(input.first?["role"] as? String == "system")
    #expect(input.first?["content"] as? String == "You are a terminal coding agent.")
    #expect(input.contains { $0["role"] as? String == "user" })

    // Responses tools are flat function objects with a JSON-Schema parameters block.
    let responsesTools = try #require(responsesBody["tools"] as? [[String: Any]])
    let responsesTool = try #require(responsesTools.first)
    #expect(responsesTool["type"] as? String == "function")
    #expect(responsesTool["name"] as? String == "read_file")
    let responsesParams = try #require(responsesTool["parameters"] as? [String: Any])
    #expect(responsesParams["type"] as? String == "object")
    #expect(responsesParams["properties"] != nil)

    #expect(JSONSerialization.isValidJSONObject(responsesBody))

    // MARK: Chat Completions shape

    let chatBody = OpenAIProvider.makeChatRequestBody(
        system: "You are a terminal coding agent.",
        messages: [.user("Read README.md")],
        tools: [toolSchema],
        model: "gpt-test-model"
    )

    #expect(chatBody["model"] as? String == "gpt-test-model")
    #expect(chatBody["stream"] as? Bool == true)

    let chatMessages = try #require(chatBody["messages"] as? [[String: Any]])
    #expect(chatMessages.first?["role"] as? String == "system")
    #expect(chatMessages.first?["content"] as? String == "You are a terminal coding agent.")
    #expect(chatMessages.contains { $0["role"] as? String == "user" })

    // Chat tools use the {type: function, function: {...}} wrapper.
    let chatTools = try #require(chatBody["tools"] as? [[String: Any]])
    let chatTool = try #require(chatTools.first)
    #expect(chatTool["type"] as? String == "function")
    let function = try #require(chatTool["function"] as? [String: Any])
    #expect(function["name"] as? String == "read_file")
    #expect(function["description"] as? String == "Read a file.")
    let chatParams = try #require(function["parameters"] as? [String: Any])
    #expect(chatParams["type"] as? String == "object")
    #expect(chatParams["properties"] != nil)

    #expect(JSONSerialization.isValidJSONObject(chatBody))

    // Both bodies must serialize to valid JSON data.
    #expect(throws: Never.self) {
        _ = try JSONSerialization.data(withJSONObject: responsesBody)
        _ = try JSONSerialization.data(withJSONObject: chatBody)
    }
}
