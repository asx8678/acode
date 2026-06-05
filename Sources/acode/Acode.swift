import ArgumentParser
import Foundation

/// Runs a single one-shot turn through the agent loop and returns the answer.
///
/// Factored out as a network-free testable seam; `run()` calls it.
func runOneShot(
    prompt: String,
    provider: any LLMProvider,
    tools: ToolRegistry,
    renderer: Renderer,
    profile: AgentProfile = .generalist
) async throws -> String {
    let agent = Agent(profile: profile, provider: provider, tools: tools, renderer: renderer)
    return try await agent.run(prompt)
}

/// A routed line of REPL input.
nonisolated enum Input {
    case slash(String)
    case shell(String)
    case task(String)
}

/// Routes a REPL line: leading `/` -> slash, leading `!` -> shell, else task.
/// Only the single leading marker is stripped; task keeps the full text.
nonisolated func route(_ s: String) -> Input {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("/") {
        return .slash(String(trimmed.dropFirst()))
    }
    if trimmed.hasPrefix("!") {
        return .shell(String(trimmed.dropFirst()))
    }
    return .task(s)
}

/// Runs `work` in a child task while SIGINT cancels just that task, so Ctrl-C
/// interrupts the current turn and returns to the prompt without killing the
/// process. Reused by the M5 orchestrator.
@MainActor
func runCancellable(_ work: @escaping () async throws -> Void, renderer: Renderer) async {
    let task = Task { try await work() }

    // Suppress default termination and route SIGINT to task cancellation.
    let previous = signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { task.cancel() }
    source.resume()
    defer {
        source.cancel()
        signal(SIGINT, previous)
    }

    do {
        try await task.value
    } catch is CancellationError {
        renderer.endAssistant()
        print("Cancelled.")
    } catch {
        renderer.endAssistant()
        print("Error: \(error)")
    }
}

/// Entry point for the acode terminal coding agent.
///
/// Supports one-shot mode (`-p`) and an interactive REPL.
@main
struct Acode: AsyncParsableCommand {
    @Option(name: .shortAndLong) var model: String?
    @Option(parsing: .upToNextOption) var agents: [String] = []
    @Flag(name: .long) var yes: Bool = false
    @Option(name: .shortAndLong) var prompt: String?
    @Flag(name: .long) var verbose: Bool = false

    /// The acode release version, surfaced in the startup banner.
    nonisolated static let version = "0.1.0"

    /// Human-readable name for the active provider, used in verbose logs.
    private nonisolated static func providerName(_ provider: any LLMProvider) -> String {
        if let openAI = provider as? OpenAIProvider,
           openAI.baseURL != defaultOpenAIBaseURL {
            return "Local"
        }
        return provider is OpenAIProvider ? "OpenAI" : "Anthropic"
    }

    mutating func run() async throws {
        // No prompt: enter the interactive REPL.
        guard let prompt else {
            await Self.runREPL(model: model, yes: yes, verbose: verbose)
            return
        }

        // One-shot: the provider throws `missingAPIKey` when a key is required,
        // so configuration is left to the provider (local providers need none).
        _ = try await Self.executeOneShot(prompt: prompt, model: model, yes: yes, verbose: verbose)
    }

    /// The interactive read-eval-print loop. Slash and shell commands work
    /// without an API key; only model turns require one.
    @MainActor
    private static func runREPL(model: String?, yes: Bool, verbose: Bool) async {
        print("acode \(version)")

        let cfg = Config.load()
        var tools = ToolRegistry()
        registerStandardTools(&tools)
        var resolvedModel = model ?? cfg.defaultModel ?? defaultAnthropicModel
        let provider = makeProvider(model: model, cfg: cfg)
        let color = Renderer.colorEnabled(
            isTTY: isatty(STDOUT_FILENO) != 0,
            noColor: ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        )
        let renderer = Renderer(color: color, autoApprove: yes, verbose: verbose)
        renderer.verboseLog("Model: \(resolvedModel)")
        renderer.verboseLog("Provider: \(providerName(provider))")
        let agent = Agent(profile: .generalist, provider: provider, tools: tools, renderer: renderer)

        loop: while true {
            print("> ", terminator: "")
            guard let line = readLine() else {
                print("")
                break
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            switch route(line) {
            case .slash(let command):
                switch command {
                case "help":
                    print("Commands: /help, /clear, /model [name], /quit. Prefix ! to run a shell command; anything else is a task.")
                case "clear":
                    agent.reset()
                    print("Conversation history cleared.")
                case "quit":
                    break loop
                default:
                    if command == "model" || command.hasPrefix("model ") {
                        let name = command.dropFirst("model".count).trimmingCharacters(in: .whitespaces)
                        if name.isEmpty {
                            print("Current model: \(resolvedModel).")
                        } else {
                            let newProvider = makeProvider(model: name, cfg: cfg)
                            agent.switchProvider(newProvider)
                            resolvedModel = name
                            renderer.verboseLog("Provider: \(providerName(newProvider))")
                            print("Model switched to \(name).")
                        }
                    } else {
                        print("Unknown command: /\(command)")
                    }
                }

            case .shell(let command):
                let result = await RunShellTool.execute(command: command, timeout: 60)
                print(result.output)

            case .task(let text):
                await runCancellable({ try await agent.run(text) }, renderer: renderer)
            }
        }
    }

    /// Builds the runtime and runs one prompt. MainActor-isolated so the
    /// MainActor-default helpers (Config, registry, Agent) compose cleanly.
    @MainActor
    private static func executeOneShot(
        prompt: String,
        model: String?,
        yes: Bool,
        verbose: Bool
    ) async throws -> String {
        let cfg = Config.load()
        var tools = ToolRegistry()
        registerStandardTools(&tools)
        let resolvedModel = model ?? cfg.defaultModel ?? defaultAnthropicModel
        let provider = makeProvider(model: model, cfg: cfg)
        let color = Renderer.colorEnabled(
            isTTY: isatty(STDOUT_FILENO) != 0,
            noColor: ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        )
        let renderer = Renderer(color: color, autoApprove: yes, verbose: verbose)
        renderer.verboseLog("Model: \(resolvedModel)")
        renderer.verboseLog("Provider: \(providerName(provider))")
        return try await runOneShot(prompt: prompt, provider: provider, tools: tools, renderer: renderer)
    }
}
