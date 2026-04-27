//! Input — byte stream → typed events.
//!
//! See SPEC.md §4. Reads bytes from a file descriptor and emits typed
//! events: keystrokes, paste payloads, EOF, errors.
//!
//! State machine:
//!   - direct byte 0x00–0x1f → C0 control (named keys / ctrl-letter)
//!   - 0x20–0x7e            → ASCII printable → KeyCode.char
//!   - 0x7f                  → backspace (DEL convention)
//!   - 0x80+                 → UTF-8 lead → decode → KeyCode.char
//!   - ESC (0x1b)            → enter escape state, dispatch on next byte
//!     - '['                 → CSI: parse parameters until final byte
//!     - 'O'                 → SS3: parse single final byte
//!     - any other char      → Alt-modified key
//!     - end of input        → bare `escape`
//!
//! Bracketed paste: `\x1b[200~ … \x1b[201~` becomes one `paste` event
//! with the unescaped payload.
//!
//! Lifted from slash's `readLine` (src/repl.zig) with the narrow
//! 2-byte escape parser replaced by a real state machine per
//! SPEC.md §14.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

// =============================================================================
// Event types — see SPEC.md §4
// =============================================================================

pub const Event = union(enum) {
    key: KeyEvent,
    paste: []const u8,
    resize,
    eof,
    error_: anyerror,
};

pub const KeyEvent = struct {
    code: KeyCode,
    mods: Modifiers = .{},
};

pub const KeyCode = union(enum) {
    char: u21,
    text: []const u8,
    function: u8,
    enter,
    tab,
    backspace,
    delete,
    escape,
    home,
    end,
    page_up,
    page_down,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    insert,
    unknown: []const u8,
};

pub const Modifiers = packed struct(u3) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

// =============================================================================
// Reader
// =============================================================================

const READ_BUF_SIZE = 256;

pub const Reader = struct {
    allocator: Allocator,
    fd: std.posix.fd_t,
    /// Optional read end of the signal self-pipe. When >=0, every
    /// blocking read also polls on this fd; readability surfaces
    /// non-keystroke events (resize, suspend/resume).
    signal_pipe_fd: c_int = -1,
    /// Pending bytes from a previous read, not yet consumed by the
    /// state machine (e.g. partial CSI).
    pending: [READ_BUF_SIZE]u8 = undefined,
    pending_len: usize = 0,
    /// Owned buffer for paste / unknown / text events; the returned
    /// event borrows from this and is valid only until the next call.
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// Set whenever a signal-pipe drain saw at least one byte, so
    /// the next `next()` call can yield `Event.resize` before going
    /// back to the keystroke read.
    signal_pending: bool = false,

    pub fn init(allocator: Allocator, fd: std.posix.fd_t) Reader {
        return .{ .allocator = allocator, .fd = fd };
    }

    pub fn deinit(self: *Reader) void {
        self.scratch.deinit(self.allocator);
    }

    /// Set or clear the signal self-pipe read fd. Called by the
    /// editor after entering raw mode (where the pipe is created)
    /// and again on leaveRawMode to clear it.
    pub fn setSignalPipe(self: *Reader, fd: c_int) void {
        self.signal_pipe_fd = fd;
    }

    /// Block until the next event is available.
    pub fn next(self: *Reader) Event {
        // Drain any signal byte queued from the previous wake — emit
        // one .resize event per call so the editor can render once
        // even if multiple signals coalesced.
        if (self.signal_pending) {
            self.signal_pending = false;
            return .resize;
        }
        while (true) {
            const byte = self.readByte() catch |err| switch (err) {
                error.Eof => return .eof,
                error.SignalEvent => {
                    self.signal_pending = false;
                    return .resize;
                },
                else => return .{ .error_ = err },
            };
            if (self.dispatch(byte)) |ev| return ev;
        }
    }

    /// Read one byte, blocking. Loops on EINTR/EAGAIN. Returns
    /// `error.SignalEvent` if the signal self-pipe woke us; the
    /// caller should surface this as an `Event.resize` and try again.
    fn readByte(self: *Reader) !u8 {
        if (self.pending_len > 0) return self.popPending();
        if (self.signal_pipe_fd >= 0) {
            try self.waitForReadable();
        }
        var byte: [1]u8 = undefined;
        while (true) {
            const n = std.c.read(self.fd, &byte, 1);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) {
                    // EINTR after a poll means a signal arrived
                    // between poll() and read(); treat it as a
                    // signal-event so the read loop re-renders.
                    if (self.signal_pipe_fd >= 0) {
                        self.drainSignalBytes();
                        return error.SignalEvent;
                    }
                    continue;
                }
                return error.ReadFailed;
            }
            if (n == 0) return error.Eof;
            return byte[0];
        }
    }

    /// Block on poll() of {tty_fd, signal_pipe_fd}. Returns when the
    /// tty has a byte ready. If the signal pipe wakes first, drain
    /// and return `error.SignalEvent` so the caller surfaces a
    /// resize event.
    fn waitForReadable(self: *Reader) !void {
        var pfds: [2]std.c.pollfd = .{
            .{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = self.signal_pipe_fd, .events = std.c.POLL.IN, .revents = 0 },
        };
        while (true) {
            const rc = std.c.poll(@ptrCast(&pfds), 2, -1);
            if (rc < 0) {
                const e = std.c.errno(rc);
                if (e == .INTR) {
                    self.drainSignalBytes();
                    return error.SignalEvent;
                }
                return error.ReadFailed;
            }
            if (pfds[1].revents & std.c.POLL.IN != 0) {
                self.drainSignalBytes();
                return error.SignalEvent;
            }
            if (pfds[0].revents & std.c.POLL.IN != 0) return;
            // Spurious wake: loop.
        }
    }

    fn drainSignalBytes(self: *Reader) void {
        if (self.signal_pipe_fd < 0) return;
        var buf: [16]u8 = undefined;
        while (true) {
            const n = std.c.read(self.signal_pipe_fd, &buf, buf.len);
            if (n <= 0) break;
        }
    }

    /// Read one byte with a millisecond-bounded wait. Used for escape
    /// sequence disambiguation: bare ESC must time out within ~50ms
    /// instead of hanging forever, while CSI/SS3 sequence bodies
    /// (whose bytes are sent back-to-back by every real terminal)
    /// resolve well within the window. If the signal self-pipe is
    /// active, also polls it and stashes a pending resize for the
    /// next `next()` call.
    fn readByteWithin(self: *Reader, timeout_ms: i32) ?u8 {
        if (self.pending_len > 0) return self.popPending();
        if (self.signal_pipe_fd < 0) {
            var pfd: std.c.pollfd = .{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 };
            while (true) {
                const rc = std.c.poll(@ptrCast(&pfd), 1, timeout_ms);
                if (rc < 0) {
                    if (std.c.errno(rc) == .INTR) continue;
                    return null;
                }
                if (rc == 0) return null;
                break;
            }
            return self.readByte() catch null;
        }
        var pfds: [2]std.c.pollfd = .{
            .{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = self.signal_pipe_fd, .events = std.c.POLL.IN, .revents = 0 },
        };
        while (true) {
            const rc = std.c.poll(@ptrCast(&pfds), 2, timeout_ms);
            if (rc < 0) {
                if (std.c.errno(rc) == .INTR) {
                    self.drainSignalBytes();
                    self.signal_pending = true;
                    continue;
                }
                return null;
            }
            if (rc == 0) return null;
            if ((pfds[1].revents & std.c.POLL.IN) != 0) {
                self.drainSignalBytes();
                self.signal_pending = true;
            }
            if ((pfds[0].revents & std.c.POLL.IN) != 0) {
                return self.readByte() catch null;
            }
            // Only the signal pipe woke us; this is a "timeout" from
            // the parser's perspective — it'll fall back to ESC and
            // the next `next()` call surfaces the resize.
            if (self.signal_pending) return null;
        }
    }

    fn popPending(self: *Reader) u8 {
        const b = self.pending[0];
        std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - 1], self.pending[1..self.pending_len]);
        self.pending_len -= 1;
        return b;
    }

    /// Push a byte back to the front of the pending queue. Used when
    /// a parser speculatively consumes a byte that turned out not to
    /// belong to it (e.g. an invalid UTF-8 continuation that's
    /// actually a fresh keystroke).
    fn pushBack(self: *Reader, byte: u8) void {
        if (self.pending_len >= self.pending.len) return; // drop on overflow
        if (self.pending_len > 0) {
            std.mem.copyBackwards(
                u8,
                self.pending[1 .. self.pending_len + 1],
                self.pending[0..self.pending_len],
            );
        }
        self.pending[0] = byte;
        self.pending_len += 1;
    }

    /// Push a slice of bytes back to the front of the pending queue,
    /// preserving their order on subsequent reads. Used to recover
    /// consumed bytes after a CSI / SS3 sequence times out mid-parse.
    fn pushBackBytes(self: *Reader, bytes: []const u8) void {
        var i = bytes.len;
        while (i > 0) {
            i -= 1;
            self.pushBack(bytes[i]);
        }
    }

    fn dispatch(self: *Reader, b0: u8) ?Event {
        switch (b0) {
            0x00 => return .{ .key = .{ .code = .{ .char = 0 }, .mods = .{ .ctrl = true } } },
            0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => {
                // Ctrl-A through Ctrl-Z, minus the named ones below.
                return .{ .key = .{ .code = .{ .char = @as(u21, b0) + 0x60 }, .mods = .{ .ctrl = true } } };
            },
            0x08 => return .{ .key = .{ .code = .backspace } }, // BS
            0x09 => return .{ .key = .{ .code = .tab } }, // TAB
            0x0a, 0x0d => return .{ .key = .{ .code = .enter } }, // LF, CR
            0x1b => return self.parseEscape(),
            0x1c, 0x1d, 0x1e, 0x1f => {
                return .{ .key = .{ .code = .{ .char = @as(u21, b0) + 0x40 }, .mods = .{ .ctrl = true } } };
            },
            0x7f => return .{ .key = .{ .code = .backspace } }, // DEL → backspace
            0x20...0x7e => return .{ .key = .{ .code = .{ .char = @as(u21, b0) } } },
            else => return self.parseUtf8(b0),
        }
    }

    fn parseUtf8(self: *Reader, b0: u8) ?Event {
        const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch {
            // Invalid lead byte — drop b0 alone. Don't read ahead.
            self.scratch.clearRetainingCapacity();
            self.scratch.append(self.allocator, b0) catch return .{ .error_ = error.OutOfMemory };
            return .{ .key = .{ .code = .{ .unknown = self.scratch.items } } };
        };
        var bytes: [4]u8 = undefined;
        bytes[0] = b0;
        var i: usize = 1;
        while (i < seq_len) : (i += 1) {
            // UTF-8 continuation bytes follow the lead immediately on
            // every well-behaved input source. A 50ms wait absorbs
            // jitter without letting a malformed/silent stream wedge
            // the editor on a single lead byte forever.
            const b = self.readByteWithin(50) orelse {
                self.scratch.clearRetainingCapacity();
                self.scratch.appendSlice(self.allocator, bytes[0..i]) catch return .{ .error_ = error.OutOfMemory };
                return .{ .key = .{ .code = .{ .unknown = self.scratch.items } } };
            };
            // Each follow-on byte must be a UTF-8 continuation byte
            // (0x80-0xBF). Anything else is the start of a fresh
            // event; push it back and abandon this sequence.
            if (b < 0x80 or b > 0xBF) {
                self.pushBack(b);
                self.scratch.clearRetainingCapacity();
                self.scratch.appendSlice(self.allocator, bytes[0..i]) catch return .{ .error_ = error.OutOfMemory };
                return .{ .key = .{ .code = .{ .unknown = self.scratch.items } } };
            }
            bytes[i] = b;
        }
        const cp = std.unicode.utf8Decode(bytes[0..seq_len]) catch {
            self.scratch.clearRetainingCapacity();
            self.scratch.appendSlice(self.allocator, bytes[0..seq_len]) catch return .{ .error_ = error.OutOfMemory };
            return .{ .key = .{ .code = .{ .unknown = self.scratch.items } } };
        };
        return .{ .key = .{ .code = .{ .char = cp } } };
    }

    fn parseEscape(self: *Reader) ?Event {
        // ESC may be a bare keystroke OR the start of a CSI/SS3 escape
        // sequence. We disambiguate by waiting briefly: real terminals
        // send the rest of an escape sequence within microseconds, so
        // a 50ms wait separates the two cases without making bare-ESC
        // feel laggy. Tradeoff: an over-network terminal that splits
        // a CSI across packets >50ms apart will be misread as bare
        // ESC, which is rare in practice and recoverable (the user
        // re-presses the key).
        const b1 = self.readByteWithin(50) orelse {
            return .{ .key = .{ .code = .escape } };
        };
        switch (b1) {
            '[' => return self.parseCsi(),
            'O' => return self.parseSs3(),
            else => {
                if (b1 >= 0x20 and b1 <= 0x7e) {
                    return .{ .key = .{ .code = .{ .char = @as(u21, b1) }, .mods = .{ .alt = true } } };
                }
                if (b1 == 0x7f) {
                    return .{ .key = .{ .code = .backspace, .mods = .{ .alt = true } } };
                }
                return .{ .key = .{ .code = .escape } };
            },
        }
    }

    fn parseCsi(self: *Reader) ?Event {
        // CSI: read parameters (digits and ';') until a final byte
        // (0x40–0x7e). Bracketed paste markers `\x1b[200~`/`\x1b[201~`
        // are a special CSI; we recognize them after parsing.
        var params: [16]u8 = undefined;
        var plen: usize = 0;
        var final: u8 = 0;
        while (true) {
            const b = self.readByteWithin(50) orelse {
                // Timeout: terminal didn't finish the CSI sequence.
                // Push back the bytes we already consumed (`[` plus
                // any params) so the next reads re-dispatch them as
                // ordinary keystrokes — silent data loss is far
                // worse than a misread on a slow link. Pattern lifted
                // from isocline (`tty_esc.c:255`, the `// recover`
                // comment).
                self.pushBackBytes(params[0..plen]);
                self.pushBack('[');
                return .{ .key = .{ .code = .escape } };
            };
            if (b >= 0x40 and b <= 0x7e) {
                final = b;
                break;
            }
            if (plen < params.len) {
                params[plen] = b;
                plen += 1;
            }
        }
        const param_slice = params[0..plen];

        // Bracketed paste open: `\x1b[200~`
        if (final == '~' and std.mem.eql(u8, param_slice, "200")) {
            return self.parsePastePayload();
        }

        // Strip trailing modifier suffix (e.g. `1;5D` → arrow with
        // modifiers). For v0.0 we ignore mod values; just look at the
        // final byte.
        const mods = parseCsiMods(param_slice);

        switch (final) {
            'A' => return .{ .key = .{ .code = .arrow_up, .mods = mods } },
            'B' => return .{ .key = .{ .code = .arrow_down, .mods = mods } },
            'C' => return .{ .key = .{ .code = .arrow_right, .mods = mods } },
            'D' => return .{ .key = .{ .code = .arrow_left, .mods = mods } },
            'H' => return .{ .key = .{ .code = .home, .mods = mods } },
            'F' => return .{ .key = .{ .code = .end, .mods = mods } },
            'Z' => return .{ .key = .{ .code = .tab, .mods = .{ .shift = true } } }, // Shift-Tab
            '~' => {
                // Numeric keycodes: 1=Home 2=Insert 3=Delete 4=End
                // 5=PgUp 6=PgDn 7=Home 8=End 11..15=F1..F5 17..21=F6..F10
                // 23=F11 24=F12
                const n = parseFirstNumber(param_slice);
                return .{ .key = .{ .code = csiTildeCode(n), .mods = mods } };
            },
            else => {
                // Unknown final — emit unknown with the full sequence.
                self.scratch.clearRetainingCapacity();
                self.scratch.append(self.allocator, 0x1b) catch return .{ .error_ = error.OutOfMemory };
                self.scratch.append(self.allocator, '[') catch return .{ .error_ = error.OutOfMemory };
                self.scratch.appendSlice(self.allocator, param_slice) catch return .{ .error_ = error.OutOfMemory };
                self.scratch.append(self.allocator, final) catch return .{ .error_ = error.OutOfMemory };
                return .{ .key = .{ .code = .{ .unknown = self.scratch.items } } };
            },
        }
    }

    fn parseSs3(self: *Reader) ?Event {
        const b = self.readByteWithin(50) orelse {
            // Same recovery as parseCsi: push the consumed `O` back
            // so the user sees ESC + 'O' separately rather than
            // losing the keystroke entirely.
            self.pushBack('O');
            return .{ .key = .{ .code = .escape } };
        };
        return switch (b) {
            'A' => .{ .key = .{ .code = .arrow_up } },
            'B' => .{ .key = .{ .code = .arrow_down } },
            'C' => .{ .key = .{ .code = .arrow_right } },
            'D' => .{ .key = .{ .code = .arrow_left } },
            'H' => .{ .key = .{ .code = .home } },
            'F' => .{ .key = .{ .code = .end } },
            'P' => .{ .key = .{ .code = .{ .function = 1 } } },
            'Q' => .{ .key = .{ .code = .{ .function = 2 } } },
            'R' => .{ .key = .{ .code = .{ .function = 3 } } },
            'S' => .{ .key = .{ .code = .{ .function = 4 } } },
            else => blk: {
                self.scratch.clearRetainingCapacity();
                self.scratch.append(self.allocator, 0x1b) catch break :blk .{ .error_ = error.OutOfMemory };
                self.scratch.append(self.allocator, 'O') catch break :blk .{ .error_ = error.OutOfMemory };
                self.scratch.append(self.allocator, b) catch break :blk .{ .error_ = error.OutOfMemory };
                break :blk .{ .key = .{ .code = .{ .unknown = self.scratch.items } } };
            },
        };
    }

    fn parsePastePayload(self: *Reader) ?Event {
        // Read until we see the close marker `\x1b[201~`.
        self.scratch.clearRetainingCapacity();
        const close = "\x1b[201~";
        var match_idx: usize = 0;
        while (true) {
            const b = self.readByte() catch return .{ .error_ = error.ReadFailed };
            if (b == close[match_idx]) {
                match_idx += 1;
                if (match_idx == close.len) {
                    return .{ .paste = self.scratch.items };
                }
                continue;
            }
            // Mismatch — flush any matched prefix into the payload.
            if (match_idx > 0) {
                self.scratch.appendSlice(self.allocator, close[0..match_idx]) catch return .{ .error_ = error.OutOfMemory };
                match_idx = 0;
            }
            // Re-check the just-read byte against the start of the
            // close marker.
            if (b == close[0]) {
                match_idx = 1;
                continue;
            }
            self.scratch.append(self.allocator, b) catch return .{ .error_ = error.OutOfMemory };
        }
    }
};

fn parseCsiMods(params: []const u8) Modifiers {
    // CSI parameters are `;`-separated. Modifier value is the second
    // (e.g. `1;5D` → mod 5 = ctrl). Mod encoding:
    //   2 = Shift
    //   3 = Alt
    //   4 = Shift+Alt
    //   5 = Ctrl
    //   6 = Ctrl+Shift
    //   7 = Ctrl+Alt
    //   8 = Ctrl+Alt+Shift
    var it = std.mem.splitScalar(u8, params, ';');
    _ = it.next();
    const mod_str = it.next() orelse return .{};
    const mod = std.fmt.parseInt(u8, mod_str, 10) catch return .{};
    if (mod < 2) return .{};
    const code = mod - 1;
    return .{
        .shift = (code & 1) != 0,
        .alt = (code & 2) != 0,
        .ctrl = (code & 4) != 0,
    };
}

fn parseFirstNumber(params: []const u8) u8 {
    var it = std.mem.splitScalar(u8, params, ';');
    const first = it.next() orelse return 0;
    return std.fmt.parseInt(u8, first, 10) catch 0;
}

fn csiTildeCode(n: u8) KeyCode {
    return switch (n) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11 => .{ .function = 1 },
        12 => .{ .function = 2 },
        13 => .{ .function = 3 },
        14 => .{ .function = 4 },
        15 => .{ .function = 5 },
        17 => .{ .function = 6 },
        18 => .{ .function = 7 },
        19 => .{ .function = 8 },
        20 => .{ .function = 9 },
        21 => .{ .function = 10 },
        23 => .{ .function = 11 },
        24 => .{ .function = 12 },
        else => .{ .unknown = "" },
    };
}

test "input: parseCsiMods" {
    try std.testing.expectEqual(Modifiers{ .ctrl = true }, parseCsiMods("1;5"));
    try std.testing.expectEqual(Modifiers{ .shift = true }, parseCsiMods("1;2"));
    try std.testing.expectEqual(Modifiers{}, parseCsiMods("1"));
    try std.testing.expectEqual(
        Modifiers{ .ctrl = true, .shift = true },
        parseCsiMods("1;6"),
    );
    try std.testing.expectEqual(
        Modifiers{ .ctrl = true, .alt = true },
        parseCsiMods("1;7"),
    );
}

test "input: csiTildeCode" {
    try std.testing.expectEqual(KeyCode.delete, csiTildeCode(3));
    try std.testing.expectEqual(KeyCode.home, csiTildeCode(1));
    try std.testing.expectEqual(KeyCode.end, csiTildeCode(4));
    try std.testing.expectEqual(KeyCode.page_up, csiTildeCode(5));
    try std.testing.expectEqual(KeyCode.page_down, csiTildeCode(6));
    try std.testing.expectEqual(KeyCode.insert, csiTildeCode(2));
}

test "input: csiTildeCode function keys" {
    const want = [_]struct { n: u8, f: u8 }{
        .{ .n = 11, .f = 1 },  .{ .n = 12, .f = 2 },  .{ .n = 13, .f = 3 },
        .{ .n = 14, .f = 4 },  .{ .n = 15, .f = 5 },  .{ .n = 17, .f = 6 },
        .{ .n = 18, .f = 7 },  .{ .n = 19, .f = 8 },  .{ .n = 20, .f = 9 },
        .{ .n = 21, .f = 10 }, .{ .n = 23, .f = 11 }, .{ .n = 24, .f = 12 },
    };
    for (want) |w| {
        const code = csiTildeCode(w.n);
        switch (code) {
            .function => |f| try std.testing.expectEqual(w.f, f),
            else => return error.TestUnexpectedResult,
        }
    }
}

// =============================================================================
// Reader-driven parser tests, using a pipe instead of a real terminal.
// =============================================================================

const PipePair = struct {
    read: std.posix.fd_t,
    write: std.posix.fd_t,

    fn open() !PipePair {
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        return .{ .read = fds[0], .write = fds[1] };
    }

    fn close(self: PipePair) void {
        _ = std.c.close(self.read);
        _ = std.c.close(self.write);
    }

    fn writeAll(self: PipePair, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.write, bytes.ptr + off, bytes.len - off);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.WriteEof;
            off += @intCast(n);
        }
    }
};

test "input: parses CSI arrow sequences end-to-end" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1b[A\x1b[B\x1b[C\x1b[D");

    try std.testing.expectEqual(KeyCode.arrow_up, r.next().key.code);
    try std.testing.expectEqual(KeyCode.arrow_down, r.next().key.code);
    try std.testing.expectEqual(KeyCode.arrow_right, r.next().key.code);
    try std.testing.expectEqual(KeyCode.arrow_left, r.next().key.code);
}

test "input: ctrl-arrow yields word-move modifier" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1b[1;5D");
    const ev = r.next().key;
    try std.testing.expectEqual(KeyCode.arrow_left, ev.code);
    try std.testing.expect(ev.mods.ctrl);
}

test "input: bracketed paste payload comes through whole" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1b[200~hello world\x1b[201~");
    switch (r.next()) {
        .paste => |payload| try std.testing.expectEqualStrings("hello world", payload),
        else => return error.TestUnexpectedResult,
    }
}

test "input: UTF-8 multi-byte char decodes to one event" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    // 'é' = 0xC3 0xA9 = U+00E9.
    try pp.writeAll("\xC3\xA9");
    const ev = r.next().key;
    switch (ev.code) {
        .char => |c| try std.testing.expectEqual(@as(u21, 0xE9), c),
        else => return error.TestUnexpectedResult,
    }
}

test "input: tab and shift-tab" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\t\x1b[Z");
    try std.testing.expectEqual(KeyCode.tab, r.next().key.code);
    const shifted = r.next().key;
    try std.testing.expectEqual(KeyCode.tab, shifted.code);
    try std.testing.expect(shifted.mods.shift);
}

test "input: tilde-form Home/End/Delete/PageUp" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1b[1~\x1b[4~\x1b[3~\x1b[5~");
    try std.testing.expectEqual(KeyCode.home, r.next().key.code);
    try std.testing.expectEqual(KeyCode.end, r.next().key.code);
    try std.testing.expectEqual(KeyCode.delete, r.next().key.code);
    try std.testing.expectEqual(KeyCode.page_up, r.next().key.code);
}

test "input: SS3 function keys" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1bOP\x1bOQ\x1bOR\x1bOS");
    inline for (&[_]u8{ 1, 2, 3, 4 }) |want| {
        const code = r.next().key.code;
        switch (code) {
            .function => |f| try std.testing.expectEqual(want, f),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "input: CSI timeout pushes consumed bytes back" {
    // ESC + '[' + '1' + ';' + '5' with no final byte — historically
    // this dropped all five bytes; now they recover as ordinary
    // events: escape, '[', '1', ';', '5'.
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1b[1;5");
    // Close the write end so the reader sees EOF after timeout.
    _ = std.c.close(pp.write);

    try std.testing.expectEqual(KeyCode.escape, r.next().key.code);
    {
        const ev = r.next().key;
        switch (ev.code) {
            .char => |c| try std.testing.expectEqual(@as(u21, '['), c),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const ev = r.next().key;
        switch (ev.code) {
            .char => |c| try std.testing.expectEqual(@as(u21, '1'), c),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const ev = r.next().key;
        switch (ev.code) {
            .char => |c| try std.testing.expectEqual(@as(u21, ';'), c),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const ev = r.next().key;
        switch (ev.code) {
            .char => |c| try std.testing.expectEqual(@as(u21, '5'), c),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "input: SS3 timeout pushes back the 'O'" {
    const pp = try PipePair.open();
    defer pp.close();

    var r = Reader.init(std.testing.allocator, pp.read);
    defer r.deinit();

    try pp.writeAll("\x1bO");
    _ = std.c.close(pp.write);

    try std.testing.expectEqual(KeyCode.escape, r.next().key.code);
    const ev = r.next().key;
    switch (ev.code) {
        .char => |c| try std.testing.expectEqual(@as(u21, 'O'), c),
        else => return error.TestUnexpectedResult,
    }
}
