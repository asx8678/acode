import Foundation

// MARK: - Command / allCommands
//
// (Single-target build: `Command` and `allCommands` live here in the
// palette file because the TUI palette is the only consumer. A future
// restructure can move them to a dedicated `SlashCommand.swift` if a
// second caller appears.)

/// A slash command exposed to the user via the palette and the `/help`
/// list. `name` includes the leading `/` (e.g. `/help`).
struct Command: Sendable, Equatable, Hashable {
    let name: String
    /// One-line description shown in the palette and `/help`.
    let blurb: String
}

/// The canonical slash-command list. Order is the order the palette and
/// `/help` present them in (the palette re-sorts on a query via `fuzzy`).
/// Aliases (`/h`, `/?`, `/q`, `/exit`) are listed after their canonical
/// form so a single fuzzy query still surfaces the canonical entry
/// first; M1 fix — the prior version only had the canonical names in
/// the palette, so a user typing `h` got nothing highlighted and a user
/// who never knew about `/help` couldn't discover `/h`.
nonisolated let allCommands: [Command] = [
    Command(name: "/help",      blurb: "show this help"),
    Command(name: "/h",         blurb: "alias for /help"),
    Command(name: "/?",         blurb: "alias for /help"),
    Command(name: "/clear",     blurb: "clear conversation history"),
    Command(name: "/quit",      blurb: "exit the TUI"),
    Command(name: "/q",         blurb: "alias for /quit"),
    Command(name: "/exit",      blurb: "alias for /quit"),
    Command(name: "/model",     blurb: "show or switch the active model"),
    Command(name: "/plan",      blurb: "run multi-agent planner → coder → reviewer"),
    Command(name: "/theme",     blurb: "switch palette (e.g. /theme dark)"),
    Command(name: "/auto",      blurb: "show or toggle blanket auto-approve"),
    Command(name: "/allow",     blurb: "add a shell prefix to the auto-allow list"),
    Command(name: "/approvals", blurb: "show or persist the approval policy"),
    Command(name: "/save",      blurb: "save the current conversation as a session"),
    Command(name: "/resume",    blurb: "resume a saved session (name, id prefix, or `last`)"),
    Command(name: "/sessions",  blurb: "list saved sessions (newest first)"),
]

// MARK: - fuzzy

/// Subsequence match + simple score ranking. The query is matched
/// against the slash form of each command (without the leading `/`).
/// Higher score wins; ties broken by command name length then by
/// alphabetical. Empty query returns the full list in name order.
///
/// **Pure**: no I/O, no `Date`, no side effects. Same input → same
/// output, so the palette is verifiable by replay.
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
