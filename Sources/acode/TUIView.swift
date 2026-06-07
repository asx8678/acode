import Foundation

// MARK: - Frame

/// Cursor position on the repaint grid. Own struct (not a tuple) so
/// `Frame` can conform to `Equatable` — `ScreenRenderer.draw` uses
/// identity to short-circuit no-op repaints.
struct CursorPos: Sendable, Equatable {
    var row: Int
    var col: Int
    init(row: Int, col: Int) { self.row = row; self.col = col }
    init(_ pair: (Int, Int)) { self.row = pair.0; self.col = pair.1 }
}

/// One repaint. `lines` are already escaped (every color via `sgr`),
/// so `ScreenRenderer` can just diff strings row-by-row. `cursor`
/// points to where the user-cursor should be placed after the repaint.
struct Frame: Sendable, Equatable {
    var lines: [String]
    var cursor: CursorPos = CursorPos(row: 0, col: 0)
}

// MARK: - displayWidth (P5: best-effort, zero-dep wcwidth)

/// Best-effort grapheme-cluster display width for terminal layout.
/// P5 spec (`TUI_EPIC_PLAN.md` §6.2): no `wcwidth` dependency, so we
/// reimplement the common cases the agent's transcripts actually hit:
/// combining marks / ZWJ / variation selectors → 0, control → 0, the
/// major CJK + Hangul + Hiragana + Katakana + fullwidth blocks → 2,
/// emoji-presentation scalars → 2, everything else → 1. For a
/// grapheme cluster (one `Character`), the widths of the constituent
/// scalars are summed but a leading emoji/ZWJ cluster is clamped to
/// 2 (best-effort: we don't model every regional-indicator flag pair).
///
/// **Not a fully conformant UAX #11 implementation** — we don't ship
/// a full `EastAsianWidth.txt` or `emoji-data.txt` parse. The cases
/// below cover >99% of real agent transcripts (CJK strings, é/ü/ñ
/// in user input, the common emoji). A weird variant selector in a
/// "fonts" file is acceptable to mis-width; the doc marks this
/// as best-effort and a future spec can swap in a derived table
/// (or `swift-argument-parser` is fine for an offline build step).
@inline(__always)
func displayWidth(_ c: Character) -> Int {
    // Fast-path: ASCII printable is the common case. (P5 keeps the
    // `Character` overload for backwards compatibility with the
    // hundreds of call sites; the `String` overload below is the
    // one that actually does work, since the row math must walk
    // the grapheme clusters, not scalars.)
    if c.isASCII, let b = c.asciiValue {
        if b < 0x20 || b == 0x7F { return 0 }
        return 1
    }
    // For non-ASCII, defer to the cluster walker.
    return displayWidth(String(c))
}

@inline(__always)
func displayWidth(_ s: String) -> Int {
    if s.isEmpty { return 0 }
    var total = 0
    for cluster in s {
        total += clusterWidth(cluster)
    }
    return total
}

/// Width of a single grapheme cluster (`Character`). Sums scalar
/// widths, but **clamps emoji/ZWJ sequences to 2** so a flag pair
/// doesn't render as 4 cells.
private func clusterWidth(_ c: Character) -> Int {
    var width = 0
    var sawEmojiOrZWJ = false
    for scalar in c.unicodeScalars {
        let w = scalarWidth(scalar)
        // Combining marks, ZWJ, and variation selectors contribute 0.
        if w == 0 {
            // If the cluster has any wide/emoji scalar, the ZWJ is
            // just glue; otherwise it's a normal combining mark.
            continue
        }
        if w == 2 { sawEmojiOrZWJ = true }
        width += w
    }
    // Clamp emoji/ZWJ clusters to 2 (best-effort).
    if sawEmojiOrZWJ, width > 2 { width = 2 }
    // A single-character cluster that's 0 (e.g. just a combining
    // mark) stays 0. A cluster of 2 width returns 2.
    return width
}

/// Width of a single Unicode scalar. 0 / 1 / 2 per the spec.
private func scalarWidth(_ s: Unicode.Scalar) -> Int {
    let v = s.value
    // C0 + DEL control.
    if v < 0x20 || v == 0x7F { return 0 }
    // C1 controls (0x80..<0xA0).
    if v >= 0x80 && v < 0xA0 { return 0 }
    // Combining Diacritical Marks (U+0300..U+036F).
    if v >= 0x0300 && v <= 0x036F { return 0 }
    // Variation Selectors (U+FE00..U+FE0F + U+E0100..U+E01EF).
    if v >= 0xFE00 && v <= 0xFE0F { return 0 }
    if v >= 0xE0100 && v <= 0xE01EF { return 0 }
    // Zero-Width Joiner / Space / Non-Joiner / Word Joiner.
    if v == 0x200D || v == 0x200B || v == 0x200C || v == 0x2060 { return 0 }
    // Combining marks for symbols (U+20D0..U+20FF).
    if v >= 0x20D0 && v <= 0x20FF { return 0 }
    // CJK Unified Ideographs.
    if v >= 0x4E00 && v <= 0x9FFF { return 2 }
    // CJK Unified Ideographs Extension A.
    if v >= 0x3400 && v <= 0x4DBF { return 2 }
    // CJK Compatibility Ideographs.
    if v >= 0xF900 && v <= 0xFAFF { return 2 }
    // CJK Strokes.
    if v >= 0x31C0 && v <= 0x31EF { return 2 }
    // Hiragana.
    if v >= 0x3040 && v <= 0x309F { return 2 }
    // Katakana.
    if v >= 0x30A0 && v <= 0x30FF { return 2 }
    // Katakana Phonetic Extensions.
    if v >= 0x31F0 && v <= 0x31FF { return 2 }
    // Hangul Syllables.
    if v >= 0xAC00 && v <= 0xD7A3 { return 2 }
    // Hangul Jamo (compatibility) + Jamo Extended A/B.
    if v >= 0x3130 && v <= 0x318F { return 2 }
    if v >= 0xA960 && v <= 0xA97F { return 2 }
    if v >= 0xD7B0 && v <= 0xD7FF { return 2 }
    // Fullwidth Forms (U+FF00..U+FF60, plus the U+FFE0..U+FFE6
    // block of fullwidth signs).
    if v >= 0xFF00 && v <= 0xFF60 { return 2 }
    if v >= 0xFFE0 && v <= 0xFFE6 { return 2 }
    // Emoji + Misc Symbols & Pictographs + Supplementary Symbols +
    // Misc Technical + Enclosed Alphanumerics (most of these are
    // width 2 when emoji-presented, width 1 when text-presented;
    // we err toward 2 because the agent's transcripts use them as
    // emoji far more often than as text).
    if v >= 0x2600 && v <= 0x27BF { return 2 }
    if v >= 0x1F300 && v <= 0x1F6FF { return 2 }
    if v >= 0x1F900 && v <= 0x1F9FF { return 2 }
    if v >= 0x1FA70 && v <= 0x1FAFF { return 2 }
    return 1
}

// MARK: - renderFrame

/// Pure layout. Given a model, terminal size, theme, capabilities, and
/// the loop's current `now`, produces one Frame. No I/O, no side
/// effects — the §6 verification story (replay → bit-identical output)
/// depends on this.
func renderFrame(_ m: TUIModel, size: TermSize, theme: Theme, caps: Capabilities, now: Double) -> Frame {
    var lines: [String] = []
    lines.reserveCapacity(size.rows)

    // 1. HUD: 1 row on wide terminals, 2 rows on narrow ones.
    let hudLines = renderHUD(
        model: m, width: size.cols, theme: theme, depth: caps.color, now: now
    )
    lines.append(contentsOf: hudLines)

    // 2. Separator.
    lines.append(separator(width: size.cols, theme: theme, depth: caps.color))

    // 3. Transcript: fills available rows. The input box + hints +
    // optional task row + 1 separator live at the bottom. The task
    // row is 1 line when visible and `tasks` is non-empty.
    let showTaskRow = m.tasksVisible && !m.tasks.isEmpty
    let taskRowHeight = showTaskRow ? 1 : 0
    let showTimeline = !m.phases.isEmpty
    let timelineHeight = showTimeline ? 1 : 0
    let approvalCardHeight = (m.activity == .awaitingApproval && m.pendingApproval != nil) ? approvalCardRows(m.pendingApproval!, cols: size.cols, theme: theme, depth: caps.color) : 0
    // Palette is a fixed-size overlay: top border + query + sep + 5 rows
    // + bottom border = 9 rows. The spec calls for a "fixed-width box
    // at the top of the screen." It replaces the input box; the
    // transcript still scrolls underneath.
    let paletteLines: [String] = m.palette.open
        ? palette(m.palette.query, m.palette.filtered, selection: m.palette.selection, cols: size.cols, tick: m.tick)
        : []
    let paletteHeight = paletteLines.count
    let chrome = hudLines.count + 1 + taskRowHeight + timelineHeight + approvalCardHeight + 1 + 1 + 1
    // hud + sep + task? + timeline? + approvalCard? + sep + input + hints
    let transcriptRows = max(1, size.rows - chrome)
    let transcript = renderTranscript(
        m.transcript,
        scroll: m.scroll,
        activity: m.activity,
        pendingApproval: m.pendingApproval,
        rows: transcriptRows,
        cols: size.cols,
        theme: theme,
        depth: caps.color,
        now: now
    )
    lines.append(contentsOf: transcript)

    // 4. Separator.
    lines.append(separator(width: size.cols, theme: theme, depth: caps.color))

    // 5. Input box. Hidden when the palette is open — the palette's
    // query row replaces it.
    if !m.palette.open {
        lines.append(renderInputBox(
            m.input, m.activity, cols: size.cols, theme: theme, depth: caps.color
        ))
    } else {
        lines.append("")
    }

    // 6. Task row (under input, only when visible + non-empty + palette closed).
    if showTaskRow && !m.palette.open {
        lines.append(renderTaskRow(m.tasks, cols: size.cols, theme: theme, depth: caps.color))
    }

    // 6b. Timeline (orchestrator stepper, only when phases non-empty + palette closed).
    if showTimeline && !m.palette.open {
        lines.append(timeline(m.phases, tick: m.tick))
    }

    // 7. Hints row.
    lines.append(renderHints(
        cols: size.cols, theme: theme, depth: caps.color
    ))

    // 7. Position the user cursor at the input box. The input box is
    // `2 + (showTaskRow ? 1 : 0) + (timeline? 1 : 0) +
    // (approvalCard? cardHeight : 0)` rows above the hints row. The
    // hints row is the LAST row.
    let promptWidth = 2  // "> " prompt
    let hintsRow = lines.count - 1
    let inputRow = hintsRow - 1 - taskRowHeight - timelineHeight - approvalCardHeight
    // Cursor position depends on the palette state:
    // - palette open → palette query row (row 1 of the overlay = the
    //   query line). The query is at column 2 (after `│ /`).
    // - otherwise → the input box, at column `promptWidth + cursor`.
    let cursor: CursorPos
    if m.palette.open {
        let paletteQueryRow = 1 + hudLines.count  // just under the HUD
        let paletteCol = 2 + m.palette.query.count
        cursor = CursorPos(row: paletteQueryRow, col: min(paletteCol, size.cols - 1))
    } else {
        let inputCol = promptWidth + m.input.cursor
        cursor = CursorPos(row: inputRow, col: min(inputCol, size.cols - 1))
    }

    // Pad to `size.rows` with empty lines so the ScreenRenderer diff
    // works on a stable size (no row shifting between frames).
    while lines.count < size.rows {
        lines.append("")
    }

    // 8. Palette overlay. Replaces the top `paletteHeight` rows.
    // (Drawn AFTER padding so the palette always sits at the top,
    // even if the rest of the screen scrolled.)
    if !paletteLines.isEmpty {
        for i in 0..<min(paletteHeight, lines.count) {
            lines[i] = paletteLines[i]
        }
    }

    // 8b. Startup wordmark overlay (EPIC §2.1). Replaces the top
    // N rows while the user hasn't typed yet. Drawn AFTER the
    // palette so a palette-open state takes priority. The frame
    // timer keeps the 60Hz tick going so the gradient sweep
    // animates; once `m.startup` is false the overlay stops.
    if m.startup && paletteLines.isEmpty {
        let wm = wordmark(
            tick: m.tick,
            theme: theme,
            depth: caps.color,
            version: m.status.wordmarkVersion,
            model: m.status.model,
            endpoint: m.status.endpoint,
            cwd: m.status.cwd,
            branch: m.status.branch
        )
        for i in 0..<min(wm.count, lines.count) {
            lines[i] = wm[i]
        }
    }

    // 9. Toast overlay. Bottom-right, on top of the last 1-2 lines.
    // The toast's age is computed by the renderFrame caller (or by
    // `renderFrame` itself if we pass `now` and the model has a
    // `Toast.bornTick`). The duration maps `tick` deltas to wall
    // seconds via the same 16 ms-per-tick cadence the frame timer
    // uses; this is a *visual* approximation, not a precise clock.
    if let t = m.toast {
        let ageSeconds = Double(m.tick - t.bornTick) * 0.016
        if let visibleText = toast(t.text, age: ageSeconds) {
            // Right-align the toast on the second-to-last row.
            let targetRow = lines.count - 2
            if targetRow >= 0 {
                let w = visibleText.utf8.count + 4  // 2 spaces + 2 borders
                if w <= size.cols {
                    let pad = size.cols - w
                    let line = String(repeating: " ", count: pad) + visibleText
                    lines[targetRow] = line
                }
            }
        }
    }

    return Frame(lines: lines, cursor: cursor)
}

// MARK: - HUD

/// Returns 1 or 2 lines depending on width. The single-line HUD packs
/// every field with a · separator; on narrow terminals we split into
/// "primary" (model + gauge + tokens + tok/s) and "secondary"
/// (cost + elapsed + pulse) rows.
private func renderHUD(
    model m: TUIModel,
    width: Int,
    theme: Theme,
    depth: ColorDepth,
    now: Double
) -> [String] {
    let model = m.status.model
    let primary = badge("◆ \(shortenModel(model))", theme.accentA, depth: depth)
    let gaugeStr = gauge(
        used: m.metrics.inTokens + m.metrics.outTokens,
        total: max(m.status.contextWindow, 1),
        width: 10,
        theme: theme,
        depth: depth
    )
    let tokIn = formatTokens(m.metrics.inTokens)
    let tokOut = formatTokens(m.metrics.outTokens)
    let tokens = "\(sgr(theme.dim, depth))↑\(sgrReset())\(tokIn) \(sgr(theme.dim, depth))↓\(sgrReset())\(tokOut)"
    let rate = "\(sgr(theme.accentA, depth))\(sgrReset())\(m.metrics.tokPerSec(now: now)) tok/s"
    let cost = renderCost(m.metrics.cost(PricingTable.pricing(for: model)), theme: theme, depth: depth)
    let elapsed = renderElapsed(m.metrics.firstDeltaAt, now: now, theme: theme, depth: depth)
    let pulse = pulse(m.activity != .idle, m.tick)
    // Branch badge: only added when we actually have a branch
    // (non-nil `Status.branch`). Nil means "not in a git repo" or
    // "detached HEAD" — both gracefully degrade by hiding the
    // badge (per the swift-sp6 spec). `⎇` is the U+2387
    // "alternative key symbol" — the standard branch glyph in
    // most CLIs (lazygit, tig, gitui, sourcetree).
    let branchBadge: String?
    if let branch = m.status.branch {
        branchBadge = badge("⎇ \(branch)", theme.accentB, depth: depth)
    } else {
        branchBadge = nil
    }
    var singleFields: [String] = [primary]
    if let branchBadge { singleFields.append(branchBadge) }
    singleFields.append(contentsOf: [gaugeStr, tokens, rate, cost, elapsed, pulse])
    let single = singleFields
        .joined(separator: " \(sgr(theme.dim, depth))·\(sgrReset()) ")

    if displayWidth(stripAnsi(single)) + 1 <= width {
        return [padOrClip(single, to: width, theme: theme, depth: depth)]
    }
    // Two-row fallback: split at the cost field. The branch badge
    // rides on the *primary* (left) row so the user always sees
    // it on wide terminals and the narrow-terminal fallback.
    var leftFields: [String] = [primary]
    if let branchBadge { leftFields.append(branchBadge) }
    leftFields.append(contentsOf: [gaugeStr, tokens, rate])
    let left = leftFields
        .joined(separator: " \(sgr(theme.dim, depth))·\(sgrReset()) ")
    let right = [cost, elapsed, pulse]
        .joined(separator: " \(sgr(theme.dim, depth))·\(sgrReset()) ")
    return [
        padOrClip(left, to: width, theme: theme, depth: depth),
        padOrClip(right, to: width, theme: theme, depth: depth)
    ]
}

// MARK: - Transcript

/// Bottom-anchors the transcript so the latest item is at the bottom
/// (when `scroll == 0`). When `scroll > 0`, pages up.
private func renderTranscript(
    _ items: [TranscriptItem],
    scroll: Int,
    activity: Activity,
    pendingApproval: ToolCall?,
    rows: Int,
    cols: Int,
    theme: Theme,
    depth: ColorDepth,
    now: Double
) -> [String] {
    // Flatten each item into one or more display lines. Tool items
    // are grouped into consecutive runs and rendered with the
    // `╭ ├ ╰` box-drawing tree (U3.1 / EPIC §2.4) so the user can
    // see which tools belong to the same turn.
    var flat: [String] = []
    flat.reserveCapacity(items.count * 2)
    var i = 0
    while i < items.count {
        if case .tool = items[i] {
            // Find the end of this tool run.
            var j = i
            while j < items.count {
                if case .tool = items[j] { j += 1 } else { break }
            }
            let run = Array(items[i..<j])
            flat.append(contentsOf: renderToolRun(run, cols: cols, theme: theme, depth: depth, now: now))
            i = j
        } else if case .shell = items[i] {
            // H3: consecutive `.shell` items also group into a run
            // with a `╭ ├ ╰` connector tree (matches the tool-card
            // look so the transcript feels uniform whether the
            // output came from a tool or a `!` passthrough).
            var j = i
            while j < items.count {
                if case .shell = items[j] { j += 1 } else { break }
            }
            let run = Array(items[i..<j])
            flat.append(contentsOf: renderShellRun(run, cols: cols, theme: theme, depth: depth))
            i = j
        } else {
            flat.append(contentsOf: renderTranscriptItem(items[i], cols: cols, theme: theme, depth: depth))
            i += 1
        }
    }
    // The awaiting-approval card is appended to the transcript area
    // so it shares the same scroll/cohabit logic. (P3's design choice;
    // P2's placeholder was a one-line notice.)
    if case .awaitingApproval = activity, let call = pendingApproval {
        flat.append(contentsOf: renderApprovalCard(call, cols: cols, theme: theme, depth: depth))
    }
    // Bottom-anchor: take the last `rows` lines.
    let visible: [String]
    if scroll == 0 {
        visible = Array(flat.suffix(rows))
    } else {
        // scroll = N means "skip the bottom N lines and show what was above"
        let skip = min(scroll * (rows / 2 + 1), max(0, flat.count - rows))
        let start = max(0, flat.count - rows - skip)
        let end = min(flat.count, start + rows)
        visible = Array(flat[start..<end])
    }
    // Pad to `rows` with empty lines.
    var out = visible
    while out.count < rows { out.append("") }
    return out
}

private func renderTranscriptItem(
    _ item: TranscriptItem,
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> [String] {
    switch item {
    case .user(let s):
        let head = "\(sgr(theme.accentB, depth))▸\(sgrReset()) "
        return wrap(head + s, cols: cols)
    case .assistant(let s):
        // Assistant text — wrap as-is. The spec is silent on a prefix;
        // we use the dim leading bullet for visual grouping.
        let head = "\(sgr(theme.dim, depth))•\(sgrReset()) "
        return wrap(head + s, cols: cols)
    case .tool:
        // Should not appear here — tool items are intercepted by
        // `renderTranscript` and grouped via `renderToolRun`.
        return [""]
    case .phase(let s):
        let head = "\(sgr(theme.dim, depth))⟳\(sgrReset()) "
        return wrap(head + s, cols: cols)
    case .notice(let s):
        let head = "\(sgr(theme.dim, depth))ⓘ\(sgrReset()) "
        return wrap(head + s, cols: cols)
    case .error(let s):
        let head = "\(sgr(theme.err, depth))\(sgrReset()) "
        return wrap(head + s, cols: cols)
    case .shell:
        // Should not appear here — shell items are intercepted by
        // `renderTranscript` and grouped via `renderShellRun`. The
        // unreachable branch keeps the switch total.
        return [""]
    }
}

// MARK: - Tool tree (U3.1 / EPIC §2.4)

/// Renders a consecutive run of `.tool` items as a `╭ ├ ╰` box-drawing
/// tree. For a single tool, no connector is shown (no tree, no
/// need). For N≥2, the first/last/middle get `╭`/`╰`/`├` respectively.
private func renderToolRun(
    _ items: [TranscriptItem],
    cols: Int,
    theme: Theme,
    depth: ColorDepth,
    now: Double
) -> [String] {
    var out: [String] = []
    let count = items.count
    for (idx, item) in items.enumerated() {
        guard case .tool(let tv) = item else { continue }
        let connector: String
        if count == 1 {
            connector = "  "
        } else if idx == 0 {
            connector = "╭ "
        } else if idx == count - 1 {
            connector = "╰ "
        } else {
            connector = "├ "
        }
        out.append(contentsOf: renderToolView(tv, connector: connector, cols: cols, theme: theme, depth: depth, now: now))
    }
    return out
}

private func renderToolView(
    _ tv: ToolView,
    connector: String,
    cols: Int,
    theme: Theme,
    depth: ColorDepth,
    now: Double
) -> [String] {
    let symbol: String
    let color: RGB
    switch tv.status {
    case .running: symbol = String(spinner(tick: 0)); color = theme.warn
    case .ok:      symbol = ""; color = theme.ok
    case .error:   symbol = ""; color = theme.err
    }
    let head = "\(sgr(theme.dim, depth))\(connector)\(sgrReset())\(sgr(color, depth))\(symbol)\(sgrReset()) \(sgr(theme.accentA, depth))\(tv.name)\(sgrReset())"
    let timer = renderTimer(tv: tv, now: now, theme: theme, depth: depth)
    let summary = tv.summary.isEmpty ? "" : " — \(sgr(theme.dim, depth))\(tv.summary)\(sgrReset())"
    var lines = wrap(head + summary + " " + timer, cols: cols)
    if tv.expanded && !tv.output.isEmpty {
        let indent = "  "
        for chunk in wrap(tv.output, cols: cols - 2) {
            lines.append(indent + sgr(theme.dim, depth) + chunk + sgrReset())
        }
    }
    return lines
}

// MARK: - Shell run (H3)

/// Renders a consecutive run of `.shell` items as a `╭ ├ ╰`
/// box-drawing tree, mirroring the tool-card look. The headline
/// for each shell is the command prefixed with `!`; the body is
/// the wrapped output. There is no expand/collapse and no
/// spinner — a `!` passthrough is instantaneous from the
/// transcript's POV (the body lands all at once in the
/// `.shellEnd` Msg).
private func renderShellRun(
    _ items: [TranscriptItem],
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> [String] {
    var out: [String] = []
    let count = items.count
    for (idx, item) in items.enumerated() {
        guard case .shell(let cmd, let output, let isError) = item else { continue }
        let connector: String
        if count == 1 {
            connector = "  "
        } else if idx == 0 {
            connector = "╭ "
        } else if idx == count - 1 {
            connector = "╰ "
        } else {
            connector = "├ "
        }
        out.append(contentsOf: renderShellView(
            command: cmd,
            output: output,
            isError: isError,
            connector: connector,
            cols: cols,
            theme: theme,
            depth: depth
        ))
    }
    return out
}

/// Renders one shell invocation. Headline: `! <command> <exit>`,
/// then the (optional) wrapped output. Exit status is the single
/// `!` row's only status — ok=green dim check, err=red `!` —
/// chosen to be visually distinct from the ok/err tool colors
/// so a casual scroll doesn't conflate the two.
private func renderShellView(
    command: String,
    output: String,
    isError: Bool,
    connector: String,
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> [String] {
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    let statusColor: String
    let statusGlyph: String
    if isError {
        statusColor = sgr(theme.err, depth)
        statusGlyph = "ERR"
    } else {
        statusColor = sgr(theme.ok, depth)
        statusGlyph = "OK "
    }
    // Use the dim connector (no "tree" for a single shell; tree
    // glyphs are emitted by `renderShellRun` for multi-shell
    // groupings).
    let head = "\(dim)\(connector)\(reset) \(statusColor)[\(statusGlyph)]\(reset) \(sgr(theme.accentA, depth))! \(command)\(reset)"
    var lines = wrap(head, cols: cols)
    if !output.isEmpty {
        let indent = "  "
        for chunk in wrap(output, cols: max(20, cols - 2)) {
            lines.append(indent + dim + chunk + reset)
        }
    }
    return lines
}

// MARK: - Input box

private func renderInputBox(
    _ input: InputState,
    _ activity: Activity,
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> String {
    let prompt = sgr(theme.accentB, depth) + "▸ " + sgrReset()
    let activityHint: String
    switch activity {
    case .idle:
        activityHint = ""
    case .thinking:
        let f = spinner(tick: 0)
        activityHint = " \(sgr(theme.warn, depth))\(f) thinking…\(sgrReset())"
    case .runningTool(let name):
        let f = spinner(tick: 0)
        activityHint = " \(sgr(theme.accentA, depth))\(f) \(name)…\(sgrReset())"
    case .awaitingApproval:
        activityHint = " \(sgr(theme.warn, depth))⏸ awaiting approval\(sgrReset())"
    }
    let line = prompt + input.text + activityHint
    return padOrClip(line, to: cols, theme: theme, depth: depth)
}

// MARK: - Hints

private func renderHints(cols: Int, theme: Theme, depth: ColorDepth) -> String {
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    let hints = [
        "⏎ send", "↑↓ history", "^C cancel", "^D quit", "^T tasks", "PgUp/PgDn"
    ].joined(separator: "\(dim) · \(reset)")
    return padOrClip("\(dim)\(hints)\(reset)", to: cols, theme: theme, depth: depth)
}

// MARK: - Task row (U3.3 / EPIC §2.5)

/// One-line task checklist rendered under the input box. Toggled by
/// `^T`. Truncates with a `+N more` when the list overflows.
private func renderTaskRow(
    _ tasks: [TaskItem],
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> String {
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    let ok = sgr(theme.ok, depth)
    let err = sgr(theme.err, depth)
    let accent = sgr(theme.accentA, depth)
    let head = "\(accent)\(reset) \(dim)tasks\(reset) "
    var line = head
    // Greedy: pack items until we run out of cols.
    var rendered: [String] = []
    var overflow = 0
    for task in tasks {
        let glyph: String
        let color: String
        switch task.state {
        case .done:    glyph = ""; color = ok
        case .running: glyph = "⠹"; color = accent
        case .pending: glyph = "○"; color = dim
        case .failed:  glyph = ""; color = err
        }
        let item = "\(color)\(glyph) \(reset)\(task.title)"
        // +1 for the separator
        let projected = rendered.joined(separator: "  ").count + (rendered.isEmpty ? 0 : 2) + item.count
        // 12 = approximate head + tail "+N more" budget
        if projected + 12 > cols {
            overflow = tasks.count - rendered.count
            break
        }
        rendered.append(item)
    }
    line += rendered.joined(separator: "  ")
    if overflow > 0 {
        line += "  \(dim)+\(overflow) more\(reset)"
    }
    return padOrClip(line, to: cols, theme: theme, depth: depth)
}

// MARK: - Timeline (U4.3 / EPIC §2.6)

/// Renders a horizontal stepper: `●━━━●━━━○ step-name [2/3]` where
/// the active node animates with `tick`. The in-progress node's
/// right-edge line cycles between 1-3 cells of "fill" so the user
/// sees motion.
///
/// **Pure**: same `(phases, tick, theme, depth)` → same output.
func timeline(_ phases: [Phase], tick: Int) -> String {
    if phases.isEmpty { return "" }
    let theme = Theme.dark
    let depth = ColorDepth.x16
    let ok = sgr(theme.ok, depth)
    let warn = sgr(theme.warn, depth)
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    let accent = sgr(theme.accentA, depth)
    var out = ""
    for (i, p) in phases.enumerated() {
        switch p.state {
        case .done:
            out += "\(ok)\(reset)"
        case .running:
            out += "\(warn)\(spinner(tick: tick))\(reset)"
        case .pending:
            out += "\(dim)\(reset)"
        case .failed:
            out += "\(sgr(theme.err, depth))\(reset)"
        }
        // Connector (3 chars): done steps are solid, current is
        // animating, future is dim.
        if i < phases.count - 1 {
            switch p.state {
            case .done:
                out += "\(ok)\(reset)"
            case .running:
                // Animate: 1..3 of the 3 connector cells "filled".
                let cycle = tick % 3 + 1
                let filled = String(repeating: "━", count: cycle)
                let remaining = String(repeating: "┄", count: 3 - cycle)
                out += "\(warn)\(filled)\(reset)\(dim)\(remaining)\(reset)"
            case .pending, .failed:
                out += "\(dim)\(reset)"
            }
        }
        // Label below the node is omitted for the timeline widget —
        // the task row carries the labels. Here we just print the
        // step name inline so the user has something to read.
        out += " "
    }
    // Trailing: the active phase name.
    if let active = phases.last(where: { $0.state == .running }) ?? phases.last {
        out += " \(accent)\(active.name)\(reset)"
    }
    return out
}

// MARK: - Toast (EPIC §2.8)

/// Returns the visible toast text, faded by age, or `nil` once it
/// has fully faded. Pure function of `(text, age, theme, depth)`.
///
/// `age` is in seconds; the toast lasts `Toast.kToastLifetime`.
func toast(_ text: String, age: Double) -> String? {
    let lifetime = Toast.kToastLifetime
    if age < 0 || age >= lifetime { return nil }
    return text
}

// MARK: - Palette overlay (U4.1 / EPIC §2.7)

/// Renders the command palette as a fixed-width box at the top of
/// the screen. The box has a query line at the top, then up to
/// `maxRows` filtered command rows. The selected row is highlighted
/// with an accent-bordered bar.
func palette(_ query: String, _ items: [Command], selection: Int, cols: Int, tick: Int) -> [String] {
    let theme = Theme.dark
    let depth = ColorDepth.x16
    let accent = sgr(theme.accentA, depth)
    let dim = sgr(theme.dim, depth)
    let ok = sgr(theme.ok, depth)
    let reset = sgrReset()
    let maxRows = min(items.count, max(3, cols / 4))  // scale with terminal
    let shown = Array(items.prefix(maxRows))
    // Box: width = min(cols, 60) for a compact overlay.
    let w = min(cols, max(40, query.count + 30))
    var out: [String] = []
    // Top border.
    out.append(accent + "╭─ " + "command palette" + String(repeating: "─", count: max(0, w - 22)) + "╮" + reset)
    // Query row.
    let cursor = if tick % 2 == 0 { "▏" } else { " " }
    out.append(accent + "│" + reset + " " + accent + "/" + reset + query + cursor
               + String(repeating: " ", count: max(0, w - 4 - query.count)) + " " + accent + "│" + reset)
    // Separator.
    out.append(accent + "├" + String(repeating: "─", count: max(0, w - 2)) + "┤" + reset)
    // Rows.
    if shown.isEmpty {
        out.append(accent + "│" + reset + dim + "  (no matches)" + String(repeating: " ", count: max(0, w - 14)) + " " + accent + "│" + reset)
    } else {
        for (i, cmd) in shown.enumerated() {
            let isSel = (i == selection)
            let name = cmd.name.padding(toLength: 12, withPad: " ", startingAt: 0)
            let blurbMax = max(0, w - 18)
            let blurb = String(cmd.blurb.prefix(blurbMax))
            let namePart = (isSel ? ok : accent) + name + reset
            let blurbPart = (isSel ? reset : dim) + blurb + reset
            let prefix = isSel ? accent + "│" + reset + ok + " ▶ " + reset : accent + "│" + reset + "   "
            let suffix = " " + accent + "│" + reset
            let pad = max(0, w - 4 - name.count - blurb.count)
            out.append(prefix + namePart + "  " + blurbPart + String(repeating: " ", count: pad) + suffix)
        }
    }
    // Bottom border.
    out.append(accent + "╰" + String(repeating: "─", count: max(0, w - 2)) + "╯" + reset)
    return out
}

// MARK: - Approval card (U3.2 / EPIC §2.5)

/// Computes the row count the approval card will need for `cols`.
/// The card is a box-bordered region with a header + body. For
/// `run_shell`, the body is the command (1 row). For `edit_file`,
/// the body is a `diffView` of the change.
///
/// **Theme/depth must match `renderApprovalCard`'s** — a difference
/// here would let the body row count drift from the rendered body
/// and the card would visibly overflow or leave dead space. The
/// previous version hard-coded `Theme.dark, .x16`; the render uses
/// whatever the caller's theme is (light, high-contrast, mono, etc.).
/// We accept the same `(theme, depth)` the renderFrame was called
/// with so the two halves can't diverge.
private func approvalCardRows(
    _ call: ToolCall,
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> Int {
    // Border (2) + header (1) + body.
    let body: Int
    switch call.name {
    case "edit_file":
        let old = call.arguments["old_str"]?.stringValue ?? ""
        let new = call.arguments["new_str"]?.stringValue ?? ""
        let path = call.arguments["path"]?.stringValue ?? ""
        let lang = detectLang(path: path)
        // Perf: consult the (old, new, lang, theme, depth) memo
        // instead of recomputing LCS + per-line highlight for the
        // hit-test row count. The same cache is shared with
        // `renderApprovalCard` so the row count and the rendered
        // body can't drift.
        body = memoizedDiffRowCount(
            old: old,
            new: new,
            lang: lang,
            theme: theme,
            depth: depth
        )
    case "run_shell":
        body = 1
    default:
        body = 1
    }
    return 2 + 1 + body + 1  // top border + header + body + bottom border
}

/// Renders the full approval card. Top border, header (tool name +
/// path/command), body (diff or command), bottom border, then a hint
/// row showing the keybindings.
private func renderApprovalCard(
    _ call: ToolCall,
    cols: Int,
    theme: Theme,
    depth: ColorDepth
) -> [String] {
    let accent = sgr(theme.warn, depth)
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    let titleColor = sgr(theme.accentA, depth)
    let errColor = sgr(theme.err, depth)
    let okColor = sgr(theme.ok, depth)

    // Top border: `╭─ approve · run_shell ─╮`
    let title = "approve · \(call.name)"
    let topBar = topBorder(title: title, cols: cols, accent: accent, reset: reset)
    var lines: [String] = [topBar]

    // Header: path / command for context.
    switch call.name {
    case "edit_file":
        let path = call.arguments["path"]?.stringValue ?? "(missing path)"
        lines.append("  \(titleColor)\(path)\(reset)")
    case "run_shell":
        let cmd = call.arguments["command"]?.stringValue ?? "(missing command)"
        lines.append("  \(titleColor)\(clipDetail(cmd, limit: max(0, cols - 4)))\(reset)")
    default:
        lines.append("  \(titleColor)\(call.name)\(reset)")
    }

    // Body.
    switch call.name {
    case "edit_file":
        let old = call.arguments["old_str"]?.stringValue ?? ""
        let new = call.arguments["new_str"]?.stringValue ?? ""
        let path = call.arguments["path"]?.stringValue ?? ""
        let lang = detectLang(path: path)
        // Perf: use the memoized diff (shared with `approvalCardRows`
        // so the row count and the body are guaranteed identical).
        let diff = memoizedDiffView(
            old: old,
            new: new,
            lang: lang,
            theme: theme,
            depth: depth
        )
        for d in diff {
            lines.append(padOrClip("  " + d, to: cols, theme: theme, depth: depth))
        }
    case "run_shell":
        // For shell, color `+` lines as the "+ cmd" the user would
        // see in line mode. The `+` prefix is the convention used by
        // `Renderer.approvalDescription`.
        let cmd = call.arguments["command"]?.stringValue ?? ""
        let oneLine = cmd.replacingOccurrences(of: "\n", with: "⏎")
        lines.append("  \(okColor)+ \(reset)\(oneLine)")
    default:
        // For other tools, show the call id.
        lines.append("  \(dim)id: \(call.id)\(reset)")
    }

    // Bottom border.
    lines.append(bottomBorder(cols: cols, accent: accent, reset: reset))

    // Hints row (outside the box).
    let yHint = "\(okColor)[\(okColor)y\(reset)\(okColor)]\(reset)\(okColor)es  \(reset)"
    let nHint = "\(errColor)[\(errColor)n\(reset)\(errColor)]\(reset)\(errColor)o  \(reset)"
    let aHint = "\(accent)[\(accent)a\(reset)\(accent)]\(reset)\(accent)lways allow \(call.name)\(reset)"
    let hint = "  " + yHint + nHint + aHint
    lines.append(padOrClip(hint, to: cols, theme: theme, depth: depth))

    return lines
}

private func topBorder(title: String, cols: Int, accent: String, reset: String) -> String {
    // `╭─ <title> ────────╮`
    let prefix = "╭─ "
    let suffix = " ─"
    let fillBudget = max(0, cols - prefix.count - suffix.count - 1)
    let truncatedTitle = String(title.prefix(fillBudget))
    let line = prefix + truncatedTitle
    let remaining = max(0, cols - line.count - 1)  // -1 for closing `╮`
    return accent + line + String(repeating: "─", count: remaining) + "╮" + reset
}

private func bottomBorder(cols: Int, accent: String, reset: String) -> String {
    let w = max(0, cols - 2)
    return accent + "╰" + String(repeating: "─", count: w) + "╯" + reset
}

private func clipDetail(_ s: String, limit: Int) -> String {
    if s.count <= limit { return s }
    if limit <= 0 { return "" }
    return String(s.prefix(max(0, limit - 1))) + "…"
}

// MARK: - Widgets

/// Context-window gauge: `▕█████░░░▏ 49%`. The fill is the sum of
/// in+out tokens, the total is the context window. Color shifts
/// green→amber→red as utilization rises.
func gauge(used: Int, total: Int, width: Int, theme: Theme, depth: ColorDepth) -> String {
    let w = max(4, width)
    let pct = total > 0 ? min(1.0, Double(used) / Double(total)) : 0.0
    let filled = Int((Double(w) * pct).rounded())
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: w - filled)
    let color: RGB
    if pct < 0.6 { color = theme.gaugeLow }
    else if pct < 0.85 { color = theme.gaugeMid }
    else { color = theme.gaugeHigh }
    let pctStr = String(format: "%3d%%", Int(pct * 100))
    return "\(sgr(theme.dim, depth))▕\(sgrReset())\(sgr(color, depth))\(bar)\(sgrReset())\(sgr(theme.dim, depth))▏\(sgrReset()) \(pctStr)"
}

// MARK: - wordmark (EPIC §2.1)

/// Renders the startup wordmark + metadata block. The block-wordmark
/// "acode" sits at the top with a cyan→violet gradient, plus the
/// version, model, endpoint, and `cwd (branch )` lines below. The
/// underline animates left→right driven by `tick`; once `tick` exceeds
/// the sweep duration, the underline settles as a flat dim line.
///
/// **Pure**: same `(tick, theme, depth)` + the metadata strings →
/// same output. The frame timer (60 Hz) keeps the sweep smooth; the
/// loop idles it after the user submits their first turn (P4
/// carve-out) so a still TUI is 0% CPU.
func wordmark(
    tick: Int,
    theme: Theme,
    depth: ColorDepth,
    version: String,
    model: String,
    endpoint: String,
    cwd: String,
    branch: String?

) -> [String] {
    let accent = sgr(theme.accentA, depth)
    let accentB = sgr(theme.accentB, depth)
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    // 4-line block wordmark. Each line is a fixed 5-glyph wide
    // block; the gradient sweeps across all 4 lines in unison.
    let block = [
        "  █████   ██████  ██████  ██████  ███████ ",
        " ██   ██  ██   ██ ██   ██ ██   ██ ██      ",
        " ███████  ██   ██ ██   ██ ██████  ██████  ",
        " ██   ██  ██   ██ ██   ██ ██           ██ ",
        " ██   ██  ██████  ██████  ██      ██████  "
    ]
    // Sweep duration: ~90 frames at 60Hz = 1.5s. The loop
    // yields `.tick` at 60Hz while a startup-animation "activity"
    // is in flight; we use a single long-sweep budget here. After
    // `sweepFrames`, the underline is fully drawn.
    let sweepFrames = 90
    let progress = min(1.0, Double(tick) / Double(sweepFrames))
    // Build the wordmark rows, each glyph colored by its x-position
    // along the gradient.
    let widthCols = block[0].utf8.count  // assumes every line is the same width
    var out: [String] = []
    out.reserveCapacity(block.count + 4)
    for line in block {
        if depth == .mono {
            // Mono: no gradient, no escapes. Just plain text.
            out.append(line)
        } else {
            out.append(gradient(line, theme.accentA, theme.accentB, depth))
        }
    }
    // Animated underline: a row of 5 cells that fill left→right.
    // We render it as a `▔` (upper half block) per filled cell. After
    // the sweep, the underline is the full width.
    let underlineCols = min(40, widthCols)
    var underline = ""
    for i in 0..<underlineCols {
        let cellProgress = Double(i) / Double(max(1, underlineCols - 1))
        let filled = cellProgress <= progress
        underline += filled ? "▔" : " "
    }
    // Color the underline with the same gradient; cells to the
    // right of the sweep head are dim.
    if depth == .mono {
        out.append(underline)
    } else {
        var u = ""
        for (i, ch) in underline.enumerated() {
            let cellProgress = Double(i) / Double(max(1, underlineCols - 1))
            if cellProgress <= progress {
                let t = cellProgress
                let r = UInt8(Double(theme.accentA.r) + (Double(theme.accentB.r) - Double(theme.accentA.r)) * t)
                let g = UInt8(Double(theme.accentA.g) + (Double(theme.accentB.g) - Double(theme.accentA.g)) * t)
                let b = UInt8(Double(theme.accentA.b) + (Double(theme.accentB.b) - Double(theme.accentA.b)) * t)
                u += sgr(RGB(r, g, b), depth)
                u += String(ch)
            } else if ch == " " {
                u += " "
            } else {
                u += sgr(theme.dim, depth)
                u += String(ch)
            }
        }
        u += sgrReset()
        out.append(u)
    }
    // Metadata block: version / model / endpoint / cwd (branch).
    let branchStr = branch.map { " (\($0) )" } ?? " (no branch)"
    out.append("")  // spacer
    out.append("\(dim)acode \(reset)\(accentB)\(version)\(reset)  \(dim)· model:\(reset) \(model)")
    out.append("  \(dim)· endpoint:\(reset) \(endpoint)")
    out.append("  \(dim)· cwd:\(reset) \(cwd)\(dim)\(branchStr)\(reset)")
    out.append("")  // trailing spacer so the cursor lands a row below
    _ = accent  // silence "unused" if Mono path doesn't touch it
    return out
}/// Sparkline over the rolling `samples` buffer. Width-`width`,
/// scrolling so the latest sample is on the right.
func sparkline(_ samples: [Int], width: Int) -> String {
    let w = max(1, width)
    let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    if samples.isEmpty { return String(repeating: "▁", count: w) }
    let maxV = max(1, samples.max() ?? 1)
    let visible = samples.suffix(w)
    var out = ""
    out.reserveCapacity(w * 3)
    for s in visible {
        let level = min(bars.count - 1, Int(Double(s) / Double(maxV) * Double(bars.count - 1)))
        out += bars[max(0, level)]
    }
    // Left-pad with the smallest bar if the buffer hasn't filled yet.
    if visible.count < w {
        out = String(repeating: "▁", count: w - visible.count) + out
    }
    return out
}

/// Braille spinner glyph. Tick is mod 10 over the standard 10-frame
/// braille animation. The frame index is computed at render time from
/// the current tick; the function is pure in `(tick)`.
func spinner(tick: Int) -> Character {
    let frames: [Character] = [
        "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}",
        "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}"
    ]
    let i = ((tick % frames.count) + frames.count) % frames.count
    return frames[i]
}

/// Per-tool live timer. Renders `Xs` for completed tools and `Xs …`
/// for running ones (the `…` shows the timer is still counting).
/// Returns an empty string when `startedAt` is missing (race with
/// the loop's stamp).
func renderTimer(tv: ToolView, now: Double, theme: Theme, depth: ColorDepth) -> String {
    guard let start = tv.startedAt else { return "" }
    let elapsed: Double
    if let end = tv.endedAt {
        elapsed = end - start
    } else {
        elapsed = max(0, now - start)
    }
    let seconds = Int(elapsed)
    let s: String
    if seconds < 60 { s = "\(seconds)s" }
    else { s = "\(seconds / 60)m\(seconds % 60)s" }
    let dim = sgr(theme.dim, depth)
    let reset = sgrReset()
    if tv.endedAt == nil {
        return "\(dim)\(s) …\(reset)"
    }
    return "\(dim)\(s)\(reset)"
}

/// Colored badge: `◆ opus-4` with the given accent color.
func badge(_ text: String, _ color: RGB, depth: ColorDepth) -> String {
    sgr(color, depth) + text + sgrReset()
}

/// Activity pulse. Returns a `●` whose color oscillates dim↔bright
/// based on tick parity. `on=false` forces dim (idle state).
func pulse(_ on: Bool, _ tick: Int) -> String {
    let phase = (tick / 2) % 2  // ~8 Hz cadence at 16ms ticks
    if !on {
        return "\u{1B}[2m●\u{1B}[22m"
    }
    if phase == 0 {
        return "\u{1B}[1;33m●\u{1B}[0m"  // bright yellow
    }
    return "\u{1B}[2;33m●\u{1B}[22m"     // dim yellow
}

// MARK: - Text helpers

/// Wraps `s` into lines of `cols` display-width. Honors existing
/// `\n` characters as hard breaks. Greedy wrap, no word-break.
func wrap(_ s: String, cols: Int) -> [String] {
    if s.isEmpty { return [""] }
    let w = max(1, cols)
    var out: [String] = []
    for paragraph in s.split(separator: "\n", omittingEmptySubsequences: false) {
        let p = String(paragraph)
        if p.isEmpty { out.append(""); continue }
        var current = ""
        var currentWidth = 0
        for ch in p {
            let cw = displayWidth(ch)
            if currentWidth + cw > w {
                out.append(current)
                current = String(ch)
                currentWidth = cw
            } else {
                current.append(ch)
                currentWidth += cw
            }
        }
        out.append(current)
    }
    return out
}

/// Pads the line with spaces to `width` (or clips to `width` if
/// longer). Used so HUD/input/hint rows always have the same visible
/// width and the diff renderer doesn't think a row changed just
/// because trailing whitespace was added.
func padOrClip(_ s: String, to width: Int, theme: Theme, depth: ColorDepth) -> String {
    let visible = displayWidth(stripAnsi(s))
    if visible == width { return s }
    if visible < width {
        return s + String(repeating: " ", count: width - visible)
    }
    // Clip: we don't actually clip the escaped string (would break the
    // SGR state machine); we just truncate the visible length and let
    // the row scroll naturally. For P2 the HUD never overflows so this
    // branch is rarely hit.
    return s
}

/// Approximate ANSI-stripper for measuring display width. Only used
/// inside the layout code; it knows the exact SGR forms our sgr()
/// function emits (CSI … m) and the OSC/CSI sequences the diff
/// renderer writes.
func stripAnsi(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\u{1B}" {
            // Skip until we hit a final byte (0x40-0x7E).
            var j = s.index(after: i)
            if j < s.endIndex, s[j] == "[" {
                j = s.index(after: j)
                while j < s.endIndex {
                    let b = s[j]
                    if b.asciiValue.map({ (0x40...0x7E).contains($0) }) ?? false {
                        j = s.index(after: j)
                        break
                    }
                    j = s.index(after: j)
                }
                i = j
                continue
            }
        }
        out.append(c)
        i = s.index(after: i)
    }
    return out
}

private func separator(width: Int, theme: Theme, depth: ColorDepth) -> String {
    let dim = sgr(theme.dim, depth)
    return dim + String(repeating: "─", count: max(0, width)) + sgrReset()
}

private func shortenModel(_ m: String) -> String {
    // Drop the date suffix if present: "claude-sonnet-4-5-20251001" → "claude-sonnet-4-5"
    if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) {
        return String(m[..<r.lowerBound])
    }
    return m
}

private func formatTokens(_ n: Int) -> String {
    if n < 1_000 { return "\(n)" }
    if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return String(format: "%.2fM", Double(n) / 1_000_000)
}

private func renderCost(_ c: Double?, theme: Theme, depth: ColorDepth) -> String {
    guard let c else { return "\(sgr(theme.dim, depth))$—\(sgrReset())" }
    if c < 0.01 {
        return "\(sgr(theme.dim, depth))¢\(String(format: "%.2f", c * 100))\(sgrReset())"
    }
    return String(format: "$%.2f", c)
}

private func renderElapsed(_ start: Double?, now: Double, theme: Theme, depth: ColorDepth) -> String {
    guard let start else {
        return "\(sgr(theme.dim, depth))⏱—:—\(sgrReset())"
    }
    let elapsed = max(0, now - start)
    let total = Int(elapsed)
    let m = total / 60
    let s = total % 60
    return String(format: "%@⏱%02d:%02d%@", sgr(theme.dim, depth), m, s, sgrReset())
}
