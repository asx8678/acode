import Foundation

/// Default Anthropic model id. Config (T3.7) will override this.
nonisolated let defaultAnthropicModel = "claude-sonnet-4-5"

/// Default max output tokens for an Anthropic request (decision D2).
private nonisolated let anthropicMaxTokens = 4096

/// Errors surfaced by the Anthropic provider.
enum AnthropicError: Error, CustomStringConvertible {
    case missingAPIKey
    case httpStatus(Int, message: String)
    case malformedResponse

    var description: String {
        switch self {
        case .missingAPIKey:
            return "ANTHROPIC_API_KEY is not set."
        case .httpStatus(let code, let message):
            return message.isEmpty
                ? "Anthropic API error (HTTP \(code))."
                : "Anthropic API error (HTTP \(code)): \(message)"
        case .malformedResponse:
            return "Malformed response from the Anthropic API."
        }
    }
}

/// An `LLMProvider` backed by the Anthropic Messages API over SSE streaming.
///
/// The HTTP status is validated before the stream is returned, so a transport
/// or non-2xx failure throws from `stream(...)` (retriable per invariant B7);
/// errors during iteration are surfaced, never retried.
struct AnthropicProvider: LLMProvider {
    var contextWindow = 200_000

    /// The Messages endpoint. Documented invariant: this is a fixed, valid
    /// literal URL, so the force-unwrap is known-safe (§D).
    private nonisolated static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Model used when the per-call `model` argument is nil.
    var configuredModel: String?

    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw AnthropicError.missingAPIKey
        }

        let resolvedModel = model ?? configuredModel
        let body = Self.makeRequestBody(system: system, messages: messages, tools: tools, model: resolvedModel)
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data

        // Establish the connection and validate status BEFORE returning the
        // stream, so failures here are retriable (invariant B7).
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = await ProviderError.body(from: bytes)
            throw AnthropicError.httpStatus(http.statusCode, message: message)
        }

        return AsyncThrowingStream { continuation in
            let producer = Task {
                let assembler = ResponseAssembler()
                do {
                    for try await line in bytes.lines {
                        for event in Self.events(forSSELines: [line], assembler: assembler) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    // Surface mid-stream errors; never retry (invariant B7).
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Maps SSE lines to events using a shared assembler. Pure and network-free
    /// so the producer loop and tests share one code path.
    nonisolated static func events(forSSELines lines: [String], assembler: ResponseAssembler) -> [StreamEvent] {
        var out: [StreamEvent] = []
        for line in lines {
            if line.isEmpty || line.hasPrefix("event:") {
                continue
            }
            guard line.hasPrefix("data:") else {
                continue
            }
            var payload = String(line.dropFirst("data:".count))
            if payload.hasPrefix(" ") {
                payload.removeFirst()
            }
            out.append(contentsOf: assembler.ingest(payload))
        }
        return out
    }

    // MARK: - Request construction (testable; no network)

    /// Builds the Anthropic Messages request body. Factored out so tests can
    /// assert JSON shape without a network call.
    nonisolated static func makeRequestBody(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) -> [String: Any] {
        // System prompt as content blocks with a cache breakpoint on the last
        // block (prompt caching, T3.4). An empty system stays a plain string.
        let systemValue: Any
        if system.isEmpty {
            systemValue = system
        } else {
            systemValue = [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"]
                ] as [String: Any]
            ]
        }

        // Tool definitions; cache_control goes on the LAST tool only, since the
        // Anthropic API allows a single breakpoint at the end of the array.
        var toolBlocks: [[String: Any]] = tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.parameters.anyValue
            ] as [String: Any]
        }
        if !toolBlocks.isEmpty {
            toolBlocks[toolBlocks.count - 1]["cache_control"] = ["type": "ephemeral"]
        }

        let body: [String: Any] = [
            "model": model ?? defaultAnthropicModel,
            "max_tokens": anthropicMaxTokens,
            "stream": true,
            "system": systemValue,
            "messages": messages.map(convert(message:)),
            "tools": toolBlocks
        ]
        return body
    }

    private nonisolated static func convert(message: Message) -> [String: Any] {
        switch message {
        case .user(let text):
            return [
                "role": "user",
                "content": [["type": "text", "text": text]]
            ]
        case .assistant(let text, let toolCalls):
            var content: [[String: Any]] = []
            if !text.isEmpty {
                content.append(["type": "text", "text": text])
            }
            for call in toolCalls {
                content.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": call.arguments.anyValue
                ])
            }
            return ["role": "assistant", "content": content]
        case .toolResults(let results):
            let content: [[String: Any]] = results.map { result in
                [
                    "type": "tool_result",
                    "tool_use_id": result.callID,
                    "content": result.output,
                    "is_error": result.isError
                ]
            }
            return ["role": "user", "content": content]
        }
    }

}
