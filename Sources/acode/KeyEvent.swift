import Foundation

/// Canonical key event produced by `KeyDecoder` from raw stdin bytes.
///
/// The shape is the union of every key we need to drive the P1–P5 TUI:
/// printable characters, common editing keys, the four arrows, Home/End,
/// PageUp/PageDown, `Ctrl+<letter>` (the only way to surface `Ctrl-C` /
/// `Ctrl-D` because raw mode leaves `ISIG` off), and a bracketed-paste
/// payload. `unknown` is the catch-all for sequences the decoder didn't
/// recognise — view code can choose to ignore or echo it.
enum KeyEvent: Sendable, Equatable {
    case char(Character)
    case enter
    case backspace
    case tab
    case esc
    case left
    case right
    case up
    case down
    case home
    case end
    case pageUp
    case pageDown
    case ctrl(Character)
    case paste(String)
    /// Mouse wheel rolled up. Translates to PageUp-ish scrolling.
    case scrollUp
    /// Mouse wheel rolled down. Translates to PageDown-ish scrolling.
    case scrollDown
    /// Left mouse press. `row`/`col` are 0-based. The view maps them
    /// back to whatever widget lives at that coordinate.
    case click(row: Int, col: Int)
    case unknown
}
