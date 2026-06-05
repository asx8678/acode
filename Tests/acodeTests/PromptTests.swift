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

@Test func test_prompt_assembles_five_layers() {
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

    // Tool help (layer ①) appears.
    #expect(prompt.contains("Available tools:"))
    #expect(prompt.contains("alpha: Alpha tool."))
    #expect(prompt.contains("RULES-LAYER"))
    #expect(prompt.contains("IDENTITY-LAYER"))

    // Order (invariant B8): tool help before rules before identity.
    let toolIndex = prompt.range(of: "Available tools:")!.lowerBound
    let rulesIndex = prompt.range(of: "RULES-LAYER")!.lowerBound
    let identityIndex = prompt.range(of: "IDENTITY-LAYER")!.lowerBound
    #expect(toolIndex < rulesIndex)
    #expect(rulesIndex < identityIndex)
}
