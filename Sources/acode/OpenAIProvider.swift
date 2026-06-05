import Foundation

/// Default OpenAI model id. Config (T3.7) will override this.
nonisolated let defaultOpenAIModel = "gpt-4o"

/// The default OpenAI API base URL. A non-default value selects a local,
/// OpenAI-compatible server (Ollama, LM Studio) and skips authentication.
nonisolated let defaultOpenAIBaseURL = "https://api.openai.com/v1"

/// Errors surfaced by the OpenAI provider.
enum OpenAIError: Error {
    case missingAPIKey
    case httpStatus(Int)
    case malformedResponse
    case invalidBaseURL(String)
}

/// An `LLMProvider` backed by the OpenAI Responses API with a Chat Completions
/// fallback over SSE streaming.
///
/// The Responses endpoint is tried first; a 404 transparently falls back to
/// Chat Completions, which keeps local OpenAI-compatible servers (that only
/// expose `/chat/completions`) working. HTTP status is validated before the
/// stream is returned, so a transport or non-2xx failure throws from
/// `stream(...)` (retriable per invariant B7); errors during iteration are
/// surfaced, never retried.
struct OpenAIProvider: LLMProvider {
    var contextWindow: Int = 128_000

    /// Model used when the per-call `model` argument is nil.
    var configuredModel: String?

    /// API base URL; defaults to OpenAI. A non-default value targets a local
    /// server and disables API-key authentication.
    var baseURL: String = defaultOpenAIBaseURL

    private var isDefaultEndpoint: Bool { baseURL == defaultOpenAIBaseURL }

    func stream(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let key: String?
        if isDefaultEndpoint {
            guard let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty else {
                throw OpenAIError.missingAPIKey
            }
            key = envKey
        } else {
            // Local OpenAI-compatible servers typically need no auth.
            key = nil
        }

        let resolvedModel = model ?? configuredModel

        // Try the Responses API first; fall back to Chat Completions on 404.
        do {
            let body = Self.makeResponsesRequestBody(
                system: system, messages: messages, tools: tools, model: resolvedModel
            )
            return try await openStream(path: "responses", body: body, key: key, kind: .responses)
        } catch OpenAIError.httpStatus(404) {
            let body = Self.makeChatRequestBody(
                system: system, messages: messages, tools: tools, model: resolvedModel
            )
            return try await openStream(path: "chat/completions", body: body, key: key, kind: .chat)
        }
    }

    /// Which API shape a stream is parsing.
    private enum APIKind {
        case responses
        case chat
    }

    /// Opens an SSE stream against `{baseURL}/{path}`, validating status before
    /// returning so connection failures are retriable (invariant B7).
    private func openStream(
        path: String,
        body: [String: Any],
        key: String?,
        kind: APIKind
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let url = URL(string: "\(baseURL)/\(path)") else {
            throw OpenAIError.invalidBaseURL(baseURL)
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.httpStatus(http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let producer = Task {
                let assembler = OpenAIStreamAssembler(kind: kind == .chat ? .chat : .responses)
                do {
                    for try await line in bytes.lines {
                        for event in assembler.ingestSSELine(line) {
                            continuation.yield(event)
                        }
                    }
                    // Synthesize a terminal event if the stream ended without one.
                    for event in assembler.finish() {
                        continuation.yield(event)
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

    // MARK: - Request construction (testable; no network)

    /// Builds the Responses API request body. Factored out so tests can assert
    /// JSON shape without a network call.
    nonisolated static func makeResponsesRequestBody(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) -> [String: Any] {
        var input: [[String: Any]] = []
        if !system.isEmpty {
            input.append(["role": "system", "content": system])
        }
        input.append(contentsOf: messages.flatMap(convertToResponsesInput(message:)))

        let toolBlocks: [[String: Any]] = tools.map { tool in
            [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters.anyValue
            ] as [String: Any]
        }

        return [
            "model": model ?? defaultOpenAIModel,
            "input": input,
            "tools": toolBlocks,
            "stream": true
        ]
    }

    /// Builds the Chat Completions request body. Factored out so tests can
    /// assert JSON shape without a network call.
    nonisolated static func makeChatRequestBody(
        system: String,
        messages: [Message],
        tools: [ToolSchema],
        model: String?
    ) -> [String: Any] {
        var chatMessages: [[String: Any]] = []
        if !system.isEmpty {
            chatMessages.append(["role": "system", "content": system])
        }
        chatMessages.append(contentsOf: messages.flatMap(convertToChatMessages(message:)))

        let toolBlocks: [[String: Any]] = tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.anyValue
                ] as [String: Any]
            ] as [String: Any]
        }

        return [
            "model": model ?? defaultOpenAIModel,
            "messages": chatMessages,
            "tools": toolBlocks,
            "stream": true
        ]
    }

    // MARK: - Message conversion

    /// Converts a `Message` into Responses API `input` items.
    private nonisolated static func convertToResponsesInput(message: Message) -> [[String: Any]] {
        switch message {
        case .user(let text):
            return [["role": "user", "content": text]]
        case .assistant(let text, let toolCalls):
            var items: [[String: Any]] = []
            if !text.isEmpty {
                items.append(["role": "assistant", "content": text])
            }
            for call in toolCalls {
                items.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": encodeArguments(call.arguments)
                ])
            }
            return items
        case .toolResults(let results):
            return results.map { result in
                [
                    "type": "function_call_output",
                    "call_id": result.callID,
                    "output": result.output
                ]
            }
        }
    }

    /// Converts a `Message` into Chat Completions `messages` entries.
    private nonisolated static func convertToChatMessages(message: Message) -> [[String: Any]] {
        switch message {
        case .user(let text):
            return [["role": "user", "content": text]]
        case .assistant(let text, let toolCalls):
            var entry: [String: Any] = ["role": "assistant"]
            entry["content"] = text.isEmpty ? NSNull() : text
            if !toolCalls.isEmpty {
                entry["tool_calls"] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": encodeArguments(call.arguments)
                        ] as [String: Any]
                    ] as [String: Any]
                }
            }
            return [entry]
        case .toolResults(let results):
            return results.map { result in
                [
                    "role": "tool",
                    "tool_call_id": result.callID,
                    "content": result.output
                ]
            }
        }
    }

    // MARK: - JSONValue bridging

    /// Serializes tool-call arguments to a compact JSON string (the wire shape
    /// OpenAI expects for `arguments`).
    private nonisolated static func encodeArguments(_ value: JSONValue) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

/// Assembles OpenAI SSE `data:` payloads into `StreamEvent`s for both the
/// Responses and Chat Completions APIs.
///
/// A pure, network-free state machine. It never throws: unrecognized or
/// malformed payloads are ignored. For Chat Completions it accumulates
/// `tool_calls[].function.arguments` partial JSON across delta chunks, keyed by
/// tool-call index, and emits `.toolCall` when `finish_reason` is `tool_calls`.
nonisolated final class OpenAIStreamAssembler {
    enum Kind {
        case responses
        case chat
    }

    /// Per-index tool-call accumulator (Chat Completions).
    private struct PendingToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private let kind: Kind
    private var pendingTools: [Int: PendingToolCall] = [:]
    private var toolOrder: [Int] = []
    private var usage = Usage()
    private var stopReason = "end"
    private var emittedDone = false

    init(kind: Kind) {
        self.kind = kind
    }

    /// Ingests one raw SSE line and returns any resulting events.
    func ingestSSELine(_ line: String) -> [StreamEvent] {
        if line.isEmpty || line.hasPrefix("event:") {
            return []
        }
        guard line.hasPrefix("data:") else {
            return []
        }
        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") {
            payload.removeFirst()
        }
        if payload == "[DONE]" {
            return finish()
        }
        guard
            let data = payload.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        switch kind {
        case .responses:
            return ingestResponses(root)
        case .chat:
            return ingestChat(root)
        }
    }

    /// Flushes any pending tool calls and emits a terminal `.done` exactly once.
    func finish() -> [StreamEvent] {
        guard !emittedDone else { return [] }
        emittedDone = true
        var out = flushToolCalls()
        out.append(.done(stop: stopReason, usage: usage))
        return out
    }

    // MARK: - Responses API

    private func ingestResponses(_ root: [String: Any]) -> [StreamEvent] {
        guard let type = root["type"] as? String else { return [] }
        switch type {
        case "response.output_text.delta":
            if let delta = root["delta"] as? String {
                return [.textDelta(delta)]
            }
            return []

        case "response.output_item.done":
            guard
                let item = root["item"] as? [String: Any],
                (item["type"] as? String) == "function_call"
            else {
                return []
            }
            let id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
            let name = item["name"] as? String ?? ""
            let arguments = JSONValue.parseArguments(item["arguments"] as? String ?? "")
            return [.toolCall(ToolCall(id: id, name: name, arguments: arguments))]

        case "response.completed":
            if
                let response = root["response"] as? [String: Any],
                let usageObject = response["usage"] as? [String: Any] {
                if let input = usageObject["input_tokens"] as? Int { usage.input = input }
                if let output = usageObject["output_tokens"] as? Int { usage.output = output }
            }
            stopReason = "stop"
            return finish()

        default:
            return []
        }
    }

    // MARK: - Chat Completions

    private func ingestChat(_ root: [String: Any]) -> [StreamEvent] {
        if let usageObject = root["usage"] as? [String: Any] {
            if let input = usageObject["prompt_tokens"] as? Int { usage.input = input }
            if let output = usageObject["completion_tokens"] as? Int { usage.output = output }
        }
        guard
            let choices = root["choices"] as? [[String: Any]],
            let choice = choices.first
        else {
            return []
        }

        var out: [StreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                out.append(.textDelta(content))
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    let index = call["index"] as? Int ?? 0
                    if pendingTools[index] == nil {
                        pendingTools[index] = PendingToolCall()
                        toolOrder.append(index)
                    }
                    if let id = call["id"] as? String, !id.isEmpty {
                        pendingTools[index]?.id = id
                    }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty {
                            pendingTools[index]?.name += name
                        }
                        if let args = function["arguments"] as? String {
                            pendingTools[index]?.arguments += args
                        }
                    }
                }
            }
        }

        if let finish = choice["finish_reason"] as? String {
            if finish == "tool_calls" {
                out.append(contentsOf: flushToolCalls())
            }
            stopReason = finish
        }
        return out
    }

    // MARK: - Helpers

    /// Emits accumulated Chat-Completions tool calls in arrival order, then clears them.
    private func flushToolCalls() -> [StreamEvent] {
        guard !pendingTools.isEmpty else { return [] }
        var out: [StreamEvent] = []
        for index in toolOrder {
            guard let pending = pendingTools[index] else { continue }
            let arguments = JSONValue.parseArguments(pending.arguments)
            out.append(.toolCall(ToolCall(id: pending.id, name: pending.name, arguments: arguments)))
        }
        pendingTools.removeAll()
        toolOrder.removeAll()
        return out
    }
}
