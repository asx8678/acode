import Foundation
import Testing
@testable import acode

// MARK: - Helpers

/// Makes a fresh temp directory for one test and removes it on exit.
private func makeTempStore() -> (store: SessionStore, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-sessionstore-\(UUID().uuidString)")
    return (SessionStore(baseDir: dir), dir)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

private func toolCall(_ id: String) -> ToolCall {
    ToolCall(id: id, name: "read_file", arguments: .object(["path": .string("/tmp/\(id).txt")]))
}

private func toolResult(_ id: String, output: String = "ok") -> ToolResult {
    ToolResult(callID: id, output: output, isError: false)
}

/// Builds a session at an explicit `updatedAt` so list-ordering tests are
/// deterministic without sleeping.
private func makeSession(
    id: String,
    title: String? = nil,
    model: String? = "claude-sonnet-4-5",
    createdAt: Date = Date(timeIntervalSince1970: 1_000_000),
    updatedAt: Date,
    messages: [Message] = []
) -> Session {
    var convo = Conversation()
    for m in messages { convo.append(m) }
    return Session(
        id: id,
        title: title,
        model: model,
        createdAt: createdAt,
        updatedAt: updatedAt,
        conversation: convo
    )
}

/// B2 invariant: every assistant tool_use is followed by matching
/// `.toolResults`, and every `.toolResults` is preceded by matching
/// assistant tool_use. Inlined (not shared with ConversationTests) because
/// the original is `private` to that file.
private func assertPairsIntact(_ messages: [Message]) {
    for (index, message) in messages.enumerated() {
        switch message {
        case .assistant(_, let calls) where !calls.isEmpty:
            guard index + 1 < messages.count,
                case .toolResults(let results) = messages[index + 1]
            else {
                Issue.record("assistant tool_use without following tool_results")
                return
            }
            let callIDs = Set(calls.map(\.id))
            let resultIDs = Set(results.map(\.callID))
            #expect(!callIDs.isDisjoint(with: resultIDs))

        case .toolResults(let results):
            guard index > 0,
                case .assistant(_, let calls) = messages[index - 1],
                !calls.isEmpty
            else {
                Issue.record("tool_results without preceding tool_use")
                return
            }
            let callIDs = Set(calls.map(\.id))
            let resultIDs = Set(results.map(\.callID))
            #expect(!callIDs.isDisjoint(with: resultIDs))

        default:
            break
        }
    }
}

// MARK: - Tests (P2: swift-be0.2)

@Test func test_sessionstore_save_load_roundtrip() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    let original = makeSession(
        id: "roundtrip-1",
        title: "hello",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        messages: [
            .user("read it"),
            .assistant(text: "Reading.", toolCalls: [toolCall("c1")]),
            .toolResults([toolResult("c1", output: "contents")]),
        ]
    )

    #expect(store.save(original))
    #expect(FileManager.default.fileExists(atPath: store.url(for: "roundtrip-1").path))

    guard let loaded = store.load(id: "roundtrip-1") else {
        Issue.record("Expected load to return a session")
        return
    }
    #expect(loaded.id == "roundtrip-1")
    #expect(loaded.title == "hello")
    #expect(loaded.model == "claude-sonnet-4-5")
    #expect(loaded.version == Session.currentVersion)
    #expect(loaded.createdAt == original.createdAt)
    #expect(loaded.updatedAt == original.updatedAt)
    #expect(loaded.conversation.messages.count == 3)
}

@Test func test_sessionstore_load_missing_id_returns_nil() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    #expect(store.load(id: "never-saved") == nil)
}

@Test func test_sessionstore_b2_pairing_preserved_through_disk() {
    // The store must serialize the FULL message history verbatim — no
    // compaction, no trimming. A round-trip through disk must preserve
    // assistant tool_use immediately followed by .toolResults, in order,
    // with matching call IDs (B2).
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    let call = toolCall("call_b2")
    let session = makeSession(
        id: "b2-disk",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        messages: [
            .user("read the file"),
            .assistant(text: "Reading now.", toolCalls: [call]),
            .toolResults([toolResult("call_b2", output: "file contents")]),
            .assistant(text: "It contains 'file contents'.", toolCalls: []),
        ]
    )

    #expect(store.save(session))
    guard let loaded = store.load(id: "b2-disk") else {
        Issue.record("Expected b2-disk to load")
        return
    }

    // Order preserved.
    #expect(loaded.conversation.messages.count == 4)
    // Tool_use at index 1, tool_results at index 2 — unchanged.
    guard case .assistant(_, let calls) = loaded.conversation.messages[1] else {
        Issue.record("Expected assistant tool_use at index 1")
        return
    }
    #expect(calls.first?.id == "call_b2")

    guard case .toolResults(let results) = loaded.conversation.messages[2] else {
        Issue.record("Expected toolResults at index 2")
        return
    }
    #expect(results.first?.callID == "call_b2")
    #expect(results.first?.output == "file contents")

    // Pairing invariant holds across the disk boundary.
    assertPairsIntact(loaded.conversation.messages)
}

@Test func test_sessionstore_list_orders_by_updatedAt_desc() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    let oldest = makeSession(
        id: "oldest",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let middle = makeSession(
        id: "middle",
        updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
    )
    let newest = makeSession(
        id: "newest",
        updatedAt: Date(timeIntervalSince1970: 1_700_002_000)
    )

    #expect(store.save(middle))
    #expect(store.save(oldest))
    #expect(store.save(newest))

    let listed = store.list()
    #expect(listed.map(\.id) == ["newest", "middle", "oldest"])
}

@Test func test_sessionstore_list_skips_corrupt_files() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    let good = makeSession(
        id: "good",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(store.save(good))

    // Drop a corrupt JSON file alongside the valid one. The store must
    // skip it (not throw, not include it, not take down the whole list).
    let corruptURL = dir.appendingPathComponent("corrupt.json")
    try? Data("this is not json".utf8).write(to: corruptURL)

    // Also a .bak file — those are filtered out by extension suffix.
    let bakURL = dir.appendingPathComponent("good.json.bak")
    try? Data("{}".utf8).write(to: bakURL)

    let listed = store.list()
    #expect(listed.count == 1)
    #expect(listed.first?.id == "good")
}

@Test func test_sessionstore_list_empty_dir_returns_empty() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    #expect(store.list().isEmpty)
    #expect(store.mostRecent() == nil)
}

@Test func test_sessionstore_mostRecent_returns_newest() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "a", updatedAt: t)))
    #expect(store.save(makeSession(id: "b", updatedAt: t.addingTimeInterval(60))))
    #expect(store.save(makeSession(id: "c", updatedAt: t.addingTimeInterval(120))))

    guard let most = store.mostRecent() else {
        Issue.record("Expected mostRecent to return a session")
        return
    }
    #expect(most.id == "c")
}

@Test func test_sessionstore_save_creates_dir_if_missing() {
    // The baseDir doesn't exist yet — save() must create it (and any
    // missing parents) before writing. Mirrors saveApprovals' pattern.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-sessionstore-\(UUID().uuidString)")
        .appendingPathComponent("nested/deep")
    let store = SessionStore(baseDir: dir)
    defer { cleanup(dir.deletingLastPathComponent().deletingLastPathComponent()) }

    let session = makeSession(
        id: "deep",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(store.save(session))
    #expect(FileManager.default.fileExists(atPath: store.url(for: "deep").path))
}

@Test func test_sessionstore_save_overwrites_existing() {
    // A save with the same id replaces the prior file (and backs the
    // previous one up to .bak, mirroring saveApprovals).
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }

    let v1 = makeSession(
        id: "evolving",
        title: "v1",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let v2 = makeSession(
        id: "evolving",
        title: "v2",
        updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
    )

    #expect(store.save(v1))
    #expect(store.save(v2))

    guard let loaded = store.load(id: "evolving") else {
        Issue.record("Expected evolving to load")
        return
    }
    #expect(loaded.title == "v2")
    #expect(loaded.updatedAt == v2.updatedAt)

    // The .bak from the first save should exist.
    let bakURL = URL(fileURLWithPath: store.url(for: "evolving").path + ".bak")
    #expect(FileManager.default.fileExists(atPath: bakURL.path))
}
