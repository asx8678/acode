import Foundation

/// An animated braille spinner that writes to stderr on a background task.
nonisolated final class Spinner: @unchecked Sendable {
    private static let frames = [
        "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}",
        "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}"
    ]

    private let label: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(label: String) {
        self.label = label
    }

    @discardableResult
    func start() -> Spinner {
        lock.withLock {
            guard task == nil else { return }
            let label = self.label
            task = Task.detached {
                var index = 0
                while !Task.isCancelled {
                    let frame = Spinner.frames[index % Spinner.frames.count]
                    FileHandle.standardError.write(Data("\r\(frame) \(label)".utf8))
                    index += 1
                    do {
                        try await Task.sleep(for: .milliseconds(80))
                    } catch {
                        break
                    }
                }
            }
        }
        return self
    }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
        // Clear the spinner line.
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}

/// Renders agent output to stdout. Nonisolated and Sendable; no actor.
///
/// Conforms to `RenderSink` so the engine can be driven through the
/// seam with `any RenderSink`; this is the post-P0 of the TUI epic
/// (recovery 2/5). The line-mode `approve` body is unchanged — it just
/// widens to `async` so the same `Renderer` works for both the REPL
/// (where `readLine` is sync inside an `async` func) and the future
/// TUI/SwiftUI frontends (which park a `CheckedContinuation`).
struct Renderer: Sendable, RenderSink {
    let color: Bool
    var verbose: Bool
    /// Shared session approval state so copies of this struct remember choices.
    let policy: ApprovalPolicy

    init(color: Bool, verbose: Bool, policy: ApprovalPolicy = ApprovalPolicy()) {
        self.color = color
        self.verbose = verbose
        self.policy = policy
    }

    /// Centralized color rule: color only on a TTY with NO_COLOR unset.
    static func colorEnabled(isTTY: Bool, noColor: Bool) -> Bool {
        isTTY && !noColor
    }

    /// Wraps `text` in an ANSI SGR code when color is enabled.
    private nonisolated func paint(_ text: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    nonisolated func banner() {
        print("acode \(Acode.version)")
    }

    /// Writes streamed text with no trailing newline.
    nonisolated func streamText(_ s: String) {
        print(s, terminator: "")
    }

    /// Ends the assistant turn with a newline.
    nonisolated func endAssistant() {
        print("")
    }

    nonisolated func toolStart(_ c: ToolCall) {
        print(paint("→ \(c.name)", "2"))
    }

    nonisolated func toolEnd(_ c: ToolCall, _ r: ToolResult) {
        if r.isError {
            print(paint("\u{2717} \(c.name)", "31"))
        } else {
            print(paint("\u{2713} \(c.name)", "32"))
        }
    }

    /// Writes a redacted diagnostic line to stderr when verbose is enabled.
    nonisolated func verboseLog(_ message: String) {
        guard verbose else { return }
        let redacted = Self.redactKeys(in: message)
        FileHandle.standardError.write(Data((redacted + "\n").utf8))
    }

    /// Masks anything that looks like an API key with `[REDACTED]`.
    ///
    /// Redacts Anthropic/OpenAI-style keys (`sk-ant-…`, `sk-…`) and the values
    /// of JSON/header pairs whose key contains `key` or `api_key`.
    nonisolated static func redactKeys(in text: String) -> String {
        var result = text

        // 1) Mask the value of JSON/header pairs whose key name ends in "key".
        //    Keep the key name; replace only the quoted value.
        let pairPattern = "(?i)(\"[a-z0-9_-]*key\"\\s*:\\s*)\"[^\"]*\""
        if let regex = try? NSRegularExpression(pattern: pairPattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: "$1\"[REDACTED]\""
            )
        }

        // 2) Mask bare Anthropic/OpenAI-style secret keys anywhere.
        for pattern in ["sk-ant-[a-zA-Z0-9_-]+", "sk-[a-zA-Z0-9_-]{20,}"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: "[REDACTED]"
            )
        }
        return result
    }

    /// Prints token usage only when verbose.
    nonisolated func usage(_ u: Usage) {
        guard verbose else { return }
        print(paint("· \(u.input)+\(u.output) tok", "2"))
    }

    nonisolated func phase(_ p: String) {
        print(paint("● \(p)", "36"))
    }

    /// Returns true under auto-approve or a remembered allow-always; otherwise
    /// reads a `y/N/a` line (default no). `a`/`all`/`always` allows the tool for
    /// the rest of the session via the shared policy. Widened from sync to
    /// `async` for the post-P0 seam; the body is unchanged — `readLine()`
    /// is fine inside an `async` function.
    nonisolated func approve(_ c: ToolCall) async -> Bool {
        if policy.shouldAutoApprove(c.name, command: c.arguments["command"]?.stringValue) { return true }
        print(Self.approvalDescription(c))
        print("Approve \(c.name)? [y/N/a] ", terminator: "")
        guard let line = readLine() else { return false }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch answer {
        case "y", "yes":
            return true
        case "a", "all", "always":
            policy.allowAlways(c.name)
            return true
        default:
            return false
        }
    }

    nonisolated func spinner(_ label: String) -> Spinner {
        Spinner(label: label)
    }

    /// A human-readable summary of what a tool call will do, shown above the
    /// approval prompt so the user can see exactly what they are approving
    /// rather than just the tool name.
    nonisolated static func approvalDescription(_ c: ToolCall) -> String {
        switch c.name {
        case "run_shell":
            let command = c.arguments["command"]?.stringValue ?? "(missing command)"
            return "  run: \(clipDetail(command))"
        case "edit_file":
            let path = c.arguments["path"]?.stringValue ?? "(missing path)"
            let oldStr = c.arguments["old_str"]?.stringValue ?? ""
            let newStr = c.arguments["new_str"]?.stringValue ?? ""
            if oldStr.isEmpty {
                return "  create \(path) (\(newStr.count) bytes)"
            }
            return "  edit \(path)\n"
                + "    - \(clipDetail(oldStr))\n"
                + "    + \(clipDetail(newStr))"
        default:
            return "  \(c.name)"
        }
    }

    /// Clips a detail string to a single, length-bounded line for the prompt.
    private nonisolated static func clipDetail(_ s: String, limit: Int = 200) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: "⏎")
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }
}
