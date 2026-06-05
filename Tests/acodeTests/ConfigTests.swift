import Foundation
import Testing
@testable import acode

@MainActor
@Test func test_registers_standard_tools() {
    var registry = ToolRegistry()
    registerStandardTools(&registry)

    let names = Set(registry.schemas(allowed: nil).map(\.name))
    #expect(names == ["read_file", "list_files", "grep", "edit_file", "run_shell"])
}

@Test func test_config_load_and_select() throws {
    let json = """
    {
      "defaultModel": "claude-sonnet-4-5",
      "defaultProvider": "anthropic",
      "models": {
        "claude-sonnet-4-5": { "provider": "anthropic" },
        "gpt-5": { "provider": "openai", "contextWindow": 64000 },
        "local-model": { "provider": "local" }
      },
      "roleModels": {
        "planner": "claude-opus-4-5"
      }
    }
    """

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-config-\(UUID().uuidString).json")
    try json.data(using: .utf8)!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let cfg = Config.load(from: url)

    #expect(cfg.defaultModel == "claude-sonnet-4-5")
    #expect(cfg.defaultProvider == "anthropic")
    #expect(cfg.models.count == 3)
    #expect(cfg.models["gpt-5"]?.provider == "openai")
    #expect(cfg.models["gpt-5"]?.contextWindow == 64000)
    #expect(cfg.roleModels?["planner"] == "claude-opus-4-5")

    let openai = makeProvider(model: "gpt-5", cfg: cfg)
    #expect(openai is OpenAIProvider)
    #expect(openai.contextWindow == 64000)

    let anthropic = makeProvider(model: "claude-sonnet-4-5", cfg: cfg)
    #expect(anthropic is AnthropicProvider)

    let local = makeProvider(model: "local-model", cfg: cfg)
    #expect(local is OpenAIProvider)
}

@Test func test_config_defaults() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-missing-\(UUID().uuidString).json")
    let cfg = Config.load(from: url)

    #expect(cfg.defaultModel == nil)
    #expect(cfg.models.isEmpty)
}
