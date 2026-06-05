import Foundation

/// The role of a participant in a model conversation.
enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// A model-requested invocation of a registered tool.
struct ToolCall: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let arguments: JSONValue
}

/// The outcome of executing a `ToolCall`.
struct ToolResult: Codable, Sendable {
    let callID: String
    let output: String
    let isError: Bool
}

/// A single turn in the conversation history.
enum Message: Sendable {
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResults([ToolResult])
}

/// A minimal JSON value model used for tool arguments and JSON-Schema fragments.
enum JSONValue: Codable, Sendable, Equatable {
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
}
