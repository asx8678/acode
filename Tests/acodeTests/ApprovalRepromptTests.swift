import Foundation
import Testing
@testable import acode

/// Tests that manipulate the process-global stdin file descriptor. They are
/// grouped in a `.serialized` suite so they never run concurrently with each
/// other (swift-testing parallelizes by default); no other test touches stdin.
@Suite(.serialized)
struct StdinSensitiveTests {

    /// Reproduction for the "approve-all keeps re-prompting" report at the unit
    /// level. Exercises the real `Renderer.approve` path (which reads stdin via
    /// `readLine()`) — the unit the existing ApprovalTests skip by passing
    /// closures directly. Feeds a SINGLE `a` (approve-all), then approves twice;
    /// the second call must auto-approve WITHOUT touching stdin.
    @Test func approveAllPersistsAcrossCalls() async throws {
        let saved = dup(STDIN_FILENO)
        defer { if saved >= 0 { dup2(saved, STDIN_FILENO); close(saved) } }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acode-stdin-\(UUID().uuidString)")
        try "a\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard freopen(tmp.path, "r", stdin) != nil else {
            Issue.record("freopen(stdin) failed")
            return
        }

        let policy = ApprovalPolicy()
        let renderer = Renderer(color: false, verbose: false, policy: policy)
        let first = ToolCall(id: "c1", name: "run_shell",
                             arguments: .object(["command": .string("echo a")]))
        let second = ToolCall(id: "c2", name: "run_shell",
                              arguments: .object(["command": .string("echo b")]))

        #expect(await renderer.approve(first) == true)          // consumes "a" → approve-all
        #expect(policy.shouldAutoApprove("run_shell", command: "echo b") == true)
        #expect(await renderer.approve(second) == true)          // auto-approved, no stdin read
    }

    /// Regression test for the actual re-prompt cause: a `run_shell` child must
    /// NOT inherit the terminal's stdin, or it can swallow the keystrokes meant
    /// for the next approval prompt. We point the PARENT's stdin at a sentinel
    /// and run `cat` (echoes stdin to stdout). The child must see `/dev/null`
    /// (EOF), so the sentinel must NOT appear in the output.
    @Test func runShellChildDoesNotInheritStdin() async throws {
        let saved = dup(STDIN_FILENO)
        defer { if saved >= 0 { dup2(saved, STDIN_FILENO); close(saved) } }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acode-stdin-leak-\(UUID().uuidString)")
        try "LEAKED-STDIN\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard freopen(tmp.path, "r", stdin) != nil else {
            Issue.record("freopen(stdin) failed")
            return
        }

        let result = await RunShellTool.execute(command: "cat", timeout: 5)

        #expect(result.isError == false)
        #expect(!result.output.contains("LEAKED-STDIN"))
    }
}
