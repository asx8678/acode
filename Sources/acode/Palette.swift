import Foundation
import AcodeCore

// `Command` and `allCommands` moved to `AcodeCore/SlashCommand.swift`
// during the Phase 1 restructure (so the lib's `CommandHandler` can
// render `/help` without depending on the TUI's `Palette` module).
// The TUI palette rendering + the fuzzy search stay in this file;
// they consume `Command` + `allCommands` from the lib.

// MARK: - fuzzy

/// Subsequence match + simple score ranking. The query is matched
/// against the slash form of each command (without the leading `/`).
/// Higher score wins; ties broken by command name length then by
/// alphabetical. Empty query returns the full list in name order.
///
/// **Pure**: no I/O, no `Date`, no side effects. Same input → same
/// output, so the palette is verifiable by replay (TUI_PLAN §6).
nonisolated func fuzzy(_ query: String, _ all: [Command] = allCommands) -> [Command] {
    let q = query.lowercased()
    if q.isEmpty { return all }
    var scored: [(Command, Int)] = []
    for cmd in all {
        let target = String(cmd.name.dropFirst()).lowercased()  // drop leading `/`
        if let score = subsequenceScore(query: q, target: target) {
            scored.append((cmd, score))
        }
    }
    return scored
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.name.count != rhs.0.name.count { return lhs.0.name.count < rhs.0.name.count }
            return lhs.0.name < rhs.0.name
        }
        .map { $0.0 }
}

/// Returns a score if `query` is a subsequence of `target`, else nil.
/// Score: 100 per matched character, +50 for a leading-char match,
/// +20 for a contiguous run, –5 per gap, –1 per position the match
/// is from the start (so earlier matches beat later ones).
private nonisolated func subsequenceScore(query: String, target: String) -> Int? {
    let qChars = Array(query)
    let tChars = Array(target)
    if qChars.isEmpty { return 0 }
    var qi = 0
    var score = 0
    var lastMatched = -2
    var runLength = 0
    for (i, c) in tChars.enumerated() {
        if qi < qChars.count, c == qChars[qi] {
            score += 100
            if i == 0 { score += 50 }
            if i == lastMatched + 1 {
                runLength += 1
                score += 20 * runLength
            } else {
                runLength = 0
            }
            lastMatched = i
            qi += 1
        } else {
            // Gap penalty only if we've already started matching.
            if lastMatched >= 0 { score -= 5 }
        }
        // Position penalty per matched char (1 pt per index position).
        if qi > 0 { score -= i }
    }
    return qi == qChars.count ? score : nil
}
