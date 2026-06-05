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
struct Renderer: Sendable {
    let color: Bool
    let autoApprove: Bool
    var verbose: Bool

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

    /// Prints token usage only when verbose.
    nonisolated func usage(_ u: Usage) {
        guard verbose else { return }
        print(paint("· \(u.input)+\(u.output) tok", "2"))
    }

    nonisolated func phase(_ p: String) {
        print(paint("● \(p)", "36"))
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
        Spinner(label: label)
    }
}
