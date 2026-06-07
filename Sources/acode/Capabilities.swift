import Foundation
import AcodeCore

// MARK: - Capabilities
//
// `ColorDepth` and `GraphicsProtocol` live in `AcodeCore` (extracted during
// the Phase 1 restructure) so the shared formatting layer (`Theme`,
// `DiffView`, `Highlight`) can produce escape sequences without depending on
// this CLI-only detection layer. The probing logic that turns env vars +
// `Terminal` queries into a concrete `ColorDepth` value still lives here in
// the CLI target.

/// Terminal capabilities detected once at startup. The whole UI is a
/// function of this struct, so one code path serves every terminal
/// (Terminal.app, iTerm, kitty, WezTerm, ssh pipe).
///
/// **Non-TTY (`-p`, pipe, CI) → the existing line renderer, no escapes
/// emitted.** The P1 throwaway harness only enters raw mode when both
/// stdin and stdout are TTYs, so non-TTY runs never see this struct.
struct Capabilities: Sendable {
    var color: ColorDepth
    var graphics: GraphicsProtocol
    var mouse: Bool
    var paste: Bool
    var barCursor: Bool

    /// Probe from environment + a `Terminal` handle. The `term` argument is
    /// reserved for queries that need a live terminal (e.g. DA1 for sixel)
    /// — not yet used in P1. `NO_COLOR` (https://no-color.org) trumps
    /// everything else.
    static func detect(env: [String: String], term: Terminal) -> Capabilities {
        var caps = Capabilities(
            color: .x16,
            graphics: .none,
            mouse: true,
            paste: true,
            barCursor: true
        )

        // NO_COLOR → mono, no graphics. Per the spec the field still gets
        // a value so callers don't have to special-case `nil`.
        if env["NO_COLOR"] != nil {
            caps.color = .mono
            caps.graphics = .none
            return caps
        }

        // Color depth: truecolor first, then 256, fall back to x16.
        if let ct = env["COLORTERM"]?.lowercased(),
           ct == "truecolor" || ct == "24bit" {
            caps.color = .truecolor
        } else if let term = env["TERM"]?.lowercased(),
                  term.hasSuffix("-256color") {
            caps.color = .x256
        }

        // Graphics: TERM_PROGRAM hints at iTerm2 / WezTerm; TERM=*kitty*
        // for kitty. Sixel would need a live DA1 query — deferred.
        if let tp = env["TERM_PROGRAM"]?.lowercased() {
            switch tp {
            case "iterm.app", "iterm2":
                caps.graphics = .iterm
            case "wezterm":
                caps.graphics = .sixel
            default:
                break
            }
        }
        if let term = env["TERM"]?.lowercased(),
           term.contains("kitty") {
            caps.graphics = .kitty
        }

        return caps
    }
}
