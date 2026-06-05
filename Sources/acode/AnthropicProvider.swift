import Foundation

/// Default Anthropic model id. Config (T3.7) will override this.
nonisolated let defaultAnthropicModel = "claude-sonnet-4-5"

/// Default max output tokens for an Anthropic request (decision D2).
private nonisolated let anthropicMaxTokens = 4096

/// Errors surfaced by the Anthropic provider.
enum AnthropicError: Error {
    case missingAPIKey
    case httpStatus(Int)
    case malformedResponse
}

/// An `LLMProvider` backed by the Anthropic Messages API.
///
/// This implementation performs a non-streaming request and then replays the
/// assembled result as a stream (text, then tool calls, then done). Real SSE
/// streaming arrives in T1.2.
struct AnthropicProvider: LLMProvider {
    let contextWindow = 200_000

    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw AnthropicError.missingAPIKey
        }

        let body = Self.makeRequestBody(system: system, messages: messages, tools: tools, model: model)
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages").unsafelyUnwrapped)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicError.httpStatus(http.statusCode)
        }

        let events = try Self.parseResponse(responseData)
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
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
        var body: [String: Any] = [
            "model": model ?? defaultAnthropicModel,
            "max_tokens": anthropicMaxTokens,
            "system": system,
            "messages": messages.map(convert(message:)),
            "tools": tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": jsonValueToAny(tool.parameters)
                ] as [String: Any]
            }
        ]
        if tools.isEmpty {
            body["tools"] = [[String: Any]]()
        }
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
                    "input": jsonValueToAny(call.arguments)
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

    // MARK: - Response parsing

    private nonisolated static func parseResponse(_ data: Data) throws -> [StreamEvent] {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            throw AnthropicError.malformedResponse
        }

        var text = ""
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "tool_use":
                if
                    let id = block["id"] as? String,
                    let name = block["name"] as? String {
                    let arguments = anyToJSONValue(block["input"] ?? [String: Any]())
                    calls.append(ToolCall(id: id, name: name, arguments: arguments))
                }
            default:
                break
            }
        }

        var usage = Usage()
        if let usageObject = root["usage"] as? [String: Any] {
            usage.input = (usageObject["input_tokens"] as? Int) ?? 0
            usage.output = (usageObject["output_tokens"] as? Int) ?? 0
        }
        let stop = (root["stop_reason"] as? String) ?? "end_turn"

        var events: [StreamEvent] = [.textDelta(text)]
        events.append(contentsOf: calls.map(StreamEvent.toolCall))
        events.append(.done(stop: stop, usage: usage))
        return events
    }

    // MARK: - JSONValue bridging

    private nonisolated static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .number(let n):
            return n
        case .string(let s):
            return s
        case .array(let arr):
            return arr.map(jsonValueToAny)
        case .object(let obj):
            return obj.mapValues(jsonValueToAny)
        }
    }

    private nonisolated static func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(arr.map(anyToJSONValue))
        case let obj as [String: Any]:
            return .object(obj.mapValues(anyToJSONValue))
        default:
            return .null
        }
    }
}
