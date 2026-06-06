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

/// Helpers for turning a failed HTTP response into a human-readable reason.
enum ProviderError {
    /// Maximum number of body bytes read from an error response.
    private nonisolated static let cap = 8192

    /// Reads up to `cap` bytes of an error response body and extracts a concise
    /// message. Both OpenAI and Anthropic wrap the reason in `{"error":{"message":…}}`
    /// (Anthropic also uses a top-level `{"error":…}`), so that field is
    /// preferred; otherwise the trimmed raw body is returned. Never throws —
    /// any failure yields an empty string so the caller falls back to the
    /// status code alone.
    nonisolated static func body(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= cap { break }
            }
        } catch {
            // Partial body is still useful; fall through with what we have.
        }
        guard !data.isEmpty else { return "" }

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = root["error"] as? String, !message.isEmpty {
                return message
            }
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
