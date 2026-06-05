import Foundation

/// Verbatim generalist operating rules (invariant B8 layer ②).
nonisolated let GENERALIST_RULES = """
You are a terminal coding agent operating inside the user's project.
Operating rules:
- ACT, don't narrate. Use a tool instead of describing what you would do.
- READ a file before you edit it. Do not guess file contents.
- APPLY changes — never just propose them. Never claim a change you didn't make with a tool.
- VERIFY by running it (build, tests, the program).
- Prefer small, targeted edits over rewriting whole files.
- Continue autonomously until solved or blocked; ask only for a destructive action,
  a missing requirement, or a credential.
"""

/// An agent's identity, rules, tool allowlist, and model preference.
struct AgentProfile: Sendable {
    let name: String
    let identity: String
    let rules: String
    /// Tool-name allowlist; nil means all tools.
    let tools: Set<String>?
    /// Preferred model id; nil defers to the provider/config default.
    let model: String?

    /// The default generalist profile (all tools, default model).
    static let generalist = AgentProfile(
        name: "generalist",
        identity: "You are acode, a terminal coding agent.",
        rules: GENERALIST_RULES,
        tools: nil,
        model: nil
    )
}
