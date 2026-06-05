import Foundation

/// Errors raised by the agent loop.
enum AgentError: Error {
    case stepLimit
    case outsideProject(String)
}

/// Maximum tool/answer iterations per turn (invariant B1).
private nonisolated let maxAgentSteps = 50

/// Attempts `make()` up to `max` times. Rethrows `CancellationError`
/// immediately; otherwise retries and throws the last error after `max`
/// attempts. Backoff/jitter and status-aware retry arrive in T3.2.
func connectWithRetry<T>(max: Int, _ make: () async throws -> T) async throws -> T {
    var lastError: Error?
    for _ in 0..<Swift.max(1, max) {
        do {
            return try await make()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }
    }
    throw lastError ?? AgentError.stepLimit
}

/// Drives the act -> observe -> re-decide loop for one conversation.
@MainActor
final class Agent {
    private let profile: AgentProfile
    private let provider: any LLMProvider
    private let tools: ToolRegistry
    private let renderer: Renderer
    private var conversation = Conversation()

    init(profile: AgentProfile, provider: any LLMProvider, tools: ToolRegistry, renderer: Renderer) {
        self.profile = profile
        self.provider = provider
        self.tools = tools
        self.renderer = renderer
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

            conversation.append(.assistant(text: text, toolCalls: toolCalls))
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
