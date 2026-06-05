# acode — Execution Plan

Companion to `plan.md`. `plan.md` is the authoritative specification (mission, invariants,
interfaces, conventions, task backlog, tests, exclusions, reviewer checklist). This document is the
dependency-ordered execution roadmap derived from `plan.md` §E, per the planning-agent instructions
in `plan.md` §0. It adds no scope; it sequences, parallelizes, and de-risks what the spec defines.

- Target: `acode`, a minimal native Swift 6.3 / macOS 26 terminal coding agent (SPM executable).
- Budget: ~1,250 lines across ~14 files, one dependency (`swift-argument-parser`), Foundation otherwise.
- Reference only (do not port or build): `stripped/` is the Python "Code Puppy" core, kept solely as
  the brain reference that invariant B10 requires `acode` to mirror.

## How to use this document

Execute waves top to bottom. A wave begins only after every prior wave is green
(`swift build` && `swift test`). Within a wave, tasks joined by the parallel marker touch disjoint
files and may run concurrently; all other tasks are serial. Each task is gated on its acceptance
check (the named tests in `plan.md` §F plus, at milestone boundaries, the manual smoke step).
Commit one task per green step with message `Txx: <title>` (`plan.md` §D). Run the reviewer
checklist (`plan.md` §H) at each milestone boundary.

## Brain-fidelity mapping (invariant B10 traceability)

| Brain pillar (reference: stripped/) | Reference file | acode target file |
|---|---|---|
| REPL input routing (slash / bang / task) | cli_runner.py | main.swift (route) |
| act -> observe -> re-decide loop | agents/_runtime.py | Agent.swift |
| Five-layer prompt assembly | _builder.py, callbacks.py | Prompt.swift |
| Compaction as working memory | _compaction.py, _history.py | Conversation.swift |
| Tools (read/list/grep/edit/shell) | tools/ | FileTools.swift, RunShell.swift |
| Progressive-disclosure skills | plugins/agent_skills/ | Skills.swift |
| Decoupled rendering / streaming | messaging/ | Renderer.swift |
| Model layer (stream + tool calls) | model_factory.py | Provider/Anthropic/OpenAI |

## Pre-flight decisions (resolve before or at T0.1)

These are under-specifications in the spec that require a value choice, not new scope. Recommended
defaults are noted; confirm or override before coding the dependent task.

- D0 — Repo and toolchain. The spec mandates one commit per green task, so acode needs its own git
  repo. Recommend initializing a standalone repo rooted at `swift/` (do not commit into any parent
  repo). First action of execution: verify `swift --version` is >= 6.3; the `swift-tools-version: 6.3`
  manifest plus `.defaultIsolation` / `NonisolatedNonsendingByDefault` settings will fail to parse on
  older toolchains. If the toolchain is older, surface it rather than weakening `plan.md` §D.
- D1 — Default model IDs and contextWindow per provider (Anthropic, OpenAI, local). Needed by
  T0.7 / T0.9 / T3.6 / T3.7.
- D2 — Default max_tokens for the Anthropic request body (T0.7). Recommend a fixed default (e.g. 4096),
  overridable by config.
- D3 — read_file large-file cap (lines or bytes) for deterministic output (T0.5).
- D4 — edit_file whitespace-normalization rule: exact semantics of the normalized fallback (e.g.
  per-line trim plus collapse of internal whitespace runs) so the non-unique test is deterministic (T2.3).
- D5 — OpenAI Responses-vs-Chat selection trigger: config flag versus try-Responses / fallback-on-404 (T3.6).
- D6 — Orchestrator Agent lifecycle: use a fresh Agent (or reset()) per role and round so
  planner/coder/reviewer identities and histories do not bleed (T5.2).

## Execution waves

Default coder: swift-coder (Foundation / Swift Concurrency / SPM only; no SwiftUI/AppKit).
Milestone review: code-critic (runs `plan.md` §H). The parallel marker below is the two-bar symbol.

### Milestone M0 — skeleton that loops (non-streaming)

| Wave | Task(s) | Files | Depends | Acceptance gate |
|---|---|---|---|---|
| 0 | T0.1 Package & entry | Package.swift, main.swift | — | build OK; `swift run acode` prints banner |
| 1 | T0.2 Core types  ||  T0.4 Path jail | Message.swift  ||  ProjectJail.swift | T0.1 | jsonvalue roundtrip; jail allow/traversal/absolute |
| 2 | T0.3 Tool protocol/registry/schema  ||  T0.6 Provider proto + FakeProvider | Tools.swift  ||  Provider.swift, FakeProvider.swift | T0.2 | registry allowlist/execute; fake provider stream |
| 3 | T0.5 read_file + run_shell  ||  T0.7 Anthropic (non-streaming) | FileTools.swift, RunShell.swift  ||  AnthropicProvider.swift | T0.3,T0.4 / T0.6 | read/echo/no-deadlock/cancellable shell; anthropic request body |
| 4 | T0.8 Agent loop (+ minimal Conversation/Prompt/Renderer/AgentProfile) | Agent.swift, Conversation.swift, Prompt.swift, Renderer.swift, AgentProfile.swift | T0.3,T0.5,T0.6 | loop tool-then-answer; loop step-limit |
| 5 | T0.9 Wire one-shot mode | main.swift, Config.swift | T0.7,T0.8 | M0 smoke: `acode -p "read README.md..."` answers via the loop |

Guidance for T0.8: declare the full §C Renderer struct shape (stub bodies) now, since §C forbids later
shape changes; T1.3 / T2.4 / T3.5 fill in bodies only.

### Milestone M1 — streaming + REPL

| Wave | Task(s) | Files | Depends | Acceptance gate |
|---|---|---|---|---|
| 6 | T1.1 SSE parser/assembler  ||  T1.3 Full Renderer | Provider.swift, SSEParser.swift  ||  Renderer.swift | T0.7 / T0.8 | assembler text+toolcall; renderer color disabled |
| 7 | T1.2 Anthropic streaming | AnthropicProvider.swift | T1.1 | anthropic stream maps events |
| 8 | T1.4 REPL + router + slash + bang + SIGINT | main.swift | T1.2,T1.3 | route test; Ctrl-C cancels mid-turn |
| 9 | T1.5 Test scaffold consolidation | Tests/acodeTests/* | T1.1–T1.4 | M1 gate: `swift test` green; REPL streams/routes/cancels |

### Milestone M2 — full tools + safety (FileTools.swift contention)

T2.1 / T2.2 / T2.3 are dependency-independent but all edit FileTools.swift, so they run serially
(single coder), not in parallel.

| Wave | Task(s) | Files | Depends | Acceptance gate |
|---|---|---|---|---|
| 10 | T2.1 -> T2.2 -> T2.3 (serial) list_files; grep; edit_file | FileTools.swift | T0.5 | ignore/grep-cap/edit-create/unique/non-unique/atomic |
| 11 | T2.4 approval gate | Renderer.swift, Tools.swift | T2.3 | execute denied-blocks / approved-runs |
| 12 | T2.5 register full tool set | Config.swift / main.swift | T2.1–T2.4 | M2 smoke: agent fixes a failing test end-to-end |

### Milestone M3 — reliability + second provider (biggest parallel wave)

All six tasks touch disjoint files and their dependencies are satisfied by the end of M1.

| Wave | Task(s) | Files | Depends | Acceptance gate |
|---|---|---|---|---|
| 13 | T3.1  ||  T3.2  ||  T3.3  ||  T3.4  ||  T3.5  ||  T3.6 (compaction; retry; AGENTS.md; cache_control; usage/log; OpenAI) | Conversation  ||  Agent  ||  Prompt  ||  AnthropicProvider  ||  Renderer+main  ||  OpenAIProvider | T0.8 / T1.2 / T1.3 / T1.1 | pair-integrity, retry, agents-md, cache_control, key-redaction, openai-body |
| 14 | T3.7 config + model registry | Config.swift | T0.9,T3.6 | config load+select; M3 smoke: Claude/GPT/local parity by config only |

Wave 13 hard rule if split across coder instances: T3.5 owns both Renderer.swift and main.swift; no
other Wave-13 task may touch them.

### Milestone M4 — polish + skills

| Wave | Task(s) | Files | Depends | Acceptance gate |
|---|---|---|---|---|
| 15 | T4.1 skills core/tools  ||  T4.3 /model + injectable shell timeout | Skills.swift  ||  main.swift, RunShell.swift | T0.3 / T3.7 | skills index/activate; run_shell timeout |
| 16 | T4.2 skills index in prompt | Prompt.swift | T4.1 | prompt lists skills; M4 smoke: list -> activate -> use a skill |

### Milestone M5 — multi-agent (optional)

| Wave | Task(s) | Files | Depends | Acceptance gate |
|---|---|---|---|---|
| 17 | T5.1 profiles (planner/coder/reviewer) | AgentProfile.swift | T0.8 | planner allowlist excludes mutating |
| 18 | T5.2 orchestrator | Orchestrator.swift | T5.1,T3.1 | orchestrator converges; verdict ignores mid-text |
| 19 | T5.3 wire /plan + --agents | main.swift | T5.2 | M5 smoke: plan -> code -> review converges >= 1 review round |

Optional early start: T5.1 depends only on T0.8 and uniquely owns AgentProfile.swift, so it can be
pulled forward to run in parallel with M3/M4.

## Parallelization summary

- True parallel waves: Wave 1 (T0.2, T0.4), Wave 2 (T0.3, T0.6), Wave 3 (T0.5, T0.7),
  Wave 6 (T1.1, T1.3), Wave 13 (six-way, M3), Wave 15 (T4.1, T4.3).
- Forced-serial (same file): M2 T2.1 -> T2.2 -> T2.3 all edit FileTools.swift.
- Highest-churn file: main.swift (T0.1, T0.9, T1.4, T3.5, T4.3, T5.3). Establish a clean
  command-dispatch/router structure in T1.4 so later additions (/model, /plan, --agents) are
  localized edits.
- Critical path: T0.1 -> T0.2 -> T0.3 -> T0.5 -> T0.8 -> T0.9 -> T1.1 -> T1.2 -> T1.4 -> T1.5 ->
  (M2 serial) -> M3 wave -> T3.7 -> M4 -> (M5). The M3 parallel wave is the main schedule compressor.

## Risks and mitigations

- Toolchain availability (blocks T0.1). Verify `swift --version` >= 6.3 first; do not downgrade the
  manifest to compensate.
- run_shell deadlock and cancellation (B5). Combined stdout+stderr drained concurrently, off the main
  actor, 60s terminate(). Gated by the no-deadlock (seq 1 60000) and cancellable tests in T0.5.
- Tool-pair integrity under compaction (B2). Easiest invariant to break; gated by the randomized
  pair-integrity test in T3.1; reviewer rejects any split pair.
- Retry semantics (B7). Retry only before first byte; never retry CancellationError. Gated in T3.2.
- Interface drift. §C shapes are load-bearing across tasks; declare full signatures early (especially
  Renderer), fill bodies later; reviewer checks signature stability each milestone.
- Scope creep into §G (MCP, browser, provider zoo, sub-agent bus, on-device Foundation Models).
  Reviewer rejects any excluded artifact in a diff.
- Honest jail framing (B9). Code and docs must state the jail confines file tools only; run_shell is
  gated by approval, not the jail.
- Line-budget drift. ~1,250 lines / ~14 files for single-agent (M0–M4). Footprint check each milestone.
- Coder fit. swift-coder is described as SwiftUI-first; acode is a CLI/SPM tool. Instruct it to use
  Foundation / Swift Concurrency / SPM only (no SwiftUI/AppKit) and the Txx commit convention.

## Alternative approaches

1. Strict milestone-gated (recommended). Execute waves in order; run §H plus smoke at each milestone.
   Lowest risk, easy per-task rollback; leaves some cross-milestone parallelism unused.
2. Aggressive cross-milestone overlap. Start the M3 parallel wave right after M1, overlapping M2.
   Shortest wall-clock but introduces file conflicts on Renderer.swift / main.swift / Config.swift and
   weaker smoke-gate guarantees; only worthwhile with multiple coordinated coder instances.
3. Single-agent MVP first, defer M5. Ship M0–M4 (the single-agent tool) and treat multi-agent as a
   follow-on. Fastest path to a usable tool; delays the planner -> coder -> reviewer feature.

## Agent coordination (for building acode)

- Planning: planning-agent (this document).
- Coding (all Txx tasks): swift-coder. Foundation / Concurrency / SPM, no SwiftUI; commits Txx: title.
- Review (after each milestone, runs §H): code-critic. swift build / swift test, invariant checks,
  §G exclusion check, line-budget sanity.
- Not used: security-auditor (Elixir-only, not applicable). The acode app's internal
  planner/coder/reviewer (M5) is a product feature, distinct from this external coordination.

## Status

Roadmap only — no code has been written. Confirm D0–D6 (especially the toolchain check and the
standalone-repo decision) before execution. On approval, execution begins with the toolchain
verification and T0.1, proceeding wave by wave with a code-critic review at each milestone boundary.
