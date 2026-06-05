import Foundation

/// Assembles Anthropic SSE `data:` payloads into `StreamEvent`s.
///
/// A pure, network-free state machine. It never throws: unrecognized or
/// malformed payloads are ignored and yield `[]` (the live stream is messy).
nonisolated final class ResponseAssembler {
    /// Per-index content-block state.
    private struct Block {
        var type: String
        var toolID: String?
        var toolName: String?
        var partialJSON: String = ""
    }

    private var blocks: [Int: Block] = [:]
    private var usage = Usage()
    private var stopReason: String?

    /// Ingests one SSE `data:` JSON payload and returns any resulting events.
    func ingest(_ ssePayload: String) -> [StreamEvent] {
        guard
            let data = ssePayload.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = root["type"] as? String
        else {
            return []
        }

        switch type {
        case "message_start":
            if
                let message = root["message"] as? [String: Any],
                let usageObject = message["usage"] as? [String: Any],
                let input = usageObject["input_tokens"] as? Int {
                usage.input = input
            }
            return []

        case "content_block_start":
            guard let index = root["index"] as? Int else { return [] }
            let block = root["content_block"] as? [String: Any]
            let blockType = (block?["type"] as? String) ?? "text"
            var entry = Block(type: blockType)
            if blockType == "tool_use" {
                entry.toolID = block?["id"] as? String
                entry.toolName = block?["name"] as? String
            }
            blocks[index] = entry
            return []

        case "content_block_delta":
            guard let index = root["index"] as? Int, let delta = root["delta"] as? [String: Any] else {
                return []
            }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String {
                    return [.textDelta(text)]
                }
                return []
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    blocks[index]?.partialJSON += partial
                }
                return []
            default:
                return []
            }

        case "content_block_stop":
            guard let index = root["index"] as? Int, let block = blocks[index] else { return [] }
            guard
                block.type == "tool_use",
                let id = block.toolID,
                let name = block.toolName
            else {
                return []
            }
            let arguments = Self.parseArguments(block.partialJSON)
            return [.toolCall(ToolCall(id: id, name: name, arguments: arguments))]

        case "message_delta":
            if let delta = root["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                stopReason = stop
            }
            if let usageObject = root["usage"] as? [String: Any], let output = usageObject["output_tokens"] as? Int {
                usage.output = output
            }
            return []

        case "message_stop":
            return [.done(stop: stopReason ?? "end", usage: usage)]

        default:
            return []
        }
    }

    /// Parses an accumulated partial-JSON tool-input buffer into a JSONValue,
    /// falling back to an empty object on failure or empty input.
    private static func parseArguments(_ buffer: String) -> JSONValue {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let data = trimmed.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .object([:])
        }
        return value
    }
}
