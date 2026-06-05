import Foundation

// MARK: - Message token accounting

extension Message {
    /// An approximate token count for this message (~4 characters per token).
    var tokenEstimate: Int {
        max(1, charCount / 4)
    }

    /// The approximate character count of this message's content.
    private var charCount: Int {
        switch self {
        case .user(let text):
            return text.count
        case .assistant(let text, let toolCalls):
            return text.count + toolCalls.reduce(0) { $0 + $1.arguments.encodedCharCount }
        case .toolResults(let results):
            return results.reduce(0) { $0 + $1.output.count }
        }
    }

    /// Returns a copy of this message whose content fits within `budget` tokens.
    ///
    /// Tool-call arguments are never truncated (doing so could corrupt JSON);
    /// only free-text and tool-result output are trimmed.
    func truncated(to budget: Int) -> Message {
        guard tokenEstimate > budget else { return self }
        let charBudget = max(4, budget * 4)

        switch self {
        case .user(let text):
            return .user(Self.clip(text, to: charBudget))

        case .assistant(let text, let toolCalls):
            // Preserve tool-call arguments verbatim; only trim the free text.
            let argChars = toolCalls.reduce(0) { $0 + $1.arguments.encodedCharCount }
            let textBudget = max(0, charBudget - argChars)
            return .assistant(text: Self.clip(text, to: textBudget), toolCalls: toolCalls)

        case .toolResults(let results):
            guard !results.isEmpty else { return self }
            let perResult = max(4, charBudget / results.count)
            let trimmed = results.map { result in
                ToolResult(
                    callID: result.callID,
                    output: Self.clip(result.output, to: perResult),
                    isError: result.isError
                )
            }
            return .toolResults(trimmed)
        }
    }

    /// Clips `text` to at most `charBudget` characters, appending a marker when truncated.
    private static func clip(_ text: String, to charBudget: Int) -> String {
        guard text.count > charBudget else { return text }
        let marker = "…[truncated]"
        guard charBudget > marker.count else {
            return String(text.prefix(charBudget))
        }
        let keep = charBudget - marker.count
        return String(text.prefix(keep)) + marker
    }
}

extension JSONValue {
    /// The character count of this value's JSON encoding (best-effort).
    var encodedCharCount: Int {
        guard let data = try? JSONEncoder().encode(self),
            let string = String(data: data, encoding: .utf8)
        else {
            return 0
        }
        return string.count
    }
}

// MARK: - Conversation

/// The running message history for an agent turn.
struct Conversation {
    private(set) var messages: [Message] = []

    mutating func append(_ m: Message) {
        messages.append(m)
    }

    /// Returns the history to send for a given context window.
    ///
    /// Algorithm (T3.1):
    /// 1. `reserve = window * 7 / 10`.
    /// 2. Truncate each message to `reserve` so no single message blows the budget.
    /// 3. If the truncated set fits within `window`, return it.
    /// 4. Otherwise keep newest-first whole messages until `reserve` tokens
    ///    (always keeping at least one message).
    /// 5. Drop orphaned tool_use/tool_result pairs so invariant B2 holds.
    func compacted(for window: Int) -> [Message] {
        guard window > 0 else { return ensureToolPairsIntact(messages) }

        let reserve = window * 7 / 10

        // Step 2: bound each message individually.
        let truncated = messages.map { $0.truncated(to: reserve) }

        // Step 3: fast path when everything fits.
        if truncated.reduce(0, { $0 + $1.tokenEstimate }) <= window {
            return ensureToolPairsIntact(truncated)
        }

        // Step 4: keep newest-first whole messages until we hit `reserve`.
        var kept: [Message] = []
        var used = 0
        for message in truncated.reversed() {
            let cost = message.tokenEstimate
            if kept.isEmpty || used + cost <= reserve {
                kept.append(message)
                used += cost
            } else {
                break
            }
        }
        kept.reverse()

        // Step 5: enforce tool-pair integrity.
        return ensureToolPairsIntact(kept)
    }

    /// Drops orphaned tool calls and tool results so pairing is never split (B2).
    ///
    /// An assistant message carrying tool calls must be followed by the matching
    /// `.toolResults`; a `.toolResults` message must be preceded by an assistant
    /// message that requested those calls. Any message violating this is removed.
    private func ensureToolPairsIntact(_ kept: [Message]) -> [Message] {
        var result: [Message] = []
        result.reserveCapacity(kept.count)

        for (index, message) in kept.enumerated() {
            switch message {
            case .user:
                result.append(message)

            case .assistant(_, let toolCalls):
                if toolCalls.isEmpty {
                    result.append(message)
                    break
                }
                // Require matching tool results immediately after.
                let callIDs = Set(toolCalls.map(\.id))
                if index + 1 < kept.count,
                    case .toolResults(let results) = kept[index + 1],
                    !callIDs.isDisjoint(with: Set(results.map(\.callID)))
                {
                    result.append(message)
                } // else: orphaned tool_use → drop.

            case .toolResults(let results):
                // Require a preceding assistant message that requested these.
                if index > 0,
                    case .assistant(_, let toolCalls) = kept[index - 1],
                    !toolCalls.isEmpty,
                    !Set(toolCalls.map(\.id)).isDisjoint(with: Set(results.map(\.callID)))
                {
                    result.append(message)
                } // else: orphaned tool_result → drop.
            }
        }

        return result
    }
}
