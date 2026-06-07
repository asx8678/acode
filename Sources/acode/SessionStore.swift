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
struct SessionStore: Sendable {
    /// Directory the store reads from and writes to. Injected for testability.
    let baseDir: URL

    /// The production store under `~/.config/acode/sessions`.
    static let `default` = SessionStore(
        baseDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/acode/sessions")
    )

    /// Filesystem URL for a given session id. Exposed for tests that want
    /// to inspect or pre-seed files directly.
    func url(for id: String) -> URL {
        baseDir.appendingPathComponent("\(id).json")
    }

    // MARK: - Write

    /// Persist `session` to `<baseDir>/<id>.json`. Returns `false` on any
    /// failure; never throws. The full message history is encoded verbatim —
    /// compaction is for context-window trimming only, never for persistence.
    @discardableResult
    func save(_ session: Session) -> Bool {
        let url = url(for: session.id)

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
    /// corrupt JSON, or wrong shape). Never throws.
    func load(id: String) -> Session? {
        let url = url(for: id)
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
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".bak") }
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
