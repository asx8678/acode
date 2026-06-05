import Foundation

/// User configuration loaded from `~/.config/acode/config.json`.
///
/// Minimal for M0: only an optional default model. The full model registry,
/// per-role overrides, and provider selection arrive in T3.7. API keys are
/// never stored here; they are read from the environment at provider
/// construction time.
struct Config: Codable {
    var defaultModel: String?

    /// Loads config from `~/.config/acode/config.json`, tolerating a missing or
    /// malformed file by returning defaults.
    static func load() -> Config {
        let path = ("~/.config/acode/config.json" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }
}

/// Builds the active provider. For M0 only Anthropic exists; the model is
/// resolved as `model ?? cfg.defaultModel ?? defaultAnthropicModel`.
func makeProvider(model: String?, cfg: Config) -> any LLMProvider {
    let resolved = model ?? cfg.defaultModel ?? defaultAnthropicModel
    return AnthropicProvider(configuredModel: resolved)
}

/// Registers the standard M0 tool set: read_file and run_shell.
func registerStandardTools(_ tools: inout ToolRegistry) {
    tools.register(ReadFileTool())
    tools.register(RunShellTool())
}
