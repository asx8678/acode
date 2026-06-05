import Foundation

/// Assembles the system prompt from the fixed five-layer order (invariant B8).
enum Prompt {
    /// Joins, in order, the non-empty fragments separated by "\n\n":
    ///   ① tool help  ② profile rules  ③ profile identity  ④ skill index  ⑤ project rules
    static func assemble(profile: AgentProfile, registry: ToolRegistry) -> String {
        let fragments = [
            toolHelp(registry, allowed: profile.tools),
            profile.rules,
            profile.identity,
            skillIndex(),
            projectRules()
        ]
        return fragments
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Renders the allowed tools as one "name: description" line each.
    static func toolHelp(_ registry: ToolRegistry, allowed: Set<String>?) -> String {
        let schemas = registry.schemas(allowed: allowed)
            .sorted { $0.name < $1.name }
        guard !schemas.isEmpty else { return "" }
        let lines = schemas.map { "\($0.name): \($0.description)" }
        return (["Available tools:"] + lines).joined(separator: "\n")
    }

    /// One line per skill (filled in T4.2).
    static func skillIndex() -> String { "" }

    /// Combined AGENTS.md project rules (filled in T3.3).
    static func projectRules() -> String { "" }
}
