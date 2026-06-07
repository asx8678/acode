import Foundation

// MARK: - chart
//
// Inline-image chart for the HUD's tok/s strip. All three graphics
// protocols the TUI detects (`.iterm`, `.kitty`, `.sixel`) speak DEC
// sixel, so we emit a single escape-sequence shape and the caller
// picks the protocol that matches `Capabilities.graphics`. Sixel is
// the common denominator — it avoids three separate PNG / iTerm-1337 /
// Kitty-`f=100` encoders and keeps this file under ~150 lines.
//
// The HUD's existing `sparkline` (TUIView.swift) is the fallback
// when `proto == .none` or when this function returns nil
// (validation fail). `chart` deliberately takes the same
// `(samples, width)` shape as `sparkline` so the HUD's call site
// is a one-line if/else.
//
// Throttling (caller's job): TUIModel calls `chart` at most ~2 FPS
// so we don't flood the terminal's sixel parser. The encoder
// itself is stateless and idempotent — re-encoding the same
// samples always produces the same escape sequence, which keeps
// the diff renderer happy when a frame is re-painted.

// MARK: - chart
//
// DEC sixel reference (VT330 / xterm):
//   introducer:  ESC P q           (q = "no special params")
//   color set:   # Pc ; Pu ; Px ; Py ; Pz
//                Pc = register (0..255), Pu = model (1=HLS, 2=RGB),
//                Px/Py/Pz = 0..100 in model units.
//   repeat:      ! Pn <char>        (Pn decimal, repeat next 6-bit char)
//   new band:    -                  (down 6 px, column 0)
//   string end:  ESC \              (ST)
//   char range:  0x3F ('?') = 000000, 0x7E ('~') = 111111
//                                        (char = 0x3F + 6-bit pattern)

/// Encodes `samples` (tok/s values, newest on the right) as a DEC
/// sixel inline-image escape sequence. Returns `nil` for `.none`,
/// empty `samples`, or an undersized chart.
///
/// **Layout** (matches the existing `sparkline` fallback in
/// `TUIView.swift`):
/// - `width` columns, each 6 pixel-columns wide in the sixel data
///   (so `width = 16` ≈ 96 px wide). Takes the most recent `width`
///   samples; left-pads with zero so the chart scrolls in from the
///   right the same way the Unicode sparkline does.
/// - `height` sixel bands stacked vertically (each 6 scanlines,
///   so `height = 3` ≈ 18 px tall). For each column, the bar is
///   filled from the bottom proportional to `sample / max(samples)`.
///
/// **Encoding** (DEC sixel, 1-bit, register 1):
/// - Color register 1 → a calm cyan that reads on dark and light
///   backgrounds (RGB ≈ 30, 80, 100 in 0–100 model units).
///   The HUD's accent theme is not threaded through `chart`
///   because the function signature is fixed; if a theme-bound
///   chart is wanted later, a `Color` argument is the natural
///   extension. Sixel's color register is global within the
///   escape sequence, so swapping it only affects this chart's
///   pixels.
/// - Per column, the 6-bit pattern represents the 6 pixels of a
///   band top-to-bottom; the byte is `0x3F + pattern` (so `?` is
///   all-off, `~` is all-on).
/// - Adjacent identical columns are compressed with the RLE
///   introducer `! Pn <char>` when Pn ≥ 3 (Pn = 3 is breakeven
///   with the raw form, Pn ≥ 4 wins).
///
/// **Output**: `\e P q <data> \e \` — the canonical DEC sixel
/// string. Multi-band output uses `-` (start new band) between
/// bands; the `!Pn<char>` RLE keeps a 3-band × 16-col chart under
/// ~80 bytes, which is well under the typical sixel-parser
/// per-payload budget.
///
/// **Validation** (return `nil`):
/// - `proto == .none`
/// - `samples.isEmpty`
/// - `width < 4` (the smallest legible bar chart)
/// - `height < 2` (one band is too short to be a "chart")
nonisolated func chart(
    _ samples: [Int],
    width: Int,
    height: Int,
    proto: GraphicsProtocol
) -> String? {
    // 1. Validation. The HUD's call site already filters on
    //    `caps.graphics != .none`, but a guard here means the
    //    encoder is self-contained and unit-testable without
    //    setting up a full Capabilities value. The `switch` uses
    //    structural case-pattern matching instead of `!=` /
    //    `==` because `GraphicsProtocol`'s `Equatable`
    //    conformance is main-actor-isolated under
    //    `.defaultIsolation(MainActor.self)` and a `nonisolated`
    //    function is not allowed to use it. Pattern matching
    //    works on the case tag, no conformance needed.
    switch proto {
    case .none:
        return nil
    case .iterm, .kitty, .sixel:
        break
    }
    guard !samples.isEmpty, width >= 4, height >= 2 else {
        return nil
    }
    let cols = width
    let bands = height
    let totalPixels = bands * 6   // 3 bands × 6 scanlines = 18 for the default

    // 2. Take the trailing `cols` samples (right-aligned, like
    //    `sparkline`); left-pad with zeros so the chart scrolls in
    //    from the right when the ring buffer hasn't filled. The
    //    ring buffer is capped at 32 by `Metrics.sampleCapacity`,
    //    so the intermediate arrays here are tiny (≤ 32 elements).
    let visible = Array(samples.suffix(cols))
    let padded: [Int] = Array(repeating: 0, count: cols - visible.count) + visible

    // 3. Normalize. `max(1, …)` so an all-zero series produces a
    //    blank chart instead of dividing by zero; the existing
    //    `sparkline` does the same. Rounded to the nearest pixel
    //    count, then clamped to `[0, totalPixels]` so a rounding
    //    overshoot doesn't bleed into a higher band.
    let maxV = max(1, padded.max() ?? 1)
    let filled: [Int] = padded.map { s in
        let v = Double(s) / Double(maxV)
        return min(totalPixels, max(0, Int((v * Double(totalPixels)).rounded())))
    }

    // 4. Encode. Reserve a generous capacity so the String never
    //    reallocates mid-build — 2 bytes per column per band (the
    //    RLE introducer can push the worst case above 1 byte/col)
    //    plus 16 bytes for the color-set prefix.
    var out = ""
    out.reserveCapacity(bands * cols * 2 + 16)

    // Color register 1 — calm cyan, readable on dark + light.
    // (Px, Py, Pz in 0–100 model units; the literal is the
    // `100 * fraction` of R, G, B.)
    out += "#1;2;30;80;100"

    for b in 0..<bands {
        if b > 0 { out += "-" }  // DEC `Mn` — start a new band
        // RLE state. A run is flushed at every column-boundary
        // change AND at the end of the band; we never let a run
        // cross a `-` separator (the run would silently mis-parse
        // on terminals that count the separator as a column op).
        var runChar: Character = "?"
        var runCount = 0

        @inline(__always)
        func flush() {
            guard runCount > 0 else { return }
            if runCount >= 3 {
                out += "!\(runCount)\(runChar)"
            } else {
                out += String(repeating: String(runChar), count: runCount)
            }
            runCount = 0
        }

        for i in 0..<cols {
            // 6-bit pattern for column `i`, band `b`.
            // bit 0 (LSB of the 6-bit value) = topmost pixel of the
            // band; bit 5 (MSB) = bottommost. `fromBottom` indexes
            // scanlines 0 (bottom) → totalPixels-1 (top).
            var pattern: UInt8 = 0
            for bit in 0..<6 {
                let fromBottom = totalPixels - 1 - (b * 6 + bit)
                if fromBottom < filled[i] {
                    pattern |= (1 << bit)
                }
            }
            // 0x3F + pattern ∈ 0x3F..0x7E ('?'..'~') — always a
            // valid Unicode scalar for a UInt8 in 0..63. The
            // `pattern & 0x3F` documents the invariant.
            // `UnicodeScalar(_:)` for `UInt8` is a non-failable
            // init in Swift (same as KeyDecoder.swift's ctrl
            // mapping), so no `?` / `!` is needed.
            let sixelChar = Character(UnicodeScalar(0x3F + (pattern & 0x3F)))
            if sixelChar == runChar {
                runCount += 1
            } else {
                flush()
                runChar = sixelChar
                runCount = 1
            }
        }
        flush()
    }

    // \e P q <data> \e \  — DEC sixel introducer + String Terminator.
    return "\u{1B}Pq" + out + "\u{1B}\\"
}
