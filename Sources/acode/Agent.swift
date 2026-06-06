import Foundation

/// Errors raised by the agent loop.
enum AgentError: Error {
    case stepLimit
}

/// Maximum tool/answer iterations per turn (invariant B1).
private nonisolated let maxAgentSteps = 50

/// HTTP status codes worth retrying: rate limit, transient server faults,
/// and Anthropic's "overloaded" (529).
private nonisolated let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 529]

/// Extracts an HTTP status code from a known provider error, if present.
/// Returns `nil` for non-HTTP errors (e.g. transport failures), which are
/// treated as transient and therefore retriable.
private func httpStatus(of error: Error) -> Int? {
    if case AnthropicError.httpStatus(let code, _) = error { return code }
    if case OpenAIError.httpStatus(let code, _) = error { return code }
    return nil
}

/// True for permanent configuration errors that must never be retried,
/// alongside `CancellationError` (invariant B7).
private func isPermanentConfigError(_ error: Error) -> Bool {
    if case AnthropicError.missingAPIKey = error { return true }
    if case OpenAIError.missingAPIKey = error { return true }
    return false
}

/// Attempts `make()` up to `max` times with exponential backoff and full
/// jitter between attempts.
///
/// Retry policy (invariant B7 — retry only before the first byte):
/// - `CancellationError` is rethrown immediately, never retried.
/// - HTTP errors retry only on `retryableStatusCodes`; other status codes
///   throw immediately.
/// - Non-HTTP errors (transport/network) are treated as transient and retried.
///
/// Backoff doubles from a 1s base (1s, 2s, 4s, ...) with full jitter: the
/// actual delay is uniformly random in `[0, baseDelay]`.
func connectWithRetry<T>(max: Int, _ make: () async throws -> T) async throws -> T {
    let attempts = Swift.max(1, max)
    var lastError: Error?
    for attempt in 0..<attempts {
        do {
            return try await make()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error

            // Permanent configuration errors fail fast (never retried).
            if isPermanentConfigError(error) {
                throw error
            }

            // HTTP errors outside the retryable set fail fast.
            if let status = httpStatus(of: error), !retryableStatusCodes.contains(status) {
                throw error
            }

            // No delay after the final attempt.
            let isLastAttempt = attempt == attempts - 1
            if isLastAttempt { break }

            let baseDelay = pow(2.0, Double(attempt))  // 1s, 2s, 4s, ...
            let delay = Double.random(in: 0...baseDelay)
            FileHandle.standardError.write(
                Data("Retrying in \(String(format: "%.1f", delay))s (attempt \(attempt + 2)/\(attempts))...\n".utf8)
            )
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    // The loop runs at least once, so a failure path always sets `lastError`;
    // the fallback is unreachable and exists only to satisfy the type checker.
    throw lastError ?? AgentError.stepLimit
}

/// Drives the act -> observe -> re-decide loop for one conversation.
@MainActor
final class Agent {
    private var profile: AgentProfile
    private var provider: any LLMProvider
    private let tools: ToolRegistry
    private let renderer: Renderer
    private var conversation = Conversation()

    init(profile: AgentProfile, provider: any LLMProvider, tools: ToolRegistry, renderer: Renderer) {
        self.profile = profile
        self.provider = provider
        self.tools = tools
        self.renderer = renderer
    }

    /// Swaps the active provider mid-session (used by the `/model` command).
    func switchProvider(_ newProvider: any LLMProvider) {
        provider = newProvider
    }

    /// Clears the conversation history.
    func reset() {
        conversation = Conversation()
    }

    @discardableResult
    func run(_ input: String) async throws -> String {
        conversation.append(.user(input))

        for _ in 0..<maxAgentSteps {
            try Task.checkCancellation()

            let history = conversation.compacted(for: provider.contextWindow)
            let system = Prompt.assemble(profile: profile, registry: tools)
            let schemas = tools.schemas(allowed: profile.tools)

            renderer.verboseLog("Request: \(history.count) messages, \(schemas.count) tools")

            let stream = try await connectWithRetry(max: 3) {
                try await provider.stream(
                    system: system,
                    messages: history,
                    tools: schemas,
                    model: profile.model
                )
            }

            var text = ""
            var toolCalls: [ToolCall] = []
            var usage = Usage()
            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    renderer.streamText(delta)
                case .toolCall(let call):
                    toolCalls.append(call)
                case .done(_, let doneUsage):
                    usage = doneUsage
                }
            }

            // Record the turn, but never persist a wholly empty assistant
            // message: it serializes to an empty content block, which both
            // provider APIs reject (400) — and because it stays in history, it
            // would poison every subsequent request until the session is reset.
            if !text.isEmpty || !toolCalls.isEmpty {
                conversation.append(.assistant(text: text, toolCalls: toolCalls))
            }
            renderer.endAssistant()
            renderer.usage(usage)

            if toolCalls.isEmpty {
                return text
            }

            var results: [ToolResult] = []
            for call in toolCalls {
                renderer.toolStart(call)
                let result = await tools.execute(call, approve: renderer.approve)
                renderer.toolEnd(call, result)
                results.append(result)
            }
            conversation.append(.toolResults(results))
        }

        throw AgentError.stepLimit
    }
}
