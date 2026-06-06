import Foundation

/// The role of a participant in a model conversation.
enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// A model-requested invocation of a registered tool.
struct ToolCall: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let arguments: JSONValue
}

/// The outcome of executing a `ToolCall`.
struct ToolResult: Codable, Sendable, Equatable {
    let callID: String
    let output: String
    let isError: Bool
}

/// A single turn in the conversation history.
enum Message: Sendable, Equatable, Codable {
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResults([ToolResult])

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolResults = "tool_results"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(Role.self, forKey: .role)
        switch role {
        case .user:
            self = .user(try container.decode(String.self, forKey: .content))
        case .assistant:
            let text = try container.decode(String.self, forKey: .content)
            let toolCalls = try container.decode([ToolCall].self, forKey: .toolCalls)
            self = .assistant(text: text, toolCalls: toolCalls)
        case .tool:
            self = .toolResults(try container.decode([ToolResult].self, forKey: .toolResults))
        case .system:
            throw DecodingError.dataCorruptedError(
                forKey: .role,
                in: container,
                debugDescription: "Unsupported message role: system."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let text):
            try container.encode(Role.user, forKey: .role)
            try container.encode(text, forKey: .content)
        case .assistant(let text, let toolCalls):
            try container.encode(Role.assistant, forKey: .role)
            try container.encode(text, forKey: .content)
            try container.encode(toolCalls, forKey: .toolCalls)
        case .toolResults(let results):
            try container.encode(Role.tool, forKey: .role)
            try container.encode(results, forKey: .toolResults)
        }
    }
}

/// A minimal JSON value model used for tool arguments and JSON-Schema fragments.
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Looks up a key in an object value, returning nil for non-objects or missing keys.
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    /// The underlying string, when this value is a string.
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// The underlying number as an integer, when this value is a number.
    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    /// Converts this JSONValue tree to an `Any` tree suitable for
    /// `JSONSerialization.data(withJSONObject:)`.
    nonisolated var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map(\.anyValue)
        case .object(let obj): return obj.mapValues { $0.anyValue }
        }
    }

    /// Parses an accumulated partial-JSON buffer into a `JSONValue`,
    /// falling back to an empty object on failure or empty input.
    nonisolated static func parseArguments(_ buffer: String) -> JSONValue {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return value
    }
}
