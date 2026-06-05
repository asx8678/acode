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

    nonisolated func set(_ p: Process) {
        lock.lock()
        process = p
        lock.unlock()
    }

    nonisolated func terminate() {
        lock.lock()
        process?.terminate()
        lock.unlock()
    }
}

/// Maximum number of trailing output lines returned.
private nonisolated let runShellLineCap = 256

/// Runs a shell command via `/bin/zsh -c`, gated by approval (invariant B9).
///
/// The jail does not confine the shell; approval is its only gate.
struct RunShellTool: Tool {
    let requiresApproval = true

    /// Timeout in seconds; injectable so later tasks can use a short value.
    var timeout: TimeInterval = 60

    static var schema: ToolSchema {
        ToolSchema(
            name: "run_shell",
            description: "Run a shell command with /bin/zsh in the project root. Requires approval.",
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
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: ProjectJail.root)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer()
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
        }

        box.set(process)
        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return ToolOutput(
                output: "Could not launch shell: \(error.localizedDescription)",
                isError: true
            )
        }

        let timeoutItem = DispatchWorkItem { box.terminate() }
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
        return ToolOutput(output: capped, isError: process.terminationStatus != 0)
    }
}
