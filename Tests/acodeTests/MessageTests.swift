import Foundation
import Testing
@testable import acode

@Test func test_jsonvalue_roundtrip() throws {
    let original: JSONValue = .object([
        "name": .string("acode"),
        "version": .number(1),
        "ready": .bool(true),
        "empty": .null,
        "tags": .array([.string("cli"), .number(42), .bool(false)]),
        "nested": .object([
            "enabled": .bool(true),
            "scores": .array([.number(1), .number(2), .number(3)])
        ])
    ])

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect(decoded == original)
}
