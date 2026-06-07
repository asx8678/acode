//
//  TuiLiveTests.swift
//  acode
//
//  Headless end-to-end test for the live `--tui` experience.
//
//  Why a PTY and not a pipe: the `Acode.run()` boot path gates the
//  alternate-screen TUI on `isatty(STDIN_FILENO) && isatty(STDOUT_FILENO)`.
//  A pipe makes both `false` and the code falls through to line mode,
//  so every prior "TUI verification" only confirmed the boot + the
//  pipe-fallback path. The real raw-mode TUI was unverified. A
//  pseudo-terminal (PTY) slave is a real TTY (both `isatty()` calls
//  return 1) AND is bidirectional, so the child enters raw mode, we
//  read its output from the master fd, and we send keystrokes by
//  writing to the same master fd. The TUI's kernel-level SIGWINCH
//  signal is also delivered to the foreground pgrp of the slave
//  (which is the child) when we set the winsize via `TIOCSWINSZ` on
//  the master, so the resize path is exercised end-to-end.
//
//  No network: we never submit a prompt, so the provider is never
//  called. The TUI's first frame is rendered with the startup
//  wordmark and the user's `defaultModel` (from
//  `~/.config/acode/config.json`), which the test greps for in the
//  captured output bytes.
//
//  Verifies the mechanical/functional portion of `swift-92m.9`:
//    - alt-screen enter (`ESC[?1049h`) is emitted on boot
//    - cursor-hide + bracketed-paste-enable + mouse-enable are emitted
//    - the wordmark's `· model:` label appears in the first frame
//    - the hints row text appears in the first frame
//    - a keystroke (3 chars) triggers a re-render (input echoes)
//    - `TIOCSWINSZ` (40×100) + SIGWINCH triggers a re-render
//    - Ctrl-D on empty input quits, alt-screen leave (`ESC[?1049l`)
//      is emitted, and the child exits cleanly (status 0)
//
//  KNOWN FINDING (this test caught a real bug — NOT a false positive):
//  As of the current `main`, `TUIApp.run()` never calls
//  `Terminal.enterRawAltScreen()`. The Terminal class defines the
//  method, but no caller invokes it. The TUI renders to the main
//  screen with `ESC[2J ESC[H` clear-and-home, not the alt-screen
//  buffer. This is exactly the kind of regression that previous
//  "TUI verification" attempts (which only ran on a pipe, never
//  hitting the raw-mode path) failed to catch. Once the TUI grows
//  an `enterRawAltScreen()` call in `TUIApp.run()` and a matching
//  `terminal.restore()` in the quit effect handler, this test will
//  go green and serve as a permanent regression guard.
//
//  Residual HUMAN-ONLY items (intentionally NOT covered here):
//    - subjective look/feel, color fidelity on the user's actual
//      terminal, GPU-terminal (Ghostty/kitty) rendering, real
//      streaming latency, mouse interaction, theme aesthetics
//

import Darwin
import Foundation
import Testing
@testable import acode

// MARK: - PTY primitives

/// Open a fresh PTY pair. Returns the master fd (caller owns it;
/// close(2) on test exit) and the slave path (a `/dev/ttysNNN`
/// string the child can `open(2)`).
/// Throws on any failure; the master fd is closed before the throw.
private func openPtyPair() throws -> (master: Int32, slave: String) {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    if master < 0 {
        throw PTYError.posixCall("posix_openpt", errno: errno)
    }
    // grant/unlock are void-returning on Darwin but the imported
    // Swift signature still hands back Int32 for the C convention.
    if grantpt(master) != 0 {
        let saved = errno
        close(master)
        throw PTYError.posixCall("grantpt", errno: saved)
    }
    if unlockpt(master) != 0 {
        let saved = errno
        close(master)
        throw PTYError.posixCall("unlockpt", errno: saved)
    }
    guard let cStr = ptsname(master) else {
        let saved = errno
        close(master)
        throw PTYError.posixCall("ptsname", errno: saved)
    }
    return (master, String(cString: cStr))
}

/// Set the PTY winsize via TIOCSWINSZ on the master. On macOS this
/// only succeeds once some process has opened the slave — the long-
/// running TUI child satisfies that by the time we resize.
private func setWinsizeViaMaster(_ master: Int32, rows: UInt16, cols: UInt16) throws {
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    let r = withUnsafeMutablePointer(to: &ws) { ptr -> Int32 in
        ioctl(master, UInt(TIOCSWINSZ), ptr)
    }
    if r != 0 {
        throw PTYError.posixCall("ioctl TIOCSWINSZ", errno: errno)
    }
}

/// Set the master fd to non-blocking so we can `poll()` + `read()`
/// without stalling the test on slow/no output.
private func setNonBlocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0 { throw PTYError.posixCall("fcntl F_GETFL", errno: errno) }
    if fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 {
        throw PTYError.posixCall("fcntl F_SETFL", errno: errno)
    }
}

private enum PTYError: Error, CustomStringConvertible {
    case posixCall(String, errno: Int32)
    var description: String {
        switch self {
        case .posixCall(let op, let e):
            return "\(op) failed: \(String(cString: strerror(e))) (errno=\(e))"
        }
    }
}

// MARK: - Child process wrapper

/// Spawns the built `acode --tui` product as a child with a PTY as
/// its stdin/stdout (real TTY → real raw-mode TUI, not the pipe
/// fallback). Stderr is routed to `/dev/null` so the TUI's diagnostic
/// messages don't pollute our byte stream. The child runs in a fresh
/// env that explicitly sets `TERM=xterm-256color` (so the
/// `Capabilities.detect` color path is `.x256`), and clears any
/// `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` that the test runner might
/// have inherited (we never call the provider, but a stray key would
/// only be relevant if we ever submitted a prompt — keeping the env
/// hermetic removes the risk of accidental network egress).
private final class TuiChild: @unchecked Sendable {
    let master: Int32
    let pid: pid_t
    private var alive: Bool = true

    init(productPath: String) throws {
        let (masterFD, slave) = try openPtyPair()
        self.master = masterFD
        try setNonBlocking(masterFD)

        // argv: [acode, --tui, NULL]. Allocated with strdup; the
        // strings are consumed by posix_spawn (the kernel reads
        // them during exec) so we can free them as soon as the
        // call returns successfully.
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(productPath),
            strdup("--tui"),
            nil
        ]
        defer { for p in argv { if let q = p { free(q) } } }

        // env: minimal, deterministic, NO_COLOR absent, keys blanked.
        // `posix_spawn` with a custom envp REPLACES the inherited env
        // (the child does not see the parent's vars), so we must list
        // PATH and friends explicitly.
        let envStrings: [String] = [
            "PATH=/usr/bin:/bin",
            "HOME=/tmp",
            "TMPDIR=/tmp",
            "TERM=xterm-256color",
            "LANG=en_US.UTF-8",
            // Intentionally NOT setting NO_COLOR (would force mono).
            // Intentionally setting the keys to empty so a stray
            // `processInfo.environment[...]` later sees "" and not a
            // real key. (The provider would throw `missingAPIKey` on
            // call; we never call it.)
            "ANTHROPIC_API_KEY=",
            "OPENAI_API_KEY=",
        ]
        let envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { for p in envp { if let q = p { free(q) } } }

        // File actions: open the slave path as stdin/stdout (RDWR
        // because the PTY is bidirectional). Stderr → /dev/null.
        // posix_spawn consumes the actions during the call; we
        // destroy them after the call returns.
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, slave, O_RDWR, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, slave, O_RDWR, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        // Attrs: defaults. (We could put the child in its own pgrp
        // for cleaner SIGWINCH delivery, but on macOS the default
        // pgrp is fine — the child becomes the foreground pgrp of
        // its slave tty by virtue of being the only opener, and
        // SIGWINCH lands there. The test process ignores SIGWINCH
        // by default, so the child is the only consumer.)
        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        var spawnedPid: pid_t = 0
        let rc = posix_spawn(
            &spawnedPid,
            productPath,
            &fileActions,
            &attrs,
            argv,
            envp
        )
        if rc != 0 {
            close(masterFD)
            throw PTYError.posixCall("posix_spawn", errno: rc)
        }
        self.pid = spawnedPid
    }

    deinit {
        if alive {
            // Best-effort: the test forgot to clean up. SIGKILL is
            // the last-resort safety net (no atexit → terminal may
            // be left raw; the test runner is unaffected).
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
        close(master)
    }

    /// Write raw bytes to the master fd. Blocks until the kernel
    /// accepts them all (POSIX `write(2)` semantics on a non-blocking
    /// fd: a short write is possible if the PTY input buffer is full;
    /// we loop to drain).
    func writeRaw(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(master, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    // Input buffer is full; yield to the child for a
                    // tick so it can drain. 5ms is plenty for one
                    // byte on a 16ms frame timer.
                    usleep(5_000)
                    continue
                }
                return  // unrecoverable
            }
        }
    }

    /// Non-blocking-ish wait for the child to exit. Returns the
    /// raw `wait` status (use `WIFEXITED`/`WEXITSTATUS` to unpack).
    /// `timeoutSeconds` is a wall-clock cap; on timeout returns nil
    /// (caller decides whether to SIGKILL).
    ///
    /// `drain` (optional) is called on every poll tick with the master
    /// fd. This is needed because the PTY's kernel buffer between the
    /// slave's output and the master's read is finite (typically 16-64
    /// KB on macOS), and bytes written by the child AFTER the
    /// previously-drained point can be silently dropped if the master
    /// stops reading while the child is writing — most importantly,
    /// the cleanup sequence from `terminal.restore()` and the atexit
    /// handler (38 bytes each) that runs as the process tears down.
    /// Without concurrent draining, those final bytes vanish and the
    /// "alt-screen leave" assertion (which checks for `ESC[?1049l`)
    /// fails spuriously. The harness was originally written without
    /// this carve-out and only worked when run manually on a pipe
    /// (where there's no real PTY, no kernel buffer, and no atexit
    /// cleanup); the PTY harness caught this.
    func waitExit(timeoutSeconds: Double, drain: ((Int32) -> Void)? = nil) -> Int32? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var status: Int32 = 0
        while Date() < deadline {
            if let drain = drain { drain(master) }
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                alive = false
                return status
            }
            usleep(20_000)  // 20ms tick
        }
        return nil
    }

    /// SIGKILL the child and reap it. Idempotent.
    func killHard() {
        guard alive else { return }
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        alive = false
    }
}

// MARK: - Output capture

/// Drains the master fd into a Data buffer with a deadline. Each
/// call to `drainFor(seconds:)` polls for the given duration and
/// appends everything available. Returns the number of NEW bytes
/// appended (caller can use this to detect "did anything happen
/// in the last N ms").
private final class OutputCapture: @unchecked Sendable {
    private var data = Data()
    private var scratch = [UInt8](repeating: 0, count: 16 * 1024)

    /// Drain the master fd for up to `seconds` wall-clock, returning
    /// the number of NEW bytes appended to the buffer.
    @discardableResult
    func drain(master: Int32, seconds: Double) -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        let startCount = data.count
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 50)  // 50ms poll slices
            if pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let n = read(master, &scratch, scratch.count)
                if n > 0 { data.append(scratch, count: n); continue }
                if n == 0 { break }  // master EOF
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break  // unrecoverable
            } else if pr < 0 && errno == EINTR {
                continue
            }
        }
        return data.count - startCount
    }

    /// Total bytes captured so far.
    var count: Int { data.count }

    /// All captured bytes (read-only).
    var bytes: Data { data }

    /// Append a raw read result. Used by the `waitExit` concurrent-drain
    /// closure, which does a single non-blocking `read(2)` per tick of
    /// the wait loop (the heavier `drain(master:seconds:)` method with
    /// its own `poll(2)` would dominate the loop). The closure already
    /// filters for `n > 0`, so we just append unconditionally here.
    func appendForDrain(_ scratch: [UInt8], count: Int) {
        data.append(scratch, count: count)
    }

    /// True iff `needle` appears anywhere in the captured bytes.
    func contains(_ needle: Data) -> Bool {
        data.range(of: needle) != nil
    }

    /// True iff `needle` (interpreted as UTF-8) appears anywhere.
    func containsString(_ needle: String) -> Bool {
        contains(Data(needle.utf8))
    }

    /// Returns the captured bytes from `start` to `end` for diffing.
    func slice(from start: Int) -> Data {
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<data.count)
    }
}

// MARK: - The test

@MainActor
@Test func test_tui_live_pty_render() async throws {
    // ---- 1. Locate the built product ----
    let cwd = FileManager.default.currentDirectoryPath
    let debugPath = "\(cwd)/.build/debug/acode"
    let releasePath = "\(cwd)/.build/release/acode"
    let productPath: String
    if FileManager.default.fileExists(atPath: debugPath) {
        productPath = debugPath
    } else if FileManager.default.fileExists(atPath: releasePath) {
        productPath = releasePath
    } else {
        Issue.record(
            "acode executable not found at \(debugPath) nor \(releasePath). Run `swift build` (or `swift build -c release`) before this test."
        )
        return
    }

    // ---- 2. Spawn the TUI child ----
    // TuiChild opens its own PTY pair and routes the child's
    // stdin/stdout through the slave; we interact with the master.
    let child: TuiChild
    do {
        child = try TuiChild(productPath: productPath)
    } catch {
        Issue.record("failed to set up PTY child: \(error)")
        return
    }

    // Safety net: if anything below throws, the child gets killed
    // and the master fd is closed by TuiChild.deinit.
    let capture = OutputCapture()

    // ---- 3. Drain until the first frame lands ----
    // The TUI does: enterRawAltScreen → renderOnce → frame timer
    // ticks. We expect the alt-screen enter + cursor-hide +
    // bracketed-paste-enable + mouse-enable escapes to appear in
    // the first ~200ms, and the model name in the wordmark shortly
    // after. Bound the wait at 3s for slow CI.
    let altScreenEnter = Data("\u{1B}[?1049h".utf8)
    let cursorHide = Data("\u{1B}[?25l".utf8)
    let pasteEnable = Data("\u{1B}[?2004h".utf8)
    let mouseEnable = Data("\u{1B}[?1000h".utf8)
    // The wordmark's metadata block renders "· model: <name>". The
    // model name is user-configurable (defaultModel in
    // ~/.config/acode/config.json) so we DON'T hardcode a specific
    // model. We assert on the stable label that always precedes the
    // name. UTF-8 of "·" (middle dot) is 0xC2 0xB7.
    let modelLabel = Data([0xC2, 0xB7, 0x20, 0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x3A])
    let hintsRow = Data("⏎ send".utf8)         // last row, never overlaid

    // Drain the first frame.
    let firstFrameTimeout: Double = 3.0
    let firstFrameStart = Date()
    var sawFirstFrame = false
    while Date().timeIntervalSince(firstFrameStart) < firstFrameTimeout {
        _ = capture.drain(master: child.master, seconds: 0.1)
        if capture.contains(altScreenEnter),
           capture.contains(modelLabel),
           capture.contains(hintsRow) {
            sawFirstFrame = true
            break
        }
    }
    // Give the frame timer a final ~200ms to emit the rest of the
    // chrome (the wordmark is animated; some glyphs come a frame
    // or two after the first).
    _ = capture.drain(master: child.master, seconds: 0.2)

    // ---- 4. Assertions on the initial frame ----
    #expect(
        sawFirstFrame,
        "first TUI frame did not arrive within \(firstFrameTimeout)s — model=\(modelLabel) hints=\(hintsRow)"
    )
    #expect(capture.contains(altScreenEnter),
            "expected alt-screen enter ESC[?1049h in TUI output; got \(capture.count) bytes — Terminal.enterRawAltScreen() is defined but never called (see file header)")
    #expect(capture.contains(cursorHide),
            "expected cursor-hide ESC[?25l in TUI output")
    #expect(capture.contains(pasteEnable),
            "expected bracketed-paste-enable ESC[?2004h in TUI output — Terminal.enterRawAltScreen() never runs (see file header)")
    #expect(capture.contains(mouseEnable),
            "expected mouse-enable ESC[?1000h in TUI output — Terminal.enterRawAltScreen() never runs (see file header)")
    #expect(capture.contains(modelLabel),
            "expected wordmark '· model:' label in initial frame")
    #expect(capture.contains(hintsRow),
            "expected hints-row text '⏎ send' in initial frame")

    // If the assertions above already failed, don't continue the
    // interactive portion — the child is in a broken state and
    // any further reads/keystrokes would be noise.
    if !sawFirstFrame {
        child.killHard()
        return
    }

    // ---- 5. Type "ZZZ" → expect a re-render with the typed text ----
    // "ZZZ" is unique to the chrome (nothing in HUD, hints, or
    // wordmark uses three consecutive uppercase Z's). After typing,
    // the input box renders "<sgr>▸ <sgr>0mZZZ" so the substring
    // "\u{1B}[0mZZZ" (SGR reset + ZZZ) is a unique marker.
    let bytesBeforeTyping = capture.count
    let typedMarker = Data("\u{1B}[0mZZZ".utf8)
    child.writeRaw([0x5A, 0x5A, 0x5A])  // "ZZZ"

    // The keystroke fires a Msg into the loop; the loop renders a
    // new frame. The wordmark overlay is dismissed on first user
    // input (m.startup = false), so we also expect to see the
    // HUD's "◆ " model badge appear AFTER typing.
    let typedTimeout: Double = 2.0
    let typedStart = Date()
    var sawTypedMarker = false
    var sawHudBadge = false
    let hudBadge = Data("◆ ".utf8)
    while Date().timeIntervalSince(typedStart) < typedTimeout {
        _ = capture.drain(master: child.master, seconds: 0.1)
        if capture.contains(typedMarker) { sawTypedMarker = true }
        if capture.contains(hudBadge) { sawHudBadge = true }
        if sawTypedMarker { break }
    }
    let bytesAfterTyping = capture.count
    #expect(
        bytesAfterTyping > bytesBeforeTyping,
        "expected a re-render after typing; bytes went \(bytesBeforeTyping) → \(bytesAfterTyping)"
    )
    #expect(
        sawTypedMarker,
        "expected typed text 'ZZZ' to render in the input box (looking for ESC[0mZZZ)"
    )
    #expect(
        sawHudBadge,
        "expected HUD model badge '◆ ' to appear after wordmark dismiss"
    )

    if !sawTypedMarker {
        child.killHard()
        return
    }

    // ---- 6. Resize via TIOCSWINSZ + SIGWINCH → expect a re-render ----
    let bytesBeforeResize = capture.count
    do {
        try setWinsizeViaMaster(child.master, rows: 40, cols: 100)
    } catch {
        // TIOCSWINSZ on the master is racy: on macOS it requires
        // some process to have opened the slave. The TUI child
        // opened it during boot, but we drain in 50ms slices —
        // by now it MUST be open. If it isn't, the slave open in
        // the child failed for some other reason and the test
        // should bail with a clear message.
        child.killHard()
        Issue.record("could not set winsize on master: \(error)")
        return
    }
    // SIGWINCH to the child's pgrp. The TUI's DispatchSourceSignal
    // catches it and posts a .resize Msg, which triggers a full
    // repaint (renderer.invalidate()).
    _ = kill(child.pid, SIGWINCH)

    let resizeTimeout: Double = 2.0
    let resizeStart = Date()
    while Date().timeIntervalSince(resizeStart) < resizeTimeout {
        _ = capture.drain(master: child.master, seconds: 0.1)
        if capture.count > bytesBeforeResize { break }
    }
    #expect(
        capture.count > bytesBeforeResize,
        "expected a re-render after SIGWINCH; bytes went \(bytesBeforeResize) → \(capture.count)"
    )

    // ---- 7. Quit: clear "ZZZ" with three backspaces, then Ctrl-D ----
    // The TUI's TUIModel reducer maps Ctrl-D (0x04) on empty input
    // to a `.quit` effect; on non-empty input it's a backspace. So
    // we must clear "ZZZ" first, then send Ctrl-D.
    child.writeRaw([0x7F, 0x7F, 0x7F])  // 3× DEL = 3 backspaces
    // Tiny pause so the loop processes the backspaces before the
    // Ctrl-D. The TUI's loop is single-threaded on the main actor
    // and each Msg is processed in order, so 50ms is plenty.
    _ = capture.drain(master: child.master, seconds: 0.05)
    child.writeRaw([0x04])  // Ctrl-D on empty input → quit

    // ---- 8. Wait for clean exit + alt-screen leave sequence ----
    let altScreenLeave = Data("\u{1B}[?1049l".utf8)
    let exitStatus = child.waitExit(timeoutSeconds: 3.0) { master in
        // Concurrent drain: the PTY's kernel buffer is finite, and
        // bytes written by the child AFTER the previous drain point
        // can be silently dropped if the master stops reading while
        // the child is writing — most importantly, the cleanup
        // sequence from `terminal.restore()` and the atexit handler
        // (38 bytes each) that runs as the process tears down.
        // Without this, the "alt-screen leave" assertion fails
        // spuriously because those final bytes vanish. We do a
        // single non-blocking read per tick of the wait loop; the
        // heavier `drain(master:seconds:)` (poll + 50ms timeouts)
        // would dominate the loop. `EAGAIN`/`EINTR`/0/<0 → no
        // bytes this tick, which is fine.
        var scratch = [UInt8](repeating: 0, count: 4096)
        let n = read(master, &scratch, scratch.count)
        if n > 0 { capture.appendForDrain(scratch, count: n) }
    }
    // Final drain in case the last batch of bytes (atexit cleanup)
    // arrived after waitExit returned.
    _ = capture.drain(master: child.master, seconds: 0.5)

    #expect(
        exitStatus != nil,
        "TUI child did not exit within 3s of Ctrl-D"
    )
    if let s = exitStatus {
        let exited = (s & 0x7f) == 0
        let code = (s >> 8) & 0xff
        #expect(
            exited && code == 0,
            "TUI child did not exit cleanly: raw status=\(s) signal=\(s & 0x7f) code=\(code)"
        )
    }
    #expect(
        capture.contains(altScreenLeave),
        "expected alt-screen leave ESC[?1049l on quit; got \(capture.count) bytes total"
    )

    // If the child is somehow still alive (waitExit returned nil),
    // SIGKILL it so the test runner doesn't accumulate zombies.
    if exitStatus == nil {
        child.killHard()
    }
}

// MARK: - SIGINT / Ctrl-C teardown-safety test
//
// Sibling of `test_tui_live_pty_render`. The harness's primary
// happy-path test quits via Ctrl-D on empty input, which goes
// through the TUI's normal quit-effect → break-out-of-for-await
// → defer terminal.restore() path. This second test exercises the
// DANGEROUS abnormal-exit path: deliver SIGINT (Ctrl-C) directly
// to the child while it's idle in the TUI's read loop. The
// terminal-restore trampolines installed in `Terminal.swift`
// (`acodeInstallSafetyHandlers` → atexit + sigaction) must catch
// the signal, write the alt-screen leave / cursor-show /
// paste-off / mouse-off cleanup sequence, restore termios, and
// re-raise with default disposition so the process actually
// dies. If the trampolines regress, the test catches the bug the
// same way a real user would: a stuck terminal in raw/alt/mouse/
// no-echo mode. This is the "abnormal-exit path" the task brief
// flagged as  SAFETY-CRITICAL.
@Test func test_tui_live_pty_sigint_restores_terminal() throws {
    // ---- 1. Locate the built product (same as primary test) ----
    let cwd = FileManager.default.currentDirectoryPath
    let debugPath = "\(cwd)/.build/debug/acode"
    let releasePath = "\(cwd)/.build/release/acode"
    let productPath: String
    if FileManager.default.fileExists(atPath: debugPath) {
        productPath = debugPath
    } else if FileManager.default.fileExists(atPath: releasePath) {
        productPath = releasePath
    } else {
        Issue.record(
            "acode executable not found at \(debugPath) nor \(releasePath). Run `swift build` (or `swift build -c release`) before this test."
        )
        return
    }
    let child = try TuiChild(productPath: productPath)
    defer { child.killHard() }
    let capture = OutputCapture()

    // ---- 1. Wait for the first frame (boot OK) ----
    let firstFrame = Data("\u{1B}[2J".utf8)  // ScreenRenderer.fullRepaint's clear
    let firstFrameTimeout: Double = 3.0
    let firstFrameStart = Date()
    var sawFirstFrame = false
    while Date().timeIntervalSince(firstFrameStart) < firstFrameTimeout {
        _ = capture.drain(master: child.master, seconds: 0.1)
        if capture.contains(firstFrame) { sawFirstFrame = true; break }
    }
    #expect(sawFirstFrame, "TUI never produced its first frame; got \(capture.count) bytes")

    // ---- 2. Confirm we entered the alt-screen (the bug being guarded) ----
    let altScreenEnter = Data("\u{1B}[?1049h".utf8)
    #expect(
        capture.contains(altScreenEnter),
        "expected alt-screen enter ESC[?1049h on boot; got \(capture.count) bytes"
    )

    // ---- 3. Deliver SIGINT directly to the child ----
    // SIGINT = 0x03; the TUI's reducer normally maps Ctrl-C while
    // idle to a `.quit` effect (clean path). But we're bypassing
    // the line discipline and sending the signal to the child
    // process from the test harness via `kill(2)`. The kernel
    // delivers it; the TUI's sigaction handler runs; the handler
    // restores the terminal, then re-raises with default
    // disposition so the process actually terminates. This
    // exercises the safety net — the path the previous version
    // of this code did NOT have (no `enterRawAltScreen` call,
    // no `terminal.restore()` call, no `defer`).
    let killResult = kill(child.pid, SIGINT)
    #expect(killResult == 0, "kill(SIGINT) failed: errno=\(errno)")

    // ---- 4. Wait for the child to die (via the signal handler re-raise) ----
    // Use the concurrent-drain variant of waitExit (same fix as
    // the primary test — without it, the alt-screen leave bytes
    // vanish into the kernel's PTY buffer because nothing is
    // draining it during the wait).
    let exitStatus = child.waitExit(timeoutSeconds: 3.0) { master in
        var scratch = [UInt8](repeating: 0, count: 4096)
        let n = read(master, &scratch, scratch.count)
        if n > 0 { capture.appendForDrain(scratch, count: n) }
    }
    _ = capture.drain(master: child.master, seconds: 0.5)

    #expect(
        exitStatus != nil,
        "TUI child did not exit within 3s of SIGINT — safety handler did not run"
    )
    if let s = exitStatus {
        // The signal handler re-raises with default disposition,
        // so the process dies from SIGINT, NOT from a clean
        // `exit(0)`. WIFEXITED is false, WTERMSIG is SIGINT.
        // We accept this as the *correct* outcome — the
        // alternative is the process ignoring the signal and
        // surviving, which is the bug we're guarding against.
        let signaled = (s & 0x7f) != 0
        let termSig = s & 0x7f
        #expect(
            signaled && termSig == SIGINT,
            "TUI child did not die from SIGINT: raw status=\(s) WTERMSIG=\(termSig)"
        )
    }

    // ---- 5.  The critical safety assertion: the terminal was
    //         still restored even on the abnormal-exit path.
    //         Without the sigaction handler in `Terminal.swift`
    //         writing the alt-screen leave + cursor-show +
    //         paste-off + mouse-off sequence, the user's real
    //         terminal would be stuck in raw/alt/mouse/no-echo
    //         mode after they ^C'd the TUI. This is the bug
    //         the task brief called out as  SAFETY-CRITICAL.
    let altScreenLeave = Data("\u{1B}[?1049l".utf8)
    #expect(
        capture.contains(altScreenLeave),
        "SIGINT did not produce alt-screen leave ESC[?1049l — terminal would be stuck in alt-screen for the user. Got \(capture.count) bytes total"
    )

    // If the child is somehow still alive (waitExit returned nil),
    // SIGKILL it so the test runner doesn't accumulate zombies.
    if exitStatus == nil {
        child.killHard()
    }
}
