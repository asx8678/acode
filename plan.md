# acode — Agent-Ready Build Plan

A self-contained build specification for a minimal Swift CLI coding agent, written to be handed to
an autonomous **planning agent** and **coding agent** (and a **reviewer agent**). It needs no other
document. Implement the interfaces in §C *exactly*, execute the backlog in §E task by task, and gate
every task on its acceptance check.

> Target: native terminal coding agent, **macOS 26 (Tahoe)**, Apple Silicon, **Swift 6.3**.
> Name `acode` is a placeholder — neutral, no theme, no mascot, no emoji. Binary `acode`,
> config dir `~/.config/acode/`, project rules `AGENTS.md`.

---

## §0. How to use this document (instructions to the agents)

**Planning agent.** Read §A (mission), §B (invariants), §C (interfaces), and §D (conventions). Then
take the backlog in §E and produce a concrete execution plan: confirm the dependency order, group
tasks that can run in parallel (none may touch the same file concurrently), and surface any task
whose acceptance check is ambiguous *before* coding starts. Do not invent scope. Output a checklist
of tasks in execution order with their dependencies and acceptance checks.

**Coding agent.** Implement **one task at a time** from §E, in dependency order. For each task:
1. Implement only what the task says, conforming to the §C interface signatures verbatim.
2. Add the tests the task names (§F).
3. Run `swift build` then `swift test`. Both must pass.
4. If a real-API smoke step is listed, note it as a manual check (don't block on a missing key).
5. Commit with a message `Txx: <title>`. Then proceed to the next task.

Hard rules for the coding agent: **do not add dependencies** beyond §C; **do not** implement
anything in §G (excluded); **never** weaken an invariant in §B to make a test pass; if a task
conflicts with an invariant or is underspecified, **stop and surface it** rather than guessing.

**Reviewer agent.** After each milestone, run §H. Reject if any invariant is violated, any acceptance
check fails, a dependency was added, or an excluded feature appears.

---

## §A. Mission and non-goals

**Mission.** Build a small terminal coding agent whose intelligence comes from one tight loop, not
from clever code: read a prompt, call a model with tool schemas, run the model's requested tools
against the real filesystem and shell, feed the results back, and repeat until the task is solved
and verified. Provide a handful of tools, two model providers (plus local OpenAI-compatible
endpoints), on-demand "skills", and an optional planner→coder→reviewer multi-agent mode. Keep the
whole single-agent tool around 1,250 lines across ~14 files with one external dependency.

**Non-goals (v1).** No MCP, no browser automation, no durable execution, no provider zoo, no plugin
or skill *marketplace*, no pub/sub message bus, no **session database** (the lightweight per-session
JSON alternative landed in v2 — see §G), no attachments, no background processes, no auto-commit,
no TUI. See §G for the full list and the reasoning.

---

## §B. Invariants (must hold across every task)

These are non-negotiable. A reviewer rejects any change that breaks one.

1. **The loop shape is fixed.** One turn = (fit history → call model → if tool calls: run them and
   append results, loop; else: return the answer). Tools run against the real FS/shell. Max 50
   steps per turn.
2. **Tool-call/tool-result pairing.** History compaction must never separate an assistant message
   that requested tools from the `toolResults` that answer it. Orphans are dropped, not split.
3. **Errors are data at the tool boundary.** A `Tool.run` never throws; failures return
   `ToolOutput(isError: true, output: <message with guidance>)` so the model can self-correct.
4. **One dependency.** `swift-argument-parser` only. Everything else is Foundation
   (`URLSession`, `Process`, `FileManager`, `JSONEncoder`/`Decoder`).
5. **Isolation model.** The whole target is main-actor-by-default. `Conversation`, `ToolRegistry`,
   `Agent`, `Renderer` are plain types (no actors). The *only* code allowed to block is the shell
   tool, which runs its blocking wait off the main actor (§C `RunShell`).
6. **Streaming is pull-based.** Providers return `AsyncThrowingStream<StreamEvent, Error>`. No
   `@Sendable` token callbacks.
7. **Retry only before the first byte.** Connection/HTTP-status failures are retried with
   backoff+jitter; once the event stream yields, errors are surfaced, never re-streamed. Never retry
   `CancellationError`.
8. **The five-layer prompt order is preserved** (tool schemas → rules → identity → skills index →
   project rules), assembled fresh each call, stable head first for caching.
9. **The path jail confines file tools; the shell tool is gated only by approval.** State this
   honestly; never claim the jail confines `run_shell`.
10. **Brain fidelity.** The design mirrors the documented "Code Puppy" core: REPL input routing
    (`/`→slash, `!`→shell, else→task, only tasks call the model), the act→observe→re-decide loop,
    tool grounding, feedback, prompt discipline, compaction memory, and progressive-disclosure
    skills. Do not remove any of these pillars.

---

## §C. Canonical interfaces — implement these signatures verbatim

The coding agent implements bodies; it must not change these public shapes (other tasks depend on
them). File assignments are in §E.

### Core types — `Message.swift`

```swift
import Foundation

enum Role: String, Codable, Sendable { case system, user, assistant, tool }

struct ToolCall: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let arguments: JSONValue
}

struct ToolResult: Codable, Sendable {
    let callID: String
    let output: String
    let isError: Bool
}

enum Message: Sendable {
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResults([ToolResult])
}

enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
    // custom init(from:)/encode(to:) using a singleValueContainer (decode in order:
    //   nil, Bool, Double, String, [JSONValue], [String: JSONValue]).
    subscript(_ key: String) -> JSONValue? { get }   // returns object's value or nil
    var stringValue: String? { get }
    var intValue: Int? { get }
}
```

### Provider layer — `Provider.swift`, `AnthropicProvider.swift`, `OpenAIProvider.swift`

```swift
struct Usage: Sendable { var input = 0; var output = 0 }

enum StreamEvent: Sendable {
    case textDelta(String)
    case toolCall(ToolCall)              // emitted once fully assembled and parsed
    case done(stop: String, usage: Usage)
}

struct ToolSchema: Codable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue            // a full JSON-Schema object (build with Schema.object)
}

protocol LLMProvider: Sendable {
    var contextWindow: Int { get }
    func stream(system: String, messages: [Message],
                tools: [ToolSchema], model: String?) async throws
        -> AsyncThrowingStream<StreamEvent, Error>
}

// Accumulates partial tool-call JSON per content block; emits .toolCall on block close.
final class ResponseAssembler { func ingest(_ ssePayload: String) -> [StreamEvent] }
```

### Tools — `Tools.swift`, `ProjectJail.swift`, `FileTools.swift`, `RunShell.swift`, `Skills.swift`

```swift
struct ToolOutput: Sendable { var output: String; var isError = false }

protocol Tool: Sendable {
    static var schema: ToolSchema { get }
    var requiresApproval: Bool { get }
    func run(_ args: JSONValue) async -> ToolOutput        // MUST NOT throw (invariant B3)
}

struct ToolRegistry {
    mutating func register(_ t: any Tool)
    func schemas(allowed: Set<String>?) -> [ToolSchema]    // nil = all; powers role allowlists
    func execute(_ call: ToolCall, approve: (ToolCall) -> Bool) async -> ToolResult
    // execute: unknown tool → isError; requiresApproval && !approve → "User denied this action."
    //          else run and stamp callID onto the result.
}

enum Schema {  // builds the full {"type":"object","properties":{...},"required":[...]} envelope
    static func object(_ props: [String:(type: String, description: String)],
                       required: [String]) -> JSONValue
}

enum ProjectJail {
    static let root: String                 // FileManager.default.currentDirectoryPath
    static func resolve(_ path: String) throws -> URL    // standardized + symlink-resolved; must be under root
}

// Tools to implement (each conforms to Tool):
// read_file, list_files, grep, edit_file (create+edit)  → FileTools.swift
// run_shell                                             → RunShell.swift
// list_skills, activate_skill                           → Skills.swift

struct Skill { let name: String; let summary: String; let body: String }
enum Skills { static func index() -> [Skill] }            // *.md from ~/.config/acode/skills + ./.acode/skills
```

`RunShell.run` requirements (invariant B5): `/bin/zsh -c <cmd>`; `currentDirectoryURL = ProjectJail.root`;
combined stdout+stderr through one `Pipe` **drained concurrently** (a `readabilityHandler` guarded by a
lock, or a reader thread) so large output cannot deadlock; a **60 s timeout** that calls `terminate()`;
wrapped in `withTaskCancellationHandler { p.terminate() }` and run off the main actor (e.g. a global
dispatch queue inside `withCheckedContinuation`); output capped to the last 256 lines.

### Agent loop — `Agent.swift`

```swift
enum AgentError: Error { case stepLimit }

@MainActor
final class Agent {
    init(profile: AgentProfile, provider: any LLMProvider, tools: ToolRegistry, renderer: Renderer)
    func reset()
    @discardableResult func run(_ input: String) async throws -> String
    // loop (≤50 steps): checkCancellation → compacted history → assemble prompt →
    //   connectWithRetry { provider.stream(...) } → consume events (stream text via renderer,
    //   collect toolCalls + usage) → append assistant msg → if no calls: return text;
    //   else run each via tools.execute(approve: renderer.approve), append toolResults, loop.
}

func connectWithRetry<T>(max: Int, _ make: () async throws -> T) async throws -> T
// retries the closure (which establishes the stream) with exponential backoff + jitter;
// rethrows CancellationError immediately; throws last error after `max` attempts.
```

### History — `Conversation.swift`

```swift
struct Conversation {
    private(set) var messages: [Message]
    mutating func append(_ m: Message)
    func compacted(for window: Int) -> [Message]
    // reserve = window*7/10; first map each message through truncated(to: reserve) so no single
    // message blows the budget; if it fits, return; else keep newest-first whole messages until
    // reserve (always keep ≥1), then ensureToolPairsIntact (drop orphaned tool_use/tool_result).
}
extension Message {
    var tokenEstimate: Int { get }                  // max(1, charCount / 4)
    func truncated(to budget: Int) -> Message       // clip long output strings
}
```

### Prompt — `Prompt.swift`

```swift
enum Prompt {
    static func assemble(profile: AgentProfile, registry: ToolRegistry) -> String
    // joins, in order, non-empty fragments separated by "\n\n":
    //   ① toolHelp(registry, allowed: profile.tools)   ② profile.rules   ③ profile.identity
    //   ④ skillIndex()  (one line per skill: "name: summary")            ⑤ projectRules()
}
// projectRules(): combine ./.acode/AGENTS.md + ./AGENTS.md + ~/.config/acode/AGENTS.md (verbatim).
```

Generalist rules text (use verbatim as `GENERALIST_RULES`):

```
You are a terminal coding agent operating inside the user's project.
Operating rules:
- ACT, don't narrate. Use a tool instead of describing what you would do.
- READ a file before you edit it. Do not guess file contents.
- APPLY changes — never just propose them. Never claim a change you didn't make with a tool.
- VERIFY by running it (build, tests, the program).
- Prefer small, targeted edits over rewriting whole files.
- Continue autonomously until solved or blocked; ask only for a destructive action,
  a missing requirement, or a credential.
```

### Rendering — `Renderer.swift`

```swift
struct Renderer: Sendable {                          // nonisolated; writes to stdout; no actor
    let color: Bool                                  // isatty(STDOUT) && NO_COLOR unset
    var verbose: Bool
    let policy: ApprovalPolicy                        // shared session approval state — the single approval gate
    func banner()
    func streamText(_ s: String)                     // no trailing newline
    func endAssistant()
    func toolStart(_ c: ToolCall)                    // dim "→ name"
    func toolEnd(_ c: ToolCall, _ r: ToolResult)     // green "✓ name" / red "✗ name"
    func usage(_ u: Usage)                           // only when verbose: "· in+out tok"
    func phase(_ p: String)                          // cyan "● <phase>"  (multi-agent)
    func approve(_ c: ToolCall) -> Bool              // policy.shouldAutoApprove ? true : readLine [y/N/a]
    func spinner(_ label: String) -> Spinner
}
final class Spinner { @discardableResult func start() -> Spinner; func stop() }
```

> Approval state lives in `ApprovalPolicy` (a lock-guarded reference type) shared
> across copied `Renderer` values so "always allow" decisions persist for the
> session. It is the single approval gate: `--yes` and the config keys
> `autoApprove` (blanket), `autoApproveTools` (per-tool), and `autoApproveShell`
> (a metacharacter-filtered `run_shell` command allowlist) seed it.

### CLI — `main.swift`, `Config.swift`

```swift
@main struct Acode: AsyncParsableCommand {
    @Option(name: .shortAndLong) var model: String?
    @Option(parsing: .upToNextOption) var agents: [String]     // e.g. plan code review
    @Flag(name: .long) var yes: Bool
    @Option(name: .shortAndLong) var prompt: String?           // one-shot, non-interactive
    @Flag(name: .long) var verbose: Bool
    mutating func run() async throws
}

enum Input { case slash(String), shell(String), task(String) }
func route(_ s: String) -> Input            // "/"→slash, "!"→shell, else→task
func runCancellable(_ work: @escaping () async throws -> Void, renderer: Renderer) async
// installs a SIGINT source that cancels the wrapping Task; used for BOTH agent.run and orchestrator.run

struct Config: Codable { static func load() -> Config }        // env keys + ~/.config/acode/config.json + model registry
func makeProvider(model: String?, cfg: Config) -> any LLMProvider
func registerStandardTools(_ tools: inout ToolRegistry)        // read_file,list_files,grep,edit_file,run_shell,list_skills,activate_skill
```

### Multi-agent (M5) — `AgentProfile.swift`, `Orchestrator.swift`

```swift
struct AgentProfile: Sendable {
    let name: String; let identity: String; let rules: String
    let tools: Set<String>?            // allowlist; nil = all
    let model: String?
    static let generalist: AgentProfile   // identity + GENERALIST_RULES, tools = nil
    static let planner: AgentProfile      // read-only tools: ["read_file","list_files","grep","list_skills","activate_skill"]
    static let coder: AgentProfile        // tools = nil (all)
    static let reviewer: AgentProfile     // ["read_file","list_files","grep","run_shell"]
}

enum Verdict {
    case approved, changes(String)
    init(_ text: String)               // inspect ONLY the last non-empty line; "VERDICT: APPROVED" → approved
}

@MainActor struct Orchestrator {
    let provider: any LLMProvider; let tools: ToolRegistry; let renderer: Renderer
    var maxRounds: Int                 // total code→review cycles (default 3)
    func run(_ task: String) async throws -> String
    // phase planning → planner.run (emits an ordered plan + the EXACT files to change);
    // then for round in 1...maxRounds: checkCancellation; coder.run(plan or feedback);
    //   reviewer.run; switch Verdict { approved → return; changes → feedback = notes }.
}
```

Role rules text to use:
- **planner:** "You are the PLANNER. Use ONLY read-only tools. Output an ordered plan AND the exact
  list of files to change (one per line), the verify commands, and acceptance criteria. Modify
  nothing. End with the plan only."
- **coder:** "You are the CODER. Follow the PLAN; start by reading the files it named. Read before you
  edit. After changes, run the build/tests and fix failures you introduced. If the plan is wrong or
  blocked, say so and stop."
- **reviewer:** "You are the REVIEWER. Inspect `git diff` and run the tests/build yourself (read +
  run_shell only). Your LAST line must be exactly `VERDICT: APPROVED` or `VERDICT: CHANGES` followed
  by a short numbered list of required changes."

---

## §D. Conventions and environment

- **Toolchain:** Swift 6.3; `swift-tools-version: 6.3`. Package settings:
  `.defaultIsolation(MainActor.self)` and `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`
  on both the executable and test targets.
- **Layout:** one `executableTarget` named `acode` under `Sources/acode/`, one `testTarget`
  `acodeTests` under `Tests/acodeTests/`. One primary type per file; file names per §E.
- **Style:** value types by default; reference type only for `Agent`/`Spinner`/`ResponseAssembler`.
  No force-unwraps (`!`) in non-test code except documented invariants. User-facing strings are
  sentence case; no emoji; no theme. Keep functions short; prefer early returns.
- **Errors:** typed `throws(AgentError)` where it clarifies; tools never throw (return `ToolOutput`).
- **Commands the agents run:**
  - build: `swift build`
  - test: `swift test`
  - run (interactive): `swift run acode`
  - run (one-shot): `swift run acode -p "<task>"`
  - multi-agent: `swift run acode --agents plan code review -p "<task>"`
- **Secrets:** read `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (or a custom endpoint) from the
  environment. Never write a key to disk; redact keys in any `--verbose` log.
- **Commits:** one commit per green task, message `Txx: <title>`.

---

## §E. Task backlog (dependency-ordered)

Each task lists **Files**, **Depends**, **Do**, **Done** (acceptance). Tests named here are created in
the same task (see §F). "Smoke (manual)" steps need a real API key and are not CI-blocking.

### Milestone M0 — skeleton that loops (non-streaming)

**T0.1 — Package & entry skeleton.**
Files: `Package.swift`, `Sources/acode/main.swift`.
Depends: —.
Do: create the package per §D (one dep, isolation settings); a minimal `@main` that parses flags and
prints a banner/version, no loop yet.
Done: `swift build` succeeds; `swift run acode` prints the banner and exits cleanly.

**T0.2 — Core types.**
Files: `Sources/acode/Message.swift`.
Depends: T0.1.
Do: implement `Role`, `ToolCall`, `ToolResult`, `Message`, `JSONValue` (+ `subscript`, `stringValue`,
`intValue`) per §C.
Done: `test_jsonvalue_roundtrip` encodes/decodes nested object/array/scalars and asserts equality.

**T0.3 — Tool protocol, registry, schema helper.**
Files: `Sources/acode/Tools.swift`.
Depends: T0.2.
Do: implement `ToolOutput`, `Tool`, `ToolRegistry`, `Schema.object` per §C.
Done: `test_registry_allowlist` (filters schemas by allowed set), `test_registry_execute`
(unknown→isError; denied when `approve`→false; stamps `callID` on success with a stub tool).

**T0.4 — Path jail.**
Files: `Sources/acode/ProjectJail.swift`.
Depends: T0.1.
Do: implement `ProjectJail.resolve` per §C.
Done: `test_jail_allows_inroot`, `test_jail_rejects_traversal` (`../../etc/passwd`),
`test_jail_rejects_absolute_outside`.

**T0.5 — read_file + run_shell.**
Files: `Sources/acode/FileTools.swift` (read_file only), `Sources/acode/RunShell.swift`.
Depends: T0.3, T0.4.
Do: `read_file` (line range optional, large-file cap, jailed); `run_shell` per §C requirements
(concurrent drain, 60 s timeout, cancellation, cwd, 256-line cap).
Done: `test_read_file_tmp`; `test_run_shell_echo` (`echo hi`→"hi", isError false);
`test_run_shell_no_deadlock` (command emits >200 KB, e.g. `seq 1 60000`, returns without hanging);
`test_run_shell_cancellable` (start a `sleep 5`, cancel the task, assert it returns promptly).

**T0.6 — Provider protocol + fake provider.**
Files: `Sources/acode/Provider.swift`, `Tests/acodeTests/FakeProvider.swift`.
Depends: T0.2.
Do: `Usage`, `StreamEvent`, `ToolSchema`, `LLMProvider` per §C; a `FakeProvider` (test target) that
yields a scripted sequence of `StreamEvent`s.
Done: `test_fake_provider_stream` consumes a scripted stream and observes the events in order.

**T0.7 — Anthropic provider (non-streaming over the stream API).**
Files: `Sources/acode/AnthropicProvider.swift`.
Depends: T0.6.
Do: implement `stream(...)` by issuing a **non-streaming** Messages request, then yielding the
assembled result as `.textDelta`(whole text) + `.toolCall`(each) + `.done`. Build the request body
(system, messages, tools, model, `max_tokens`); set `x-api-key`, `anthropic-version: 2023-06-01`;
throw on non-2xx.
Done: `test_anthropic_request_body` (encode a sample call; assert top-level keys and the tool schema
envelope) with no network. Smoke (manual): `swift run acode -p "say hello"` returns text.

**T0.8 — The agent loop.**
Files: `Sources/acode/Agent.swift`, `Sources/acode/Conversation.swift` (minimal: append + pass-through
`compacted`), `Sources/acode/Prompt.swift` (assemble with rules+identity+toolHelp; skills/AGENTS later),
`Sources/acode/Renderer.swift` (minimal: streamText/toolStart/toolEnd/endAssistant/approve→autoApprove),
`Sources/acode/AgentProfile.swift` (`.generalist` only).
Depends: T0.3, T0.5, T0.6.
Do: implement `Agent.run` per §C and `connectWithRetry`.
Done: `test_loop_tool_then_answer` (FakeProvider scripts: read_file call → final answer; assert the
tool ran and the returned string matches); `test_loop_step_limit` (FakeProvider always returns a tool
call; assert `AgentError.stepLimit`).

**T0.9 — Wire one-shot mode.**
Files: `Sources/acode/main.swift`, `Sources/acode/Config.swift`.
Depends: T0.7, T0.8.
Do: `Config.load` (env keys + optional config.json); `makeProvider`; `registerStandardTools`
(read_file + run_shell for now); `-p` one-shot path that builds a generalist `Agent` and runs it.
Done (M0): Smoke (manual) `swift run acode -p "read README.md and tell me what it does"` reads the
file through the loop and answers; all M0 tests pass (`swift test`).

### Milestone M1 — streaming + REPL

**T1.1 — SSE parser + response assembler.**
Files: `Sources/acode/Provider.swift` (extend), a new `Sources/acode/SSEParser.swift` if needed.
Depends: T0.7.
Do: implement `ResponseAssembler.ingest` to accumulate `input_json_delta` per content-block index and
emit `.toolCall` on `content_block_stop`; emit `.textDelta` on `text_delta`; `.done` on `message_stop`
with usage.
Done: `test_assembler_text_and_toolcall` (feed canned Anthropic `data:` lines; assert text deltas, one
assembled tool call with valid parsed arguments, and a final `.done`).

**T1.2 — Anthropic streaming.**
Files: `Sources/acode/AnthropicProvider.swift`.
Depends: T1.1.
Do: switch `stream` to `URLSession.bytes`; iterate `bytes.lines`; feed `data:` payloads to the
assembler; retry only around establishing the stream (invariant B7).
Done: `test_anthropic_stream_maps_events` (inject a line sequence into the parse path; assert mapping).
Smoke (manual): tokens appear incrementally.

**T1.3 — Renderer.**
Files: `Sources/acode/Renderer.swift`.
Depends: T0.8.
Do: full `Renderer` per §C with ANSI gated on `isatty` + `NO_COLOR`; `Spinner` (braille frames on a
Task, `stop()` cancels).
Done: `test_renderer_color_disabled` (no-tty / NO_COLOR ⇒ `color == false`). Smoke (manual): spinner
shows during "thinking" and stops on first token.

**T1.4 — REPL + input router + slash + shell + SIGINT.**
Files: `Sources/acode/main.swift`.
Depends: T1.2, T1.3.
Do: interactive read loop; `route(_:)`; `/help` `/clear` `/quit` (local, no model); `!cmd` passthrough;
`runCancellable` SIGINT harness wrapping each task turn.
Done: `test_route` (`/`,`!`,plain). Smoke (manual): Ctrl-C mid-turn cancels and returns to prompt;
`/help` prints with no model call.

**T1.5 — Test suite scaffold.**
Files: `Tests/acodeTests/*`.
Depends: T1.1–T1.4.
Do: ensure FakeProvider is shared; consolidate the loop/router/jail/SSE tests.
Done (M1): `swift test` green; interactive REPL streams, routes, cancels.

### Milestone M2 — full tools + safety

**T2.1 — list_files.** Files: `FileTools.swift`. Depends: T0.5.
Do: list one directory with ignore rules (`.git`,`.build`,`DerivedData`,`node_modules`,`.venv`,`dist`).
Done: `test_list_files_ignores` (temp tree; excludes ignored dirs).

**T2.2 — grep.** Files: `FileTools.swift`. Depends: T0.5.
Do: use `rg --json` if available else `NSRegularExpression`; cap ~50 hits.
Done: `test_grep_finds` and `test_grep_caps`.

**T2.3 — edit_file (create + edit).** Files: `FileTools.swift`. Depends: T0.5.
Do: exact unique-string replace; create when file missing; whitespace-normalized fallback before
failing; atomic write (temp→rename); jailed; `requiresApproval = true`.
Done: `test_edit_create`, `test_edit_unique_replace`, `test_edit_refuses_nonunique` (returns an error
string with guidance, file unchanged), `test_edit_atomic`.

**T2.4 — approval gate.** Files: `Renderer.swift`, `Tools.swift`. Depends: T2.3.
Do: `Renderer.approve` (y/n; `--yes` bypass); registry calls it for `requiresApproval` tools.
Done: `test_execute_denied_blocks` and `test_execute_approved_runs`.

**T2.5 — register full tool set.** Files: `Config.swift`/`main.swift`. Depends: T2.1–T2.4.
Do: `registerStandardTools` adds read/list/grep/edit/run_shell; jail wired into every file tool.
Done (M2): Smoke (manual) — agent fixes a failing unit test end-to-end (read→edit→`swift test`→pass→
answer) with approvals; `swift test` green.

### Milestone M3 — reliability + second provider

**T3.1 — compaction.** Files: `Conversation.swift`. Depends: T0.8.
Do: implement `compacted`, `tokenEstimate`, `truncated`, `ensureToolPairsIntact` per §C/B2.
Done: `test_compaction_keeps_pairs` (random transcripts: no split pair), `test_compaction_fits_budget`,
`test_compaction_single_oversized` (one huge message ⇒ truncated, still returns ≥1 message).

**T3.2 — retry.** Files: `Agent.swift`. Depends: T0.8.
Do: `connectWithRetry` with backoff+jitter; retry 429/500/502/503/529; never retry `CancellationError`.
Done: `test_retry_succeeds_after_failures`, `test_retry_passes_cancellation`.

**T3.3 — AGENTS.md.** Files: `Prompt.swift`. Depends: T0.8.
Do: `projectRules()` combines global + per-repo; inject into assembled prompt.
Done: `test_prompt_includes_agents_md` (temp AGENTS.md content appears in the assembled prompt).

**T3.4 — prompt caching.** Files: `AnthropicProvider.swift`. Depends: T1.2.
Do: add `cache_control: {type: ephemeral}` to the last system block and the tools block.
Done: `test_request_has_cache_control`.

**T3.5 — usage line + verbose log.** Files: `Renderer.swift`, `main.swift`. Depends: T1.3.
Do: print usage when `--verbose`; write redacted request/response log when `--verbose`.
Done: `test_redacts_api_key` (a key in a log payload is masked).

**T3.6 — OpenAI provider.** Files: `Sources/acode/OpenAIProvider.swift`. Depends: T1.1.
Do: implement `stream` for the Responses API with a Chat Completions fallback; support a local
endpoint via `baseURL` + no auth; accumulate `tool_calls[].function.arguments` partial JSON.
Done: `test_openai_request_body` (Responses + Chat shapes). Smoke (manual): runs against a local
OpenAI-compatible server if one is available.

**T3.7 — config + model registry.** Files: `Config.swift`. Depends: T0.9, T3.6.
Do: `Config.load` reads config.json (default model, per-role overrides, model registry id→provider+
contextWindow); flags overlay; `makeProvider` selects by model id.
Done: `test_config_load_and_select` (env + json ⇒ correct provider chosen).
Done (M3): Smoke (manual) — identical behavior across Claude, GPT, and a local model by config only;
`swift test` green.

### Milestone M4 — polish + skills

**T4.1 — skills core + tools.** Files: `Sources/acode/Skills.swift`. Depends: T0.3.
Do: `Skills.index()` (read `*.md` from `~/.config/acode/skills` and `./.acode/skills`; summary = first
line); `ListSkills` and `ActivateSkill` tools (activate returns the skill body as `ToolOutput`,
`summary = "activated <name>"`; unknown → isError).
Done: `test_skills_index_reads_md`, `test_activate_returns_body`, `test_activate_unknown_errors`.

**T4.2 — skills index in prompt.** Files: `Prompt.swift`. Depends: T4.1.
Do: add `skillIndex()` as the 4th prompt layer (one line per skill); register the two skill tools in
`registerStandardTools`.
Done: `test_prompt_lists_skills` (assembled prompt contains one line per temp skill).

**T4.3 — /model + timeouts.** Files: `main.swift`, `RunShell.swift`. Depends: T3.7.
Do: `/model <name>` switches provider mid-session; confirm per-tool timeout (make the shell timeout
injectable for tests).
Done: `test_run_shell_timeout` (short injected timeout on a `sleep` ⇒ terminated, isError true). Smoke
(manual): `/model` switches backend.
Done (M4): Smoke (manual) — a task triggers `list_skills`→`activate_skill`→uses the skill; single-agent
tool complete; `swift test` green.

### Milestone M5 — multi-agent (optional)

**T5.1 — profiles.** Files: `Sources/acode/AgentProfile.swift`. Depends: T0.8.
Do: implement `.generalist/.planner/.coder/.reviewer` per §C (allowlists + rule texts).
Done: `test_planner_allowlist_excludes_mutating` (planner schemas omit edit_file/run_shell).

**T5.2 — orchestrator.** Files: `Sources/acode/Orchestrator.swift`. Depends: T5.1, T3.1.
Do: implement `Orchestrator.run` and `Verdict.init` per §C (planner → bounded coder/review loop;
reuse `Agent`; parse only the last non-empty line; cancellation per round).
Done: `test_orchestrator_converges` (FakeProvider scripts plan → `VERDICT: CHANGES` → second code →
`VERDICT: APPROVED`; assert exactly two coding rounds and convergence);
`test_verdict_ignores_midtext` (a body containing "…VERDICT: APPROVED…" not on the last line ⇒ changes).

**T5.3 — wire /plan and --agents.** Files: `main.swift`. Depends: T5.2.
Do: route `/plan <task>` and `--agents plan code review` through `runCancellable` → `Orchestrator.run`.
Done (M5): Smoke (manual) `swift run acode --agents plan code review -p "<task>"` plans, codes,
reviews, and converges through ≥1 review round; `swift test` green.

---

## §F. Testing requirements

- Framework: Swift Testing (`import Testing`, `@Test`, `#expect`), parallel by default.
- The `FakeProvider` (yields scripted `StreamEvent`s) is the backbone of all loop/orchestrator tests —
  no test hits a live model.
- Every task that adds behavior adds at least the named test(s). A milestone is not "done" until
  `swift test` is green and the milestone's manual smoke step has been run (or explicitly deferred for
  lack of a key).
- Provider request-body tests assert JSON *shape* (keys, schema envelope, cache_control) by encoding a
  sample call — never by calling the network.

---

## §G. Excluded — do not implement (anti-bloat)

MCP servers; browser/Playwright automation; durable execution / checkpointing; a multi-provider
factory or round-robin routing; a plugin/skill **marketplace** (the lightweight skills mechanism in
T4.1 *is* in scope); a pub/sub message bus (the `Renderer` is enough until a second subscriber exists);
image/document attachments; background shell processes; auto-commits; a fancy TUI; and the on-device
Foundation Models backend — it dispatches tool calls in-process, which would bypass the approval
gate, the path jail, and the per-role tool allowlist, so it is out of scope for v1. If any of these
appears in a diff, the reviewer rejects it.

> **Note (v2, swift-be0):** Session persistence is **not** excluded — it is implemented as lightweight
> per-session JSON files under `~/.config/acode/sessions/<id>.json` (one file per session), not a
> database. Writes are atomic with a `<id>.json.bak` backup of the previous good copy (mirrors the
> `saveApprovals` pattern in `Config.swift`). The on-disk schema is split: a pure-data `Session` plus
> a file-backed `SessionStore` (with an injectable `baseDir` for testability), and uses ISO 8601
> timestamps plus a `version` field for forward-compat. The full message history is encoded
> verbatim — the B2 tool-call/tool-result pairing invariant is preserved across save/load.

---

## §H. Reviewer checklist (run after each milestone)

1. `swift build` and `swift test` both pass; the milestone's manual smoke step works (or is noted as
   key-deferred).
2. No dependency beyond `swift-argument-parser`; no file in §G.
3. Invariants hold: loop shape (B1); a test proves tool pairs are never split (B2); no `Tool.run`
   throws (B3); isolation respected — only `run_shell` blocks, off-main (B5); providers return
   `AsyncThrowingStream` (B6); retry only before first byte and never on cancel (B7); five-layer prompt
   order intact (B8); shell is gated by approval, not the jail, and the docs say so (B9); all brain
   pillars present (B10).
4. Interfaces match §C signatures (no silent shape changes that would break other tasks).
5. Conventions (§D): one primary type per file, no stray force-unwraps in non-test code, sentence-case
   user strings, no theme/emoji, key redaction in verbose logs.
6. Line budget sanity: single-agent tool ≈ 1,250 lines / ~14 files; flag any file far over its §E
   footprint as a candidate for trimming.

---

### Background (optional, for humans)

The design mirrors the documented "Code Puppy" core (a stripped Python coding agent whose README,
"How the Core Works", describes the brain): REPL input routing, an act→observe→re-decide loop, real
tool grounding, feedback into history, prompt discipline, compaction as working memory, and
progressive-disclosure skills. This document re-implements that brain in Swift, minimally, with the
correctness fixes already folded into §C (pull-based streaming, a non-deadlocking cancellable shell,
correct JSON-Schema envelopes, retry-before-first-byte, defensive compaction, last-line verdict
parsing). Agents should not need this section to execute; it explains *why* the invariants exist.
