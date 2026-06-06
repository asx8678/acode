import Foundation

/// A saved conversation session with metadata.
struct Session: Codable, Identifiable {
    let id: String
    var title: String?
    var model: String?
    let createdAt: Date
    var updatedAt: Date
    var conversation: Conversation

    /// Directory where sessions are stored.
    static let sessionsDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/acode/sessions")
        return base
    }()

    /// Save this session to disk as JSON (atomic write).
    func save() -> Bool {
        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: Self.sessionsDir, withIntermediateDirectories: true
        )
        let url = Self.sessionsDir.appendingPathComponent("\(id).json")
        guard let data = try? JSONEncoder().encode(self) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Load a session from disk by id.
    static func load(id: String) -> Session? {
        let url = sessionsDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Session.self, from: data)
        else { return nil }
        return session
    }

    /// Create a new session with a fresh UUID and the current timestamp.
    static func new(title: String? = nil, model: String? = nil) -> Session {
        let now = Date()
        return Session(
            id: UUID().uuidString,
            title: title,
            model: model,
            createdAt: now,
            updatedAt: now,
            conversation: Conversation()
        )
    }
}
