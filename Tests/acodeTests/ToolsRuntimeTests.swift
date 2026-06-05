import Foundation
import Testing
@testable import acode

@Test func test_read_file_tmp() async throws {
    // read_file is jailed, so write the temp file under ProjectJail.root.
    let name = "acode-read-test-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    let body = "line one\nline two\nline three"
    try body.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let tool = ReadFileTool()
    let result = await tool.run(.object(["path": .string(name)]))

    #expect(result.isError == false)
    #expect(result.output == body)
}

@Test func test_run_shell_echo() async {
    let tool = RunShellTool()
    let result = await tool.run(.object(["command": .string("echo hi")]))

    #expect(result.isError == false)
    #expect(result.output.contains("hi"))
}

@Test func test_run_shell_no_deadlock() async {
    let tool = RunShellTool()
    let result = await tool.run(.object(["command": .string("seq 1 60000")]))

    #expect(result.isError == false)
    // Output is capped to the last 256 lines; the last line of seq is 60000.
    #expect(result.output.contains("60000"))
}

@Test func test_run_shell_cancellable() async {
    let start = Date()
    let task = Task { () -> ToolOutput in
        let tool = RunShellTool()
        return await tool.run(.object(["command": .string("sleep 5")]))
    }
    // Give the process a moment to start, then cancel.
    try? await Task.sleep(for: .milliseconds(200))
    task.cancel()
    _ = await task.value

    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 4.0)
}
