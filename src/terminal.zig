//! Terminal — raw mode, size query, fd ownership, terminal modes.
//!
//! See SPEC.md §9. Owns the saved termios for restoration, the
//! input/output fds (borrowed from caller), and the bracketed-paste
//! enable/disable state.
//!
//! The library does not install signal handlers by default — that's
//! application policy. An opt-in `Options.signal_policy` (v0.2) will
//! let callers ask for shell-friendly defaults.
//!
//! POSIX-only. Lifted from slash's `RawMode` (src/repl.zig) with the
//! fd-hardcoding fixed: this module honors the `input_fd` /
//! `output_fd` passed at init.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Terminal = struct {
    input_fd: std.posix.fd_t,
    output_fd: std.posix.fd_t,
    /// Saved termios for restore on exit. `null` means raw mode is
    /// not currently active.
    saved_termios: ?std.c.termios = null,
    bracketed_paste_enabled: bool = false,

    pub fn init(input_fd: std.posix.fd_t, output_fd: std.posix.fd_t) Terminal {
        return .{ .input_fd = input_fd, .output_fd = output_fd };
    }

    pub fn isInputTty(self: *const Terminal) bool {
        return std.c.isatty(self.input_fd) != 0;
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

        // Enable bracketed paste so pasted text doesn't trigger
        // editing keybindings during the paste.
        self.writeAll("\x1b[?2004h") catch {};
        self.bracketed_paste_enabled = true;
    }

    pub fn leaveRawMode(self: *Terminal) void {
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
