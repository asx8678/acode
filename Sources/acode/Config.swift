import Foundation

/// A model-registry entry mapping a model id to its provider and an optional
/// context-window override.
struct ModelEntry: Codable {
    /// Provider id: `"anthropic"`, `"openai"`, or `"local"`.
    let provider: String
    /// Overrides the provider's default context window when set.
    let contextWindow: Int?
}

/// User configuration loaded from `~/.config/acode/config.json`.
///
/// Carries a default model, a default provider, a model registry (id →
/// provider + optional context window), and per-role model overrides. API keys
/// are never stored here; they are read from the environment at provider
/// construction time.
struct Config: Codable {
    /// Model used when no per-call model is supplied.
    var defaultModel: String?
    /// Provider used when a resolved model is absent from `models`.
    var defaultProvider: String?
    /// Model id → provider + optional context window.
    var models: [String: ModelEntry] = [:]
    /// Role name → model id override (e.g. `"planner"` → `"claude-opus-4-5"`).
    var roleModels: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case defaultModel, defaultProvider, models, roleModels
    }

    init(
        defaultModel: String? = nil,
        defaultProvider: String? = nil,
        models: [String: ModelEntry] = [:],
        roleModels: [String: String]? = nil
    ) {
        self.defaultModel = defaultModel
        self.defaultProvider = defaultProvider
        self.models = models
        self.roleModels = roleModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultProvider = try container.decodeIfPresent(String.self, forKey: .defaultProvider)
        models = try container.decodeIfPresent([String: ModelEntry].self, forKey: .models) ?? [:]
        roleModels = try container.decodeIfPresent([String: String].self, forKey: .roleModels)
    }

    /// Loads config from `~/.config/acode/config.json`, tolerating a missing or
    /// malformed file by returning defaults. Environment variables
    /// `ACODE_MODEL` and `ACODE_PROVIDER` overlay the loaded values.
    static func load() -> Config {
        let path = ("~/.config/acode/config.json" as NSString).expandingTildeInPath
        return load(from: URL(fileURLWithPath: path))
    }

    /// Loads config from an explicit URL, applying environment overrides.
    /// Factored out so tests can point at a temp file.
    static func load(from url: URL) -> Config {
        var config: Config
        if
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
        } else {
            config = Config()
        }

        let env = ProcessInfo.processInfo.environment
        if let model = env["ACODE_MODEL"], !model.isEmpty {
            config.defaultModel = model
        }
        if let provider = env["ACODE_PROVIDER"], !provider.isEmpty {
            config.defaultProvider = provider
        }
        return config
    }
}

/// Builds the active provider for a resolved model.
///
/// Resolution order:
/// 1. `model ?? cfg.defaultModel ?? defaultAnthropicModel`
/// 2. Look up the model in `cfg.models` to pick the provider.
/// 3. Absent from the registry, fall back to `cfg.defaultProvider`
///    (`"openai"` → OpenAI, otherwise Anthropic).
/// 4. A registry `contextWindow` overrides the provider default.
/// 5. The `"local"` provider builds an `OpenAIProvider` against a local,
///    OpenAI-compatible endpoint (`OPENAI_BASE_URL` or Ollama's default).
func makeProvider(model: String?, cfg: Config) -> any LLMProvider {
    let resolved = model ?? cfg.defaultModel ?? defaultAnthropicModel
    let entry = cfg.models[resolved]
    let providerID = entry?.provider ?? cfg.defaultProvider ?? "anthropic"

    switch providerID {
    case "openai":
        let baseURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
            ?? defaultOpenAIBaseURL
        var provider = OpenAIProvider(configuredModel: resolved, baseURL: baseURL)
        if let window = entry?.contextWindow {
            provider.contextWindow = window
        }
        return provider

    case "local":
        let baseURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
            ?? "http://localhost:11434/v1"
        var provider = OpenAIProvider(configuredModel: resolved, baseURL: baseURL)
        if let window = entry?.contextWindow {
            provider.contextWindow = window
        }
        return provider

    default: // "anthropic" or anything unknown
        var provider = AnthropicProvider(configuredModel: resolved)
        if let window = entry?.contextWindow {
            provider.contextWindow = window
        }
        return provider
    }
}

/// Registers the standard M2 tool set: read_file, list_files, grep, edit_file,
/// run_shell, list_skills, activate_skill. Each file tool jails its paths via
/// ProjectJail internally.
func registerStandardTools(_ tools: inout ToolRegistry) {
    tools.register(ReadFileTool())
    tools.register(ListFilesTool())
    tools.register(GrepTool())
    tools.register(EditFileTool())
    tools.register(RunShellTool())
    tools.register(ListSkillsTool())
    tools.register(ActivateSkillTool())
}
