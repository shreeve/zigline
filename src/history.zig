//! History — in-memory navigation + persistent flat-file storage.
//!
//! See SPEC.md §8. One line per entry, UTF-8, no metadata in v0.1.
//! Caller owns construction and passes via `Editor.Options.history`.
//!
//! Lifted from slash's `History` (src/repl.zig) with these changes:
//!   - the persistence path is configured via `HistoryOptions`, not
//!     hardcoded to `~/.slash/history`.
//!   - dedup policy (none / adjacent / all) is applied consistently;
//!     slash's `append` had a bug where exact-duplicate lines still
//!     got persisted (SPEC.md §14).
//!   - `max_entries` prunes at append time.

const std = @import("std");

const buffer_mod = @import("buffer.zig");

pub const Allocator = std.mem.Allocator;

pub const HistoryOptions = struct {
    path: ?[]const u8 = null,
    max_entries: usize = 1000,
    dedupe: Dedupe = .adjacent,
};

pub const Dedupe = enum {
    none,
    adjacent,
    all,
};

pub const History = struct {
    allocator: Allocator,
    options: HistoryOptions,
    entries: std.ArrayListUnmanaged([]u8) = .empty,
    cursor: ?usize = null,
    snapshot: ?[]u8 = null,
    /// Owned copy of options.path so it outlives caller-owned input.
    owned_path: ?[]u8 = null,

    pub fn init(allocator: Allocator, options: HistoryOptions) !History {
        var h: History = .{ .allocator = allocator, .options = options };
        // If `load()` fails after partially populating `h.entries` or
        // after dupe'ing `owned_path`, we'd leak. errdefer cleans up.
        errdefer h.deinit();
        if (options.path) |p| {
            h.owned_path = try allocator.dupe(u8, p);
            try h.load();
        }
        return h;
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
        if (self.snapshot) |s| self.allocator.free(s);
        if (self.owned_path) |p| self.allocator.free(p);
    }

    fn load(self: *History) !void {
        const path = self.owned_path orelse return;
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) return; // missing history is fine
        defer _ = std.c.close(fd);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &chunk, chunk.len);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return; // hard read error: keep what we have so far
            }
            if (n == 0) break;
            try buf.appendSlice(self.allocator, chunk[0..@intCast(n)]);
        }

        var it = std.mem.splitScalar(u8, buf.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            // Sanitize: history files written by other processes
            // (older shells, hand-edited, corrupted) can contain
            // invalid UTF-8 or control bytes. Both would break the
            // buffer's invariants if recalled. Skip bad lines so a
            // single bad entry doesn't poison interactive editing.
            if (!std.unicode.utf8ValidateSlice(line)) continue;
            if (buffer_mod.findUnsafeByte(line) != null) continue;
            // Apply dedup policy at load time too: with `.adjacent`,
            // skip a duplicate of the just-loaded prior entry; with
            // `.all`, drop earlier matches and keep the newest. This
            // means restarting the editor doesn't resurrect duplicates
            // that the policy says shouldn't be there.
            switch (self.options.dedupe) {
                .none => {},
                .adjacent => {
                    if (self.entries.items.len > 0) {
                        const tail = self.entries.items[self.entries.items.len - 1];
                        if (std.mem.eql(u8, tail, line)) continue;
                    }
                },
                .all => {
                    var i: usize = 0;
                    while (i < self.entries.items.len) {
                        if (std.mem.eql(u8, self.entries.items[i], line)) {
                            self.allocator.free(self.entries.items[i]);
                            _ = self.entries.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                },
            }
            const dup = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(dup);
            try self.entries.append(self.allocator, dup);
        }
        self.applyMaxEntries();
    }

    /// Append a line to history.
    ///
    /// **UTF-8 contract.** `line` must be valid UTF-8. The editor's
    /// `Buffer` enforces this on its content, so callers feeding
    /// `Editor.acceptCurrentLine`'s output never violate it.
    /// Embedders calling `append` with externally-sourced bytes
    /// should validate first; we double-check here and return
    /// `error.InvalidUtf8` on failure.
    ///
    /// **Control-byte policy.** Lines from `Editor.acceptCurrentLine`
    /// can contain control bytes the user intentionally inserted via
    /// `quoted_insert` (the documented escape hatch for typing
    /// literal control characters). Such bytes pass through unchanged
    /// here so the feature is preserved within a session. They are
    /// **dropped at next-session `load`** because we can't tell
    /// trusted-user-typed bytes from untrusted-other-process bytes
    /// once the line has been written to disk; the file is the trust
    /// boundary. This means quoted-insert bytes survive Up-arrow
    /// recall in the same session but disappear after restart —
    /// document this in your app if quoted-insert control bytes are
    /// part of your UX.
    ///
    /// **Aliasing safety.** Safe to call with a slice that aliases
    /// an existing history entry (e.g. `h.append(h.entryAt(0).?)`):
    /// the input is duplicated before any state mutation, so dedup
    /// scans don't free their own source.
    pub fn append(self: *History, line: []const u8) !void {
        if (line.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;

        // Dupe FIRST. Subsequent dedup compares against `dup`, not
        // `line`, so freeing an aliased entry mid-loop is safe.
        const dup = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(dup);

        // Adjacent dedup: cheap O(1) check, doesn't mutate state on
        // the no-op path. Compare against `dup` for aliasing safety.
        if (self.options.dedupe == .adjacent and self.entries.items.len > 0) {
            const tail = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, tail, dup)) {
                self.allocator.free(dup);
                return;
            }
        }

        // Reserve in-memory space first; then persist; then commit.
        // Ordering ensures any failure leaves history unchanged:
        // persistence errors don't half-apply, and post-persistence
        // in-memory failures can't happen because capacity is
        // already reserved.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);

        // Persist via `dup` (not `line`) so in-flight aliasing into
        // the entries we're about to mutate doesn't matter.
        try self.persistAppend(dup);

        // `.all` dedup: scan + remove prior matches. AFTER persist so
        // persistence failure doesn't lose duplicates we'd already
        // removed. Compare against `dup` for aliasing safety.
        if (self.options.dedupe == .all) {
            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (std.mem.eql(u8, self.entries.items[i], dup)) {
                    self.allocator.free(self.entries.items[i]);
                    _ = self.entries.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // In-memory commit. Capacity was reserved above so this
        // can't fail.
        self.entries.appendAssumeCapacity(dup);
        self.applyMaxEntries();
    }

    fn applyMaxEntries(self: *History) void {
        if (self.options.max_entries == 0) return;
        while (self.entries.items.len > self.options.max_entries) {
            const oldest = self.entries.orderedRemove(0);
            self.allocator.free(oldest);
        }
    }

    pub fn previous(self: *History, current: []const u8) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            if (self.snapshot) |s| self.allocator.free(s);
            self.snapshot = self.allocator.dupe(u8, current) catch null;
            self.cursor = self.entries.items.len;
        }
        if (self.cursor.? == 0) return null;
        self.cursor = self.cursor.? - 1;
        return self.entries.items[self.cursor.?];
    }

    pub fn next(self: *History) ?[]const u8 {
        const cur = self.cursor orelse return null;
        if (cur + 1 < self.entries.items.len) {
            self.cursor = cur + 1;
            return self.entries.items[cur + 1];
        }
        self.cursor = null;
        if (self.snapshot) |s| return s;
        return "";
    }

    /// Jump to the oldest entry (`M-<` / `beginning-of-history`).
    /// Snapshots the live buffer if not already cursoring. Returns
    /// the oldest entry's text, or null if history is empty.
    pub fn first(self: *History, current: []const u8) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            if (self.snapshot) |s| self.allocator.free(s);
            self.snapshot = self.allocator.dupe(u8, current) catch null;
        }
        self.cursor = 0;
        return self.entries.items[0];
    }

    /// Jump back to the live buffer (`M->` / `end-of-history`),
    /// past the most recent entry. Returns the saved snapshot, or
    /// the empty string if no snapshot was taken (no history
    /// navigation happened first).
    pub fn last(self: *History) ?[]const u8 {
        self.cursor = null;
        if (self.snapshot) |s| return s;
        return "";
    }

    /// Read-only peek at the most-recently-appended entry without
    /// touching the cursor or snapshot. Used by `yank_last_arg` to
    /// pull the last whitespace-separated token from the previous
    /// command. Returns null on empty history.
    pub fn lastEntry(self: *const History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.entries.items.len - 1];
    }

    /// Read-only peek at an arbitrary entry by index, with `0` being
    /// the oldest. Returns null if out of range. Used by `yank_last_arg`
    /// cycling to walk back through prior entries.
    pub fn entryAt(self: *const History, idx: usize) ?[]const u8 {
        if (idx >= self.entries.items.len) return null;
        return self.entries.items[idx];
    }

    /// Number of stored entries (in-memory; persistence is separate).
    pub fn entryCount(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn resetCursor(self: *History) void {
        self.cursor = null;
        if (self.snapshot) |s| {
            self.allocator.free(s);
            self.snapshot = null;
        }
    }

    fn persistAppend(self: *History, line: []const u8) !void {
        const path = self.owned_path orelse return;
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const fd = std.c.open(
            path_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        // Open failures (permission, missing parent dir, ENOSPC on
        // create, etc.) propagate so the caller's diagnostic hook
        // fires. Pre-v0.2.x silently `if (fd < 0) return;`'d.
        if (fd < 0) return error.OpenFailed;
        defer _ = std.c.close(fd);

        // Advisory whole-file lock so two shells writing the same
        // history file don't interleave bytes mid-line. The lock
        // releases automatically on `close(fd)` (the deferred call
        // above) — even on crash, since the kernel cleans up on
        // process exit. Best-effort: if flock fails (e.g. on a
        // filesystem that doesn't support it like NFS-without-lockd),
        // we proceed unlocked; a torn line is still less bad than
        // refusing to persist.
        _ = std.c.flock(fd, std.c.LOCK.EX);
        defer _ = std.c.flock(fd, std.c.LOCK.UN);

        try writeAllRetry(fd, line);
        try writeAllRetry(fd, "\n");
    }

    /// Atomically rewrite the persistent history file with the
    /// current in-memory entries (after dedup + max_entries pruning
    /// have been applied). Used to compact the file when a long-
    /// running session has accumulated duplicates that the
    /// `dedupe = .all` policy already removed in memory but couldn't
    /// remove on disk. Tmp-file + fsync + rename: either the new
    /// file fully replaces the old one, or the old one survives.
    pub fn compact(self: *History) !void {
        const path = self.owned_path orelse return;

        // Build a unique tmp path: `<path>.tmp.<pid>`. The PID-based
        // suffix avoids the predictable `.tmpZ` collision hazard from
        // pre-v0.2.x; combined with `O_EXCL` below, the open fails
        // cleanly if a stale tmp from a crashed prior run exists.
        const pid = std.c.getpid();
        var tmp_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const tmp_path = std.fmt.bufPrintZ(
            &tmp_buf,
            "{s}.tmp.{d}",
            .{ path, pid },
        ) catch return error.PathTooLong;

        const tmp_fd = std.c.open(
            tmp_path.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        if (tmp_fd < 0) return error.OpenFailed;
        var commit = false;
        defer {
            _ = std.c.close(tmp_fd);
            if (!commit) _ = std.c.unlink(tmp_path.ptr);
        }

        for (self.entries.items) |entry| {
            try writeAllRetry(tmp_fd, entry);
            try writeAllRetry(tmp_fd, "\n");
        }
        // Force content to disk before swap. Surface failure: if the
        // backing storage can't durably receive writes, the caller
        // should know rather than getting a silent rename of stale
        // data.
        if (std.c.fsync(tmp_fd) != 0) return error.FsyncFailed;

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        if (std.c.rename(tmp_path.ptr, path_z.ptr) != 0) return error.RenameFailed;
        commit = true;

        // Fsync the parent directory so the rename is durable. Without
        // this, a crash between rename and dir-block-flush can lose
        // the new file. Best-effort: errors here don't undo the
        // already-renamed file.
        fsyncParentDir(path) catch {};
    }
};

/// Open the parent directory of `path` and fsync it. Used by
/// `History.compact` to make the rename(2) durable. Best-effort:
/// the caller treats failures here as non-fatal because the data is
/// already at rest under the target path.
fn fsyncParentDir(path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const dir_slice: []const u8 = if (slash) |s|
        (if (s == 0) "/" else path[0..s])
    else
        ".";
    var dir_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir_slice.len + 1 > dir_buf.len) return error.PathTooLong;
    @memcpy(dir_buf[0..dir_slice.len], dir_slice);
    dir_buf[dir_slice.len] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(&dir_buf);

    const fd = std.c.open(dir_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.fsync(fd) != 0) return error.FsyncFailed;
}

/// Loop-on-EINTR-and-partial-write helper for the history file.
/// `std.c.write` returning a short count is legal POSIX behavior and
/// the bare append the seed shipped silently truncated lines on a
/// SIGINT race or filled disk.
fn writeAllRetry(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR or e == .AGAIN) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.UnexpectedEof;
        off += @intCast(n);
    }
}

test "history: append + navigate" {
    var h = try History.init(std.testing.allocator, .{});
    defer h.deinit();

    try h.append("first");
    try h.append("second");

    try std.testing.expectEqualStrings("second", h.previous("").?);
    try std.testing.expectEqualStrings("first", h.previous("").?);
    try std.testing.expect(h.previous("") == null); // off the top
    try std.testing.expectEqualStrings("second", h.next().?);
    // past-the-end returns the snapshot
    try std.testing.expectEqualStrings("", h.next().?);
}

test "history: first jumps to oldest entry" {
    var h = try History.init(std.testing.allocator, .{});
    defer h.deinit();

    try h.append("a");
    try h.append("b");
    try h.append("c");

    try std.testing.expectEqualStrings("a", h.first("draft").?);
    // After first(), next() walks forward.
    try std.testing.expectEqualStrings("b", h.next().?);
    try std.testing.expectEqualStrings("c", h.next().?);
}

test "history: last restores live snapshot" {
    var h = try History.init(std.testing.allocator, .{});
    defer h.deinit();

    try h.append("a");
    try h.append("b");
    // Walk to oldest first to set up a snapshot.
    _ = h.first("my draft").?;
    // Now jump back.
    try std.testing.expectEqualStrings("my draft", h.last().?);
}

test "history: first on empty history returns null" {
    var h = try History.init(std.testing.allocator, .{});
    defer h.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), h.first(""));
}

test "history: append handles aliased input under .all dedup" {
    // Regression: pre-fix, `.all` dedup compared incoming `line`
    // against entries it freed mid-loop. If `line` aliased one of
    // those entries, post-free reads were use-after-free.
    var h = try History.init(std.testing.allocator, .{ .dedupe = .all });
    defer h.deinit();
    try h.append("alpha");
    try h.append("beta");
    try h.append("alpha");
    // After three appends with .all dedup:
    //   ["alpha"] → ["alpha","beta"] → ["beta","alpha"]
    // entryAt(0) is "beta". Re-appending it via alias must not UAF
    // and should leave entries = ["alpha","beta"].
    const alias = h.entryAt(0).?;
    try h.append(alias);
    try std.testing.expectEqual(@as(usize, 2), h.entryCount());
    try std.testing.expectEqualStrings("beta", h.lastEntry().?);
    try std.testing.expectEqualStrings("alpha", h.entryAt(0).?);
}

test "history: lastEntry / entryAt / entryCount peek without moving cursor" {
    var h = try History.init(std.testing.allocator, .{});
    defer h.deinit();

    try h.append("foo");
    try h.append("bar baz");

    try std.testing.expectEqual(@as(usize, 2), h.entryCount());
    try std.testing.expectEqualStrings("bar baz", h.lastEntry().?);
    try std.testing.expectEqualStrings("foo", h.entryAt(0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), h.entryAt(2));
    // Cursor untouched: previous still walks from newest.
    try std.testing.expectEqualStrings("bar baz", h.previous("").?);
}

test "history: load skips lines with control bytes / invalid UTF-8" {
    // Write a fake history file with one safe + two unsafe lines.
    // After load, only the safe line should be in memory.
    const path = "/tmp/zigline-test-history-bad.txt";
    {
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        const fd = std.c.open(
            path_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        // Three lines: safe, ESC-injected, invalid-UTF-8.
        const data = "safe line\n\x1b[2Jbad\nbad\xff\xfeutf8\n";
        _ = std.c.write(fd, data.ptr, data.len);
    }
    defer _ = std.c.unlink(@ptrCast(@constCast("/tmp/zigline-test-history-bad.txt")));

    var h = try History.init(std.testing.allocator, .{ .path = path });
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 1), h.entryCount());
    try std.testing.expectEqualStrings("safe line", h.entryAt(0).?);
}

test "history: dedup adjacent skips repeat" {
    var h = try History.init(std.testing.allocator, .{ .dedupe = .adjacent });
    defer h.deinit();

    try h.append("ls");
    try h.append("ls");
    try h.append("cd /");

    try std.testing.expectEqual(@as(usize, 2), h.entries.items.len);
}

test "history: dedup all removes earlier copies" {
    var h = try History.init(std.testing.allocator, .{ .dedupe = .all });
    defer h.deinit();

    try h.append("a");
    try h.append("b");
    try h.append("a");

    try std.testing.expectEqual(@as(usize, 2), h.entries.items.len);
    try std.testing.expectEqualStrings("b", h.entries.items[0]);
    try std.testing.expectEqualStrings("a", h.entries.items[1]);
}

test "history: max_entries prunes oldest" {
    var h = try History.init(std.testing.allocator, .{ .max_entries = 3 });
    defer h.deinit();

    try h.append("a");
    try h.append("b");
    try h.append("c");
    try h.append("d");

    try std.testing.expectEqual(@as(usize, 3), h.entries.items.len);
    try std.testing.expectEqualStrings("b", h.entries.items[0]);
    try std.testing.expectEqualStrings("d", h.entries.items[2]);
}

test "history: compact rewrites file with current in-memory entries" {
    const path = "/tmp/zigline_history_compact_test";
    {
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
    }
    defer {
        const path_z = std.testing.allocator.dupeZ(u8, path) catch unreachable;
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
    }

    var h = try History.init(std.testing.allocator, .{
        .path = path,
        .dedupe = .all,
    });
    defer h.deinit();
    try h.append("alpha");
    try h.append("beta");
    try h.append("alpha"); // moves "alpha" to the end in memory; file
                            //    still has the duplicate appended literally
    try h.compact();

    // Re-open and verify the on-disk file matches the in-memory state.
    var h2 = try History.init(std.testing.allocator, .{
        .path = path,
        .dedupe = .all,
    });
    defer h2.deinit();
    try std.testing.expectEqual(@as(usize, 2), h2.entries.items.len);
    try std.testing.expectEqualStrings("beta", h2.entries.items[0]);
    try std.testing.expectEqualStrings("alpha", h2.entries.items[1]);
}

test "history: load applies dedup policy" {
    // Construct a history file by hand with duplicates that an
    // `.adjacent` policy would reject; load should drop them.
    const path = "/tmp/zigline_history_load_dedup_test";
    {
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
        const fd = std.c.open(
            path_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        const lines = "alpha\nalpha\nbeta\nalpha\n";
        _ = std.c.write(fd, lines, lines.len);
    }
    defer {
        const path_z = std.testing.allocator.dupeZ(u8, path) catch unreachable;
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
    }

    var h = try History.init(std.testing.allocator, .{
        .path = path,
        .dedupe = .adjacent,
    });
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 3), h.entries.items.len);
    try std.testing.expectEqualStrings("alpha", h.entries.items[0]);
    try std.testing.expectEqualStrings("beta", h.entries.items[1]);
    try std.testing.expectEqualStrings("alpha", h.entries.items[2]);
}
