import Foundation

// MARK: - RGB

/// 24-bit color. Every cell of the HUD and every widget color flows
/// through `sgr(_:_:)` (or `gradient`) so a 16-color terminal never
/// receives a raw `\e[38;2;…m` sequence.
struct RGB: Sendable, Equatable, Hashable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }
}

// MARK: - Theme

/// The color palette the renderer uses. **All fields must be addressed
/// via `sgr(_:depth:)`** — no widget should ever emit a hardcoded
/// `\e[38;2;r;g;bm` sequence. The `dark` preset is the only one in P2;
/// a future wave can add `light`.
struct Theme: Sendable, Equatable {
    /// Gradient endpoints (cyan → violet) for accents, model badge, etc.
    var accentA: RGB
    var accentB: RGB
    /// Status colors.
    var ok: RGB
    var warn: RGB
    var err: RGB
    /// Muted text and chrome (separators, dim labels).
    var dim: RGB
    /// Default foreground / background.
    var fg: RGB
    var bg: RGB
    /// Three-stop context gauge (low/mid/high utilization).
    var gaugeLow: RGB
    var gaugeMid: RGB
    var gaugeHigh: RGB

    static let dark = Theme(
        accentA:    RGB(0x22, 0xD3, 0xEE),   // cyan
        accentB:    RGB(0xA7, 0x8B, 0xFA),   // violet
        ok:         RGB(0x4A, 0xDE, 0x80),   // green
        warn:       RGB(0xFB, 0xBF, 0x24),   // amber
        err:        RGB(0xF8, 0x71, 0x71),   // red
        dim:        RGB(0x6B, 0x72, 0x80),   // slate-500
        fg:         RGB(0xE4, 0xE4, 0xE7),   // zinc-200
        bg:         RGB(0x09, 0x0B, 0x10),   // near-black
        gaugeLow:   RGB(0x4A, 0xDE, 0x80),
        gaugeMid:   RGB(0xFB, 0xBF, 0x24),
        gaugeHigh:  RGB(0xF8, 0x71, 0x71)
    )

    /// Light-mode equivalent of `dark` for users on a white-background
    /// terminal. Same gradient endpoints, but the foregrounds and
    /// gauge stops are pulled to higher-luma values so contrast holds
    /// against the `bg` (white-ish, off-white to avoid the pure-white
    /// burn).
    static let light = Theme(
        accentA:    RGB(0x08, 0x96, 0x9B),   // cyan-700
        accentB:    RGB(0x6D, 0x28, 0xD9),   // violet-700
        ok:         RGB(0x16, 0x82, 0x43),   // green-700
        warn:       RGB(0xB4, 0x53, 0x09),   // amber-700
        err:        RGB(0xB9, 0x1C, 0x1C),   // red-700
        dim:        RGB(0x6B, 0x72, 0x80),   // slate-500 (works on both)
        fg:         RGB(0x18, 0x18, 0x1B),   // zinc-900
        bg:         RGB(0xFA, 0xFA, 0xFA),   // zinc-50
        gaugeLow:   RGB(0x16, 0x82, 0x43),
        gaugeMid:   RGB(0xB4, 0x53, 0x09),
        gaugeHigh:  RGB(0xB9, 0x1C, 0x1C)
    )

    /// High-contrast variant. Pushes accent A/B to pure cyan + magenta
    /// and status colors to fully saturated primaries so a colorblind
    /// user can still tell the difference between ok / warn / err /
    /// the two accents. Background is pure black; foreground is pure
    /// white.
    static let highContrast = Theme(
        accentA:    RGB(0x00, 0xFF, 0xFF),   // pure cyan
        accentB:    RGB(0xFF, 0x00, 0xFF),   // pure magenta
        ok:         RGB(0x00, 0xFF, 0x00),   // pure green
        warn:       RGB(0xFF, 0xFF, 0x00),   // pure yellow
        err:        RGB(0xFF, 0x40, 0x40),   // bright red
        dim:        RGB(0xAA, 0xAA, 0xAA),   // light gray
        fg:         RGB(0xFF, 0xFF, 0xFF),   // pure white
        bg:         RGB(0x00, 0x00, 0x00),   // pure black
        gaugeLow:   RGB(0x00, 0xFF, 0x00),
        gaugeMid:   RGB(0xFF, 0xFF, 0x00),
        gaugeHigh:  RGB(0xFF, 0x40, 0x40)
    )

    /// Mono: every field is a value the 16-color palette can reach,
    /// but the canonical use is to drive `ColorDepth = .mono` from the
    /// user (`NO_COLOR=1`). Forcing `Theme.mono` via `/theme mono`
    /// lets the user get the same flat experience on a TTY that
    /// doesn't set `NO_COLOR` (some IDEs and CI emulators).
    static let mono = Theme(
        accentA:    RGB(0xFF, 0xFF, 0xFF),
        accentB:    RGB(0xCC, 0xCC, 0xCC),
        ok:         RGB(0xAA, 0xAA, 0xAA),
        warn:       RGB(0x88, 0x88, 0x88),
        err:        RGB(0x66, 0x66, 0x66),
        dim:        RGB(0x88, 0x88, 0x88),
        fg:         RGB(0xE0, 0xE0, 0xE0),
        bg:         RGB(0x10, 0x10, 0x10),
        gaugeLow:   RGB(0xAA, 0xAA, 0xAA),
        gaugeMid:   RGB(0x88, 0x88, 0x88),
        gaugeHigh:  RGB(0x66, 0x66, 0x66)
    )

    /// All named presets in display order. Used by `/theme` to print
    /// the list and validate user input.
    static let all: [Theme] = [.dark, .light, .highContrast, .mono]

    /// Friendly name (lowercased) — used in `/theme` and the palette.
    var name: String {
        switch self {
        case .dark:         return "dark"
        case .light:        return "light"
        case .highContrast: return "high-contrast"
        case .mono:         return "mono"
        default:            return "custom"
        }
    }

    /// Look up a preset by its friendly name. Returns `nil` for
    /// unknown inputs.
    static func named(_ s: String) -> Theme? {
        switch s.lowercased() {
        case "dark":           return .dark
        case "light":          return .light
        case "high-contrast", "hc", "highcontrast": return .highContrast
        case "mono", "monochrome", "no-color":      return .mono
        default:               return nil
        }
    }
}

// MARK: - SGR (color → escape sequence)

/// Returns the SGR sequence that selects the given color at the given
/// depth. **Mono returns ""** — no escapes ever, so `NO_COLOR` /
/// dumb-terminal users get plain text. The same RGB is always reachable
/// via this function, which means a future audit can grep for `\e[38;2;`
/// and trust nothing raw is shipping.
func sgr(_ c: RGB, _ depth: ColorDepth, bg: Bool = false) -> String {
    switch depth {
    case .mono:
        return ""
    case .x16:
        return ansi16(c, bg: bg)
    case .x256:
        return "\u{1B}[\(bg ? 48 : 38);5;\(nearest256(c))m"
    case .truecolor:
        return "\u{1B}[\(bg ? 48 : 38);2;\(c.r);\(c.g);\(c.b)m"
    }
}

/// Resets all attributes (`SGR 0`).
func sgrReset() -> String { "\u{1B}[0m" }

// MARK: - 256-color cube mapping

/// 6×6×6 RGB cube, indices 16-231, using the standard xterm palette.
/// Round to nearest of {0, 95, 135, 175, 215, 255} per channel.
private func nearest256(_ c: RGB) -> Int {
    let cube: [UInt8] = [0, 95, 135, 175, 215, 255]
    func pick(_ v: UInt8) -> Int {
        var bestIdx = 0
        var bestDist = Int.max
        for (i, level) in cube.enumerated() {
            let d = abs(Int(level) - Int(v))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }
    let r = pick(c.r)
    let g = pick(c.g)
    let b = pick(c.b)
    return 16 + 36 * r + 6 * g + b
}

// MARK: - 16-color mapping

/// Coarse nearest-ANSI matching. Maps an RGB to one of the 16 standard
/// ANSI colors using brightness (normal vs. bright) and a coarse hue
/// family. Good enough for HUD chrome; full perceptual mapping comes
/// later if anyone notices the gaps.
private func ansi16(_ c: RGB, bg: Bool) -> String {
    let r = Double(c.r) / 255.0
    let g = Double(c.g) / 255.0
    let b = Double(c.b) / 255.0
    let brightness = (r + g + b) / 3.0
    let bright = brightness > 0.55
    // 0=red, 1=yellow, 2=green, 3=cyan, 4=blue, 5=magenta, 6=gray
    let maxC = max(r, max(g, b))
    let minC = min(r, min(g, b))
    let delta = maxC - minC
    var family: Int = 6  // default gray
    if delta > 0.12 {
        if maxC == r {
            family = g >= b ? 1 : 0       // r: yellow if g>=b, else red
        } else if maxC == g {
            family = b >= r ? 3 : 2        // g: cyan if b>=r, else green
        } else {
            family = r >= g ? 5 : 4        // b: magenta if r>=g, else blue
        }
    }
    // Map to ANSI indices: 0=red(1), 1=yellow(3), 2=green(2),
    // 3=cyan(6), 4=blue(4), 5=magenta(5), 6=gray(7)
    let ansiHue = [1, 3, 2, 6, 4, 5, 7][family]
    let fgBase = bright ? 90 : 30
    let code = fgBase + ansiHue
    return bg ? "\u{1B}[\(code + 10)m" : "\u{1B}[\(code)m"
}

// MARK: - Gradient

/// Per-glyph lerp between two RGBs. At 24-bit depth, each glyph gets a
/// slightly different color, producing a smooth cyan→violet sweep. At
/// lower depths, each glyph's RGB is still fed through `sgr` so a
/// 16-color terminal gets a single best-fit color (less pretty but
/// always correct).
func gradient(_ s: String, _ a: RGB, _ b: RGB, _ depth: ColorDepth) -> String {
    if s.isEmpty { return s }
    if depth == .mono { return s }  // Mono = no escapes
    let chars = Array(s)
    if chars.count == 1 {
        return "\(sgr(a, depth))\(s)\(sgrReset())"
    }
    var out = ""
    out.reserveCapacity(s.utf8.count + chars.count * 12)
    let last = chars.count - 1
    for (i, c) in chars.enumerated() {
        let t = last == 0 ? 0.0 : Double(i) / Double(last)
        let r = UInt8(Double(a.r) + (Double(b.r) - Double(a.r)) * t)
        let g = UInt8(Double(a.g) + (Double(b.g) - Double(a.g)) * t)
        let bl = UInt8(Double(a.b) + (Double(b.b) - Double(a.b)) * t)
        out += sgr(RGB(r, g, bl), depth)
        out += String(c)
    }
    out += sgrReset()
    return out
}
