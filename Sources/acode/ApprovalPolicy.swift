import Foundation

/// Thread-safe, reference-typed approval state shared across copied `Renderer`
/// values so the approval gate has session memory.
///
/// `Renderer` is a copied value type; without a shared reference its `approve`
/// method would re-prompt on every command. This holder mirrors the
/// `OutputBuffer`/`ProcessBox` `NSLock` pattern in `RunShell.swift`.
///
/// Default behavior remains "ask": nothing here is enabled unless a caller
/// opts in via `--yes`, config (`autoApprove`/`autoApproveTools`), or the
/// runtime `a`/`/auto` choices.
nonisolated final class ApprovalPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var autoApproveAll: Bool
    private var alwaysAllowed: Set<String>
    private var allowedShellPrefixes: [String]

    /// Shell metacharacters that, if present anywhere in a command, force an
    /// interactive prompt. This blocks chaining (`;`/`&&`/`||`), pipes (`|`),
    /// backgrounding (`&`), command substitution (backtick, `$(`), expansion
    /// and subshells (`$`,`{`,`}`,`(`,`)`), redirects (`<`,`>`), and
    /// escapes/line-continuation (`\`, CR, LF).
    private static let shellMetacharacters: Set<Character> = [
        ";", "|", "&", "`", "$", "(", ")", "{", "}", "<", ">", "\n", "\r", "\\",
        "~", "#", "!", "^", "*", "?", "[", "]", "\t"
    ]

    init(
        autoApproveAll: Bool = false,
        alwaysAllowed: Set<String> = [],
        allowedShellPrefixes: [String] = []
    ) {
        self.autoApproveAll = autoApproveAll
        self.alwaysAllowed = alwaysAllowed
        self.allowedShellPrefixes = allowedShellPrefixes
    }

    /// Returns true when `name` (optionally with its shell `command`) should
    /// bypass the interactive prompt.
    func shouldAutoApprove(_ name: String, command: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if autoApproveAll { return true }
        if alwaysAllowed.contains(name) { return true }
        if name == "run_shell", let command, isShellCommandAllowed(command) { return true }
        return false
    }

    /// Decides whether a shell command is safe to auto-approve against the
    /// configured allowlist. Rejects anything containing shell metacharacters
    /// BEFORE matching, so chained/substituted/redirected commands always
    /// prompt. False negatives (a safe command that gets prompted) are
    /// acceptable; false positives (a dangerous command auto-approved) are not.
    ///
    /// IMPORTANT: this must NOT take `lock` — it is only called from
    /// `shouldAutoApprove`, which already holds it. NSLock is non-recursive.
    private func isShellCommandAllowed(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains(where: { Self.shellMetacharacters.contains($0) }) {
            return false
        }
        let normalized = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for entry in allowedShellPrefixes {
            let normalizedEntry = entry.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if normalizedEntry.isEmpty { continue }
            if normalized == normalizedEntry || normalized.hasPrefix(normalizedEntry + " ") {
                return true
            }
        }
        return false
    }

    /// Records that `name` is always allowed for the rest of the session.
    func allowAlways(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        alwaysAllowed.insert(name)
    }

    /// Toggles blanket auto-approve for all tools.
    func setAutoApproveAll(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        autoApproveAll = on
    }

    /// A human-readable summary for `/auto` and `/approvals`.
    func describe() -> String {
        lock.lock()
        defer { lock.unlock() }
        let allowed = alwaysAllowed.sorted().joined(separator: ", ")
        let shell = allowedShellPrefixes.joined(separator: ", ")
        return "auto-approve-all: \(autoApproveAll ? "on" : "off"); always-allowed: [\(allowed)]; shell-allowlist: [\(shell)]"
    }
}
