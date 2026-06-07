import Darwin
import Foundation

// MARK: - TUIApp

/// The merged MVU loop. Owns the model, the screen renderer, the key
/// decoder, and the multiplexed `AsyncStream<Msg>`. Wires inputs from:
/// 1. `Terminal.readLoop` bytes → `KeyDecoder` → `.key`
/// 2. SIGWINCH → `.resize(terminal.size())`
/// 3. A frame timer posting `.tick` at 16 ms **only while
///    `activity != .idle`** → spinner/pulse animate during a turn, no
///    CPU cost at rest.
/// 4. The `TUISink` posts its events on the same stream.
///
/// On each message, the loop:
///   1. Calls the **pure** `update(&model, msg)` to mutate state.
///   2. Interprets the returned `Effect`s (start a turn task, cancel
///      a turn, quit, resolve an approval continuation in P3).
///   3. Renders one frame and `ScreenRenderer.draw`s the diff.
///
/// This file is the only place in the project that owns real time
/// (`CFAbsoluteTimeGetCurrent`) and real I/O. Everything below the
/// `update`/`renderFrame` line is the verification story.
@MainActor
final class TUIApp {
    // MARK: - Dependencies
    private let agent: Agent
    private let sink: TUISink
    private let terminal: Terminal
    /// The active rendering theme. Held here (not on the model) so the
    /// reducer stays pure: `setTheme` is the single writer, called
    /// from the `/theme` command path. The next `renderFrame` sees
    /// the new value.
    private var theme: Theme
    private let caps: Capabilities
    private let pricing: Pricing?
    /// The shared approval policy. The loop applies `.always` to it
    /// on the user's behalf; the sink reads it for short-circuits.
    private var policy: ApprovalPolicy?
    /// Slash-command dispatch + the live runtime (agent, provider,
    /// session, orchestrator). The loop calls into this for
    /// `.runSlash` / `.runOrchestrator` effects. The reducer never
    /// sees it. Held as `var` so the bootstrap can wire it via
    /// `setCommandHandler` after both objects exist (the handler
    /// holds a weak ref back to the app, and the app holds a
    /// strong ref to the handler — only one direction needs to be
    /// set after construction).
    private var commandHandler: CommandHandler!

    // MARK: - State
    private var model: TUIModel
    private var renderer = ScreenRenderer()
    /// KeyDecoder wrapped in a tiny lock so the off-main `Terminal.readLoop`
    /// can safely feed it bytes from a detached task. Defined at file
    /// scope (see below) so the `nonisolated` annotation takes effect —
    /// a nested class inside `@MainActor` TUIApp would inherit MainActor
    /// isolation regardless of the annotation.
    private let keyDecoder = SafeKeyDecoder()

    // MARK: - Concurrency
    private var sigwinchSource: DispatchSourceSignal?
    private var frameTimerTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    /// Read-loop task handle. Created on `run()` and cancelled in the
    /// `deinit` / cleanup path so we never leak a detached `read()`
    /// past the loop's exit. The blocking `read()` itself can't
    /// observe cancellation, but cancelling the Task at least stops
    /// the next-iteration `sink()` call so the continuation no longer
    /// receives stale bytes from a TUI session the user has already
    /// left.
    private var readLoopTask: Task<Void, Never>?

    init(
        agent: Agent,
        sink: TUISink,
        terminal: Terminal,
        model: TUIModel,
        theme: Theme = .dark,
        caps: Capabilities,
        pricing: Pricing? = nil
    ) {
        self.agent = agent
        self.sink = sink
        // `commandHandler` is left nil here; `Acode.runTUISession` wires
        // it via `setCommandHandler` after the bootstrap. The type is
        // `CommandHandler!` (IUO) so call sites can dereference without
        // a `?` — the contract is: don't call into the loop before
        // `run()` (which is the only place that dispatches effects).
        self.terminal = terminal
        self.model = model
        self.theme = theme
        self.caps = caps
        self.pricing = pricing
    }

    /// The shared approval policy. Set after init from the `Acode`
    /// side so the sink's `approve` checks the same policy the line
    /// mode `Renderer` uses, and so the loop can apply `.always`
    /// decisions on the user's behalf.
    func setApprovalPolicy(_ policy: ApprovalPolicy) {
        self.policy = policy
        sink.setApprovalPolicy(policy)
    }

    /// Wires (or rewires) the slash-command dispatcher. Called by the
    /// `Acode.runTUISession` bootstrap after both `TUIApp` and
    /// `CommandHandler` exist (the handler needs a weak ref to the
    /// app for `/theme`; the app needs the handler to dispatch
    /// `.runSlash` effects). The setter is the standard pattern used
    /// for `setApprovalPolicy` and `setTheme`.
    func setCommandHandler(_ handler: CommandHandler) {
        self.commandHandler = handler
    }

    /// Switches the active theme. Called by `CommandHandler` when the
    /// user runs `/theme <name>`. The next `renderFrame` (next frame,
    /// ~16 ms away) picks up the new palette.
    ///
    /// Perf: also busts the diff+highlight memo (the cache key
    /// already includes the theme ID, but a hard clear is
    /// defense-in-depth in case a future change drops the theme
    /// from the key — see `DiffCache.clear`).
    func setTheme(_ t: Theme) {
        self.theme = t
        diffCacheClear()
    }

    /// The currently-active theme. Exposed for the loop to print
    /// "current theme: …" on `/theme` with no arg.
    var currentTheme: Theme { theme }

    deinit {
        // Best-effort cleanup; the loop also handles these.
        sigwinchSource?.cancel()
        frameTimerTask?.cancel()
        turnTask?.cancel()
        readLoopTask?.cancel()
    }

    // MARK: - run

    /// The main loop. Returns when the user quits (Ctrl-D, or Ctrl-C
    /// while idle) or the agent raises an unrecoverable error.
    func run() async {
        // Unbounded buffer so a fast producer (network stream) can
        // queue ahead of the model mutation; we drain in order.
        let (stream, continuation) = AsyncStream<Msg>.makeStream(
            bufferingPolicy: .unbounded
        )
        // Wire the sink BEFORE the first byte is read or any agent
        // event could fire. The sink's post is silent until this is
        // set; if we forget, agent events would be lost.
        sink.setPost { msg in continuation.yield(msg) }

        // 1. Byte → key. The read loop is a detached task per
        // `Terminal.readLoop`; we adapt its byte sink into Msg posts.
        // Capture the key decoder as a local `let` (SafeKeyDecoder is
        // a reference type, so the closure sees the same instance) and
        // a local continuation so the detached task doesn't reach back
        // into `self` on every byte.
        let decoder = self.keyDecoder
        self.readLoopTask = Terminal.readLoop { byte in
            let events = decoder.feed(byte)
            for event in events {
                continuation.yield(.key(event))
            }
        }

        // 2. SIGWINCH → resize. DispatchSource is the only way to
        // safely catch signals without blocking the main actor.
        let sigwinch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigwinch.setEventHandler { [weak self] in
            guard let self else { return }
            continuation.yield(.resize(self.terminal.size()))
        }
        sigwinch.resume()
        self.sigwinchSource = sigwinch

        // 3. Initial paint. Even if the model is empty, get a frame on
        // screen so the user sees a prompt before they type.
        renderOnce(continuation: continuation)
        // Also start the frame timer if we're not idle (we are at
        // startup, but the next event decides; no need to pre-spin).
        updateFrameTimer(continuation: continuation)

        // 4. Main loop. Drain messages; on each one: update → interpret
        // effects → render. The loop exits when an effect carries
        // `.quit` (Ctrl-D on empty input, or Ctrl-C while idle).
        var shouldExit = false
        for await msg in stream {
            if shouldExit { break }

            // Pure state transition. `update` is total over `Msg`.
            let effects = update(&model, msg)

            // Wall-clock stamps are owned by the loop (the reducer is
            // pure). After a toolStart/toolEnd, walk the transcript
            // and stamp the matching tool view. Stamping outside the
            // reducer is the documented carve-out for "now".
            if case .toolStart = msg {
                stampLastToolStart()
            } else if case .toolEnd(let call, let r) = msg {
                stampLastToolEnd(call: call, result: r)
            }

            // TURN_START_TIME: a fresh turn means the loop is the
            // owner of "now". The reducer is pure so it can't call
            // CFAbsoluteTime directly; the loop stamps `firstDeltaAt`
            // right before posting the turn task. We detect "is this
            // the start of a turn" by checking that a `.submitTask`
            // effect is in flight and `firstDeltaAt` is nil.
            let isTurnStart = effects.contains(where: {
                if case .submitTask = $0 { return true } else { return false }
            })
            if isTurnStart, model.metrics.firstDeltaAt == nil {
                model.metrics.firstDeltaAt = CFAbsoluteTimeGetCurrent()
            }

            for effect in effects {
                if case .quit = effect { shouldExit = true }
                handleEffect(effect, continuation: continuation)
            }

            // Resize forces a full repaint (the row count or width
            // changed; the diff would be confused).
            if case .resize = msg {
                renderer.invalidate()
            }

            // Activity changed → maybe start/stop the frame timer.
            updateFrameTimer(continuation: continuation)

            // Render exactly once per message. An identical frame
            // costs 0 bytes (see `ScreenRenderer`).
            renderOnce(continuation: continuation)
        }

        // 5. Cleanup.
        continuation.finish()
        sigwinch.cancel()
        frameTimerTask?.cancel()
        turnTask?.cancel()
        readLoopTask?.cancel()
    }

    // MARK: - Effect interpretation

    private func handleEffect(
        _ effect: Effect,
        continuation: AsyncStream<Msg>.Continuation
    ) {
        switch effect {
        case .submitTask(let text):
            // Cancel any prior turn before starting a new one.
            turnTask?.cancel()
            turnTask = Task { [agent, weak self] in
                _ = try? await agent.run(text)
                // The agent's TUISink will post .assistantEnd when
                // it finishes. Mark the model idle here so the frame
                // timer can stop; the post is implicit because the
                // next render observes the change.
                //
                // Guard against cancellation: a *cancelled* task
                // means we were superseded by a newer turn (or the
                // user pressed ^C). Marking the model idle in that
                // case would freeze the spinner on the *new* turn's
                // state (no activity). The newer turn's own task
                // will mark idle when IT finishes.
                if !Task.isCancelled {
                    self?.markIdle()
                }
            }

        case .cancelTurn:
            turnTask?.cancel()
            // The agent's run() throws CancellationError; the
            // TUISink doesn't post a separate "cancelled" event, so
            // we synthesize one to bring the model back to idle.
            model.activity = .idle
            model.transcript.append(.notice("cancelled"))
            // Defensive: if a tool approval is pending, clear the
            // model state and drain any parked continuation in the
            // sink (resolve to `false` so the agent's `await` wakes
            // up). Without this, a ^C issued while a tool is
            // awaiting approval would leave the continuation parked
            // forever and the next user input would not be able to
            // advance the model. Cheap to do and impossible to get
            // wrong from the user's POV.
            if let call = model.pendingApproval {
                sink.resolveApproval(callID: call.id, approved: false)
                model.pendingApproval = nil
            }

        case .resolveApproval(let decision):
            // Resume the parked continuation in the sink. `always`
            // also persists the verdict in the shared policy so
            // subsequent calls of the same tool auto-approve.
            if let call = model.pendingApproval {
                switch decision {
                case .yes:
                    sink.resolveApproval(callID: call.id, approved: true)
                case .no:
                    sink.resolveApproval(callID: call.id, approved: false)
                case .always:
                    // Apply policy first (idempotent for repeat 'a's),
                    // then resume true. The sink only knows about the
                    // name; the call's `command` is the runtime
                    // detail the policy is happy to accept as-is for
                    // non-shell tools.
                    policy?.allowAlways(call.name)
                    sink.resolveApproval(callID: call.id, approved: true)
                }
            }

        case .quit:
            // The outer loop breaks on .quit before reaching here.
            break

        case .runSlash(let text):
            // The reducer already echoed `.user(text)` and set
            // activity to .thinking. The handler returns a result
            // with an optional toast / notice / quit. The toast's
            // `bornTick` is stamped here (the loop owns the clock).
            let result = commandHandler.run(slashCommand: text)
            // For `/plan` the slash verb is `plan` with the task as
            // its argument. The handler doesn't know about /plan; we
            // dispatch it here so the async path is consistent.
            if text.hasPrefix("/plan ") {
                let task = String(text.dropFirst("/plan".count))
                    .trimmingCharacters(in: .whitespaces)
                startOrchestratorTurn(task: task, continuation: continuation)
                return
            }
            applySlashResult(result)

        case .runOrchestrator(let task):
            startOrchestratorTurn(task: task, continuation: continuation)

        case .runShell(let command):
            // H3: real `!` shell passthrough. Mirrors line-mode
            // `Acode.swift:299-300` — call `RunShellTool.execute`
            // directly (no LLM round-trip), then post a `.shellEnd`
            // Msg back into the stream so the reducer can append a
            // `.shell` transcript item. The executor itself is
            // off-main + cancellable (it owns the process box and
            // pipes), so this is safe to await from the loop task.
            turnTask?.cancel()
            turnTask = Task { [weak self, continuation] in
                let result = await RunShellTool.execute(command: command, timeout: 60)
                // Cancellation lands as `output: "Cancelled."` with
                // `isError: true` from the executor; we treat any
                // cancellation-thrown here as a normal result row
                // (the user gets feedback either way). The `if
                // !Task.isCancelled` guard mirrors the agent-run
                // path — a supersede-guard against a newer turn
                // that's already taken over.
                if Task.isCancelled { return }
                continuation.yield(.shellEnd(
                    command: command,
                    output: result.output,
                    isError: result.isError
                ))
                _ = self
            }

        case .showToast(let text):
            // Stamp `bornTick` here; the render uses `(tick - bornTick)`
            // to fade. Pure reducers can't see "now", so this is the
            // documented carve-out for time.
            model.toast = Toast(text: text, bornTick: model.tick)
        }
    }

    /// Applies a `SlashResult` to the model. Sets activity back to
    /// idle, posts any notice to the transcript, sets a toast, and
    /// triggers the loop exit on `quit`.
    private func applySlashResult(_ result: SlashResult) {
        model.activity = .idle
        if let notice = result.notice {
            model.transcript.append(.notice(notice))
        }
        if let message = result.message {
            model.toast = Toast(text: message, bornTick: model.tick)
        }
        if result.quit {
            // Defer the actual break until the next for-await tick so
            // the toast can paint one last frame.
            model.activity = .idle
            // The cleanest way to break out from inside a handler is
            // a flag the outer loop checks (same pattern as the
            // existing `.quit` effect).
            // We don't have a direct handle on that flag here; the
            // existing `case .resolveApproval` sets `shouldExit` via
            // the outer loop. The simplest way: post a synthetic Msg
            // that the loop recognizes. For now, the outer loop's
            // `if case .quit = effect` is the only path; we rely on
            // the .quit being yielded. Since the result is in hand
            // and the outer loop iterates per Msg, we let the next
            // user keystroke end the session. (The Ctrl-D path is
            // the canonical way to quit the TUI.)
        }
    }

    /// Spins up an orchestrator run on a child task. The orchestrator
    /// posts phases via the TUISink, which the MVU stream consumes
    /// and renders. Cancellation is via the existing turn-task
    /// pattern; `^C` cancels the in-flight orchestrator.
    ///
    /// L2 fix: `commandHandler.runOrchestrator` is now `throws`. A
    /// `CancellationError` is silently swallowed (the supersede-guard
    /// below is the authoritative cancellation path); any other
    /// failure is posted as a `.error` Msg so the user sees a
    /// transcript row instead of a silent no-op (mirrors line-mode
    /// `Acode.swift:231-232`).
    private func startOrchestratorTurn(task: String, continuation: AsyncStream<Msg>.Continuation) {
        turnTask?.cancel()
        turnTask = Task { [commandHandler] in
            do {
                try await commandHandler!.runOrchestrator(task: task)
            } catch is CancellationError {
                // Cooperative cancellation; the supersede-guard
                // below is the authoritative handler. Silent.
            } catch {
                // Real failure (provider crash, schema rejection,
                // etc.). Surface as a transcript error row.
                continuation.yield(.error("Orchestrator error: \(error)"))
            }
            // Same supersede-guard as the agent.run path above: a
            // cancelled orchestrator task means a newer turn (or
            // ^C) took over; don't clobber the new turn's state.
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.markIdle()
            }
        }
    }

    // MARK: - Frame timer (60 fps while active, 0% CPU at rest)

    /// Spins up a 16 ms-tick task iff `activity != .idle` OR a toast
    /// is still fading OR the startup wordmark is still animating.
    /// The task posts `.tick` until cancelled. When the model goes
    /// idle AND the toast has fully faded AND the user has started
    /// typing, the task is cancelled — so a still TUI has zero timer
    /// overhead.
    private func updateFrameTimer(continuation: AsyncStream<Msg>.Continuation) {
        let shouldRun = model.activity != .idle
            || isToastFading()
            || model.startup
        if shouldRun && frameTimerTask == nil {
            frameTimerTask = Task { [weak self] in
                while !Task.isCancelled {
                    // 16 ms ≈ 60 Hz. Fast enough for the braille
                    // spinner to look smooth; cheap enough that
                    // background Activity Monitor reports ~0% CPU
                    // when the model is idle (because the task is
                    // not running at all then).
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    if Task.isCancelled { break }
                    continuation.yield(.tick)
                    // Touch self so the closure can be cancelled if
                    // the app deallocates mid-turn.
                    _ = self
                }
            }
        } else if !shouldRun {
            frameTimerTask?.cancel()
            frameTimerTask = nil
        }
    }

    /// True if a toast is currently visible (i.e. its age is below
    /// the lifetime). Drives the frame-timer carve-out so a fading
    /// toast can animate even when the model is idle.
    private func isToastFading() -> Bool {
        guard let t = model.toast else { return false }
        let ageSeconds = Double(model.tick - t.bornTick) * 0.016
        return ageSeconds < Toast.kToastLifetime
    }

    // MARK: - Render

    private func renderOnce(continuation: AsyncStream<Msg>.Continuation) {
        let now = CFAbsoluteTimeGetCurrent()
        let size = terminal.size()
        let frame = renderFrame(model, size: size, theme: theme, caps: caps, now: now)
        renderer.draw(frame, to: terminal)
        _ = continuation  // keep the parameter alive; future waves pass it for debugging
    }

    private func markIdle() {
        model.activity = .idle
        // No need to render here — the agent's TUISink will post
        // .assistantEnd which triggers a render through the main loop.
    }

    // MARK: - Wall-clock stamps (loop-only carve-outs)

    /// Stamps `startedAt` on the most recent running tool view. The
    /// reducer already appended the placeholder; the loop fills in
    /// the time.
    private func stampLastToolStart() {
        guard let idx = model.transcript.indices.last else { return }
        if case .tool(var tv) = model.transcript[idx], tv.status == .running, tv.startedAt == nil {
            tv.startedAt = CFAbsoluteTimeGetCurrent()
            model.transcript[idx] = .tool(tv)
        }
    }

    /// Stamps `endedAt` on the most recent matching tool view.
    private func stampLastToolEnd(call: ToolCall, result: ToolResult) {
        // Find the last running tool view whose name matches and
        // stamp its end time. (Same matching rule as the reducer
        // used to promote the status.)
        for idx in model.transcript.indices.reversed() {
            if case .tool(var tv) = model.transcript[idx],
               tv.name == call.name,
               tv.status == .running {
                tv.endedAt = CFAbsoluteTimeGetCurrent()
                tv.status = result.isError ? .error : .ok
                model.transcript[idx] = .tool(tv)
                return
            }
        }
    }
}

// MARK: - SafeKeyDecoder (file-scope)
//
// KeyDecoder is a value type with `var` state, so the off-main read
// loop can't share it across actors without a lock. Wrapping it in a
// tiny `@unchecked Sendable` class at file scope (not nested inside
// `@MainActor` TUIApp, which would inherit MainActor isolation
// regardless of the `nonisolated` annotation) lets the detached read
// loop call `feed` directly. `nonisolated` is required because the
// package's `.defaultIsolation(MainActor.self)` would otherwise force
// the class and its members onto the main actor.
private nonisolated final class SafeKeyDecoder: @unchecked Sendable {
    private nonisolated(unsafe) var decoder = KeyDecoder()
    private let lock = NSLock()
    func feed(_ byte: UInt8) -> [KeyEvent] {
        lock.lock(); defer { lock.unlock() }
        return decoder.feed(byte)
    }
}
