import Foundation

/// Token usage reported by a provider for a turn.
struct Usage: Sendable {
    var input = 0
    var output = 0
}

/// An incremental event emitted while streaming a model response.
enum StreamEvent: Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    case done(stop: String, usage: Usage)
}

/// The JSON-Schema description of a tool, sent to the model.
struct ToolSchema: Codable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
}

/// A streaming chat-completion provider.
protocol LLMProvider: Sendable {
    var contextWindow: Int { get }
    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error>
}
