import Foundation
import Testing
@testable import acode

// MARK: - transcriptItems(from:)
//
// Pure mapper used by `/resume` and `--resume`/`--continue` to
// rebuild the visible TUI transcript from a loaded `Conversation`.
// Tested in isolation so the TUI's MVU loop and `Msg` plumbing
// are not exercised (those need a real TTY).

@MainActor
@Test func test_transcript_items_maps_user_and_assistant() {
    var convo = Conversation()
    convo.append(.user("hi"))
    convo.append(.assistant(text: "hello back", toolCalls: []))

    let items = transcriptItems(from: convo)
    #expect(items.count == 2)
    guard case .user(let u) = items[0] else {
        Issue.record("Expected .user at index 0; got \(items[0])")
        return
    }
    #expect(u == "hi")
    guard case .assistant(let a) = items[1] else {
        Issue.record("Expected .assistant at index 1; got \(items[1])")
        return
    }
    #expect(a == "hello back")
}

@MainActor
@Test func test_transcript_items_emits_tool_view_per_call() {
    var convo = Conversation()
    convo.append(.user("read both"))
    let callA = ToolCall(id: "a", name: "read_file", arguments: .object([:]))
    let callB = ToolCall(id: "b", name: "read_file", arguments: .object([:]))
    convo.append(.assistant(text: "Reading.", toolCalls: [callA, callB]))

    let items = transcriptItems(from: convo)
    // user + assistant text + two tool views
    #expect(items.count == 4)
    guard case .tool(let tv1) = items[2] else {
        Issue.record("Expected .tool at index 2")
        return
    }
    #expect(tv1.name == "read_file")
    #expect(tv1.status == .running)
    guard case .tool(let tv2) = items[3] else {
        Issue.record("Expected .tool at index 3")
        return
    }
    #expect(tv2.name == "read_file")
    #expect(tv2.status == .running)
}

@MainActor
@Test func test_transcript_items_fills_tool_output_from_results() {
    // B2 pairing: assistant with tool_use followed by .toolResults
    // must map to a .tool row with the result's output and a
    // .ok status. A `restoreTranscript` cycle with the
    // (assistant, toolResults) pair should be visually
    // indistinguishable from a live stream.
    var convo = Conversation()
    let call = ToolCall(id: "c1", name: "read_file", arguments: .object([:]))
    convo.append(.assistant(text: "Reading.", toolCalls: [call]))
    convo.append(.toolResults([ToolResult(callID: "c1", output: "contents", isError: false)]))

    let items = transcriptItems(from: convo)
    // assistant text + 1 tool view (the .toolResults got merged in)
    #expect(items.count == 2)
    guard case .tool(let tv) = items[1] else {
        Issue.record("Expected .tool at index 1; got \(items[1])")
        return
    }
    #expect(tv.output == "contents")
    #expect(tv.status == .ok)
}

@MainActor
@Test func test_transcript_items_marks_error_results() {
    var convo = Conversation()
    let call = ToolCall(id: "c1", name: "read_file", arguments: .object([:]))
    convo.append(.assistant(text: "Reading.", toolCalls: [call]))
    convo.append(.toolResults([ToolResult(callID: "c1", output: "not found", isError: true)]))

    let items = transcriptItems(from: convo)
    guard case .tool(let tv) = items[1] else {
        Issue.record("Expected .tool at index 1")
        return
    }
    #expect(tv.status == .error)
    #expect(tv.output == "not found")
}

@MainActor
@Test func test_transcript_items_handles_assistant_with_no_text() {
    // An assistant turn with empty text but tool calls is legal
    // (e.g. pure tool_use); the mapper must NOT emit a phantom
    // empty `.assistant("")` row that the live reducer would have
    // skipped (see Agent.run: an empty assistant message is never
    // persisted to history).
    var convo = Conversation()
    let call = ToolCall(id: "c1", name: "list", arguments: .object([:]))
    convo.append(.assistant(text: "", toolCalls: [call]))

    let items = transcriptItems(from: convo)
    // One .tool view, no .assistant row.
    #expect(items.count == 1)
    guard case .tool = items[0] else {
        Issue.record("Expected a .tool row; got \(items[0])")
        return
    }
}

@MainActor
@Test func test_transcript_items_preserves_ordering() {
    // Sanity: the order in the conversation is the order on
    // screen. Useful as a regression guard if a future change
    // tries to batch tool results in a single `.tool` row.
    var convo = Conversation()
    convo.append(.user("a"))
    let c1 = ToolCall(id: "c1", name: "x", arguments: .object([:]))
    convo.append(.assistant(text: "b", toolCalls: [c1]))
    convo.append(.toolResults([ToolResult(callID: "c1", output: "c", isError: false)]))
    convo.append(.assistant(text: "d", toolCalls: []))

    let items = transcriptItems(from: convo)
    // user, assistant text, tool view (filled), assistant text
    #expect(items.count == 4)
    // Index 2 must be the (now-completed) tool view, index 3
    // must be the trailing assistant text — preserving
    // turn-by-turn order across the B2 boundary.
    guard case .tool(let tv) = items[2] else {
        Issue.record("Expected .tool at index 2")
        return
    }
    #expect(tv.status == .ok)
    guard case .assistant(let last) = items[3] else {
        Issue.record("Expected .assistant at index 3")
        return
    }
    #expect(last == "d")
}

@MainActor
@Test func test_transcript_items_empty_conversation() {
    let items = transcriptItems(from: Conversation())
    #expect(items.isEmpty)
}

@MainActor
@Test func test_transcript_items_parallel_tool_results_match_by_callID() {
    // swift-be0.7 #6: a single assistant turn with two PARALLEL
    // tool_use (a, b) produces a `.toolResults` with two
    // results, in some order — the order is not guaranteed by
    // either provider API (Anthropic streams them as they
    // finish; OpenAI sends them as a single block). The old
    // `lastIndex` matching paired results with the latest
    // running row regardless of `callID`, so a result for `a`
    // could end up on the `b` card. The fix matches by
    // `callID`; this test pins the contract.
    var convo = Conversation()
    let callA = ToolCall(id: "alpha", name: "read_file", arguments: .object([:]))
    let callB = ToolCall(id: "beta",  name: "read_file", arguments: .object([:]))
    convo.append(.user("read both"))
    convo.append(.assistant(text: "Reading both.", toolCalls: [callA, callB]))
    // Results arrive in REVERSED order (Beta finishes first).
    // The mapper must still attach "alpha output" to the alpha
    // card and "beta output" to the beta card.
    convo.append(.toolResults([
        ToolResult(callID: "beta",  output: "beta output", isError: false),
        ToolResult(callID: "alpha", output: "alpha output", isError: false),
    ]))

    let items = transcriptItems(from: convo)
    // user + assistant text + 2 tool views = 4 items
    #expect(items.count == 4)

    // Find the two .tool rows and assert each carries the
    // output of its own call (not the other's).
    let toolRows: [ToolView] = items.compactMap {
        if case .tool(let tv) = $0 { return tv } else { return nil }
    }
    #expect(toolRows.count == 2)
    let alphaRow = toolRows.first { $0.callID == "alpha" }
    let betaRow = toolRows.first { $0.callID == "beta" }
    #expect(alphaRow?.output == "alpha output")
    #expect(alphaRow?.status == .ok)
    #expect(betaRow?.output == "beta output")
    #expect(betaRow?.status == .ok)
}

@MainActor
@Test func test_transcript_items_parallel_tool_results_match_one_error() {
    // Same shape as above but with one of the parallel
    // tool calls failing. The error status must land on the
    // correct card; the success status on the other.
    var convo = Conversation()
    let callA = ToolCall(id: "alpha", name: "read_file", arguments: .object([:]))
    let callB = ToolCall(id: "beta",  name: "read_file", arguments: .object([:]))
    convo.append(.user("read both"))
    convo.append(.assistant(text: "Reading both.", toolCalls: [callA, callB]))
    convo.append(.toolResults([
        ToolResult(callID: "alpha", output: "alpha output", isError: false),
        ToolResult(callID: "beta",  output: "beta boom",    isError: true),
    ]))

    let items = transcriptItems(from: convo)
    let toolRows: [ToolView] = items.compactMap {
        if case .tool(let tv) = $0 { return tv } else { return nil }
    }
    let alphaRow = toolRows.first { $0.callID == "alpha" }
    let betaRow = toolRows.first { $0.callID == "beta" }
    #expect(alphaRow?.status == .ok)
    #expect(alphaRow?.output == "alpha output")
    #expect(betaRow?.status == .error)
    #expect(betaRow?.output == "beta boom")
}
