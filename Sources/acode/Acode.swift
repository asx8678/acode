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

/// Entry point for the acode terminal coding agent.
///
/// Supports one-shot mode (`-p`); the interactive REPL is T1.4.
@main
struct Acode: AsyncParsableCommand {
    @Option(name: .shortAndLong) var model: String?
    @Option(parsing: .upToNextOption) var agents: [String] = []
    @Flag(name: .long) var yes: Bool = false
    @Option(name: .shortAndLong) var prompt: String?
    @Flag(name: .long) var verbose: Bool = false

    /// The acode release version, surfaced in the startup banner.
    nonisolated static let version = "0.1.0"

    mutating func run() async throws {
        // No prompt: print the banner and exit. Interactive REPL is T1.4.
        guard let prompt else {
            print("acode \(Acode.version)")
            return
        }

        // UX guard: a missing key should not become a crash.
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        if key == nil || key?.isEmpty == true {
            FileHandle.standardError.write(Data("Set ANTHROPIC_API_KEY to use acode.\n".utf8))
            throw ExitCode.failure
        }

        _ = try await Self.executeOneShot(prompt: prompt, model: model, yes: yes, verbose: verbose)
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
        let provider = makeProvider(model: model, cfg: cfg)
        let color = isatty(STDOUT_FILENO) != 0
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        let renderer = Renderer(color: color, autoApprove: yes, verbose: verbose)
        return try await runOneShot(prompt: prompt, provider: provider, tools: tools, renderer: renderer)
    }
}
