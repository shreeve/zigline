//! Terminal — raw mode, size query, fd ownership, terminal modes,
//! signal handlers for terminal hygiene.
//!
//! See SPEC.md §9. Owns the saved termios for restoration, the
//! input/output fds (borrowed from caller), bracketed-paste state,
//! and (when in raw mode) a `SignalGuard` that owns a self-pipe used
//! to wake up a blocked `read()` from a signal handler.
//!
//! POSIX-only.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Size = struct {
    rows: u16,
    cols: u16,
};

/// One-byte sentinels written to the self-pipe by signal handlers,
/// drained by the read loop to drive non-keystroke events.
pub const PipeSignal = struct {
    pub const winch: u8 = 'W';
    pub const cont: u8 = 'C';
    pub const wake: u8 = 'K'; // application-initiated (notifyResize)
};

/// Process-wide claim on the active editor's self-pipe + saved
/// sigactions. Only one `SignalGuard` may be active at a time —
/// the atomic write-end FD is the claim. While zero, no editor
/// owns signals; signal handlers are no-ops.
var active_pipe_write: std.atomic.Value(c_int) = .init(-1);
var active_termios_saved: std.atomic.Value(?*const std.c.termios) = .init(null);
var active_termios_raw: std.atomic.Value(?*const std.c.termios) = .init(null);
var active_input_fd: std.atomic.Value(c_int) = .init(-1);
var active_output_fd: std.atomic.Value(c_int) = .init(-1);

fn winchHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    const fd = active_pipe_write.load(.acquire);
    if (fd < 0) return;
    var b: [1]u8 = .{PipeSignal.winch};
    _ = std.c.write(fd, &b, 1);
}

fn tstpHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    // Restore cooked termios + disable bracketed paste so the user's
    // shell sees a sane terminal while we're stopped. Both
    // tcsetattr() and write() are async-signal-safe per POSIX.
    const saved = active_termios_saved.load(.acquire);
    const out_fd = active_output_fd.load(.acquire);
    const in_fd = active_input_fd.load(.acquire);
    if (saved) |s| {
        if (in_fd >= 0) _ = std.c.tcsetattr(in_fd, .NOW, s);
    }
    if (out_fd >= 0) _ = std.c.write(out_fd, "\x1b[?2004l", 8);

    // Re-raise SIGTSTP with default disposition so the kernel
    // actually stops the process.
    var dfl: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    var prev: std.c.Sigaction = undefined;
    _ = std.c.sigaction(.TSTP, &dfl, &prev);
    _ = std.c.raise(.TSTP);
    // ──── PROCESS IS STOPPED HERE ──── (resumed by SIGCONT)

    // Resume: reinstall our handler, re-enter raw mode, and signal
    // the read loop to repaint.
    _ = std.c.sigaction(.TSTP, &prev, null);

    const raw = active_termios_raw.load(.acquire);
    if (raw) |r| {
        if (in_fd >= 0) _ = std.c.tcsetattr(in_fd, .NOW, r);
    }
    if (out_fd >= 0) _ = std.c.write(out_fd, "\x1b[?2004h", 8);

    const pipe_w = active_pipe_write.load(.acquire);
    if (pipe_w >= 0) {
        var b: [1]u8 = .{PipeSignal.cont};
        _ = std.c.write(pipe_w, &b, 1);
    }
}

fn contHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    // Defensive: if we were stopped via SIGSTOP (uncatchable) the
    // SIGTSTP handler never ran — termios is in whatever state the
    // shell put it in. Re-enter raw mode and signal a redraw.
    const raw = active_termios_raw.load(.acquire);
    const in_fd = active_input_fd.load(.acquire);
    if (raw) |r| {
        if (in_fd >= 0) _ = std.c.tcsetattr(in_fd, .NOW, r);
    }
    const out_fd = active_output_fd.load(.acquire);
    if (out_fd >= 0) _ = std.c.write(out_fd, "\x1b[?2004h", 8);
    const pipe_w = active_pipe_write.load(.acquire);
    if (pipe_w >= 0) {
        var b: [1]u8 = .{PipeSignal.cont};
        _ = std.c.write(pipe_w, &b, 1);
    }
}

/// Self-pipe + saved-sigaction bundle. Created during
/// `Terminal.enterRawMode`, destroyed during `leaveRawMode`. The
/// read end of the pipe is exposed via `Terminal.signalPipeFd()`
/// so the input layer can poll on it alongside the tty.
pub const SignalGuard = struct {
    pipe_read: c_int,
    pipe_write: c_int,
    prev_winch: std.c.Sigaction,
    prev_tstp: std.c.Sigaction,
    prev_cont: std.c.Sigaction,
    have_winch: bool = false,
    have_tstp: bool = false,
    have_cont: bool = false,

    pub fn install(
        saved_termios: *const std.c.termios,
        raw_termios: *const std.c.termios,
        input_fd: c_int,
        output_fd: c_int,
    ) !SignalGuard {
        // Atomically claim the global write fd. If somebody else
        // already owns it, we don't try to install handlers — the
        // existing owner stays in charge. This is a nested-editor
        // safety check, not the common path.
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }

        // Both ends nonblocking — handler must never block on write,
        // and the read-loop drain shouldn't block on a partial drain.
        // `std.c.O` is a packed struct on most platforms, so we bit-
        // cast a single-flag literal into the int that fcntl wants.
        const o_nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        const r_flags = std.c.fcntl(fds[0], std.c.F.GETFL, @as(c_int, 0));
        _ = std.c.fcntl(fds[0], std.c.F.SETFL, r_flags | o_nonblock);
        const w_flags = std.c.fcntl(fds[1], std.c.F.GETFL, @as(c_int, 0));
        _ = std.c.fcntl(fds[1], std.c.F.SETFL, w_flags | o_nonblock);
        // Close-on-exec so child processes don't inherit our pipe.
        _ = std.c.fcntl(fds[0], std.c.F.SETFD, @as(c_int, 1)); // FD_CLOEXEC
        _ = std.c.fcntl(fds[1], std.c.F.SETFD, @as(c_int, 1));

        // Prior owner check. -1 means "no active editor."
        const swapped = active_pipe_write.cmpxchgStrong(-1, fds[1], .acq_rel, .acquire);
        if (swapped != null) return error.SignalsAlreadyClaimed;

        active_termios_saved.store(saved_termios, .release);
        active_termios_raw.store(raw_termios, .release);
        active_input_fd.store(input_fd, .release);
        active_output_fd.store(output_fd, .release);

        var guard: SignalGuard = .{
            .pipe_read = fds[0],
            .pipe_write = fds[1],
            .prev_winch = undefined,
            .prev_tstp = undefined,
            .prev_cont = undefined,
        };

        const empty_mask = std.mem.zeroes(std.c.sigset_t);

        const sa_winch: std.c.Sigaction = .{
            .handler = .{ .handler = winchHandler },
            .mask = empty_mask,
            .flags = 0,
        };
        if (std.c.sigaction(.WINCH, &sa_winch, &guard.prev_winch) == 0) {
            guard.have_winch = true;
        }

        const sa_tstp: std.c.Sigaction = .{
            .handler = .{ .handler = tstpHandler },
            .mask = empty_mask,
            .flags = 0,
        };
        if (std.c.sigaction(.TSTP, &sa_tstp, &guard.prev_tstp) == 0) {
            guard.have_tstp = true;
        }

        const sa_cont: std.c.Sigaction = .{
            .handler = .{ .handler = contHandler },
            .mask = empty_mask,
            .flags = 0,
        };
        if (std.c.sigaction(.CONT, &sa_cont, &guard.prev_cont) == 0) {
            guard.have_cont = true;
        }

        return guard;
    }

    pub fn uninstall(self: *SignalGuard) void {
        // Restore the previous sigactions in the reverse order we
        // installed them, then clear the global claim, then close
        // the pipe. Order matters: a signal that fires after we
        // clear the claim but before we close the pipe would no-op
        // safely; the reverse sequence is the dangerous one.
        if (self.have_cont) _ = std.c.sigaction(.CONT, &self.prev_cont, null);
        if (self.have_tstp) _ = std.c.sigaction(.TSTP, &self.prev_tstp, null);
        if (self.have_winch) _ = std.c.sigaction(.WINCH, &self.prev_winch, null);
        active_termios_saved.store(null, .release);
        active_termios_raw.store(null, .release);
        active_input_fd.store(-1, .release);
        active_output_fd.store(-1, .release);
        _ = active_pipe_write.cmpxchgStrong(self.pipe_write, -1, .acq_rel, .acquire);
        _ = std.c.close(self.pipe_read);
        _ = std.c.close(self.pipe_write);
        self.* = undefined;
    }

    /// Drain the read end. Returns the bytes that were queued so the
    /// caller can decide what each means. Called by the input loop
    /// after `poll()` indicates the pipe is readable.
    pub fn drain(self: *const SignalGuard, out: []u8) usize {
        const n = std.c.read(self.pipe_read, out.ptr, out.len);
        if (n <= 0) return 0;
        return @intCast(n);
    }
};

/// Send a `wake` byte on the active editor's signal pipe (if any).
/// Used by `Editor.notifyResize` so the application can synthesize a
/// resize event without an actual SIGWINCH — useful for tests and
/// for callers wiring up their own SIGWINCH path.
pub fn pokeActiveSignalPipe() void {
    const fd = active_pipe_write.load(.acquire);
    if (fd < 0) return;
    var b: [1]u8 = .{PipeSignal.wake};
    _ = std.c.write(fd, &b, 1);
}

/// Ensure the active editor's next render starts on a fresh row.
/// Call this between `readLine` invocations when the embedding
/// application has emitted text to the tty whose cursor position
/// is uncertain — e.g., after a foreground job died via signal
/// (the kernel may have echoed `^C` to the prompt row, and the
/// editor's render-on-readLine would otherwise clear that row
/// before the user sees it).
///
/// Writes `\r\n` to the active editor's output fd. No-op when no
/// editor is currently active. Idempotent ONLY in the sense that
/// calling it twice produces two newlines; callers should call it
/// at most once per "external content was emitted" event.
pub fn pokeActiveFreshRow() void {
    const fd = active_output_fd.load(.acquire);
    if (fd < 0) return;
    _ = std.c.write(fd, "\r\n", 2);
}

pub const Terminal = struct {
    input_fd: std.posix.fd_t,
    output_fd: std.posix.fd_t,
    /// Saved termios for restore on exit. `null` means raw mode is
    /// not currently active.
    saved_termios: ?std.c.termios = null,
    /// Active raw-mode termios. We hold this so the SIGTSTP/SIGCONT
    /// handlers can restore it post-resume without going through the
    /// editor.
    raw_termios: std.c.termios = undefined,
    bracketed_paste_enabled: bool = false,
    signal_guard: ?SignalGuard = null,

    pub fn init(input_fd: std.posix.fd_t, output_fd: std.posix.fd_t) Terminal {
        return .{ .input_fd = input_fd, .output_fd = output_fd };
    }

    pub fn isInputTty(self: *const Terminal) bool {
        return std.c.isatty(self.input_fd) != 0;
    }

    pub fn isOutputTty(self: *const Terminal) bool {
        return std.c.isatty(self.output_fd) != 0;
    }

    /// File descriptor of the read end of the signal self-pipe, or
    /// -1 if signal handlers aren't currently installed. The caller
    /// (typically the input layer) polls on this fd alongside the
    /// tty input so signals wake a blocked read.
    pub fn signalPipeFd(self: *const Terminal) c_int {
        if (self.signal_guard) |*g| return g.pipe_read;
        return -1;
    }

    /// Drain queued signal bytes from the self-pipe. Returns the
    /// number of bytes read (0 if the pipe was empty or signals
    /// aren't installed). The caller inspects each byte via
    /// `PipeSignal` constants to learn what fired.
    pub fn drainSignalPipe(self: *Terminal, buf: []u8) usize {
        if (self.signal_guard) |*g| return g.drain(buf);
        return 0;
    }

    /// True iff a signal-guard is installed at all (some subset of
    /// SIGWINCH/TSTP/CONT may have failed to attach individually).
    /// Most callers want `canSuspendSafely` instead, which checks
    /// the SIGTSTP handler specifically.
    pub fn hasSignalGuard(self: *const Terminal) bool {
        return self.signal_guard != null;
    }

    /// True iff the SIGTSTP handler is installed and ready to
    /// restore termios before the process stops. `SignalGuard.install`
    /// can succeed-with-some-handlers-failing (e.g. `sigaction(TSTP)`
    /// returned non-zero); this method checks the specific handler
    /// that `Editor.dispatch(.suspend_self)` depends on. If false,
    /// `raise(SIGTSTP)` would leave the terminal in raw mode +
    /// bracketed paste — the editor routes to a diagnostic and
    /// no-ops in that case.
    pub fn canSuspendSafely(self: *const Terminal) bool {
        if (self.signal_guard) |g| return g.have_tstp;
        return false;
    }

    pub fn enterRawMode(self: *Terminal) !void {
        if (self.saved_termios != null) return; // already in raw mode

        var saved: std.c.termios = undefined;
        if (std.c.tcgetattr(self.input_fd, &saved) != 0) return error.NotATty;

        var raw = saved;

        // Local flags (cfmakeraw-equivalent — all "cooked" features off).
        raw.lflag.ICANON = false; // byte-at-a-time, no line discipline
        raw.lflag.ECHO = false; // we draw the cursor ourselves
        raw.lflag.ECHONL = false; // and we don't want kernel newline echo either
        raw.lflag.ISIG = false; // Ctrl-C / Ctrl-Z arrive as bytes (keymap dispatches)
        raw.lflag.IEXTEN = false; // Ctrl-V doesn't quote the next byte

        // Input flags (cfmakeraw + UTF-8-friendly).
        raw.iflag.ICRNL = false; // don't auto-translate CR → NL on input
        raw.iflag.IXON = false; // Ctrl-S / Ctrl-Q don't suspend output
        raw.iflag.BRKINT = false; // break doesn't synthesize SIGINT
        raw.iflag.IGNBRK = false; // ... and isn't ignored either
        raw.iflag.PARMRK = false; // no parity-error byte marking
        raw.iflag.INLCR = false; // no NL → CR translation on input
        raw.iflag.IGNCR = false; // don't drop CR
        raw.iflag.INPCK = false; // no parity check
        raw.iflag.ISTRIP = false; // don't strip the 8th bit (UTF-8 needs all 8)

        // Output flags. The big one is OPOST: with ONLCR enabled (the
        // default), our deliberately emitted "\n\r" autowrap-fix
        // becomes "\r\n\r" and the cursor lands one column off. The
        // renderer assumes raw output throughout.
        raw.oflag.OPOST = false;

        // Control flags: 8-bit chars, no parity.
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        // Read returns as soon as 1 byte is available.
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

        if (std.c.tcsetattr(self.input_fd, .NOW, &raw) != 0) return error.SetattrFailed;
        self.saved_termios = saved;
        self.raw_termios = raw;

        // Enable bracketed paste so pasted text doesn't trigger
        // editing keybindings during the paste.
        self.writeAll("\x1b[?2004h") catch {};
        self.bracketed_paste_enabled = true;

        // Install SIGWINCH/SIGTSTP/SIGCONT handlers and a self-pipe
        // for waking up blocked reads. If installation fails (e.g.
        // another zigline instance already owns the slot), we
        // continue without — the editor still works, just less
        // responsive to signals.
        if (self.signal_guard == null) {
            self.signal_guard = SignalGuard.install(
                &self.saved_termios.?,
                &self.raw_termios,
                self.input_fd,
                self.output_fd,
            ) catch null;
        }
    }

    pub fn leaveRawMode(self: *Terminal) void {
        if (self.signal_guard) |*g| {
            g.uninstall();
            self.signal_guard = null;
        }
        if (self.bracketed_paste_enabled) {
            self.writeAll("\x1b[?2004l") catch {};
            self.bracketed_paste_enabled = false;
        }
        if (self.saved_termios) |saved| {
            _ = std.c.tcsetattr(self.input_fd, .NOW, &saved);
            self.saved_termios = null;
        }
    }

    pub fn querySize(self: *const Terminal) Size {
        var ws: std.c.winsize = undefined;
        const rc = std.c.ioctl(self.output_fd, std.c.T.IOCGWINSZ, &ws);
        if (rc < 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    /// Write all `bytes` to the output fd, retrying on EINTR / partial
    /// write. The slash editor used `_ = std.c.write(...)` directly,
    /// which silently dropped partial writes — fixed here per
    /// SPEC.md §14.
    pub fn writeAll(self: *const Terminal, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.output_fd, bytes[off..].ptr, bytes.len - off);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.UnexpectedEof;
            off += @intCast(n);
        }
    }
};

test "terminal: init does not touch fds" {
    const t = Terminal.init(0, 1);
    _ = t;
}

test "terminal: pokeActiveFreshRow writes CRLF to the active output fd" {
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }

    // Stand in for `SignalGuard.install`'s claim — same atomic, same
    // contract, no signal handlers needed for this hook's behavior.
    active_output_fd.store(fds[1], .release);
    defer active_output_fd.store(-1, .release);

    pokeActiveFreshRow();

    var buf: [4]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 2), n);
    try std.testing.expectEqualSlices(u8, "\r\n", buf[0..2]);
}

test "terminal: pokeActiveFreshRow is a no-op when no editor is active" {
    // Sanity: with no claim, the call must not crash and must not
    // touch any fd. We assert by confirming the global stays cleared.
    try std.testing.expectEqual(@as(c_int, -1), active_output_fd.load(.acquire));
    pokeActiveFreshRow();
    try std.testing.expectEqual(@as(c_int, -1), active_output_fd.load(.acquire));
}
