import Foundation

// MARK: - Hunk

/// One block of a diff. `oldStart`/`newStart` are 1-based; `0` for
/// additions or deletions that have no counterpart. `lines` is the
/// ordered list of (context/removed/added) lines.
struct Hunk: Sendable, Equatable {
    var oldStart: Int
    var newStart: Int
    var lines: [DiffLine]
}

enum DiffLine: Sendable, Equatable {
    case context(String)
    case removed(String)
    case added(String)
}

// MARK: - buildHunks

/// Line-based LCS diff of two strings. Pure, O(n·m) — fine for the
/// small hunks the agent produces (typical edit_file is 5-50 lines).
/// Returns a single hunk containing every line; for multi-hunk
/// grouping we'd need the standard git/diff3 algorithm, which is out
/// of scope for P3 (the card shows the full change).
func buildHunks(old: String, new: String) -> [Hunk] {
    let a = old.components(separatedBy: "\n")
    let b = new.components(separatedBy: "\n")
    let lcs = longestCommonSubsequenceMatrix(a, b)
    var lines: [DiffLine] = []
    var i = a.count
    var j = b.count
    // Walk the LCS matrix backwards, building the diff in reverse.
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
            lines.append(.context(a[i - 1]))
            i -= 1; j -= 1
        } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
            lines.append(.added(b[j - 1]))
            j -= 1
        } else if i > 0 {
            lines.append(.removed(a[i - 1]))
            i -= 1
        }
    }
    lines.reverse()
    // Drop the trailing empty line that a trailing "\n" produces.
    if lines.last == .context("") { lines.removeLast() }
    return [Hunk(oldStart: 1, newStart: 1, lines: lines)]
}

/// Standard LCS dynamic-programming matrix. Returns a 2D array of
/// `count+1 × count+1` ints (i.e. (a.count+1) × (b.count+1) where
/// row/column 0 is the empty prefix).
private func longestCommonSubsequenceMatrix(_ a: [String], _ b: [String]) -> [[Int]] {
    let n = a.count
    let m = b.count
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 1...n {
        for j in 1...m {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }
    return dp
}

// MARK: - diffView

/// Renders a list of hunks to display lines. Each line is gutter +
/// (optional line number) + content. Colors via `sgr(_,depth)`; a
/// `mono` terminal receives plain text. Pure function.
func diffView(_ hunks: [Hunk], theme: Theme, depth: ColorDepth, lang: Lang = .plain) -> [String] {
    var out: [String] = []
    for (i, hunk) in hunks.enumerated() {
        if i > 0 { out.append("") }  // blank line between hunks
        out.append(renderHunkHeader(hunk, theme: theme, depth: depth))
        // Track live line numbers as we walk the hunk.
        var oldLine = hunk.oldStart
        var newLine = hunk.newStart
        for line in hunk.lines {
            switch line {
            case .context(let s):
                out.append(renderRow(mark: " ", oldNum: oldLine, newNum: newLine, body: s, theme: theme, depth: depth, lang: lang))
                oldLine += 1; newLine += 1
            case .removed(let s):
                out.append(renderRow(mark: "-", oldNum: oldLine, newNum: nil, body: s, theme: theme, depth: depth, lang: lang))
                oldLine += 1
            case .added(let s):
                out.append(renderRow(mark: "+", oldNum: nil, newNum: newLine, body: s, theme: theme, depth: depth, lang: lang))
                newLine += 1
            }
        }
    }
    return out
}

private func renderHunkHeader(_ hunk: Hunk, theme: Theme, depth: ColorDepth) -> String {
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    return "\(dim)@@ -\(hunk.oldStart), +\(hunk.newStart) @@\(reset)"
}

/// Renders one diff row.
///
/// Layout: ` `|mark|  |oldNum|newNum|  |body`. The line-number pair is
/// right-aligned, 4-wide each, so columns line up visually.
private func renderRow(
    mark: Character,
    oldNum: Int?,
    newNum: Int?,
    body: String,
    theme: Theme,
    depth: ColorDepth,
    lang: Lang
) -> String {
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    // Line-number column. 4-wide per side keeps the gutter at 11 chars
    // total; a wider terminal just shows more whitespace.
    let oldStr = oldNum.map { String(format: "%4d", $0) } ?? "    "
    let newStr = newNum.map { String(format: "%4d", $0) } ?? "    "
    let gutter = "\(dim)\(oldStr)\(reset) \(dim)\(newStr)\(reset) \(mark) "

    // Body color depends on the mark. `+` → green bg + ok text,
    // `-` → red bg + err text, ` ` → uncolored (but we still highlight
    // the content via `lang` so a JSON file gets colored even on a
    // context line).
    let bodyColored: String
    switch mark {
    case "+":
        bodyColored = sgr(theme.ok, depth) + highlight(body, lang, theme: theme, depth: depth) + reset
    case "-":
        bodyColored = sgr(theme.err, depth) + highlight(body, lang, theme: theme, depth: depth) + reset
    default:
        bodyColored = highlight(body, lang, theme: theme, depth: depth)
    }
    return gutter + bodyColored
}
