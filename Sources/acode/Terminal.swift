import Darwin
import Foundation

// MARK: - Terminal size

/// Terminal dimensions in rows × columns. Sendable + Equatable so the
/// `ScreenRenderer` (P2) can diff against the previous frame.
struct TermSize: Sendable, Equatable {
    let rows: Int
    let cols: Int
}

// MARK: - Terminal errors

enum TerminalError: Error {
    case cannotCaptureTermios(errno: Int32)
}

// MARK: - File-scope safety state
//
// All of this lives at file scope (not on `Terminal`) so it can be touched
// from `nonisolated` contexts — specifically the C-calling-convention
// signal and atexit trampolines at the bottom of the file. The package's
// `.defaultIsolation(MainActor.self)` would otherwise force it back onto
// the main actor.

/// The original termios captured at init. The async-signal-safe restore
/// trampoline reads it without holding a reference to the `@MainActor`
/// `Terminal` instance. Documented carve-out (TUI_PLAN §6).
///
/// **L3**: split the Optional into a raw `termios` value + a separate
/// `Bool` "is saved" flag. Both are trivially copyable (the `termios`
/// is a flat C struct of fixed-size fields), so the signal handler
/// can read both without a Swift Optional/enum indirection. A Swift
/// `Optional<termios>` is not in the POSIX async-signal-safe set
/// (the discriminant is a non-trivial load), and any future audit
/// for async-safety needs the raw value. The `Bool` is also flat
/// (1 byte) and safe to read lock-free from a sigaction handler.
private nonisolated(unsafe) var acodeSavedTermios: termios = termios()
private nonisolated(unsafe) var acodeSavedTermiosValid: Bool = false

/// Guard so the safety handlers are installed exactly once per process.
private nonisolated(unsafe) var acodeSafetyInstalled = false
private nonisolated let acodeSafetyLock = NSLock()

// MARK: - Terminal

/// Imperative shim over `termios`, `ioctl`, and a buffered stdout writer.
/// The only file in the project that touches termios (`TUI_PLAN.md` §3).
///
/// **Triple restore is the top correctness risk for the TUI work**
/// (`TUI_PLAN.md` §6): a bug here leaves the user's shell broken. The
/// mitigation, applied in three places so a crash or `kill` never strands
/// the user in raw mode:
///   1. `defer { terminal.restore() }` in the harness (normal exit)
///   2. `atexit` handler (process exit)
///   3. `sigaction` for `SIGINT` / `SIGTERM` / `SIGHUP` (crash / kill)
@MainActor
final class Terminal {
    private let originalTermios: termios
    private var isRaw = false
    private var writeBuffer = Data()

    init() throws {
        var t = termios()
        if tcgetattr(STDIN_FILENO, &t) != 0 {
            throw TerminalError.cannotCaptureTermios(errno: errno)
        }
        self.originalTermios = t
        acodeInstallSafetyHandlers(termios: t)
    }

    deinit {
        // Best-effort restore if the caller forgot. The atexit + sigaction
        // handlers are the real safety net for crashes and `kill`.
        if isRaw {
            var t = originalTermios
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
        }
    }

    /// Enters raw mode + alt-screen + hide-cursor + bracketed-paste +
    /// SGR-mouse (when `enableMouse` is true; defaults to true).
    /// Idempotent: subsequent calls are no-ops.
    ///
    /// Raw mode clears `ICANON` and `ECHO`. **Leaves `ISIG` off** so
    /// `Ctrl-C` (0x03) and `Ctrl-D` (0x04) arrive as raw bytes — the TUI
    /// decodes them itself; `Ctrl-C` cancels the *turn*, not the app.
    ///
    /// Mouse enable: `\e[?1000h` (basic button tracking) +
    /// `\e[?1006h` (SGR encoding). Disabling: the inverse, in `restore()`.
    func enterRawAltScreen(enableMouse: Bool = true) {
        guard !isRaw else { return }
        var raw = originalTermios
        // cfmakeraw-equivalent for `c_lflag`: clear ICANON, ECHO, ISIG,
        // and IEXTEN. The original code only cleared the first three;
        // leaving IEXTEN set caused `0x04` (Ctrl-D) to be interpreted as
        // VEOF by the tty line discipline on some macOS PTY configurations
        // even with ICANON off, swallowing the byte and breaking the
        // TUI's quit path. Clearing IEXTEN is the documented fix from
        // `cfmakeraw(3)`.
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG) | tcflag_t(IEXTEN))
        if tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0 {
            return  // Can't enter raw; caller sees no effect and can decide.
        }
        var seq = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h"
        if enableMouse {
            seq += "\u{1B}[?1000h\u{1B}[?1006h"
        }
        write(seq)
        flush()
        isRaw = true
    }

    /// Leaves alt-screen, shows cursor, disables bracketed paste + mouse,
    /// restores termios. Idempotent.
    func restore() {
        guard isRaw else { return }
        // Disable everything we may have enabled. Use a direct `write(2)`
        // syscall (not the buffered `Terminal.write` + `flush` pair)
        // because the cleanup path runs from a `defer` at the very end
        // of the TUI's lifetime — we want the bytes to hit the slave
        // pty atomically, before the runtime starts tearing the
        // process down. The buffered path uses Foundation's
        // `FileHandle.standardOutput.write` which can split the data
        // across multiple syscalls if the kernel buffer is congested,
        // and (worse) the Foundation write goes through a higher-level
        // FILE* layer that may flush stdio buffers — by the time the
        // `defer` runs the underlying fd may already be in a state
        // where partial writes succeed but the bytes are discarded
        // by the tty layer. The direct `write(2)` here is the same
        // syscall the atexit handler uses (see `acodeRestoreTerminalUnsafe`)
        // so the two paths produce byte-identical output.
        let cleanupBytes: [UInt8] = [
            0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68,                          // \e[?25h
            0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x30, 0x34, 0x6C,              // \e[?2004l
            0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x36, 0x6C,              // \e[?1006l
            0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x30, 0x6C,              // \e[?1000l
            0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C               // \e[?1049l
        ]
        cleanupBytes.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = Darwin.write(STDOUT_FILENO, base, buf.count)
            }
        }
        var t = originalTermios
        // Use TCSANOW, NOT TCSAFLUSH. The cleanup sequence above is
        // already in the kernel's output buffer; it will be transmitted
        // to the master/terminal as soon as the master reads. TCSANOW
        // returns immediately (termios change applied at once) without
        // waiting for the output queue to drain. TCSAFLUSH would block
        // here until the master drains the output — a real problem in
        // PTY test harnesses (and any environment) where the reader is
        // not actively draining the master. The bytes still reach the
        // terminal; the termios change is decoupled from the output
        // queue. The async-signal safety handler below still uses
        // TCSAFLUSH (it's the atexit/sigaction path, where blocking is
        // acceptable and we want to discard any pending input).
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &t)
        isRaw = false
    }

    /// Current terminal size via `ioctl(TIOCGWINSZ)`. Falls back to 24×80 on
    /// failure (e.g., stdout redirected) so layout code never sees 0×0.
    func size() -> TermSize {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0,
           ws.ws_row > 0, ws.ws_col > 0 {
            return TermSize(rows: Int(ws.ws_row), cols: Int(ws.ws_col))
        }
        return TermSize(rows: 24, cols: 80)
    }

    /// Appends to the write buffer. Pair with `flush()` to actually write.
    func write(_ s: String) {
        writeBuffer.append(Data(s.utf8))
    }

    /// Writes the buffer to stdout and clears it.
    func flush() {
        let toWrite = writeBuffer
        writeBuffer.removeAll(keepingCapacity: true)
        if !toWrite.isEmpty {
            FileHandle.standardOutput.write(toWrite)
        }
    }

    /// The second documented off-main blocking reader (TUI_PLAN §1
    /// invariant 5 carve-out — mirrors `RunShellTool.runBlocking`'s
    /// pattern). Reads one byte at a time from stdin on a detached task
    /// and forwards each byte to the supplied `@Sendable` sink. Never
    /// touches UI state directly — the sink is the only thing that
    /// crosses the thread boundary. Runs until stdin closes or an
    /// unrecoverable read error.
    ///
    /// **Returns the `Task` handle** so the caller can cancel it on
    /// session exit. Cancelling the Task is observed at the top of
    /// the next loop iteration; the `read(2)` syscall itself is
    /// blocking and can't observe cancellation, so the worst case
    /// is one extra read after the user has left the TUI. In
    /// practice the user closing stdin (^D) makes `read` return 0
    /// and the loop exits immediately.
    @discardableResult
    nonisolated static func readLoop(_ sink: @Sendable @escaping (UInt8) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var byte: UInt8 = 0
            while !Task.isCancelled {
                let n = read(STDIN_FILENO, &byte, 1)
                if n > 0 {
                    sink(byte)
                } else if n == 0 {
                    break  // EOF
                } else {
                    // n < 0
                    if errno == EINTR { continue }  // interrupted; retry
                    break  // unrecoverable
                }
            }
        }
    }
}

// MARK: - Safety handler trampolines (C calling convention)

/// Installs the atexit + sigaction handlers exactly once per process.
/// Safe to call from any `Terminal.init`.
private nonisolated func acodeInstallSafetyHandlers(termios: termios) {
    acodeSafetyLock.lock()
    defer { acodeSafetyLock.unlock() }
    guard !acodeSafetyInstalled else { return }
    acodeSafetyInstalled = true
    acodeSavedTermios = termios
    acodeSavedTermiosValid = true

    atexit(acodeAtexitHandler)

    var action = sigaction()
    action.__sigaction_u.__sa_handler = acodeSignalHandler
    action.sa_mask = sigset_t()
    action.sa_flags = 0  // no SA_RESTART: our read() should return EINTR

    _ = sigaction(SIGINT, &action, nil)
    _ = sigaction(SIGTERM, &action, nil)
    _ = sigaction(SIGHUP, &action, nil)
}

/// `@convention(c)` so it can be installed as a `sigaction` handler.
/// Catches SIGINT / SIGTERM / SIGHUP, restores the terminal, then
/// re-raises with default disposition so the process actually terminates.
private nonisolated let acodeSignalHandler: @convention(c) (Int32) -> Void = { sig in
    acodeRestoreTerminalUnsafe()
    // Re-raise with default disposition; the process should die here.
    signal(sig, SIG_DFL)
    raise(sig)
}

/// `@convention(c)` so it can be passed to `atexit`. Process-exit
/// fallback (covers `exit()` and normal return from `main`).
@_cdecl("acodeAtexitHandler")
private nonisolated func acodeAtexitHandler() {
    acodeRestoreTerminalUnsafe()
}

/// Async-signal-safe restore: writes the cleanup escape sequences via
/// `write(2)` and (best-effort) restores termios. `tcsetattr` is not in
/// the POSIX async-signal-safe list but works on Darwin in practice —
/// this is the documented carve-out for triple-restore.
///
/// The byte array MUST mirror `restore()` byte-for-byte so a
/// `kill -INT/TERM/HUP` produces the same terminal state as a clean
/// exit. The previous version omitted the mouse-disable sequences;
/// on xterm/kitty/etc. the terminal was left reporting mouse events
/// to whatever the next foreground process was — a real footgun
/// when the user `^C`s an inline edit.
private nonisolated func acodeRestoreTerminalUnsafe() {
    // \e[?25h  +  \e[?2004l  +  \e[?1006l  +  \e[?1000l  +  \e[?1049l
    //   cursor on   paste off      SGR-mouse off   basic mouse off  leave alt-screen
    let cleanup: [UInt8] = [
        0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68,                          // \e[?25h
        0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x30, 0x34, 0x6C,              // \e[?2004l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x36, 0x6C,              // \e[?1006l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x30, 0x6C,              // \e[?1000l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C               // \e[?1049l
    ]
    cleanup.withUnsafeBufferPointer { buf in
        if let base = buf.baseAddress {
            _ = write(STDOUT_FILENO, base, buf.count)
        }
    }
    // L3: read the validity flag first, then snapshot the raw
    // termios into a local. Both reads are of trivially-copyable
    // types, so the sigaction handler can do this lock-free on
    // Darwin. We still `withUnsafeMutablePointer` to hand the C
    // API a mutable pointer (the C contract is the only reason
    // for the pointer dance).
    if acodeSavedTermiosValid {
        var copy = acodeSavedTermios
        // Use TCSANOW, not TCSAFLUSH. The cleanup escape sequence
        // above is already in the kernel's tty output queue — the
        // bytes will reach the master/terminal as soon as the
        // master reads. TCSANOW applies the termios change
        // immediately and returns without waiting for the output
        // queue to drain. TCSAFLUSH would block until the output
        // drained, which is a real problem at process exit: by
        // then nobody is draining the master (the test harness is
        // blocked in `waitpid` polling, not reading). The same
        // rationale applies to the atexit path *and* the signal
        // path — in all three the termios change is independent
        // of the output bytes already in the kernel buffer.
        _ = withUnsafeMutablePointer(to: &copy) { ptr in
            tcsetattr(STDIN_FILENO, TCSANOW, ptr)
        }
    }
}
