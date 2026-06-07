import Foundation
import AcodeCore

// MARK: - ScreenRenderer

/// Minimal flicker-free diff renderer (TUI_PLAN §3 canonical signature).
/// Strategy:
/// - Cache the last `Frame`'s lines + cursor position.
/// - On each `draw(_:to:)`, walk both frames row-by-row. Unchanged rows
///   are skipped entirely. Changed rows get `\e[<row+1>;1H` (move
///   cursor), `\e[2K` (erase line), then the new content.
/// - After all row updates, position the user cursor and show it.
/// - **An identical Frame emits 0 bytes** — a still animation (no
///   ticking) costs nothing. This is the §6 "no wasted escapes" rule.
///
/// Limitations (acceptable for P2):
/// - Clears and rewrites the entire changed row, even if only the last
///   few characters differ. P3 can switch to per-cell diffing for
///   really long transcripts.
/// - Doesn't track per-cell style — if a widget's color changes but the
///   text doesn't, the row will be rewritten. Fine for P2; a future
///   style-aware diff can fix that.
struct ScreenRenderer {
    private var lastLines: [String] = []
    private var lastCursor: CursorPos = CursorPos(row: 0, col: 0)
    /// `true` once we've drawn at least one frame. Before that, the
    /// first draw always emits (no comparison is meaningful).
    private var hasFrame: Bool = false

    /// Repaints `next` onto `term`. Returns the number of bytes written
    /// (useful for debugging and the §6 verification: a no-op frame
    /// should report 0).
    @discardableResult
    mutating func draw(_ next: Frame, to term: Terminal) -> Int {
        // Cache the new frame regardless of the diff outcome so the
        // next call has something to compare against.
        let prevLines = lastLines
        let prevCursor = lastCursor
        defer {
            lastLines = next.lines
            lastCursor = next.cursor
            hasFrame = true
        }
        // First frame, or an explicit invalidate: full repaint.
        guard hasFrame else {
            return fullRepaint(next, to: term)
        }
        // No-op check: identical rows + identical cursor → 0 bytes.
        if next.lines == prevLines && next.cursor == prevCursor {
            return 0
        }
        // Line count changed: do a full repaint (cheaper than a
        // midpoint teardown). Common during resize.
        if next.lines.count != prevLines.count {
            return fullRepaint(next, to: term)
        }
        // Row-by-row diff.
        var out = ""
        // Hide cursor while we paint to reduce flicker.
        out += "\u{1B}[?25l"
        for (i, line) in next.lines.enumerated() {
            if line == prevLines[i] { continue }
            // Move to row, col 0
            out += "\u{1B}[\(i + 1);1H"
            // Erase the entire line before writing
            out += "\u{1B}[2K"
            out += line
        }
        // Position user cursor and show it.
        out += "\u{1B}[\(next.cursor.row + 1);\(next.cursor.col + 1)H"
        out += "\u{1B}[?25h"
        let bytes = out.utf8.count
        term.write(out)
        term.flush()
        return bytes
    }

    /// Marks the cache as stale. The next `draw` will do a full repaint
    /// (cheaper than trying to reconcile a resizing display). Called
    /// from the loop on `.resize` so the user sees the new layout
    /// immediately, not just on the next model change.
    mutating func invalidate() {
        hasFrame = false
        lastLines = []
    }

    /// Forces a full repaint without consulting the cache. Used on the
    /// first frame and after `invalidate()`.
    private func fullRepaint(_ frame: Frame, to term: Terminal) -> Int {
        var out = ""
        // Reset cursor, clear screen, move home.
        out += "\u{1B}[2J\u{1B}[H"
        out += "\u{1B}[?25l"
        for (i, line) in frame.lines.enumerated() {
            out += "\u{1B}[\(i + 1);1H"
            out += line
        }
        out += "\u{1B}[\(frame.cursor.row + 1);\(frame.cursor.col + 1)H"
        out += "\u{1B}[?25h"
        let bytes = out.utf8.count
        term.write(out)
        term.flush()
        return bytes
    }
}
