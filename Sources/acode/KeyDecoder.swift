import Foundation

/// Stateful, byte-by-byte decoder. Feeds in raw bytes one at a time
/// (typically from `Terminal.readLoop`) and yields zero or more
/// `KeyEvent`s per call. Designed for incremental input where the OS may
/// return a single byte per read, so it has to:
///
/// - Reassemble UTF-8 multi-byte characters (1–4 bytes per codepoint).
/// - Hold partial CSI sequences that arrive split across reads
///   (e.g. `\e` in one read, `[A` in the next).
/// - Recognise bracketed-paste end sequences (`\e[201~`) and emit the
///   payload between `\e[200~` and `\e[201~` as one `.paste` event.
/// - Map control bytes `0x01…0x1A` to `.ctrl(letter)` so callers can
///   detect `Ctrl-C` (`0x03` → `ctrl("c")`) and `Ctrl-D` (`0x04` → `ctrl("d")`)
///   in raw mode where `ISIG` is off.
/// - A lone `0x1B` becomes `.esc`; printable escapes (e.g. `\eA`) are
///   surfaced as `.char("A")` and `ESC ESC` collapses to a single `.esc`.
/// `nonisolated` so the off-main `Terminal.readLoop` task can call
/// `feed` from a detached task without an actor hop. The decoder is
/// a value type with `var` state; the caller is responsible for
/// serialising access (TUIApp wraps it in a `SafeKeyDecoder` with a
/// lock).
nonisolated struct KeyDecoder {
    private enum State {
        case normal
        case escape                       // just saw 0x1B
        case csi(csiBuf: [UInt8])         // saw \e[, accumulating params
        case ss3                          // saw \eO, waiting for one final byte
        case utf8(expected: Int, buf: [UInt8])
        case paste
    }

    private var state: State = .normal
    private var pasteBuf: [UInt8] = []

    mutating func feed(_ byte: UInt8) -> [KeyEvent] {
        switch state {
        case .normal:
            return feedNormal(byte)
        case .escape:
            return feedEscape(byte)
        case .csi(let buf):
            return feedCSI(byte, buf: buf)
        case .ss3:
            return feedSS3(byte)
        case .utf8(let expected, let buf):
            return feedUTF8(byte, expected: expected, buf: buf)
        case .paste:
            return feedPaste(byte)
        }
    }

    // MARK: - Normal

    private mutating func feedNormal(_ byte: UInt8) -> [KeyEvent] {
        switch byte {
        case 0x1B:
            state = .escape
            return []
        case 0x0D, 0x0A:
            return [.enter]
        case 0x09:
            return [.tab]
        case 0x7F, 0x08:
            return [.backspace]
        case 0x01...0x1A:
            // 0x01 → 'a', 0x03 → 'c', 0x04 → 'd', …, 0x1A → 'z'.
            return [.ctrl(Character(UnicodeScalar(byte + 0x60)))]
        case 0x20...0x7E:
            return [.char(Character(UnicodeScalar(byte)))]
        case 0xC0...0xDF:
            state = .utf8(expected: 1, buf: [byte])
            return []
        case 0xE0...0xEF:
            state = .utf8(expected: 2, buf: [byte])
            return []
        case 0xF0...0xF7:
            state = .utf8(expected: 3, buf: [byte])
            return []
        default:
            // Continuation bytes (0x80–0xBF) at the start, or other C0/C1 garbage.
            return [.unknown]
        }
    }

    // MARK: - Escape (just saw 0x1B)

    private mutating func feedEscape(_ byte: UInt8) -> [KeyEvent] {
        switch byte {
        case 0x5B:  // '['
            state = .csi(csiBuf: [])
            return []
        case 0x4F:  // 'O'  (SS3: \eOA, \eOB, …, \eOH, \eOF)
            state = .ss3
            return []
        case 0x1B:
            // ESC ESC: emit one ESC, stay in .escape for whatever follows.
            return [.esc]
        case 0x20...0x7E:
            // ESC + printable = Alt/Meta. For P1's throwaway harness we
            // surface just the character; a future TUI can model Alt+x
            // explicitly.
            state = .normal
            return [.char(Character(UnicodeScalar(byte)))]
        default:
            // Unknown ESC sequence. Emit lone ESC and resume normal.
            state = .normal
            return [.esc]
        }
    }

    // MARK: - CSI (\e[...)

    private mutating func feedCSI(_ byte: UInt8, buf: [UInt8]) -> [KeyEvent] {
        // Parameter bytes: 0x30–0x3F ('0'..'?', ';', etc.)
        if (0x30...0x3F).contains(byte) {
            state = .csi(csiBuf: buf + [byte])
            return []
        }
        // Intermediate bytes: 0x20–0x2F (space, '!', '"', …, '/'). Rare in
        // modern terminals but the standard allows them.
        if (0x20...0x2F).contains(byte) {
            state = .csi(csiBuf: buf + [byte])
            return []
        }
        // Final byte: 0x40–0x7E ('@', 'A'..'~').
        if (0x40...0x7E).contains(byte) {
            let params = String(bytes: buf, encoding: .ascii) ?? ""
            state = .normal
            return dispatchCSI(params: params, final: byte)
        }
        // Out-of-range; bail to normal and report the lost ESC.
        state = .normal
        return [.esc, .unknown]
    }

    private mutating func dispatchCSI(params: String, final: UInt8) -> [KeyEvent] {
        // Bracketed-paste start \e[200~. Don't emit an event — the paste
        // payload is the event, and we transition to .paste so subsequent
        // bytes are accumulated until \e[201~.
        if final == 0x7E && params == "200" {
            state = .paste
            pasteBuf = []
            return []
        }

        // Single-letter arrows + Home/End.
        switch final {
        case UInt8(ascii: "A"): return [.up]
        case UInt8(ascii: "B"): return [.down]
        case UInt8(ascii: "C"): return [.right]
        case UInt8(ascii: "D"): return [.left]
        case UInt8(ascii: "H"): return [.home]
        case UInt8(ascii: "F"): return [.end]
        default: break
        }

        // Tilde-terminated sequences: \e[1~ Home, \e[4~ End,
        // \e[5~ PageUp, \e[6~ PageDown.
        if final == 0x7E {
            switch params {
            case "1": return [.home]
            case "4": return [.end]
            case "5": return [.pageUp]
            case "6": return [.pageDown]
            default: return [.unknown]
            }
        }

        // SGR mouse: \e[<b;x;yM (press) or \e[<b;x;ym (release).
        // The leading `<` is the xterm 1006 mode marker; without it
        // the body is one of the regular CSI sequences above.
        if params.hasPrefix("<") {
            return dispatchSGRMouse(params: params, final: final)
        }
        return [.unknown]
    }

    /// Parses the body of an SGR-mouse report. Returns one mouse
    /// event (or `.unknown` on a malformed report).
    /// - `M` (capital) = press/move; `m` (lower) = release.
    /// - Button field: 0=left, 1=middle, 2=right, 64=scroll-up,
    ///   65=scroll-down. Higher bits encode modifier keys (ignored
    ///   for P4 — the spec only needs scroll + click).
    private func dispatchSGRMouse(params: String, final: UInt8) -> [KeyEvent] {
        let body = String(params.dropFirst())  // strip the leading `<`
        let parts = body.split(separator: ";")
        guard parts.count == 3,
              let button = Int(parts[0]),
              let col = Int(parts[1]),
              let row = Int(parts[2]) else {
            return [.unknown]
        }
        // 1-based terminal coords → 0-based widget coords.
        let r = max(0, row - 1)
        let c = max(0, col - 1)
        // Release reports (`m`) are noise for the click-to-expand
        // model; swallow them silently (P5 may want hover tracking).
        if final == UInt8(ascii: "m") { return [] }
        switch button {
        case 64: return [.scrollUp]
        case 65: return [.scrollDown]
        case 0, 1, 2: return [.click(row: r, col: c)]
        default: return [.unknown]
        }
    }

    // MARK: - SS3 (\eO...)

    private mutating func feedSS3(_ byte: UInt8) -> [KeyEvent] {
        state = .normal
        switch byte {
        case UInt8(ascii: "A"): return [.up]
        case UInt8(ascii: "B"): return [.down]
        case UInt8(ascii: "C"): return [.right]
        case UInt8(ascii: "D"): return [.left]
        case UInt8(ascii: "H"): return [.home]
        case UInt8(ascii: "F"): return [.end]
        default: return [.unknown]
        }
    }

    // MARK: - UTF-8 continuation

    private mutating func feedUTF8(_ byte: UInt8, expected: Int, buf: [UInt8]) -> [KeyEvent] {
        // Continuation bytes are 0x80–0xBF; anything else is malformed.
        guard (0x80...0xBF).contains(byte) else {
            state = .normal
            // Reprocess the offending byte in normal mode so it's not lost.
            return [.unknown] + feedNormal(byte)
        }
        let next = buf + [byte]
        if next.count >= expected + 1 {
            if let s = String(bytes: next, encoding: .utf8), let c = s.first {
                state = .normal
                return [.char(c)]
            }
            state = .normal
            return [.unknown]
        }
        state = .utf8(expected: expected, buf: next)
        return []
    }

    // MARK: - Bracketed paste

    private mutating func feedPaste(_ byte: UInt8) -> [KeyEvent] {
        pasteBuf.append(byte)
        // End sequence: \e[201~ (6 bytes: ESC [ 2 0 1 ~).
        if pasteBuf.count >= 6 {
            let n = pasteBuf.count
            let tail = Array(pasteBuf[(n - 6)..<n])
            if tail == [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] {
                let payload = String(decoding: pasteBuf[0..<(n - 6)], as: UTF8.self)
                pasteBuf = []
                state = .normal
                return [.paste(payload)]
            }
        }
        return []
    }
}
