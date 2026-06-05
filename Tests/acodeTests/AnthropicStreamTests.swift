import Foundation
import Testing
@testable import acode

@Test func test_anthropic_stream_maps_events() {
    let lines = [
        "event: message_start",
        #"data: {"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
        "",
        "event: content_block_start",
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
        "event: content_block_delta",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
        #"data: {"type":"content_block_stop","index":0}"#,
        "",
        #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"read_file"}}"#,
        #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
        #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"README.md\"}"}}"#,
        #"data: {"type":"content_block_stop","index":1}"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
        "",
        #"data: {"type":"message_stop"}"#
    ]

    let assembler = ResponseAssembler()
    let events = AnthropicProvider.events(forSSELines: lines, assembler: assembler)

    let texts = events.compactMap { event -> String? in
        if case .textDelta(let t) = event { return t }
        return nil
    }
    #expect(texts.contains("Hello"))

    let calls = events.compactMap { event -> ToolCall? in
        if case .toolCall(let c) = event { return c }
        return nil
    }
    #expect(calls.count == 1)
    #expect(calls.first?.name == "read_file")
    #expect(calls.first?.arguments["path"]?.stringValue == "README.md")

    guard case .done? = events.last else {
        Issue.record("Expected a final .done event.")
        return
    }
}
