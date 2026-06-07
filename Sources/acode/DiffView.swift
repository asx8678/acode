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

// MARK: - Memoized diff cache (perf, swift-7p2)
//
// `renderFrame` runs in `frameTimerTask` at ~60Hz while a tool
// approval is on screen. The approval card renders `buildHunks`
// (LCS — O(n·m) on edit_file payloads) and a per-line `highlight`
// for every diff line, EVERY frame, even when the card is static.
// That was the dominant CPU hotspot on a long diff with a
// mid-approval pause.
//
// The cache is keyed on `(old, new, lang, themeID, depth)`. Theme
// and depth are in the key so a `/theme` switch naturally
// invalidates by producing a fresh key (old theme's entries become
// unreachable and are evicted on overflow). Width is *not* in the
// key: `diffView` does not wrap — callers wrap the output with the
// current terminal width after the cache lookup. A resize never
// needs to bust the diff cache.
//
// Process-global `static let` is intentional: the cache is
// process-wide so a `/theme` switch from a previous session (no,
// the process is fresh each launch, but) or a long-running TUI
// benefits from sharing across all approval cards rendered in
// the session. The `nonisolated final class` + `NSLock` pattern
// mirrors `ScreenRenderer`'s off-main shared-state carve-out.

/// Composite key for the diff+highlight memo. `old`/`new` are
/// the raw `old_str`/`new_str` arguments from an `edit_file`
/// call; identical content hashes to the same key.
struct DiffCacheKey: Hashable, Sendable {
    let old: String
    let new: String
    let lang: Lang
    let themeID: String
    let depth: ColorDepth
}

/// Bounded process-global cache. LRU is overkill for a TUI; a hard
/// cap with a full clear on overflow keeps the dict small without
/// tracking recency. 64 entries covers a realistic session: the
/// default cap is roughly 3x the largest transcript any user will
/// have on screen at once.
///
/// MainActor-isolated (the package's `.defaultIsolation(MainActor.self)`
/// makes this the default) and only ever called from `diffView`,
/// which is itself a main-actor function. No lock, no `Sendable`
/// escape hatch needed: the dict is single-threaded by construction.
@MainActor
private final class DiffCache {
    private var entries: [DiffCacheKey: [String]] = [:]
    private let cap: Int

    init(cap: Int = 64) {
        self.entries = [:]
        self.cap = cap
    }

    func get(_ key: DiffCacheKey) -> [String]? {
        entries[key]
    }

    func put(_ key: DiffCacheKey, _ value: [String]) {
        if entries.count >= cap {
            // Full clear on overflow — same effective behavior as
            // a soft LRU, but allocation-free. The next miss will
            // re-populate from the (small) current set of edits.
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = value
    }

    /// Hard reset. Wired to the theme-change path in
    /// `TUIApp.setTheme` for defense-in-depth — the themeID in the
    /// key already isolates, so this is belt-and-suspenders against
    /// a future change that drops the themeID from the key.
    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}

@MainActor
private let diffCache = DiffCache()

/// Memoized `buildHunks` + `diffView` for the approval-card path.
/// Use this in renderFrame so the per-frame diff+highlight work
/// is amortized to once per (old, new, lang, theme, depth) tuple.
/// `lang` defaults to `.plain`; the approval card passes the
/// extension-detected value from `Highlight.detectLang`.
func memoizedDiffView(
    old: String,
    new: String,
    lang: Lang = .plain,
    theme: Theme,
    depth: ColorDepth
) -> [String] {
    // NOTE: `themeID: theme.name` would collide if two custom
    // themes with the same name ever coexisted. Safe today because
    // `/theme` resolves preset themes exclusively — no code path
    // constructs a custom `Theme` value — so name uniqueness is
    // guaranteed for the lifetime of this cache.
    let key = DiffCacheKey(
        old: old,
        new: new,
        lang: lang,
        themeID: theme.name,
        depth: depth
    )
    if let cached = diffCache.get(key) {
        return cached
    }
    let hunks = buildHunks(old: old, new: new)
    let lines = diffView(hunks, theme: theme, depth: depth, lang: lang)
    diffCache.put(key, lines)
    return lines
}

/// Convenience for the count-only path. Same cache; the caller
/// only needs the row count to drive hit-test math in
/// `approvalCardRows`. Avoids a second traversal of the result
/// when all the caller wants is `.count`.
func memoizedDiffRowCount(
    old: String,
    new: String,
    lang: Lang = .plain,
    theme: Theme,
    depth: ColorDepth
) -> Int {
    memoizedDiffView(old: old, new: new, lang: lang, theme: theme, depth: depth).count
}

/// Wired to `TUIApp.setTheme` for defense-in-depth cache busting.
/// See `DiffCache.clear` for the rationale.
func diffCacheClear() {
    diffCache.clear()
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
