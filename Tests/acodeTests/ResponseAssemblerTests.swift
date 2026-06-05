import Foundation
import Testing
@testable import acode

@Test func test_assembler_text_and_toolcall() {
    let assembler = ResponseAssembler()
    let payloads = [
        #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"read_file"}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"README.md\"}"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
        #"{"type":"message_stop"}"#
    ]

    var events: [StreamEvent] = []
    for payload in payloads {
        events.append(contentsOf: assembler.ingest(payload))
    }

    // Text delta emitted.
    let texts = events.compactMap { event -> String? in
        if case .textDelta(let t) = event { return t }
        return nil
    }
    #expect(texts == ["Hello"])

    // Exactly one tool call, with correct name and parsed arguments.
    let calls = events.compactMap { event -> ToolCall? in
        if case .toolCall(let c) = event { return c }
        return nil
    }
    #expect(calls.count == 1)
    #expect(calls.first?.name == "read_file")
    #expect(calls.first?.arguments["path"]?.stringValue == "README.md")

    // Final done with captured stop reason and usage.
    guard case .done(let stop, let usage)? = events.last else {
        Issue.record("Expected a final .done event.")
        return
    }
    #expect(stop == "tool_use")
    #expect(usage.input == 12)
    #expect(usage.output == 7)
}
