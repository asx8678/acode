# acode — Epic TUI Plan (high-detail)

The maximalist elaboration of `TUI_PLAN.md`. That doc fixes the **architecture** (raw-ANSI MVU, the
`RenderSink` seam, async approval) and the **chosen layout** (Top HUD strip). This one specifies the
*epic* layer in full: capability tiers, the complete visual language, a theme + animation system, a
widget catalog, syntax-highlighted diffs, a command palette, an orchestrator timeline, and an optional
graphics tier — plus a file-by-file build plan.

Constraints carried over, unchanged: **pure Swift, Foundation only, zero new dependencies**, opt-in via
`--tui`, line mode as the non-TTY fallback. **No tests** (owner preference) — every wave is verified by
`swift build` + driving the app by hand; the existing suite is kept compiling.

---

## §0. What "epic" means here

The experience targets, in priority order:

1. **Alive, not static.** A steady animation clock drives a pulsing activity dot, braille spinners,
   smoothly-filling gauges, a scrolling tok/s sparkline, and a soft "typing" cursor on streamed text.
2. **Truecolor identity.** A cohesive 24-bit palette with an accent **gradient** (cyan→violet) on the
   wordmark, active widgets, and progress fills. Degrades cleanly to 256/16/no-color.
3. **Information-dense but legible.** The HUD shows model, context, tokens, tok/s, cost, elapsed, and
   live activity in one row, without clutter — every glyph earns its place.
4. **Code looks like code.** Diffs are unified, line-numbered, with subtle red/green backgrounds and
   **syntax highlighting**.
5. **Fast to drive.** A fuzzy **command palette** (`/`), `^T` task toggle, history recall, mouse
   scroll/click-to-expand, bracketed paste.
6. **Cinematic edges.** A gradient startup wordmark, an animated orchestrator **timeline**
   (planner→coder→reviewer), and transient **toasts** ("session saved").
7. **Never breaks the terminal.** Capability detection + triple-restore guarantee a clean exit on any
   terminal, including dumb pipes.

---

## §1. Capability tiers (detected once at startup, re-checked on resize)

`Capabilities` is probed from `$TERM`, `$COLORTERM`, `$TERM_PROGRAM`, and terminal queries; the whole
UI is a function of it, so one code path serves every terminal:

| Capability | Probe | Epic tier | Fallback |
|---|---|---|---|
| Color depth | `$COLORTERM=truecolor`, `$TERM=*-256color` | 24-bit gradients | 256 → 16 → mono (NO_COLOR) |
| Graphics | `$TERM_PROGRAM` = kitty / iTerm / WezTerm; sixel via DA1 query | inline charts (kitty/iTerm/sixel) | Unicode sparkline/braille |
| Mouse | always offer SGR 1006 | scroll + click-to-expand | keyboard only |
| Bracketed paste | `?2004` | multi-line paste as one block | char-by-char |
| Cursor style | DECSCUSR | bar cursor in input | block |
| Unicode width | assume modern; `displayWidth()` seam | emoji/CJK aware | width-1 |

Non-TTY (`-p`, pipe, CI) → the existing line renderer, no escapes emitted.

---

## §2. The look — every state

### 2.1 Startup wordmark (gradient underline animates L→R once)
```
   ▄▀█ █▀▀ █▀█ █▀▄ █▀▀      acode 0.1.0
   █▀█ █▄▄ █▄█ █▄▀ ██▄      ◆ claude-opus-4 · api.anthropic.com
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━   [cyan→violet gradient]
   ~/projects/swift (main ✗)          ⏎ start · / commands · ^C quit
```

### 2.2 The HUD (one row; annotated)
```
 ◆ opus-4  ▕▰▰▰▰▰▰▰▰▱▱▱▱▏49%  ↑12.4k ↓3.1k  ⚡82 t/s ▁▂▃▅▇▆▅  $0.21  ⏱00:42  ●
 └ model    └ context gauge    └ tokens       └ live tok/s + sparkline  └cost └clock └pulse
```
- gauge fill is a truecolor gradient green→amber→red as it nears the window limit;
- the sparkline scrolls left as new tok/s samples arrive;
- `●` pulses (dim↔bright) while a turn is active, steady when idle.

### 2.3 Streaming with a typing cursor
```
 › refactor the approval flow
 I'll read the approval code first, then harden the file-clobber guard▌
                                                                      └ soft-blinking cursor
```

### 2.4 Tool calls — a connected tree with live timers
```
 ╭ read_file  ApprovalPolicy.swift ·············· ✓ 117 lines   0.02s
 │
 ├ edit_file  ApprovalPolicy.swift ·············· +12 −3        0.01s
 │
 ╰ run_shell  swift build ······················· ⠹ 3.1s        ← amber spinner, ticking
```

### 2.5 Syntax-highlighted diff + approval card
```
 ╭─ approve · edit RunShell.swift ───────────────────────────────────╮
 │  41 │ - process.standardError = pipe                               │  [red bg, dimmed]
 │  42 │ + process.standardInput = FileHandle.nullDevice              │  [green bg, hl]
 │                                                                    │
 │     [y] yes      [n] no      [a] always allow edit_file            │  [accent border]
 ╰────────────────────────────────────────────────────────────────────╯
```
Keywords/types/strings colored; `+`/`−` gutters; line numbers from the hunk.

### 2.6 Orchestrator timeline (`/plan`) — animated stepper
```
 ●━━━━━━━━━●━━━━━━━━○      planner ✓   coder ◐ round 2   reviewer ○
 Planning   Coding   Review     ▕▰▰▰▰▰▱▱▏ 2/3 rounds
```

### 2.7 Command palette (`/` opens; fuzzy filter)
```
        ╭─ ⌘ command ─────────────────────────────╮
        │ /mo▏                                    │
        │ ───────────────────────────────────────  │
        │ ◆ /model         switch active model    │  ← selected, accent
        │   /mode plan     multi-agent mode       │
        │   /approvals     show approval policy    │
        ╰─────────────────────────────────────────╯
```

### 2.8 Toast (transient, bottom-right, fades after ~2s)
```
                                              ╭ ✓ session saved ╮
                                              ╰─────────────────╯
```

---

## §3. Theme & color system

```swift
struct RGB: Sendable { let r, g, b: UInt8 }
struct Theme: Sendable {
    var accentA, accentB: RGB          // gradient endpoints (cyan → violet)
    var ok, warn, err, dim, fg, bg: RGB
    var gaugeLow, gaugeMid, gaugeHigh: RGB
}
enum ColorDepth: Sendable { case truecolor, x256, x16, mono }

func sgr(_ c: RGB, _ depth: ColorDepth, bg: Bool = false) -> String   // → \e[38;2;r;g;bm or nearest-256 / nearest-16 / ""
func gradient(_ s: String, _ a: RGB, _ b: RGB, _ depth: ColorDepth) -> String   // per-glyph lerp
```
Presets: `dark` (default), `light`, `high-contrast`, `mono`. `NO_COLOR` forces `mono`. Every color
goes through `sgr(_,depth)` so a 16-color terminal gets the nearest palette match, never raw truecolor.

---

## §4. Animation system

A single clock drives all motion; widgets are pure functions of `tick`.

```swift
// TUIModel gains: var tick: Int        (frame counter; pure — no Date in the reducer)
// Msg gains:      case frame            (posted by an off-main timer while `active`)
```
- **Cadence:** ~16/frame (≈60 fps) **only while something is animating** (active turn, spinner,
  gradient sweep, toast). Idle → timer stops → **0% CPU**.
- **What animates:** activity pulse, spinner frame, gauge ease-in toward target %, sparkline scroll,
  typing cursor blink, startup gradient sweep, toast fade, timeline progress.
- **Coalescing (carried from `TUIPLAN §2`):** the loop drains all pending `Msg`s, then renders once
  per frame. A `frame` tick that produces an identical `Frame` emits **zero** bytes (the diff is empty),
  so a "still" animation costs nothing.

---

## §5. Widget catalog (pure string builders in `TUIView`)

```swift
func gauge(_ used: Int, _ total: Int, width: Int, theme: Theme, depth: ColorDepth) -> String
func sparkline(_ samples: [Int], width: Int) -> String                 // ▁▂▃▄▅▆▇█, scrolling
func spinner(_ tick: Int) -> Character                                  // braille frame
func progress(_ frac: Double, width: Int, tick: Int) -> String          // gradient fill + shimmer
func badge(_ text: String, _ color: RGB, depth: ColorDepth) -> String   // ◆ model, status chips
func pulse(_ on: Bool, _ tick: Int) -> String                           // ● dim↔bright
func diffView(_ hunks: [Hunk], theme: Theme, depth: ColorDepth) -> [String]   // numbered, colored, syntax-hl
func timeline(_ phases: [Phase], tick: Int) -> [String]                 // orchestrator stepper
func palette(_ query: String, _ items: [Command]) -> [String]           // fuzzy overlay
func toast(_ text: String, _ age: Int) -> String?                       // nil once faded
```
All deterministic given `(state, tick, theme, depth)` → the whole screen is reproducible and easy to
eyeball-debug.

---

## §6. Architecture (extends `TUI_PLAN.md`)

Same MVU spine — `Terminal` · `KeyDecoder` · `TUIModel`+`update` · `TUIView` · `ScreenRenderer` ·
`TUIApp` · `RenderSink`/`TUISink` · `Metrics`. The epic layer adds **pure** modules (no new control
flow): `Capabilities`, `Theme`, `Highlight` (syntax), `Graphics` (optional charts), `Palette`
(commands), and the widget builders in `TUIView`. `Mouse` events extend `KeyEvent`. The animation
timer is a second off-main poster into the existing `AsyncStream<Msg>` — no new concurrency model.

---

## §7. New canonical interfaces

```swift
// Capabilities.swift
struct Capabilities: Sendable {
    var color: ColorDepth
    var graphics: GraphicsProtocol     // .none / .sixel / .kitty / .iterm
    var mouse, paste, barCursor: Bool
    static func detect(env: [String:String], term: Terminal) -> Capabilities
}

// KeyEvent.swift (additions)
enum KeyEvent { /* …existing… */ case scrollUp, scrollDown, click(row: Int, col: Int) }

// Highlight.swift — lightweight, dependency-free tokenizer → colored spans
enum Lang: Sendable { case swift, shell, json, diff, plain }
func highlight(_ line: String, _ lang: Lang, theme: Theme, depth: ColorDepth) -> String
func detectLang(path: String) -> Lang

// Graphics.swift — OPTIONAL tier; only used when caps.graphics != .none
func chart(_ samples: [Int], cols: Int, rows: Int, proto: GraphicsProtocol) -> String?   // kitty/iTerm/sixel image of the tok/s graph

// Palette.swift
struct Command: Sendable { let name, blurb: String }
func fuzzy(_ query: String, _ all: [Command]) -> [Command]
```

---

## §8. Data plumbing

- **Metrics** (from `TUI_PLAN.md §3`): tokens/cache from `Usage`; tok/s = out ÷ (now − firstDelta);
  cost from a built-in `$ /Mtok` table keyed by model (config-overridable; "—" if unknown).
- **Context used:** compacted-history token estimate vs `provider.contextWindow`.
- **Syntax highlight:** `Highlight` runs over diff hunks + fenced code in assistant text; regex/lexer
  for Swift, shell, JSON, and diff — **scoped to those four** to bound size (see risks).
- **Git branch/dirty:** `git symbolic-ref --short HEAD` + `git status --porcelain` via the existing
  shell path, refreshed per turn.
- **Tasks:** orchestrator phases by default; optional `set_tasks` tool for single-agent turns
  (confirm scope — `TUI_PLAN.md §3`).
- **Graphics charts:** only when `caps.graphics != .none`; otherwise the Unicode sparkline stands in.

---

## §9. Performance

Unchanged budget despite the motion, because:
- **Diff render + frame coalescing** mean an idle/looping animation that doesn't change pixels emits
  **0 bytes**; a moving spinner repaints ~1 cell.
- **Idle-stop:** the frame timer only runs while something animates → 0% CPU at rest.
- **Truecolor cost is bytes, not compute:** ~20 B/cell of SGR; only changed cells are rewritten.
- **Graphics tier is gated + throttled:** charts redraw at most ~2/s and only if the terminal supports
  them; never on the hot streaming path.
- Network streaming + `swift build` still dominate runtime by 3–4 orders of magnitude.

---

## §10. Implementation waves (build + manual verify; no tests)

> Per wave: `swift build` green, existing suite still compiles
> (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`), and the hands-on check passes.

### P0 — Seam (zero visible change) — *as `TUI_PLAN.md §5`*
`RenderSink` extraction + async `approve`. *Verify:* builds; REPL identical.

### P1 — Terminal, keys, capabilities
`Terminal` (raw/alt-screen/size/**triple restore**), `KeyDecoder` (+mouse/paste), `Capabilities.detect`.
*Verify:* `kill -TERM` mid-session leaves a clean terminal; caps print correctly under Terminal.app,
iTerm, kitty, and a pipe.

### P2 — MVU + HUD + theme + animation spine
`TUIModel`/`update`/`renderFrame`/`ScreenRenderer`/`TUIApp`/`TUISink`/`Metrics`, the **HUD strip**,
`Theme`+`sgr`/`gradient`, the **frame clock** + pulse/spinner/gauge/sparkline. `--tui` launches; line
mode stays default. *Verify:* stream a real turn — HUD animates live, input stays put, idle = 0% CPU,
`-p`/pipe stays line-mode.

### P3 — Tool tree, syntax diffs, approval card, tasks
Connected tool-call tree with live timers; `Highlight` + `diffView`; the accent approval card on the
async continuation; task row (orchestrator phases; optional `set_tasks`). *Verify:* run/ok/error
states; colored diff; `y/n/a` mid-turn (`a` persists).

### P4 — Command palette, history, scrollback, timeline, toasts
Fuzzy `Palette` overlay; ↑/↓ history; PageUp/Dn + mouse scrollback; SIGWINCH re-wrap; orchestrator
`timeline`; transient `toast`s. *Verify:* drive everything by hand at 80×24 and 120×40.

### P5 — Epic polish + optional graphics tier
Startup gradient wordmark; theme presets + `NO_COLOR`/256/16 degradation; `displayWidth` emoji/CJK
refinement; **optional** `Graphics` charts on kitty/iTerm/sixel; `--no-tui`. *Verify:* full manual
session across capability tiers; graphics gracefully absent on Terminal.app.

---

## §11. File-by-file estimate (production only; no test lines)

| File | Low | High |
|---|---|---|
| `RenderSink.swift` (+ existing edits: Agent/Tools/Acode/Renderer/Orchestrator) | 120 | 230 |
| `Terminal.swift` | 150 | 230 |
| `KeyEvent.swift` + `KeyDecoder.swift` (+mouse/paste) | 170 | 270 |
| `Capabilities.swift` | 90 | 150 |
| `TUIModel.swift` (state + `update` + animation) | 260 | 400 |
| `TUIView.swift` (layout + HUD + widgets) | 280 | 430 |
| `ScreenRenderer.swift` | 90 | 150 |
| `TUIApp.swift` (loop + timer + effects) | 160 | 250 |
| `TUISink.swift` | 60 | 100 |
| `Theme.swift` (palette + sgr + gradient + presets) | 130 | 200 |
| `Metrics.swift` (+ `Pricing`, cost) | 90 | 150 |
| `Highlight.swift` (4 languages) | 220 | 360 |
| `Palette.swift` (commands + fuzzy) | 90 | 150 |
| `Graphics.swift` (optional tier) | 150 | 300 |
| **Total** | **~2,060** | **~3,370** |

Point estimate: **~2,700 production lines across ~15 files** (~2,400 if the optional `Graphics` tier
is deferred). No test lines. For scale: the repo's `Sources/` is ~3,640 lines today — this roughly
**doubles** it. That is the honest cost of "epic"; it is justified only under the lifted-non-goal
decision, and each file should stay tight.

---

## §12. Risks & open decisions

1. **Scope/size.** ~2,700 lines is the headline risk. Mitigate by shipping P0–P3 first (a fully usable
   epic TUI ≈ **1,700 lines**); P4–P5 (palette, graphics, themes) are independent add-ons.
2. **Syntax highlighter.** A real multi-language highlighter is a tar pit. **Decision: cap at Swift /
   shell / JSON / diff**, regex-based, best-effort — not a general lexer. Everything else renders plain.
3. **Graphics protocols.** kitty/iTerm/sixel are fiddly and terminal-specific. Keep `Graphics`
   **optional and gated**; the Unicode sparkline is always the default. Could be cut entirely.
4. **Terminal restore** (from `TUI_PLAN.md`): still the top *correctness* risk — triple restore,
   abused in P1.
5. **Truecolor on 16-color terminals:** all color flows through `sgr(_,depth)` nearest-match; never
   leak raw 24-bit codes.
6. **Open decisions to confirm:** (a) `set_tasks` tool — yes/no; (b) include the `Graphics` tier or
   defer; (c) default theme (dark) and whether to add a `/theme` command.

---

## §13. Escape-code reference (extended)

Base (`TUI_PLAN.md §7`) plus: `\e[38;2;r;g;bm`/`48;2` truecolor fg/bg · `\e[?1000;1006h` SGR mouse ·
`\e[<n> q` cursor style (DECSCUSR) · `\e[c` DA1 (sixel probe) · kitty `\e_Gf=100,a=T;<b64>\e\\` /
iTerm `\e]1337;File=...\a` inline images · `\e[6 q` bar cursor. All optional tiers are
capability-gated; the core UI needs only the base set.
