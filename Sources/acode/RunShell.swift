import Foundation

/// Thread-safe accumulator for combined stdout+stderr.
private nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    nonisolated func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    nonisolated func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Holds the running process so the timeout and cancellation paths can terminate it.
private nonisolated final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    /// Stores the process, returning `false` if cancellation already arrived —
    /// so the caller skips launching a command that was cancelled before the
    /// process was registered (closing the cancel-before-`set` race).
    nonisolated func set(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    nonisolated var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// Cancellation: mark cancelled and send SIGTERM.
    nonisolated func terminate() {
        lock.lock()
        cancelled = true
        process?.terminate()
        lock.unlock()
    }

    /// Timeout: record it (so the caller can report it distinctly) and SIGTERM.
    nonisolated func timeOut() {
        lock.lock()
        timedOut = true
        cancelled = true
        process?.terminate()
        lock.unlock()
    }

    /// Escalation: SIGKILL a process that ignored SIGTERM, so the worker thread
    /// blocked in `waitUntilExit()` cannot hang indefinitely.
    nonisolated func forceKill() {
        lock.lock()
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        lock.unlock()
    }
}

/// Maximum number of trailing output lines returned.
private nonisolated let runShellLineCap = 256

/// The shell used to run commands: `/bin/zsh` when present (the macOS default),
/// otherwise `/bin/sh` so the tool still works on minimal/CI environments.
private nonisolated func resolvedShellPath() -> String {
    let zsh = "/bin/zsh"
    return FileManager.default.isExecutableFile(atPath: zsh) ? zsh : "/bin/sh"
}

/// Runs a shell command via `zsh -c` (or `sh -c` where zsh is unavailable),
/// gated by approval (invariant B9).
///
/// The jail does not confine the shell; approval is its only gate.
struct RunShellTool: Tool {
    let requiresApproval = true

    /// Timeout in seconds; injectable so later tasks can use a short value.
    var timeout: TimeInterval = 60

    static var schema: ToolSchema {
        ToolSchema(
            name: "run_shell",
            description: "Run a shell command (zsh, or sh where zsh is unavailable) in the project root. Requires approval.",
            parameters: Schema.object(
                ["command": (type: "string", description: "The shell command to run.")],
                required: ["command"]
            )
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        guard let command = args["command"]?.stringValue else {
            return ToolOutput(output: "Missing required argument: command.", isError: true)
        }
        return await Self.execute(command: command, timeout: timeout)
    }

    /// Launches the command off the main actor, draining output concurrently,
    /// with a timeout and cooperative cancellation.
    nonisolated static func execute(command: String, timeout: TimeInterval) async -> ToolOutput {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ToolOutput, Never>) in
                DispatchQueue.global().async {
                    let result = runBlocking(command: command, timeout: timeout, box: box)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Synchronous worker run on a background queue.
    private nonisolated static func runBlocking(
        command: String,
        timeout: TimeInterval,
        box: ProcessBox
    ) -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedShellPath())
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: ProjectJail.root)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Critical: do NOT inherit the parent's stdin. When the REPL's
        // `readLine` is waiting for an approval, a shell child that
        // inherited stdin would swallow the user's keystroke intended
        // for the next approval prompt (a real "approve-all keeps
        // re-prompting" bug). `/dev/null` is EOF — `cat` reads nothing,
        // `read` returns nothing. Post-P0 fix (swift-92m.1 follow-up);
        // `ApprovalRepromptTests.runShellChildDoesNotInheritStdin` covers
        // it. Foundation's `Process` defaults `standardInput` to nil,
        // which means "inherit the parent's stdin" — so we MUST set it
        // explicitly to a closed handle to opt out.
        if let devNull = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = devNull
        }

        let buffer = OutputBuffer()
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
        }

        guard box.set(process) else {
            readHandle.readabilityHandler = nil
            return ToolOutput(output: "Cancelled.", isError: true)
        }
        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return ToolOutput(
                output: "Could not launch shell: \(error.localizedDescription)",
                isError: true
            )
        }
        // Cancellation that landed between `set` and `run` would have hit a
        // not-yet-started process; terminate now that it is running.
        if box.isCancelled {
            process.terminate()
        }

        let timeoutItem = DispatchWorkItem {
            box.timeOut()
            // If SIGTERM is ignored, SIGKILL after a short grace so the worker
            // thread blocked in waitUntilExit() cannot hang forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { box.forceKill() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        readHandle.readabilityHandler = nil
        let remaining = readHandle.readDataToEndOfFile()
        if !remaining.isEmpty {
            buffer.append(remaining)
        }

        let text = String(decoding: buffer.snapshot(), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let capped: String
        if lines.count > runShellLineCap {
            capped = lines.suffix(runShellLineCap).joined(separator: "\n")
        } else {
            capped = text
        }

        // Report a timeout distinctly so the model knows the command was killed
        // rather than that it merely exited non-zero.
        if box.didTimeOut {
            let note = "[timed out after \(Int(timeout))s and was terminated]"
            let body = capped.isEmpty ? note : capped + "\n" + note
            return ToolOutput(output: body, isError: true)
        }
        return ToolOutput(output: capped, isError: process.terminationStatus != 0)
    }
}
