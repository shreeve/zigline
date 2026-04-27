//! Buffer — bytes + cluster index + cursor invariants.
//!
//! See SPEC.md §3. Storage is `[]u8` of valid UTF-8; a cluster array
//! is recomputed lazily on edit. The cursor is a byte offset that
//! always sits on a UAX #29 grapheme cluster boundary, segmented by
//! `grapheme.zig` (backed by the `zg` library).

const std = @import("std");
const grapheme = @import("grapheme.zig");

pub const Allocator = std.mem.Allocator;

pub const Cluster = struct {
    byte_start: usize,
    byte_end: usize,
    /// Display width in terminal cells: 0, 1, or 2.
    width: u8,
};

pub const Buffer = struct {
    allocator: Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    clusters: std.ArrayListUnmanaged(Cluster) = .empty,
    cursor_byte: usize = 0,
    clusters_valid: bool = false,
    width_policy: grapheme.WidthPolicy = .{},

    pub fn init(allocator: Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.allocator);
        self.clusters.deinit(self.allocator);
    }

    pub fn slice(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }

    pub fn isEmpty(self: *const Buffer) bool {
        return self.bytes.items.len == 0;
    }

    /// Recompute cluster boundaries if the bytes have changed since
    /// the last segmentation. Called by render and any cursor move
    /// that needs cluster info.
    pub fn ensureClusters(self: *Buffer) !void {
        if (self.clusters_valid) return;
        self.clusters.clearRetainingCapacity();
        const new = try grapheme.segment(self.allocator, self.bytes.items, self.width_policy);
        defer self.allocator.free(new);
        try self.clusters.appendSlice(self.allocator, new);
        self.clusters_valid = true;
    }

    /// Insert valid UTF-8 text at the cursor. Cursor advances past
    /// the inserted bytes.
    pub fn insertText(self: *Buffer, text: []const u8) !void {
        if (text.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        try self.bytes.insertSlice(self.allocator, self.cursor_byte, text);
        self.cursor_byte += text.len;
        self.clusters_valid = false;
    }

    /// Delete the cluster ending at the cursor. Cursor moves to where
    /// that cluster started.
    pub fn deleteBackwardCluster(self: *Buffer) !void {
        if (self.cursor_byte == 0) return;
        try self.ensureClusters();
        const idx = self.clusterIndexAt(self.cursor_byte) orelse return;
        if (idx == 0) return;
        const prev = self.clusters.items[idx - 1];
        const remove_start = prev.byte_start;
        const remove_end = prev.byte_end;
        const len = remove_end - remove_start;
        std.mem.copyForwards(
            u8,
            self.bytes.items[remove_start..],
            self.bytes.items[remove_end..],
        );
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len - len);
        self.cursor_byte = remove_start;
        self.clusters_valid = false;
    }

    pub fn deleteForwardCluster(self: *Buffer) !void {
        if (self.cursor_byte >= self.bytes.items.len) return;
        try self.ensureClusters();
        const idx = self.clusterIndexAt(self.cursor_byte) orelse return;
        if (idx >= self.clusters.items.len) return;
        const cur = self.clusters.items[idx];
        const len = cur.byte_end - cur.byte_start;
        std.mem.copyForwards(
            u8,
            self.bytes.items[cur.byte_start..],
            self.bytes.items[cur.byte_end..],
        );
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len - len);
        self.clusters_valid = false;
    }

    pub fn moveLeftCluster(self: *Buffer) !void {
        if (self.cursor_byte == 0) return;
        try self.ensureClusters();
        const idx = self.clusterIndexAt(self.cursor_byte) orelse return;
        if (idx == 0) return;
        self.cursor_byte = self.clusters.items[idx - 1].byte_start;
    }

    pub fn moveRightCluster(self: *Buffer) !void {
        if (self.cursor_byte >= self.bytes.items.len) return;
        try self.ensureClusters();
        const idx = self.clusterIndexAt(self.cursor_byte) orelse return;
        if (idx >= self.clusters.items.len) return;
        self.cursor_byte = self.clusters.items[idx].byte_end;
    }

    pub fn moveLeftWord(self: *Buffer) !void {
        if (self.cursor_byte == 0) return;
        var b = self.cursor_byte;
        while (b > 0 and isWordSep(self.bytes.items[b - 1])) b -= 1;
        while (b > 0 and !isWordSep(self.bytes.items[b - 1])) b -= 1;
        self.cursor_byte = b;
    }

    pub fn moveRightWord(self: *Buffer) !void {
        const len = self.bytes.items.len;
        if (self.cursor_byte >= len) return;
        var b = self.cursor_byte;
        while (b < len and isWordSep(self.bytes.items[b])) b += 1;
        while (b < len and !isWordSep(self.bytes.items[b])) b += 1;
        self.cursor_byte = b;
    }

    pub fn moveToStart(self: *Buffer) void {
        self.cursor_byte = 0;
    }

    pub fn moveToEnd(self: *Buffer) void {
        self.cursor_byte = self.bytes.items.len;
    }

    pub fn killToStart(self: *Buffer) !void {
        if (self.cursor_byte == 0) return;
        const remaining = self.bytes.items[self.cursor_byte..];
        std.mem.copyForwards(u8, self.bytes.items[0..remaining.len], remaining);
        self.bytes.shrinkRetainingCapacity(remaining.len);
        self.cursor_byte = 0;
        self.clusters_valid = false;
    }

    pub fn killToEnd(self: *Buffer) !void {
        if (self.cursor_byte >= self.bytes.items.len) return;
        self.bytes.shrinkRetainingCapacity(self.cursor_byte);
        self.clusters_valid = false;
    }

    pub fn killWordBackward(self: *Buffer) !void {
        if (self.cursor_byte == 0) return;
        const start_byte = self.cursor_byte;
        var b = self.cursor_byte;
        while (b > 0 and isWordSep(self.bytes.items[b - 1])) b -= 1;
        while (b > 0 and !isWordSep(self.bytes.items[b - 1])) b -= 1;
        const remaining = self.bytes.items[start_byte..];
        std.mem.copyForwards(u8, self.bytes.items[b..][0..remaining.len], remaining);
        self.bytes.shrinkRetainingCapacity(b + remaining.len);
        self.cursor_byte = b;
        self.clusters_valid = false;
    }

    pub fn killWordForward(self: *Buffer) !void {
        const len = self.bytes.items.len;
        if (self.cursor_byte >= len) return;
        var b = self.cursor_byte;
        while (b < len and isWordSep(self.bytes.items[b])) b += 1;
        while (b < len and !isWordSep(self.bytes.items[b])) b += 1;
        const remaining = self.bytes.items[b..];
        std.mem.copyForwards(
            u8,
            self.bytes.items[self.cursor_byte..][0..remaining.len],
            remaining,
        );
        self.bytes.shrinkRetainingCapacity(self.cursor_byte + remaining.len);
        self.clusters_valid = false;
    }

    /// Replace the entire buffer with `text`. Cursor moves to end.
    pub fn replaceAll(self: *Buffer, text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(self.allocator, text);
        self.cursor_byte = self.bytes.items.len;
        self.clusters_valid = false;
    }

    pub fn clear(self: *Buffer) void {
        self.bytes.clearRetainingCapacity();
        self.clusters.clearRetainingCapacity();
        self.cursor_byte = 0;
        self.clusters_valid = true;
    }

    /// Take the buffer's bytes; caller owns the allocation. Buffer
    /// is reset to empty.
    pub fn take(self: *Buffer) ![]u8 {
        const out = try self.allocator.dupe(u8, self.bytes.items);
        self.clear();
        return out;
    }

    /// Find the cluster index whose `byte_start` equals `byte`. Returns
    /// the count when `byte == bytes.len` (one past the last cluster).
    fn clusterIndexAt(self: *const Buffer, byte: usize) ?usize {
        if (byte == 0) return 0;
        if (byte == self.bytes.items.len) return self.clusters.items.len;
        for (self.clusters.items, 0..) |c, i| {
            if (c.byte_start == byte) return i;
        }
        return null;
    }
};

fn isWordSep(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '/' or c == ':';
}

// =============================================================================
// Tests
// =============================================================================

test "buffer: insert and delete ASCII" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("hello");
    try std.testing.expectEqual(@as(usize, 5), b.cursor_byte);
    try std.testing.expectEqualStrings("hello", b.slice());

    try b.deleteBackwardCluster();
    try std.testing.expectEqualStrings("hell", b.slice());
    try std.testing.expectEqual(@as(usize, 4), b.cursor_byte);
}

test "buffer: insert UTF-8 stays valid" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("café");
    try std.testing.expectEqualStrings("café", b.slice());
    // 'é' is two bytes in UTF-8; cursor should be at 5 bytes.
    try std.testing.expectEqual(@as(usize, 5), b.cursor_byte);

    try b.deleteBackwardCluster();
    try std.testing.expectEqualStrings("caf", b.slice());
    try std.testing.expectEqual(@as(usize, 3), b.cursor_byte);
}

test "buffer: cursor moves cluster-by-cluster over multibyte" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("aé");
    try std.testing.expectEqual(@as(usize, 3), b.cursor_byte);

    try b.moveLeftCluster();
    // Should be at byte 1 (start of 'é'), not byte 2.
    try std.testing.expectEqual(@as(usize, 1), b.cursor_byte);

    try b.moveLeftCluster();
    try std.testing.expectEqual(@as(usize, 0), b.cursor_byte);

    try b.moveLeftCluster();
    try std.testing.expectEqual(@as(usize, 0), b.cursor_byte); // no-op
}

test "buffer: invalid UTF-8 rejected" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try std.testing.expectError(error.InvalidUtf8, b.insertText("\xff\xfe"));
    try std.testing.expectEqualStrings("", b.slice());
}

test "buffer: clear resets state" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("hello");
    b.clear();
    try std.testing.expectEqual(@as(usize, 0), b.cursor_byte);
    try std.testing.expectEqualStrings("", b.slice());
}

test "buffer: replaceAll moves cursor to end" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("hi");
    b.cursor_byte = 1;
    try b.replaceAll("world");
    try std.testing.expectEqualStrings("world", b.slice());
    try std.testing.expectEqual(@as(usize, 5), b.cursor_byte);
}

test "buffer: killWordBackward over space" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("foo bar baz");
    try b.killWordBackward();
    try std.testing.expectEqualStrings("foo bar ", b.slice());
}
