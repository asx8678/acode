import Foundation

// MARK: - Title derivation (swift-be0.3)
//
// Helper: when the user runs `/save` with no name, derive a short
// human-readable title from the conversation. The first `.user`
// message is the canonical anchor (it's what the user actually
// wrote); a timestamp is the fallback when history is empty.

/// Derives a short title from `conversation` for use as a default
/// session title. The first non-empty `.user` message is trimmed
/// to `maxLength` characters; if there is no user message (e.g. a
/// fresh, empty session), the function falls back to a compact
/// ISO-8601 timestamp.
///
/// `maxLength` defaults to 40 — long enough for a useful preview,
/// short enough to fit in a one-line `print` row in `/sessions`.
/// A short prefix is also visibly distinct across multiple
/// sessions in `/sessions` output (the table is sorted newest
/// first, so the freshest title floats to the top).
func deriveSessionTitle(from conversation: Conversation, maxLength: Int = 40) -> String {
    for message in conversation.messages {
        if case .user(let text) = message {
            let trimmed = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.count <= maxLength { return trimmed }
                // Cut at maxLength-1 and append an ellipsis to make
                // the truncation visible. We deliberately don't
                // snap to a word boundary — short prompts are
                // typically short phrases, and snapping can chew
                // the meaning.
                return String(trimmed.prefix(maxLength - 1)) + "…"
            }
        }
    }
    // No user message → fall back to a compact timestamp so the
    // title is still distinct from other empty-history sessions
    // saved in the same minute (down to the second).
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date())
}

// MARK: - Session resolution (swift-be0.4)
//
// Helper: `--resume <idOrPrefix>` (and the slash form `/resume
// <name>`) can accept a UUID, an id prefix, an exact title, or a
// title prefix. The exact-id path is fast (one file read); the
// others walk the store. We centralize the policy here so the
// `Acode.run()` and `CommandHandler` paths share one
// implementation and the tests can exercise every branch.

/// The resolution outcome, surfaced so the CLI/REPL can print
/// helpful diagnostics (e.g. "2 sessions match that prefix" vs.
/// "no such session"). `nil` candidates + non-empty input means
/// "no match"; multiple candidates means "ambiguous" — call
/// sites print the matching set so the user can disambiguate.
enum SessionResolution {
    case found(Session)
    case notFound
    case ambiguous(matches: [Session])
}

/// Resolves `idOrPrefix` against `store`. Resolution order:
///
/// 1. **Exact id.** `store.load(id:)` — fast path, hits a single file.
/// 2. **Unique id prefix.** Any session whose UUID starts with the
///    input. Uniqueness required; ambiguity is reported.
/// 3. **Exact title match** (case-insensitive). Uniqueness required.
/// 4. **Title prefix match** (case-insensitive). Uniqueness required.
///
/// The "last" sentinel is handled at the call site (it expands
/// to `store.mostRecent()` before calling this helper). The
/// "list" path (`/sessions`) bypasses this helper entirely and
/// calls `store.list()` directly.
func resolveSession(idOrPrefix: String, store: SessionStore) -> SessionResolution {
    let needle = idOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return .notFound }

    // 1. Exact id (fastest path: one file read).
    if let exact = store.load(id: needle) {
        return .found(exact)
    }

    let all = store.list()

    // 2. Unique id prefix.
    let idPrefix = all.filter { $0.id.hasPrefix(needle) }
    if idPrefix.count == 1 {
        return .found(idPrefix[0])
    }
    if idPrefix.count > 1 {
        return .ambiguous(matches: idPrefix)
    }

    // 3. Exact title (case-insensitive). Empty title is ignored.
    let lower = needle.lowercased()
    let exactTitles = all.filter { session in
        guard let t = session.title else { return false }
        return t.lowercased() == lower
    }
    if exactTitles.count == 1 {
        return .found(exactTitles[0])
    }
    if exactTitles.count > 1 {
        return .ambiguous(matches: exactTitles)
    }

    // 4. Title prefix (case-insensitive).
    let titlePrefix = all.filter { session in
        guard let t = session.title else { return false }
        return t.lowercased().hasPrefix(lower)
    }
    if titlePrefix.count == 1 {
        return .found(titlePrefix[0])
    }
    if titlePrefix.count > 1 {
        return .ambiguous(matches: titlePrefix)
    }

    return .notFound
}
