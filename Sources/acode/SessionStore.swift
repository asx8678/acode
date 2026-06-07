import Foundation

/// File-backed persistence for `Session`.
///
/// `baseDir` is injected so tests can point at a temp dir; production code
/// uses `SessionStore.default`. Files are `<baseDir>/<id>.json`. The store
/// never throws — every failure mode (missing file, corrupt JSON, unwritable
/// directory) returns `nil` or `false` so callers can degrade gracefully
/// (a failed save shouldn't crash the REPL, a missing id shouldn't crash
/// `--resume`).
///
/// The atomic-write + backup pattern mirrors `saveApprovals` in `Config.swift`:
/// read the existing file → back it up to `<path>.bak` → ensure the
/// directory exists → write the new content with `.atomic`. With atomic
/// writes the `.bak` is mostly belt-and-suspenders, but it preserves the
/// previous good version if a buggy future build writes garbage.
///
/// **Sendable + nonisolated** so callers (e.g. `Acode.run()`'s
/// `resolveStartupSession`) can read the store from any isolation. File
/// I/O is synchronous and the store holds no mutable state.
nonisolated struct SessionStore: Sendable {
    /// Directory the store reads from and writes to. Injected for testability.
    let baseDir: URL

    /// The production store under `~/.config/acode/sessions`.
    nonisolated static let `default` = SessionStore(
        baseDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/acode/sessions")
    )

    /// Filesystem URL for a given session id. The id is sanitized to a
    /// safe filename (no separators, no `..`, no leading `.`) AND the
    /// resulting URL is validated to still be inside `baseDir`. Either
    /// guard alone is insufficient: a sanitization bug could let a
    /// crafted id escape; a containment-only check can't prevent
    /// weird file names. Both layers run, on the read and write paths,
    /// so a malicious JSON `id` field can't write outside the store.
    /// Exposed for tests that want to inspect or pre-seed files
    /// directly.
    func url(for id: String) -> URL? {
        let sanitized = Self.sanitize(id: id)
        guard let safe = sanitized else { return nil }
        let candidate = baseDir.appendingPathComponent("\(safe).json")
        // Defense in depth: even with sanitization, validate the
        // resolved path is still inside `baseDir`. A future change
        // to `sanitize(id:)` (or a symlink planted under `baseDir`)
        // could re-introduce a traversal; the standardized-path
        // containment check catches it before any I/O.
        return Self.contains(baseDir: baseDir, url: candidate) ? candidate : nil
    }

    /// Returns a filename-safe form of `id` (non-empty, no `/` or
    /// `..`, no leading `.`), or `nil` if no safe form exists.
    /// Replaces every disallowed character with `_` and folds any
    /// run of `..` segments into a single `_`. An id that is empty
    /// or reduces to all-`_` is rejected (no safe filename to use).
    nonisolated static func sanitize(id raw: String) -> String? {
        // Reject empty input outright.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Replace path separators, NULs, and any character that
        // could let a caller escape `baseDir` or write a hidden
        // file. The set is intentionally broader than the strict
        // minimum (e.g. it also drops `:`, `\`, control chars)
        // because session ids are user-supplied (they come from
        // `--resume <user-input>`, `/resume <user-input>`, and
        // session JSON files) and we'd rather over-restrict than
        // leave a path-traversal vector.
        let illegal: Set<Character> = Set("/\\:*?\"<>|\u{0}\u{1}\u{2}\u{3}\u{4}\u{5}\u{6}\u{7}\u{8}\u{9}\u{0A}\u{0B}\u{0C}\u{0D}\u{1B}\u{7F}")
        var replaced = String(trimmed.map { ch in
            illegal.contains(ch) ? "_" : ch
        })

        // Squash any `..` segment (after replacement, `_` is the
        // only allowed punctuation). This catches inputs that
        // spelled out `..` literally (the replacement left them
        // alone because `.` isn't in the illegal set).
        replaced = replaced.replacingOccurrences(of: "..", with: "_")

        // Reject leading dot (hidden file) and the empty result
        // (the whole id was illegal).
        guard !replaced.isEmpty, !replaced.hasPrefix(".") else { return nil }

        return replaced
    }

    /// True when `url.standardized.path` lives under
    /// `baseDir.standardized.path`. Symlink-resolved path
    /// containment for the store's read/write paths.
    nonisolated static func contains(baseDir: URL, url: URL) -> Bool {
        let base = baseDir.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        // `path` must start with `base + "/"` (or equal `base`,
        // which is rejected by callers — a session file can't
        // share the base dir's name). String prefix match is
        // acceptable here because both have been standardized
        // (no `..`, no symlinks).
        return path == base || path.hasPrefix(base + "/")
    }

    // MARK: - Write

    /// Persist `session` to `<baseDir>/<id>.json`. Returns `false` on any
    /// failure; never throws. The full message history is encoded verbatim —
    /// compaction is for context-window trimming only, never for persistence.
    @discardableResult
    func save(_ session: Session) -> Bool {
        // A loaded session whose JSON `id` is malicious (or
        // hand-edited) must not be able to write outside `baseDir`.
        // `url(for:)` already sanitizes the id and validates
        // containment; we re-check here on the write path.
        guard let url = url(for: session.id) else { return false }

        // Back up any existing file to `<path>.bak` first. Mirrors the
        // saveApprovals pattern: keep the previous good copy in case a
        // buggy write produces a corrupt file.
        if let existing = try? Data(contentsOf: url) {
            let backupURL = URL(fileURLWithPath: url.path + ".bak")
            do {
                try existing.write(to: backupURL, options: .atomic)
            } catch {
                return false
            }
        }

        guard let data = try? Session.encoder().encode(session) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: baseDir, withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Read

    /// Load a session by id, returning `nil` for any failure (missing file,
    /// corrupt JSON, wrong shape, or a malformed id that can't be
    /// resolved safely inside `baseDir`). Never throws.
    func load(id: String) -> Session? {
        // Same containment guard as the write path: a session
        // file under `baseDir` is the only legal target. Any id
        // that can't be turned into a safe URL yields `nil`
        // (and crucially, never throws or reads a file outside
        // the store).
        guard let url = url(for: id) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Session.decoder().decode(Session.self, from: data)
    }

    /// List every parseable session in `baseDir`, sorted by `updatedAt`
    /// descending (newest first). Corrupt or wrongly-typed files are
    /// silently skipped — a single bad file mustn't take down `/sessions`.
    /// Returns an empty array if `baseDir` doesn't exist.
    func list() -> [Session] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = Session.decoder()
        let sessions: [Session] = entries
            // `.pathExtension == "json"` already excludes `.json.bak`
            // (whose extension is `.bak`), so no suffix check is
            // needed. Walking the directory via `contentsOfDirectory`
            // also excludes subdirectories and any non-file entries.
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Session.self, from: data)
            }

        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The newest session by `updatedAt`, or `nil` if the store is empty.
    /// This is what `--continue` will resolve against in swift-be0.4.
    func mostRecent() -> Session? {
        list().first
    }
}
