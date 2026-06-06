import Foundation
import Testing
@testable import acode

@Test func test_allow_always_is_per_tool() {
    let policy = ApprovalPolicy()
    policy.allowAlways("run_shell")
    #expect(policy.shouldAutoApprove("run_shell") == true)
    #expect(policy.shouldAutoApprove("edit_file") == false)
}

@Test func test_auto_approve_all_approves_anything() {
    let policy = ApprovalPolicy(autoApproveAll: true)
    #expect(policy.shouldAutoApprove("anything") == true)
    #expect(policy.shouldAutoApprove("run_shell") == true)
}

@Test func test_always_allowed_seed_is_granular() {
    let policy = ApprovalPolicy(alwaysAllowed: ["run_shell"])
    #expect(policy.shouldAutoApprove("run_shell") == true)
    #expect(policy.shouldAutoApprove("edit_file") == false)
}

@Test func test_set_auto_approve_all_flips_behavior() {
    let policy = ApprovalPolicy()
    #expect(policy.shouldAutoApprove("edit_file") == false)
    policy.setAutoApproveAll(true)
    #expect(policy.shouldAutoApprove("edit_file") == true)
    policy.setAutoApproveAll(false)
    #expect(policy.shouldAutoApprove("edit_file") == false)
}

@Test func test_renderer_approve_uses_policy_without_stdin() {
    // Allow-listed tool short-circuits on the policy before any readLine().
    let renderer = Renderer(
        color: false, verbose: false,
        policy: ApprovalPolicy(alwaysAllowed: ["run_shell"])
    )
    let allowed = ToolCall(id: "t", name: "run_shell", arguments: .object([:]))
    #expect(renderer.approve(allowed) == true)

    // Non-allowed tool with an empty policy denies by default (readLine() nil).
    let denyRenderer = Renderer(
        color: false, verbose: false,
        policy: ApprovalPolicy()
    )
    let denied = ToolCall(id: "t2", name: "edit_file", arguments: .object([:]))
    #expect(denyRenderer.approve(denied) == false)
}

// MARK: - Runtime /allow + persistence

@Test func test_allow_shell_prefix_runtime() {
    let policy = ApprovalPolicy()
    policy.allowShellPrefix("git push")
    #expect(policy.shouldAutoApprove("run_shell", command: "git push") == true)
    #expect(policy.shouldAutoApprove("run_shell", command: "git push --force") == true)
    #expect(policy.shouldAutoApprove("run_shell", command: "git push; rm -rf /") == false)
}

@Test func test_allow_shell_prefix_dedupes() {
    let policy = ApprovalPolicy()
    policy.allowShellPrefix("git push")
    policy.allowShellPrefix("git push")
    policy.allowShellPrefix("  ")
    let desc = policy.describe()
    // "git push" should appear exactly once in the shell-allowlist.
    let occurrences = desc.components(separatedBy: "git push").count - 1
    #expect(occurrences == 1)
}

@Test func test_save_approvals_roundtrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-save-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".bak"))
    }

    let ok = saveApprovals(
        autoApprove: true,
        autoApproveTools: ["edit_file"],
        autoApproveShell: ["git status", "swift build"],
        to: url
    )
    #expect(ok == true)

    let cfg = Config.load(from: url)
    #expect(cfg.autoApprove == true)
    #expect(cfg.autoApproveTools == ["edit_file"])
    #expect(cfg.autoApproveShell == ["git status", "swift build"])
}

@Test func test_save_approvals_preserves_existing_keys_and_secret() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-secret-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".bak"))
    }

    let original = """
    {
      "defaultModel": "deepseek-v4-pro",
      "models": {
        "deepseek-v4-pro": {
          "provider": "openai",
          "apiKey": "sk-secret-1234"
        }
      }
    }
    """
    try original.data(using: .utf8)!.write(to: url)

    let ok = saveApprovals(
        autoApprove: false,
        autoApproveTools: ["run_shell"],
        autoApproveShell: ["git status"],
        to: url
    )
    #expect(ok == true)

    let data = try Data(contentsOf: url)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(root?["defaultModel"] as? String == "deepseek-v4-pro")
    let models = root?["models"] as? [String: Any]
    let entry = models?["deepseek-v4-pro"] as? [String: Any]
    #expect(entry?["apiKey"] as? String == "sk-secret-1234")
    #expect(entry?["provider"] as? String == "openai")
    #expect(root?["autoApprove"] as? Bool == false)
    #expect(root?["autoApproveTools"] as? [String] == ["run_shell"])
    #expect(root?["autoApproveShell"] as? [String] == ["git status"])

    // Backup file was created.
    #expect(FileManager.default.fileExists(atPath: url.path + ".bak") == true)
}

// MARK: - Shell allowlist

@Test func test_shell_allowlist_exact_match() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "git status") == true)
}

@Test func test_shell_allowlist_prefix_with_args() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "git status --short -b") == true)
}

@Test func test_shell_allowlist_whitespace_normalized() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "git   status") == true)
}

@Test func test_shell_allowlist_word_boundary() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "git statusfoo") == false)
    let policy2 = ApprovalPolicy(allowedShellPrefixes: ["git"])
    #expect(policy2.shouldAutoApprove("run_shell", command: "github") == false)
}

@Test func test_shell_allowlist_rejects_chaining() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "git status; rm -rf /") == false)
    #expect(policy.shouldAutoApprove("run_shell", command: "git status && rm -rf /") == false)
    #expect(policy.shouldAutoApprove("run_shell", command: "git status || rm -rf /") == false)
}

@Test func test_shell_allowlist_rejects_pipe() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["cat foo"])
    #expect(policy.shouldAutoApprove("run_shell", command: "cat foo | sh") == false)
}

@Test func test_shell_allowlist_rejects_substitution() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "git status `rm -rf /`") == false)
    #expect(policy.shouldAutoApprove("run_shell", command: "git status $(rm -rf /)") == false)
}

@Test func test_shell_allowlist_rejects_redirect() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["echo hi"])
    #expect(policy.shouldAutoApprove("run_shell", command: "echo hi > /etc/hosts") == false)
}

@Test func test_shell_allowlist_rejects_expansion_metacharacters() {
    let git = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(git.shouldAutoApprove("run_shell", command: "git status ~/x") == false)
    #expect(git.shouldAutoApprove("run_shell", command: "git status # comment") == false)
    #expect(git.shouldAutoApprove("run_shell", command: "git status !!") == false)
    #expect(git.shouldAutoApprove("run_shell", command: "git status ^a^b") == false)
    #expect(git.shouldAutoApprove("run_shell", command: "git\tstatus") == false)

    let ls = ApprovalPolicy(allowedShellPrefixes: ["ls"])
    #expect(ls.shouldAutoApprove("run_shell", command: "ls *.swift") == false)
    #expect(ls.shouldAutoApprove("run_shell", command: "ls file?.txt") == false)

    let rm = ApprovalPolicy(allowedShellPrefixes: ["rm"])
    #expect(rm.shouldAutoApprove("run_shell", command: "rm [a-z]*") == false)
}

@Test func test_shell_allowlist_scoped_to_run_shell() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("deploy", command: "git status") == false)
}

@Test func test_shell_allowlist_not_in_list() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("run_shell", command: "rm -rf /") == false)
}

@Test func test_shell_allowlist_empty() {
    let policy = ApprovalPolicy()
    #expect(policy.shouldAutoApprove("run_shell", command: "git status") == false)
}

@Test func test_shell_allowlist_other_tools_unaffected() {
    let policy = ApprovalPolicy(allowedShellPrefixes: ["git status"])
    #expect(policy.shouldAutoApprove("edit_file", command: nil) == false)
}

@Test func test_shell_allowlist_renderer_integration() {
    let renderer = Renderer(
        color: false, verbose: false,
        policy: ApprovalPolicy(allowedShellPrefixes: ["swift build"])
    )
    let call = ToolCall(id: "t", name: "run_shell", arguments: .object(["command": .string("swift build")]))
    #expect(renderer.approve(call) == true)
}

@Test func test_config_decodes_shell_allowlist() throws {
    let json = """
    {
      "autoApproveShell": ["git status", "swift build"]
    }
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-shell-\(UUID().uuidString).json")
    try json.data(using: .utf8)!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let cfg = Config.load(from: url)
    #expect(cfg.autoApproveShell == ["git status", "swift build"])

    let emptyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-noshell-\(UUID().uuidString).json")
    try "{}".data(using: .utf8)!.write(to: emptyURL)
    defer { try? FileManager.default.removeItem(at: emptyURL) }
    #expect(Config.load(from: emptyURL).autoApproveShell == nil)
}

@Test func test_config_decodes_approval_fields() throws {
    let json = """
    {
      "defaultModel": "claude-sonnet-4-5",
      "autoApprove": true,
      "autoApproveTools": ["run_shell"]
    }
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-approval-\(UUID().uuidString).json")
    try json.data(using: .utf8)!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let cfg = Config.load(from: url)
    #expect(cfg.autoApprove == true)
    #expect(cfg.autoApproveTools == ["run_shell"])
}

@Test func test_config_without_approval_fields_still_decodes() throws {
    let json = """
    {
      "defaultModel": "claude-sonnet-4-5"
    }
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-noapproval-\(UUID().uuidString).json")
    try json.data(using: .utf8)!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let cfg = Config.load(from: url)
    #expect(cfg.defaultModel == "claude-sonnet-4-5")
    #expect(cfg.autoApprove == nil)
    #expect(cfg.autoApproveTools == nil)
}
