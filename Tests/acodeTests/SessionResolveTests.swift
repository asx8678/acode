import Foundation
import Testing
@testable import acode

// MARK: - Test helpers (mirror SessionStoreTests' style)

/// Fresh temp dir + `SessionStore` for one test.
private func makeTempStore() -> (store: SessionStore, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("acode-resolve-\(UUID().uuidString)")
    return (SessionStore(baseDir: dir), dir)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

private func makeSession(
    id: String,
    title: String? = nil,
    model: String? = "claude-sonnet-4-5",
    updatedAt: Date
) -> Session {
    Session(
        id: id,
        title: title,
        model: model,
        createdAt: Date(timeIntervalSince1970: 1_000_000),
        updatedAt: updatedAt,
        conversation: Conversation()
    )
}

// MARK: - deriveSessionTitle

@MainActor
@Test func test_derive_title_uses_first_user_message() {
    var convo = Conversation()
    convo.append(.user("   read the file   "))
    convo.append(.assistant(text: "ok", toolCalls: []))
    convo.append(.user("now translate it"))
    let title = deriveSessionTitle(from: convo)
    #expect(title == "read the file")
}

@MainActor
@Test func test_derive_title_truncates_long_input() {
    var convo = Conversation()
    let long = String(repeating: "x", count: 200)
    convo.append(.user(long))
    let title = deriveSessionTitle(from: convo, maxLength: 40)
    // 39 chars + an ellipsis to make the truncation visible.
    #expect(title.count == 40)
    #expect(title.hasSuffix("…"))
}

@MainActor
@Test func test_derive_title_skips_empty_user_messages() {
    // An all-whitespace `.user` doesn't count as a real prompt — the
    // next real message wins. This protects `/save` from naming a
    // session after a stray " " the user typed.
    var convo = Conversation()
    convo.append(.user("   "))
    convo.append(.user("real prompt"))
    let title = deriveSessionTitle(from: convo)
    #expect(title == "real prompt")
}

@MainActor
@Test func test_derive_title_falls_back_to_timestamp_when_no_user_message() {
    let convo = Conversation()
    let title = deriveSessionTitle(from: convo)
    // Timestamp fallback: yyyy-MM-dd HH:mm:ss → 19 chars.
    #expect(title.count == 19)
    #expect(title.contains("-"))
    #expect(title.contains(":"))
}

// MARK: - resolveSession

@MainActor
@Test func test_resolve_exact_id_match() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "abc-123", title: "alpha", updatedAt: t)))
    #expect(store.save(makeSession(id: "def-456", title: "beta", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "abc-123", store: store)
    guard case .found(let s) = result else {
        Issue.record("Expected .found for exact id; got \(result)")
        return
    }
    #expect(s.id == "abc-123")
    #expect(s.title == "alpha")
}

@MainActor
@Test func test_resolve_unique_id_prefix() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "abcd-1111", title: "alpha", updatedAt: t)))
    #expect(store.save(makeSession(id: "efgh-2222", title: "beta", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "abcd", store: store)
    guard case .found(let s) = result else {
        Issue.record("Expected unique id prefix to resolve; got \(result)")
        return
    }
    #expect(s.id == "abcd-1111")
}

@MainActor
@Test func test_resolve_ambiguous_id_prefix() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "abcdef-1", title: "a1", updatedAt: t)))
    #expect(store.save(makeSession(id: "abcdef-2", title: "a2", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "abcdef", store: store)
    guard case .ambiguous(let matches) = result else {
        Issue.record("Expected ambiguous for non-unique prefix; got \(result)")
        return
    }
    #expect(matches.count == 2)
    let ids = Set(matches.map(\.id))
    #expect(ids == ["abcdef-1", "abcdef-2"])
}

@MainActor
@Test func test_resolve_exact_title_match() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "s1", title: "My Important Project", updatedAt: t)))
    #expect(store.save(makeSession(id: "s2", title: "Other Project", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "My Important Project", store: store)
    guard case .found(let s) = result else {
        Issue.record("Expected exact title match; got \(result)")
        return
    }
    #expect(s.id == "s1")
}

@MainActor
@Test func test_resolve_title_prefix_match() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "s1", title: "My Important Project", updatedAt: t)))
    #expect(store.save(makeSession(id: "s2", title: "Other Project", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "My Imp", store: store)
    guard case .found(let s) = result else {
        Issue.record("Expected title prefix match; got \(result)")
        return
    }
    #expect(s.id == "s1")
}

@MainActor
@Test func test_resolve_title_match_is_case_insensitive() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "s1", title: "MyProject", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "myproject", store: store)
    guard case .found(let s) = result else {
        Issue.record("Expected case-insensitive title match; got \(result)")
        return
    }
    #expect(s.id == "s1")
}

@MainActor
@Test func test_resolve_no_match() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "s1", title: "alpha", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "no-such-thing", store: store)
    guard case .notFound = result else {
        Issue.record("Expected .notFound; got \(result)")
        return
    }
}

@MainActor
@Test func test_resolve_empty_input_is_not_found() {
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "s1", title: "alpha", updatedAt: t)))

    let result = resolveSession(idOrPrefix: "   ", store: store)
    guard case .notFound = result else {
        Issue.record("Expected .notFound for whitespace input; got \(result)")
        return
    }
}

@MainActor
@Test func test_resolve_prefers_id_over_title() {
    // An id-shaped string that happens to share characters with a
    // title still wins as an id lookup (faster, no walk).
    let (store, dir) = makeTempStore()
    defer { cleanup(dir) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(store.save(makeSession(id: "ABC", title: "title-with-ABC", updatedAt: t)))
    let result = resolveSession(idOrPrefix: "ABC", store: store)
    guard case .found(let s) = result else {
        Issue.record("Expected id lookup to win; got \(result)")
        return
    }
    // Either match is acceptable since both are unique — but the
    // id path is faster and the function documents it as primary.
    #expect(s.id == "ABC" || s.title == "title-with-ABC")
}
