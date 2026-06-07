# acode — TUI Plan (full alternate-screen UI)

Companion to `plan.md` / `EXECUTION_PLAN.md`, in the same idiom: invariants up front, canonical
interfaces to implement verbatim, dependency-ordered waves, each task gated on a named acceptance
check. This document adds **one** deliberate scope change and records exactly how it interacts with
the spec's non-negotiables.

> Target unchanged: `acode`, native Swift 6.3 / macOS 26, SPM executable, Apple Silicon.
>
> See **`TUI_EPIC_PLAN.md`** for the maximalist elaboration of the chosen Top HUD layout (theme +
> animation system, syntax-highlighted diffs, command palette, orchestrator timeline, optional
> graphics tier) and the file-by-file build plan. This file remains the architectural base.

---

## §0. The scope decision (owner-approved 2026-06-06)

`plan.md` §A lists **"no TUI"** as a v1 non-goal and §G excludes **"a fancy TUI"** as anti-bloat.
This plan **supersedes that non-goal by explicit owner decision**. The TUI is built as an **opt-in
front-end** (`--tui`): default behaviour and the non-TTY path are unchanged, so nothing already
shipped regresses. When this lands, update `plan.md` §A/§G to point here rather than leaving them
contradictory.

This is the *only* scope addition. No new tools, no new providers, no new dependency.

---

## §1. Invariant disposition (how the TUI honours, or amends, §B)

| Inv. | Statement | Disposition |
|---|---|---|
| **4** | One dependency (`swift-argument-parser`); Foundation otherwise. | **Honoured.** Zero new deps. Raw ANSI + `termios`/`ioctl` via the platform `Darwin` module (a system import, not an SPM package). No SwiftTUI / ncurses / SwiftUI. |
| **5** | Plain types, no actors; *only the shell tool may block*, off the main actor. | **Amended, narrowly.** Add a second documented blocking reader — the TUI stdin read loop — which runs **off the main actor exactly like `RunShell`**. `Renderer`, the model, the view stay plain value types; `TUIApp` is a `@MainActor` class, not an actor. Record this carve-out beside the RunShell one. |
| **6** | Streaming is pull-based; no `@Sendable` token callbacks. | **Honoured.** Providers still return `AsyncThrowingStream`. All UI input — keys, agent events, resize, timer — funnels through a single `AsyncStream<Msg>`. The sink *posts Sendable messages*; it does not call back into the renderer with tokens. |
| **10** | Brain fidelity: REPL routing (`/`,`!`,task), the act→observe loop, etc. | **Preserved.** `route()` is reused verbatim; the TUI is a new shell around the same `Agent.run` loop. |
| 1,2,3,7,8,9 | loop shape, pairing, errors-as-data, retry, prompt order, path jail | **Untouched.** The TUI never reaches into the agent loop or tools. |

---

## §2. Architecture — Model-View-Update over a single event stream

One reducer, one render path, one input funnel. Everything that can change the screen becomes a
`Msg`; the loop applies it and repaints. Single-threaded on the main actor ⇒ no locks on UI state.

```
            ┌────────────┐  bytes    ┌────────────┐ KeyEvent
 keyboard → │ Terminal   │──(off-main)│ KeyDecoder │────────────┐
            │ read loop  │            └────────────┘            │
            └────────────┘                                       ▼
 Agent ─ streamText/toolStart/toolEnd/approve ─→ TUISink ─ post(.streamDelta/.toolStart/…) ─→ ┌───────────────┐
 SIGWINCH ───────────────────────────────────── post(.resize) ──────────────────────────────→│ AsyncStream    │
 100ms timer ─────────────────────────────────── post(.tick) ───────────────────────────────→│  <Msg>         │
                                                                                              └──────┬────────┘
                                                                                                     ▼
                                            update(&model, msg) -> [Effect]   (pure)
                                                                                                     ▼
                                            renderFrame(model, size) -> Frame  (pure)
                                                                                                     ▼
                                            ScreenRenderer.draw(frame)  → diff → minimal ANSI → Terminal
```

**Effects** are the loop's only outside-world actions: `submitTask`, `resolveApproval`, `cancelTurn`,
`quit`. Keeping `update` pure (returns `[Effect]`, performs nothing) keeps the reducer easy to reason
about and to drive by hand — no terminal needed to exercise it.

---

## §2.5. Chosen layout — Top HUD strip + live metrics

Owner pick (2026-06-06): a dense metrics HUD pinned at the top, a full-width transcript below, a fixed
input box at the bottom. Tasks render inline under the active turn and toggle with `^T`.

```
 opus-4 · ▕███████░░▏ 49% · ↑12.4k ↓3.1k · 82 tok/s · $0.21 · 00:42      ← HUD (1 row)
─────────────────────────────────────────────────────────────────────
 › refactor the approval flow and add tests                            ← transcript (fills)
 I'll read the approval code first, then harden the guard.
 → read_file ApprovalPolicy.swift   ✓ 117 lines
 → run_shell swift build            ⠹ 3.1s
   tasks: ✓ read · ⠹ guard · ○ tests · ○ swift test    ^T toggle
─────────────────────────────────────────────────────────────────────
 › ▏                                                                    ← input (1+ rows)
 ⏎ send · ^C cancel · ^T tasks · /model · /help                        ← hints (1 row)
```

The HUD is one styled row (two if narrow), rebuilt only when a value changes. Every field is a small
widget over data the loop already has:

| Field | Shows | Source / plumbing |
|---|---|---|
| model | active model id | `status.model`; `/model` updates it; orchestrator → per-role |
| context gauge | used/window bar + % | window = `provider.contextWindow`; used = compacted-history token estimate |
| ↑/↓ tokens | cumulative in/out | summed from `Usage` on each `.done` (cache hits available too) |
| tok/s | live output speed | `Metrics`: out-tokens ÷ (now − firstDelta); refreshed per frame |
| cost | running $ estimate | `Pricing[model]` × tokens; config-overridable; "—" if model unknown |
| elapsed | turn clock | now − turn start |
| tasks | ✓/⠹/○/✗ inline row | orchestrator phases now; optional `set_tasks` tool (see §3) |

Degradation: <80 cols → HUD wraps to two rows; non-TTY / `--no-tui` / `-p` → line mode. `^T` hides the
task row.

---

## §3. Canonical interfaces — implement these signatures verbatim

### Seam — `RenderSink.swift` (the one cross-cutting refactor)
Extract a protocol from the hooks `Agent`/`Orchestrator` already call. `Renderer` keeps its current
bodies (line mode); `TUISink` translates each call into a `Msg`.

```swift
protocol RenderSink: Sendable {
    func banner()
    func streamText(_ s: String)
    func endAssistant()
    func usage(_ u: Usage)
    func phase(_ p: String)
    func toolStart(_ c: ToolCall)
    func toolEnd(_ c: ToolCall, _ r: ToolResult)
    func approve(_ c: ToolCall) async -> Bool          // ← was sync; now async (see §4)
    func verboseLog(_ message: String)
}
```
`Agent.init` / `Orchestrator.run` change `renderer: Renderer` → `renderer: any RenderSink`.

### `Terminal.swift` — the imperative shim (the only file that touches termios)
```swift
struct TermSize: Sendable, Equatable { let rows: Int; let cols: Int }

@MainActor final class Terminal {
    init() throws                                   // capture original termios
    func enterRawAltScreen()                        // raw + \e[?1049h \e[?25l \e[?2004h
    func restore()                                  // alt-screen off, cursor on, paste off, termios back
    func size() -> TermSize                          // ioctl(TIOCGWINSZ)
    func write(_ s: String); func flush()           // buffered
    nonisolated static func readLoop(_ sink: @Sendable @escaping (UInt8) -> Void)  // OFF-main blocking read
}
```
Restore is belt-and-suspenders: `defer` in `run()`, `atexit`, **and** `sigaction` for
INT/TERM/HUP so a crash or kill never leaves the user's terminal in raw mode. (Highest-risk area —
see §6.)

### `KeyEvent.swift` — pure, incremental decoder
```swift
enum KeyEvent: Sendable, Equatable {
    case char(Character), enter, backspace, tab, esc
    case left, right, up, down, home, end, pageUp, pageDown
    case ctrl(Character)                  // ctrl("c"), ctrl("d")
    case paste(String)                    // bracketed-paste payload
    case unknown
}
struct KeyDecoder { mutating func feed(_ byte: UInt8) -> [KeyEvent] }   // handles UTF-8 + split escapes
```

### `TUIModel.swift` — state + pure reducer
```swift
struct TUIModel: Sendable {
    var transcript: [TranscriptItem]
    var input: InputState                 // text + grapheme cursor
    var status: Status                    // model, cwd, branch, in/out tokens, contextWindow
    var activity: Activity                // idle / thinking / runningTool / awaitingApproval
    var scroll: Int                       // 0 = pinned to bottom
    var history: [String]; var historyIdx: Int?
    var pendingApproval: ToolCall?
}
enum TranscriptItem: Sendable {
    case user(String), assistant(text: String), tool(ToolView)
    case phase(String), notice(String), error(String)
}
struct ToolView: Sendable { var name, summary, output: String; var status: ToolStatus; var expanded: Bool }
enum ToolStatus: Sendable { case running, ok, error }

enum Msg: Sendable {
    case key(KeyEvent)
    case streamDelta(String), assistantEnd, phase(String)
    case toolStart(ToolCall), toolEnd(ToolCall, ToolResult)
    case approvalRequest(ToolCall), usage(Usage)
    case resize(TermSize), tick
}
enum Effect: Sendable { case submitTask(String), resolveApproval(Bool), cancelTurn, quit }

func update(_ m: inout TUIModel, _ msg: Msg) -> [Effect]            // PURE
```

### `TUIView.swift` — pure layout
```swift
struct Frame: Sendable, Equatable { var lines: [String]; var cursor: (row: Int, col: Int) }
func renderFrame(_ m: TUIModel, size: TermSize) -> Frame           // wrap + region math, ANSI baked in
```
Regions, top→bottom: `transcript` (fills) · separator · `input` (1+ rows) · `status` (1 row).
Transcript is bottom-anchored; `scroll>0` pages up.

### `ScreenRenderer.swift` — flicker-free diff
```swift
struct ScreenRenderer {
    mutating func draw(_ next: Frame, to term: Terminal)           // repaint only changed rows
    mutating func invalidate()                                     // full repaint (after resize)
}
```

### `TUISink.swift` — `RenderSink` that feeds the loop
```swift
final class TUISink: RenderSink, @unchecked Sendable {
    init(post: @Sendable @escaping (Msg) -> Void)
    // streamText → post(.streamDelta) … toolEnd → post(.toolEnd) …
    func approve(_ c: ToolCall) async -> Bool {                    // post + await continuation
        await withCheckedContinuation { cont in stash(c, cont); post(.approvalRequest(c)) }
    }
}
```

### `TUIApp.swift` — the merged loop
```swift
@MainActor final class TUIApp {
    init(agent: Agent, route: @Sendable @escaping (String) -> Input, terminal: Terminal)
    func run() async        // build AsyncStream<Msg>; for await: update → interpret Effects → renderFrame → draw
}
```

### `Metrics.swift` — live counters + cost (pure values, fed by the loop)
```swift
struct Metrics: Sendable {
    var inTokens = 0, outTokens = 0, cacheHits = 0
    var firstDeltaAt: Double?               // turn-start stamp (passed in; no Date.now in pure code)
    var samples: [Int] = []                 // recent out-tok/s, ring buffer for the sparkline
    func tokPerSec(now: Double) -> Int      // outTokens ÷ (now − firstDeltaAt)
    func cost(_ p: Pricing?) -> Double?      // (in/out/cache) × $/Mtok; nil if model unpriced
}
struct Pricing: Sendable { let inM, outM, cacheM: Double }   // $ per 1M tokens; per-model, config-overridable

enum TaskState: Sendable { case done, running, pending, failed }   // ✓ ⠹ ○ ✗
struct TaskItem: Sendable { var title: String; var state: TaskState }
```
`Metrics`, `[TaskItem]`, and `Status` live on `TUIModel`. The HUD, gauge, and sparkline are **pure
string builders** in `TUIView` — `hud(Status, Metrics)`, `gauge(used, total, width)`,
`sparkline([Int])` — so the whole strip is reproducible from those three values alone.

**Task source.** Default: render the orchestrator's phases (planner→coder→reviewer + rounds), which
already exist — no new scope. To populate the row for *single-agent* turns too, add a tiny `set_tasks`
tool (model maintains a todo list, ~40 lines) — a small, explicit scope add; confirm before P3.

---

## §4. The async-approval flow (the only behavioural refactor)

`approve` is synchronous + blocking today (`readLine`). The TUI must show an approval block and keep
rendering while it waits, so it becomes `async`:

1. `Agent` → `await tools.execute(call, approve: renderer.approve)` — `ToolRegistry.execute`'s
   `approve` param widens `(_ ) -> Bool` → `(_ ) async -> Bool`.
2. `TUISink.approve` stashes a `CheckedContinuation` and posts `.approvalRequest(call)`.
3. `update` sets `pendingApproval`, `activity=.awaitingApproval`; the view draws a highlighted block
   (command, or coloured diff for `edit_file`) with `y / n / a`.
4. A key → `update` clears `pendingApproval`, returns `.resolveApproval(Bool)`; the loop resumes the
   stashed continuation. `a` also calls `policy.allowAlways` (unchanged semantics).

Line-mode `Renderer.approve` gains `async` but keeps its `readLine` body. Existing closure call-sites
(`{ _ in true }` in `ApprovalTests`) adapt automatically; the existing `ApprovalRepromptTests` is
updated to `await renderer.approve(...)` so the suite keeps compiling (an edit to an existing test —
no new tests). **This refactor ships first (P0) with no visible change** so the risky part is isolated
and proven before any drawing code exists.

---

## §5. Execution waves (gate each on `swift build` green + a manual smoke check)

> **No new tests** (owner preference — see memory `no-tests`). New behaviour is verified by building
> and driving the app by hand against the per-wave checks below. The pure core (`update`,
> `renderFrame`, `KeyDecoder`) is exercised interactively, not via test files. The **existing** suite
> must still compile and pass — run it once per wave with
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

### Wave P0 — Seam, zero visible change
- **U0.1** Extract `RenderSink`; `Renderer: RenderSink`; `Agent`/`Orchestrator` take `any RenderSink`.
  *Verify:* builds; existing suite still green; REPL behaves identically.
- **U0.2** `approve` async through `RenderSink` + `ToolRegistry.execute`; update existing call-sites
  (and edit the two existing approval tests to `await` so they keep compiling — no new tests).
  *Verify:* builds; existing suite green.

### Wave P1 — Terminal + input core
- **U1.1** `Terminal` (raw/alt-screen/size/restore + signal & atexit restore).
  *Verify:* enter/leave clean; `kill -TERM` mid-session leaves a sane terminal.
- **U1.2** `KeyEvent` + `KeyDecoder`. *Verify by hand:* arrows, Home/End, PageUp/Dn, `ctrl(c/d)`,
  multi-byte UTF-8 paste, an escape split across two reads.
- **U1.3** Minimal bottom input box behind `--tui` (echo, Enter submits, Ctrl-D quits) replacing
  `readLine`. *Verify:* type/edit/submit a line; quit cleanly.

### Wave P2 — MVU + transcript + HUD
- **U2.1** `TUIModel`+`Msg`+`update`. *Verify:* typing, submit, ↑/↓ history, `streamDelta`
  accumulation, scroll clamping.
- **U2.2** `renderFrame` incl. the **HUD strip**, transcript wrap, input box, hints. *Verify:* layout
  holds at 80×24 and 120×40.
- **U2.3** `ScreenRenderer` diff. *Verify:* no flicker; only changed rows move.
- **U2.4** `TUIApp` loop + `TUISink` + `Metrics` plumbing (cumulative tokens, context gauge, tok/s,
  elapsed). `--tui` launches; line mode stays default + non-TTY fallback. *Verify:* stream a real turn
  — input stays put, HUD updates live; `acode -p` and piped stdout remain line-mode (no escapes).

### Wave P3 — Tool, approval & tasks
- **U3.1** Tool blocks (status + collapsible output) + coloured `edit_file` diff. *Verify:* run/ok/error.
- **U3.2** Inline approval on the async continuation. *Verify:* `y/n/a` mid-turn; `a` persists
  (ties back to the stdin fix).
- **U3.3** Task row — orchestrator phases by default; optional `set_tasks` tool **(confirm scope first)**.
  *Verify:* `/plan` shows phases; if the tool is added, a single-agent turn shows its todo list.

### Wave P4 — Polish
- **U4.1** ↑/↓ history recall + slash-command autocomplete popup.
- **U4.2** Scrollback (PageUp/Dn, wheel), SIGWINCH re-wrap, bracketed paste.
- **U4.3** Sparkline + cost (`Pricing` table), NO_COLOR / 256 / truecolor, `displayWidth` refinement,
  verified `--no-tui`. *Verify:* a full manual TUI session checklist.

---

## §6. Verification & risks

**How it's verified (no test files).** `swift build` green each wave + drive the app by hand against
the per-wave checks in §5; keep the existing suite compiling and passing. The pure core (`update`,
`renderFrame`, `KeyDecoder`) needs no terminal, so it can be poked interactively — but per owner
preference (`no-tests`) we add **no new tests**. Keeping `Terminal` behind a small surface still pays
off: it isolates the one risky, hard-to-eyeball component.

**Risks, highest first.**
1. **Terminal restore.** A bug here leaves the user's shell broken. Mitigate with triple restore
   (`defer` + `atexit` + `sigaction`) landed and manually abused in P1 before any UI exists.
2. **Unicode display width.** Correct wrap/cursor needs a `wcwidth`-like width (emoji/CJK/ZWJ).
   Start with a documented width-1 simplification + a `displayWidth(Character)` seam; refine in P4.
   Flag as a known limitation until then.
3. **Line budget.** ~1,900–2,300 production lines across ~10 files (TUI core + `Metrics` / HUD / task
   row) — a real step past the original ~1,250-line ethos (repo is already ~3,640). No test lines are
   added. Acceptable only under the §0 decision; keep each file tight.
4. **Off-main input reader + `defaultIsolation(MainActor)`.** Reader is a detached loop posting
   `Sendable` `Msg`s; never touches UI state directly. Mirror RunShell's pattern and comment.

**Pre-flight choices (confirm at U1.1 / U2.4):**
- Gating: `--tui` opt-in now; auto-enable-on-TTY later. `--no-tui` / `-p` / non-TTY → line mode.
- `ISIG`: keep **off** and decode `0x03`/`0x04` ourselves (Ctrl-C cancels the *turn*, not the app),
  superseding the `runCancellable` SIGINT source while the TUI owns the screen.
- Status `branch`: cheap `git symbolic-ref --short HEAD` via the existing shell path, refreshed per turn.
- Cost/pricing: ship a small built-in `$/Mtok` table keyed by model, overridable in config; show "—"
  for an unpriced model rather than guessing.
- Task source: orchestrator phases by default; the `set_tasks` tool only if you green-light the scope.

---

## §7. ANSI cheat-sheet (the whole vocabulary needed)

`\e[?1049h/l` alt-screen · `\e[?25l/h` cursor hide/show · `\e[?2004h/l` bracketed paste ·
`\e[<row>;<col>H` move · `\e[2K` clear line · `\e[0m` reset · `\e[38;2;r;g;bm` truecolor ·
`ioctl(TIOCGWINSZ)` size · `SIGWINCH` resize. No library required.
