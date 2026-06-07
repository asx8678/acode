import Foundation

/// A sink the agent loop uses to render user-facing output.
///
/// This is the "render seam" extracted from `Renderer` for the TUI work in
/// `TUI_PLAN.md` §3. The line-mode `Renderer` and the future TUI `ScreenRenderer`
/// are both implementations. By design the seam is `Sendable` and the approval
/// hook is `async` (§4): the TUI will park the call on a `CheckedContinuation`
/// while the user decides, and the line-mode `Renderer` simply keeps its
/// synchronous `readLine` body inside an `async` function.
protocol RenderSink: Sendable {
    func banner()
    func streamText(_ s: String)
    func endAssistant()
    func usage(_ u: Usage)
    func phase(_ p: String)
    func toolStart(_ c: ToolCall)
    func toolEnd(_ c: ToolCall, _ r: ToolResult)
    /// Widened from synchronous to `async` for the TUI approval path.
    /// The line-mode `Renderer` keeps its `readLine` body verbatim — an async
    /// function is allowed to call `readLine`.
    func approve(_ c: ToolCall) async -> Bool
    func verboseLog(_ message: String)
}
