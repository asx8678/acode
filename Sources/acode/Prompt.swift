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

    /// One line per skill, prefixed with an activation hint (invariant B8 layer ④).
    static func skillIndex() -> String {
        let entries = Skills.index()
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { "- \($0.name): \($0.summary)" }
        return (["Available skills (use activate_skill to load full instructions):"] + lines)
            .joined(separator: "\n")
    }

    /// Combined AGENTS.md project rules, included verbatim (invariant B8 layer ⑤).
    ///
    /// Reads, in order, and concatenates the non-empty contents of:
    ///   1. `./.acode/AGENTS.md` — project-local acode rules
    ///   2. `./AGENTS.md`        — standard project rules
    ///   3. `~/.config/acode/AGENTS.md` — global user rules
    ///
    /// Missing files are silently skipped. No transformation is applied.
    ///
    /// NOTE: Performs synchronous file I/O on the main actor. The AGENTS.md
    /// files are small and few, so the blocking cost is negligible; acceptable
    /// for now.
    static func projectRules() -> String {
        let rootURL = URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            rootURL.appendingPathComponent(".acode/AGENTS.md"),
            rootURL.appendingPathComponent("AGENTS.md"),
            homeURL.appendingPathComponent(".config/acode/AGENTS.md")
        ]
        let contents = paths.compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.isEmpty else { return nil }
            return text
        }
        return contents.joined(separator: "\n\n")
    }
}
