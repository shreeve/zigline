//! PTY-driven tests for zigline.
//!
//! Each test allocates a fresh pseudo-terminal via `posix_openpt` /
//! `grantpt` / `unlockpt` / `ptsname`, forks an example program with
//! the slave end as its stdin/stdout, and drives keystrokes through
//! the master end. Lifted from slash's pty_tests.zig with the binary
//! path and the test cases adapted to drive `zig-out/bin/minimal`.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn setsid() std.c.pid_t;

const ioctl_with_ulong_request = struct {
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
}.ioctl;

const TIOCSWINSZ: c_ulong = switch (builtin.target.os.tag) {
    .linux => 0x5414,
    .macos, .ios, .driverkit, .maccatalyst, .tvos, .visionos, .watchos => 0x80087467,
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x80087467,
    else => 0x80087467,
};

fn setWinsize(master: c_int, rows: u16, cols: u16) void {
    var ws: std.c.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    _ = ioctl_with_ulong_request(master, TIOCSWINSZ, &ws);
}

const O_RDWR: c_int = 2;
const O_NOCTTY: c_int = switch (builtin.target.os.tag) {
    .macos, .ios => 0x20000,
    .linux => 0o400,
    else => 0,
};

/// Default path to the example the harness drives. Tests that need a
/// different example pass an override into `runScript`.
const example_bin = "zig-out/bin/minimal";

const PtyPair = struct {
    master: c_int,
    slave: c_int,
    slave_path: [256]u8,

    fn open() !PtyPair {
        const master = posix_openpt(O_RDWR | O_NOCTTY);
        if (master < 0) return error.OpenPtFailed;
        errdefer _ = std.c.close(master);

        if (grantpt(master) != 0) return error.GrantPtFailed;
        if (unlockpt(master) != 0) return error.UnlockPtFailed;

        const name_ptr = ptsname(master) orelse return error.PtsnameFailed;
        const name = std.mem.span(name_ptr);

        var path_buf: [256]u8 = undefined;
        if (name.len + 1 > path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..name.len], name);
        path_buf[name.len] = 0;

        const slave = std.c.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (slave < 0) return error.OpenSlaveFailed;

        return .{ .master = master, .slave = slave, .slave_path = path_buf };
    }
};

const Spawned = struct {
    pid: std.c.pid_t,
    master: c_int,

    fn send(self: Spawned, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteEof;
            off += @intCast(n);
        }
    }

    fn drain(
        self: Spawned,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        deadline_ms: i64,
    ) !void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (try waitReadable(self.master, deadline_ms)) {
                const n = std.c.read(self.master, &chunk, chunk.len);
                if (n < 0) {
                    const e = std.c.errno(@as(c_int, -1));
                    if (e == .INTR) continue;
                    if (e == .IO) return; // PTY master returns EIO when slave closes
                    return error.ReadFailed;
                }
                if (n == 0) return; // EOF
                try out.appendSlice(alloc, chunk[0..@intCast(n)]);
            } else {
                return; // deadline
            }
        }
    }

    fn reap(self: Spawned) u8 {
        var status: c_int = 0;
        while (true) {
            const r = std.c.waitpid(self.pid, &status, 0);
            if (r >= 0) break;
            const e = std.c.errno(r);
            if (e == .INTR) continue;
            return 0;
        }
        const ux: u32 = @bitCast(status);
        if (std.c.W.IFEXITED(ux)) return std.c.W.EXITSTATUS(ux);
        return 128;
    }

    fn close(self: Spawned) void {
        _ = std.c.close(self.master);
    }
};

fn waitReadable(fd: c_int, deadline_ms: i64) !bool {
    var pfd: std.c.pollfd = .{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 };
    const rc = std.c.poll(@ptrCast(&pfd), 1, @intCast(deadline_ms));
    if (rc < 0) {
        const e = std.c.errno(rc);
        if (e == .INTR) return false;
        return error.PollFailed;
    }
    return rc > 0;
}

fn ptySupported() bool {
    return switch (builtin.target.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

fn spawnExample(bin_path: []const u8, args: []const []const u8) !Spawned {
    if (bin_path.len + 1 > 256) return error.PathTooLong;
    var bin_buf: [256]u8 = undefined;
    @memcpy(bin_buf[0..bin_path.len], bin_path);
    bin_buf[bin_path.len] = 0;

    const pty = try PtyPair.open();

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = std.c.close(pty.master);
        _ = setsid();

        _ = std.c.dup2(pty.slave, 0);
        _ = std.c.dup2(pty.slave, 1);
        _ = std.c.dup2(pty.slave, 2);
        if (pty.slave > 2) _ = std.c.close(pty.slave);

        var argv_buf: [16]?[*:0]const u8 = undefined;
        var i: usize = 0;
        argv_buf[i] = @ptrCast(&bin_buf);
        i += 1;

        var arg_storage: [16][256]u8 = undefined;
        for (args) |a| {
            if (i + 1 >= argv_buf.len) std.c._exit(127);
            if (a.len + 1 > arg_storage[i].len) std.c._exit(127);
            @memcpy(arg_storage[i][0..a.len], a);
            arg_storage[i][a.len] = 0;
            argv_buf[i] = @ptrCast(&arg_storage[i]);
            i += 1;
        }
        argv_buf[i] = null;

        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(std.c.environ));
        _ = std.c.execve(@ptrCast(&bin_buf), @ptrCast(&argv_buf), envp);
        std.c._exit(127);
    }

    _ = std.c.close(pty.slave);
    return .{ .pid = pid, .master = pty.master };
}

const Step = struct {
    send: ?[]const u8 = null,
    settle_ms: i64 = 100,
};

const ScriptResult = struct { out: []u8, status: u8 };

fn runScript(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    steps: []const Step,
) !ScriptResult {
    return runScriptOn(alloc, example_bin, args, steps);
}

fn runScriptOn(
    alloc: std.mem.Allocator,
    bin_path: []const u8,
    args: []const []const u8,
    steps: []const Step,
) !ScriptResult {
    const child = try spawnExample(bin_path, args);
    defer child.close();

    var collected: std.ArrayListUnmanaged(u8) = .empty;
    defer collected.deinit(alloc);

    for (steps) |step| {
        if (step.send) |bytes| try child.send(bytes);
        try child.drain(alloc, &collected, step.settle_ms);
    }

    try child.drain(alloc, &collected, 1500);
    const status = child.reap();
    return .{ .out = try collected.toOwnedSlice(alloc), .status = status };
}

// =============================================================================
// Tests
// =============================================================================

test "pty: basic line entry echoes input via the example" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "hello world\n" },
        .{ .send = "\x04" }, // Ctrl-D on empty buffer = EOF
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // The example prints `got: hello world` after the line is accepted.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "hello world") != null);
}

test "pty: backspace deletes before submit" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "abcX\x7fY\n" }, // type "abcX", BS, "Y" → "abcY"
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: abcY") != null);
}

test "pty: Ctrl-C cancels in-flight buffer" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "discarded" },
        .{ .send = "\x03" },
        .{ .send = "kept\n" },
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // The accepted line is "kept", not "discarded...kept"
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: kept") != null);
}

test "pty: Ctrl-D on empty line returns EOF" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "\x04" }, // immediately EOF
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
}

test "pty: arrow keys move cursor" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Type "abc", left twice, "X", Enter → "aXbc"
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "abc\x1b[D\x1b[DX\n" },
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: aXbc") != null);
}

test "pty: UTF-8 multibyte text round-trips through readLine" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // "café" — three ASCII + one 2-byte UTF-8 char (é). The shell's
    // typed bytes go through the input parser, the buffer's grapheme
    // index, the renderer, then come back out via the example's
    // `got: {s}` print on accept.
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "café\n" },
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: café") != null);
}

test "pty: word-delete (Ctrl-W) removes the last word" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "foo bar baz\x17\n" }, // Ctrl-W kills "baz"
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: foo bar ") != null);
}

test "pty: kill-to-start (Ctrl-U) clears prefix before cursor" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Type "junkjunkkeep", Ctrl-A (move to start)... no, actually we
    // want to kill backward from end: type "junkjunk", then "keep",
    // Ctrl-A skips, instead use Ctrl-U at end: kills entire line.
    // Better: type "garbagekeep", Home, then forward to "keep", Ctrl-U
    // kills "garbage". For simplicity: type "garbage", Ctrl-U, "kept",
    // Enter → "kept".
    const r = try runScript(alloc, &.{}, &.{
        .{ .send = "garbage\x15kept\n" },
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: kept") != null);
}

test "pty: history Up arrow recalls last submitted line" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // Per-test history file under /tmp; name keyed off the test's pid
    // so concurrent runs don't collide.
    var path_buf: [128]u8 = undefined;
    const pid = std.c.getpid();
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/zigline_test_history_{d}", .{pid});
    {
        var path_z: [128]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&path_z));
    }
    defer {
        var path_z: [128]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&path_z));
    }

    const r = try runScriptOn(alloc, "zig-out/bin/with_history", &.{path}, &.{
        .{ .send = "first\n" },
        .{ .send = "second\n" },
        .{ .send = "\x1b[A\n" }, // Up = recall "second", submit
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);

    try std.testing.expectEqual(@as(u8, 0), r.status);
    // We accepted three lines; the third is the recalled "second".
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, r.out, i, "got: second")) |idx| : (i = idx + 1) {
        count += 1;
    }
    try std.testing.expect(count >= 2);
}

test "pty: completion fills longest common prefix" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // The with_completion example's candidates are
    // {"hello", "world", "wonderful"}. Typing "wo" + Tab sees two
    // matches ("world", "wonderful"), so the editor inserts the LCP
    // "wo" (already typed) and lists the matches — buffer unchanged.
    // Typing "won" + Tab uniquely picks "wonderful" + ' ' → "wonderful ".
    const r = try runScriptOn(alloc, "zig-out/bin/with_completion", &.{}, &.{
        .{ .send = "won\t\n" },
        .{ .send = "\x04" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got: wonderful") != null);
}
