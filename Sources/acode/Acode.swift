import ArgumentParser

/// Entry point for the acode terminal coding agent.
///
/// T0.1 establishes the command shape only; `run()` prints a banner and exits.
/// Later tasks fill in routing, the agent loop, and provider wiring without
/// changing these public option/flag shapes.
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
        print("acode \(Acode.version)")
    }
}
