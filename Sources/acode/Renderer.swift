import Foundation

/// A no-op spinner placeholder; real braille animation arrives in T1.3.
nonisolated final class Spinner {
    @discardableResult
    func start() -> Spinner { self }
    func stop() {}
}

/// Renders agent output to stdout. Nonisolated and Sendable; no actor.
struct Renderer: Sendable {
    let color: Bool
    let autoApprove: Bool
    var verbose: Bool

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
        print("→ \(c.name)")
    }

    nonisolated func toolEnd(_ c: ToolCall, _ r: ToolResult) {
        print(r.isError ? "\u{2717} \(c.name)" : "\u{2713} \(c.name)")
    }

    /// Prints token usage only when verbose.
    nonisolated func usage(_ u: Usage) {
        guard verbose else { return }
        print("· \(u.input)+\(u.output) tok")
    }

    nonisolated func phase(_ p: String) {
        print("● \(p)")
    }

    /// Returns true under auto-approve; otherwise reads a y/n line (default no).
    nonisolated func approve(_ c: ToolCall) -> Bool {
        if autoApprove { return true }
        print("Approve \(c.name)? [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    nonisolated func spinner(_ label: String) -> Spinner {
        Spinner()
    }
}
