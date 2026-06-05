import Foundation
import Testing
@testable import acode

private struct PromptTestTool: Tool {
    var requiresApproval = false
    static var schema: ToolSchema {
        ToolSchema(name: "alpha", description: "Alpha tool.", parameters: .object([:]))
    }
    func run(_ args: JSONValue) async -> ToolOutput { ToolOutput(output: "alpha-ran") }
}

@Test func test_prompt_includes_agents_md() throws {
    let acodeDir = URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
        .appendingPathComponent(".acode", isDirectory: true)
    let fileURL = acodeDir.appendingPathComponent("AGENTS.md")

    // Preserve any pre-existing file so the test is non-destructive.
    let fm = FileManager.default
    let existed = fm.fileExists(atPath: fileURL.path)
    let backup = existed ? try? Data(contentsOf: fileURL) : nil
    let dirExisted = fm.fileExists(atPath: acodeDir.path)

    try fm.createDirectory(at: acodeDir, withIntermediateDirectories: true)
    let marker = "PROJECT-RULE-MARKER-\(UUID().uuidString)"
    try marker.write(to: fileURL, atomically: true, encoding: .utf8)

    defer {
        if let backup {
            try? backup.write(to: fileURL)
        } else {
            try? fm.removeItem(at: fileURL)
            if !dirExisted { try? fm.removeItem(at: acodeDir) }
        }
    }

    let rules = Prompt.projectRules()
    #expect(rules.contains(marker))
}

@Test func test_prompt_lists_skills() throws {
    let skillsDir = URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
        .appendingPathComponent(".acode/skills", isDirectory: true)

    let fm = FileManager.default
    let dirExisted = fm.fileExists(atPath: skillsDir.path)
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

    let suffix = UUID().uuidString.prefix(8)
    let nameA = "zskill-a-\(suffix)"
    let nameB = "zskill-b-\(suffix)"
    let summaryA = "Summary for skill A."
    let summaryB = "Summary for skill B."
    let fileA = skillsDir.appendingPathComponent("\(nameA).md")
    let fileB = skillsDir.appendingPathComponent("\(nameB).md")
    try "\(summaryA)\nmore body".write(to: fileA, atomically: true, encoding: .utf8)
    try "\(summaryB)\nmore body".write(to: fileB, atomically: true, encoding: .utf8)

    defer {
        try? fm.removeItem(at: fileA)
        try? fm.removeItem(at: fileB)
        if !dirExisted { try? fm.removeItem(at: skillsDir) }
    }

    var registry = ToolRegistry()
    registry.register(PromptTestTool())
    let profile = AgentProfile(
        name: "test",
        identity: "IDENTITY-LAYER",
        rules: "RULES-LAYER",
        tools: nil,
        model: nil
    )

    let prompt = Prompt.assemble(profile: profile, registry: registry)
    #expect(prompt.contains("Available skills (use activate_skill to load full instructions):"))
    #expect(prompt.contains("- \(nameA): \(summaryA)"))
    #expect(prompt.contains("- \(nameB): \(summaryB)"))
}

@Test func test_prompt_assembles_five_layers() throws {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
    let acodeDir = rootURL.appendingPathComponent(".acode", isDirectory: true)
    let skillsDir = rootURL.appendingPathComponent(".acode/skills", isDirectory: true)
    let agentsURL = acodeDir.appendingPathComponent("AGENTS.md")

    // Preserve any pre-existing AGENTS.md so the test is non-destructive.
    let agentsExisted = fm.fileExists(atPath: agentsURL.path)
    let agentsBackup = agentsExisted ? try? Data(contentsOf: agentsURL) : nil
    let acodeDirExisted = fm.fileExists(atPath: acodeDir.path)
    let skillsDirExisted = fm.fileExists(atPath: skillsDir.path)

    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

    let suffix = UUID().uuidString.prefix(8)
    let skillName = "zlayer-skill-\(suffix)"
    let skillSummary = "SKILL-INDEX-LAYER"
    let skillURL = skillsDir.appendingPathComponent("\(skillName).md")
    try "\(skillSummary)\nbody".write(to: skillURL, atomically: true, encoding: .utf8)

    let ruleMarker = "PROJECT-RULES-LAYER-\(suffix)"
    try ruleMarker.write(to: agentsURL, atomically: true, encoding: .utf8)

    defer {
        try? fm.removeItem(at: skillURL)
        if !skillsDirExisted { try? fm.removeItem(at: skillsDir) }
        if let agentsBackup {
            try? agentsBackup.write(to: agentsURL)
        } else {
            try? fm.removeItem(at: agentsURL)
            if !acodeDirExisted { try? fm.removeItem(at: acodeDir) }
        }
    }

    var registry = ToolRegistry()
    registry.register(PromptTestTool())

    let profile = AgentProfile(
        name: "test",
        identity: "IDENTITY-LAYER",
        rules: "RULES-LAYER",
        tools: nil,
        model: nil
    )

    let prompt = Prompt.assemble(profile: profile, registry: registry)

    // All five layers appear.
    #expect(prompt.contains("Available tools:"))
    #expect(prompt.contains("alpha: Alpha tool."))
    #expect(prompt.contains("RULES-LAYER"))
    #expect(prompt.contains("IDENTITY-LAYER"))
    #expect(prompt.contains(skillSummary))
    #expect(prompt.contains(ruleMarker))

    // Order (invariant B8): ① tool help < ② rules < ③ identity < ④ skill index < ⑤ project rules.
    let toolIndex = prompt.range(of: "Available tools:")!.lowerBound
    let rulesIndex = prompt.range(of: "RULES-LAYER")!.lowerBound
    let identityIndex = prompt.range(of: "IDENTITY-LAYER")!.lowerBound
    let skillIndex = prompt.range(of: skillSummary)!.lowerBound
    let projectRulesIndex = prompt.range(of: ruleMarker)!.lowerBound
    #expect(toolIndex < rulesIndex)
    #expect(rulesIndex < identityIndex)
    #expect(identityIndex < skillIndex)
    #expect(skillIndex < projectRulesIndex)
}
