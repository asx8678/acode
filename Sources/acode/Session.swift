import Foundation

/// A saved conversation session with metadata.
///
/// On-disk schema is versioned via `Session.currentVersion`. The decoder is
/// forward-compatible: a file missing the `version` key loads as
/// `Session.currentVersion` so older binaries' files keep working. Persistence
/// and I/O live on `SessionStore`; this type is pure data.
struct Session: Codable, Identifiable {
    /// Current on-disk schema version. Bump on backwards-incompatible changes.
    static let currentVersion: Int = 1

    let version: Int
    let id: String
    var title: String?
    var model: String?
    let createdAt: Date
    var updatedAt: Date
    var conversation: Conversation

    init(
        id: String,
        title: String? = nil,
        model: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        conversation: Conversation,
        version: Int = Session.currentVersion
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversation = conversation
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, title, model, createdAt, updatedAt, conversation
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Forward-compat: older files (or hand-rolled fixtures) may omit
        // `version` entirely; treat them as the current schema.
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Session.currentVersion
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.conversation = try c.decode(Conversation.self, forKey: .conversation)
    }

    /// Build a new session with a fresh UUID and the current timestamp.
    /// Persistence lives in `SessionStore`; this is just the constructor.
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

extension Session {
    /// Encoder configured for stable, human-readable session JSON.
    /// ISO 8601 dates + pretty-printed sorted keys for diff-friendly on-disk files.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Decoder whose date strategy matches `encoder()`.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
