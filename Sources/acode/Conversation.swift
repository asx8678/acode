import Foundation

/// The running message history for an agent turn.
///
/// Compaction is a pass-through for now; the working-memory algorithm
/// (token estimate, truncation, tool-pair integrity) arrives in T3.1.
struct Conversation {
    private(set) var messages: [Message] = []

    mutating func append(_ m: Message) {
        messages.append(m)
    }

    /// Returns the history to send for a given context window.
    /// Pass-through until T3.1.
    func compacted(for window: Int) -> [Message] {
        messages
    }
}
