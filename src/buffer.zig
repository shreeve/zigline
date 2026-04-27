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

/// Result of a single-cluster delete: where the deletion happened
/// and what bytes were removed (allocator-owned, caller frees).
pub const DeletedRange = struct {
    idx: usize,
    bytes: []u8,
};

/// Result of an in-place range edit (transpose, case-map, squeeze).
/// `start` is the byte offset of the modified region; `old_bytes` is
/// what was there before, `new_bytes` is what's there now. Both
/// slices are allocator-owned — the caller frees both. Pairs with
/// `Changeset.recordReplace` directly.
pub const EditResult = struct {
    start: usize,
    old_bytes: []u8,
    new_bytes: []u8,
};

/// Word case-mapping selector for `Buffer.editWord`.
pub const WordCase = enum {
    /// Uppercase the first ASCII letter; lowercase the rest.
    capitalize,
    /// Uppercase every ASCII letter in the word.
    upper,
    /// Lowercase every ASCII letter in the word.
    lower,
};

/// Single-line UTF-8 buffer with cluster index and cursor.
///
/// **Field-access policy (v1.0 commitment):** the `bytes`,
/// `clusters`, `cursor_byte`, and `clusters_valid` fields are exposed
/// `pub` because Zig has no language-level access control, but they
/// are documented as **low-level**: external callers that mutate them
/// directly are responsible for preserving the invariants below.
/// The public API for safe mutation is `insertText`, `replaceAll`,
/// the `delete*Cluster` / `kill*` family, the `move*` family, and the
/// in-place transforms (`transposeChars`, `editWord`,
/// `squeezeWhitespace`). Read-only access via `slice`, `byteLen`,
/// `isEmpty`. Future zigline versions may move these fields behind a
/// nested `Internal` struct without a SemVer break — apps using the
/// accessor API keep working; apps mutating fields directly should
/// expect to migrate.
///
/// **Invariants:**
///   - `bytes` is always valid UTF-8 (enforced by `insertText` and
///     `replaceAll`; external content paths sanitize via
///     `findUnsafeByte` to also reject control bytes).
///   - `cursor_byte` sits on a grapheme-cluster boundary or at
///     `bytes.len` (one past the last cluster). Cluster-aware
///     methods rely on this.
///   - `clusters_valid` is `true` iff `clusters` reflects the
///     current `bytes` content. Edit methods invalidate; renders
///     re-segment via `ensureClusters`.
pub const Buffer = struct {
    allocator: Allocator,
    /// **Low-level.** Backing UTF-8 bytes. See type-level doc.
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    /// **Low-level.** Cluster index; valid only when `clusters_valid`
    /// is true. Recomputed on demand by `ensureClusters`.
    clusters: std.ArrayListUnmanaged(Cluster) = .empty,
    /// **Low-level.** Cursor byte offset; must sit on a cluster
    /// boundary. The accessor `cursorByte()` is the read API; for
    /// safe writes use the `move*` family or `setCursorByteAtClusterBoundary`.
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

    /// Buffer size in bytes (not graphemes / not display columns).
    /// Stable v1.0 surface — promised by STABILITY.md.
    pub fn byteLen(self: *const Buffer) usize {
        return self.bytes.items.len;
    }

    /// Cursor byte offset. Always sits on a grapheme-cluster boundary
    /// or at `byteLen()`. Stable v1.0 surface; prefer this over
    /// reading `cursor_byte` directly so future internal moves don't
    /// break callers.
    pub fn cursorByte(self: *const Buffer) usize {
        return self.cursor_byte;
    }

    /// Set the cursor at a verified cluster boundary. Returns
    /// `error.NotClusterBoundary` if `byte` doesn't land on one
    /// (re-segments if needed). Use this instead of writing
    /// `cursor_byte` directly to preserve the invariant.
    pub fn setCursorByteAtClusterBoundary(self: *Buffer, byte: usize) !void {
        if (byte > self.bytes.items.len) return error.OutOfBounds;
        try self.ensureClusters();
        if (byte == self.bytes.items.len) {
            self.cursor_byte = byte;
            return;
        }
        for (self.clusters.items) |c| {
            if (c.byte_start == byte) {
                self.cursor_byte = byte;
                return;
            }
            if (c.byte_start > byte) return error.NotClusterBoundary;
        }
        return error.NotClusterBoundary;
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
    /// that cluster started. Returns the deletion range so callers
    /// can record an undo op or push to a kill ring; null at start.
    pub fn deleteBackwardCluster(self: *Buffer) !?DeletedRange {
        if (self.cursor_byte == 0) return null;
        try self.ensureClusters();
        const idx = self.clusterIndexAt(self.cursor_byte) orelse return null;
        if (idx == 0) return null;
        const prev = self.clusters.items[idx - 1];
        const removed = try self.allocator.dupe(u8, self.bytes.items[prev.byte_start..prev.byte_end]);
        const len = prev.byte_end - prev.byte_start;
        std.mem.copyForwards(
            u8,
            self.bytes.items[prev.byte_start..],
            self.bytes.items[prev.byte_end..],
        );
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len - len);
        self.cursor_byte = prev.byte_start;
        self.clusters_valid = false;
        return .{ .idx = prev.byte_start, .bytes = removed };
    }

    pub fn deleteForwardCluster(self: *Buffer) !?DeletedRange {
        if (self.cursor_byte >= self.bytes.items.len) return null;
        try self.ensureClusters();
        const idx = self.clusterIndexAt(self.cursor_byte) orelse return null;
        if (idx >= self.clusters.items.len) return null;
        const cur = self.clusters.items[idx];
        const removed = try self.allocator.dupe(u8, self.bytes.items[cur.byte_start..cur.byte_end]);
        const len = cur.byte_end - cur.byte_start;
        std.mem.copyForwards(
            u8,
            self.bytes.items[cur.byte_start..],
            self.bytes.items[cur.byte_end..],
        );
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len - len);
        self.clusters_valid = false;
        return .{ .idx = cur.byte_start, .bytes = removed };
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

    /// Delete from cursor backward to start. Returns the killed text
    /// as an allocator-owned slice (caller frees), or null if the
    /// cursor was at start. The byte order returned is original
    /// document order, so callers pushing to a kill ring should use
    /// `Mode.prepend` to coalesce with later backward-kills.
    pub fn killToStart(self: *Buffer) !?[]u8 {
        if (self.cursor_byte == 0) return null;
        const killed = try self.allocator.dupe(u8, self.bytes.items[0..self.cursor_byte]);
        const remaining = self.bytes.items[self.cursor_byte..];
        std.mem.copyForwards(u8, self.bytes.items[0..remaining.len], remaining);
        self.bytes.shrinkRetainingCapacity(remaining.len);
        self.cursor_byte = 0;
        self.clusters_valid = false;
        return killed;
    }

    /// Delete from cursor forward to end. Returns the killed text;
    /// callers should use `Mode.append` for ring coalescing.
    pub fn killToEnd(self: *Buffer) !?[]u8 {
        if (self.cursor_byte >= self.bytes.items.len) return null;
        const killed = try self.allocator.dupe(u8, self.bytes.items[self.cursor_byte..]);
        self.bytes.shrinkRetainingCapacity(self.cursor_byte);
        self.clusters_valid = false;
        return killed;
    }

    /// Delete the word ending at the cursor (skipping any trailing
    /// separators first). Returns the killed text in document order.
    pub fn killWordBackward(self: *Buffer) !?[]u8 {
        if (self.cursor_byte == 0) return null;
        const start_byte = self.cursor_byte;
        var b = self.cursor_byte;
        while (b > 0 and isWordSep(self.bytes.items[b - 1])) b -= 1;
        while (b > 0 and !isWordSep(self.bytes.items[b - 1])) b -= 1;
        if (b == start_byte) return null;
        const killed = try self.allocator.dupe(u8, self.bytes.items[b..start_byte]);
        const remaining = self.bytes.items[start_byte..];
        std.mem.copyForwards(u8, self.bytes.items[b..][0..remaining.len], remaining);
        self.bytes.shrinkRetainingCapacity(b + remaining.len);
        self.cursor_byte = b;
        self.clusters_valid = false;
        return killed;
    }

    /// Delete the word starting at the cursor. Returns killed text;
    /// callers should use `Mode.append`.
    pub fn killWordForward(self: *Buffer) !?[]u8 {
        const len = self.bytes.items.len;
        if (self.cursor_byte >= len) return null;
        var b = self.cursor_byte;
        while (b < len and isWordSep(self.bytes.items[b])) b += 1;
        while (b < len and !isWordSep(self.bytes.items[b])) b += 1;
        if (b == self.cursor_byte) return null;
        const killed = try self.allocator.dupe(u8, self.bytes.items[self.cursor_byte..b]);
        const remaining = self.bytes.items[b..];
        std.mem.copyForwards(
            u8,
            self.bytes.items[self.cursor_byte..][0..remaining.len],
            remaining,
        );
        self.bytes.shrinkRetainingCapacity(self.cursor_byte + remaining.len);
        self.clusters_valid = false;
        return killed;
    }

    /// Swap the cluster ending at the cursor with the cluster starting
    /// at the cursor. If the cursor is at end-of-buffer, swap the
    /// last two clusters instead (emacs convention). Cursor lands
    /// past the swapped pair so repeated invocations scroll a
    /// cluster rightward through the buffer.
    ///
    /// Returns null when there's nothing to swap (fewer than 2
    /// clusters, or cursor sits before the first cluster).
    pub fn transposeChars(self: *Buffer) !?EditResult {
        try self.ensureClusters();
        const n = self.clusters.items.len;
        if (n < 2) return null;
        var idx = self.clusterIndexAt(self.cursor_byte) orelse return null;
        if (idx == n) {
            // At end — swap the last two clusters; cursor stays at end.
            idx = n - 1;
        } else if (idx == 0) {
            return null;
        }

        const a = self.clusters.items[idx - 1];
        const b = self.clusters.items[idx];
        const start = a.byte_start;
        const end = b.byte_end;
        const a_len = a.byte_end - a.byte_start;
        const b_len = b.byte_end - b.byte_start;

        const old_bytes = try self.allocator.dupe(u8, self.bytes.items[start..end]);
        errdefer self.allocator.free(old_bytes);
        const new_bytes = try self.allocator.alloc(u8, a_len + b_len);
        errdefer self.allocator.free(new_bytes);

        @memcpy(new_bytes[0..b_len], self.bytes.items[b.byte_start..b.byte_end]);
        @memcpy(new_bytes[b_len..], self.bytes.items[a.byte_start..a.byte_end]);
        @memcpy(self.bytes.items[start..end], new_bytes);

        self.cursor_byte = end;
        self.clusters_valid = false;
        return .{ .start = start, .old_bytes = old_bytes, .new_bytes = new_bytes };
    }

    /// Apply a case transform to the word at/after the cursor. If
    /// the cursor is in whitespace, skips forward to the next word
    /// first. Cursor lands past the modified word (emacs convention).
    /// Returns null when there's no word at/after the cursor.
    ///
    /// ASCII-only: non-ASCII bytes pass through unchanged. Full
    /// Unicode case folding is post-v1.0 work.
    pub fn editWord(self: *Buffer, op: WordCase) !?EditResult {
        const len = self.bytes.items.len;
        var b = self.cursor_byte;
        while (b < len and isWordSep(self.bytes.items[b])) b += 1;
        if (b >= len) return null;
        const start = b;
        while (b < len and !isWordSep(self.bytes.items[b])) b += 1;
        const end = b;

        const old_bytes = try self.allocator.dupe(u8, self.bytes.items[start..end]);
        errdefer self.allocator.free(old_bytes);
        const new_bytes = try self.allocator.dupe(u8, self.bytes.items[start..end]);
        errdefer self.allocator.free(new_bytes);

        switch (op) {
            .capitalize => {
                if (new_bytes.len > 0) new_bytes[0] = std.ascii.toUpper(new_bytes[0]);
                for (new_bytes[1..]) |*c| c.* = std.ascii.toLower(c.*);
            },
            .upper => for (new_bytes) |*c| {
                c.* = std.ascii.toUpper(c.*);
            },
            .lower => for (new_bytes) |*c| {
                c.* = std.ascii.toLower(c.*);
            },
        }

        // No-op short-circuit: if nothing changed, return null. Saves
        // an undo entry for actions like "uppercase NUMBERS".
        if (std.mem.eql(u8, old_bytes, new_bytes)) {
            self.allocator.free(old_bytes);
            self.allocator.free(new_bytes);
            self.cursor_byte = end;
            return null;
        }

        @memcpy(self.bytes.items[start..end], new_bytes);
        self.cursor_byte = end;
        self.clusters_valid = false;
        return .{ .start = start, .old_bytes = old_bytes, .new_bytes = new_bytes };
    }

    /// Delete all whitespace bytes adjacent to the cursor. Matches
    /// emacs `delete-horizontal-space` (`M-\`): collapses a run of
    /// whitespace to zero, not to one. Cursor lands at the start of
    /// the deleted run. Returns null when there's no whitespace
    /// adjacent.
    pub fn squeezeWhitespace(self: *Buffer) !?EditResult {
        const len = self.bytes.items.len;
        var s = self.cursor_byte;
        while (s > 0 and isAsciiHSpace(self.bytes.items[s - 1])) s -= 1;
        var e = self.cursor_byte;
        while (e < len and isAsciiHSpace(self.bytes.items[e])) e += 1;
        if (s == e) return null;

        const old_bytes = try self.allocator.dupe(u8, self.bytes.items[s..e]);
        errdefer self.allocator.free(old_bytes);
        const new_bytes = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(new_bytes);

        std.mem.copyForwards(u8, self.bytes.items[s..], self.bytes.items[e..]);
        self.bytes.shrinkRetainingCapacity(len - (e - s));
        self.cursor_byte = s;
        self.clusters_valid = false;
        return .{ .start = s, .old_bytes = old_bytes, .new_bytes = new_bytes };
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

/// Scan `text` for bytes that aren't safe to land in the single-line
/// UTF-8 buffer model. Returns the offset of the first unsafe byte,
/// or null if all bytes are safe. Does NOT validate UTF-8 — combine
/// with `std.unicode.utf8ValidateSlice` for a complete check.
///
/// Unsafe bytes:
///   - C0 controls (0x00..0x1F): includes `\r` and `\n` (which would
///     break the single-line invariant), `\x1b` ESC (which would
///     inject ANSI sequences into the rendered output), `\x07` BEL,
///     and the rest.
///   - DEL (0x7F).
///
/// Quoted-insert (Ctrl-V / Ctrl-Q) is the documented escape hatch
/// for typing literal control bytes interactively. This function is
/// for sanitizing **external** content (completion candidates,
/// history entries, custom-action insertions, paste payloads) before
/// it enters the buffer — the editor uses it at every hook boundary.
pub fn findUnsafeByte(text: []const u8) ?usize {
    for (text, 0..) |b, i| {
        if (b < 0x20 or b == 0x7f) return i;
    }
    return null;
}

/// Horizontal whitespace only — what `M-\` (squeeze) targets.
/// Distinct from `isWordSep` because newlines and word-internal
/// separators like `/` and `:` shouldn't be squeezed.
fn isAsciiHSpace(c: u8) bool {
    return c == ' ' or c == '\t';
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

    if (try b.deleteBackwardCluster()) |range| {
        defer std.testing.allocator.free(range.bytes);
        try std.testing.expectEqualStrings("o", range.bytes);
    } else return error.TestUnexpectedResult;
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

    if (try b.deleteBackwardCluster()) |range| {
        defer std.testing.allocator.free(range.bytes);
        try std.testing.expectEqualStrings("é", range.bytes);
    } else return error.TestUnexpectedResult;
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
    if (try b.killWordBackward()) |killed| {
        defer std.testing.allocator.free(killed);
        try std.testing.expectEqualStrings("baz", killed);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("foo bar ", b.slice());
}

test "buffer: killToEnd returns killed text" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();

    try b.insertText("hello world");
    b.cursor_byte = 5;
    if (try b.killToEnd()) |killed| {
        defer std.testing.allocator.free(killed);
        try std.testing.expectEqualStrings(" world", killed);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", b.slice());
}

test "buffer: killToStart at byte 0 returns null" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("hi");
    b.cursor_byte = 0;
    try std.testing.expectEqual(@as(?[]u8, null), try b.killToStart());
}

fn freeEditResult(alloc: Allocator, r: ?EditResult) void {
    const x = r orelse return;
    alloc.free(x.old_bytes);
    alloc.free(x.new_bytes);
}

test "buffer: transposeChars swaps mid-buffer + advances cursor" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("abcd");
    b.cursor_byte = 2; // between b and c
    const r = try b.transposeChars();
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("acbd", b.slice());
    try std.testing.expectEqual(@as(usize, 3), b.cursor_byte);
}

test "buffer: transposeChars at end-of-buffer swaps last two" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("abcd");
    // cursor is at end (byte 4) by default after insert
    const r = try b.transposeChars();
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("abdc", b.slice());
    try std.testing.expectEqual(@as(usize, 4), b.cursor_byte);
}

test "buffer: transposeChars at start is no-op" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("abcd");
    b.cursor_byte = 0;
    const r = try b.transposeChars();
    try std.testing.expectEqual(@as(?EditResult, null), r);
    try std.testing.expectEqualStrings("abcd", b.slice());
}

test "buffer: transposeChars on single-char buffer is no-op" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("a");
    const r = try b.transposeChars();
    try std.testing.expectEqual(@as(?EditResult, null), r);
}

test "buffer: transposeChars across grapheme clusters" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    // "café" — the 'é' is a 2-byte cluster (U+00E9)
    try b.insertText("café");
    // Cursor at end. Swap 'f' and 'é'.
    const r = try b.transposeChars();
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("caéf", b.slice());
}

test "buffer: editWord capitalize on lowercase word" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("hello world");
    b.cursor_byte = 0;
    const r = try b.editWord(.capitalize);
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("Hello world", b.slice());
    try std.testing.expectEqual(@as(usize, 5), b.cursor_byte);
}

test "buffer: editWord upper on mixed case" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("Hello world");
    b.cursor_byte = 6;
    const r = try b.editWord(.upper);
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("Hello WORLD", b.slice());
    try std.testing.expectEqual(@as(usize, 11), b.cursor_byte);
}

test "buffer: editWord lower on uppercase" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("HELLO");
    b.cursor_byte = 0;
    const r = try b.editWord(.lower);
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("hello", b.slice());
}

test "buffer: editWord skips leading whitespace" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("   word");
    b.cursor_byte = 0;
    const r = try b.editWord(.upper);
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("   WORD", b.slice());
}

test "buffer: editWord no-op on numbers" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("12345");
    b.cursor_byte = 0;
    const r = try b.editWord(.upper);
    try std.testing.expectEqual(@as(?EditResult, null), r);
    try std.testing.expectEqualStrings("12345", b.slice());
    try std.testing.expectEqual(@as(usize, 5), b.cursor_byte);
}

test "buffer: editWord at end-of-buffer returns null" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("hi   ");
    // cursor at end, only whitespace left
    const r = try b.editWord(.upper);
    try std.testing.expectEqual(@as(?EditResult, null), r);
}

test "buffer: squeezeWhitespace deletes run around cursor" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("foo   bar");
    b.cursor_byte = 4; // inside the spaces
    const r = try b.squeezeWhitespace();
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("foobar", b.slice());
    try std.testing.expectEqual(@as(usize, 3), b.cursor_byte);
}

test "buffer: squeezeWhitespace at non-whitespace returns null" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("foo");
    b.cursor_byte = 1;
    const r = try b.squeezeWhitespace();
    try std.testing.expectEqual(@as(?EditResult, null), r);
}

test "buffer: squeezeWhitespace handles tabs + spaces" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("a \t \tb");
    b.cursor_byte = 3;
    const r = try b.squeezeWhitespace();
    defer freeEditResult(std.testing.allocator, r);
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("ab", b.slice());
}

test "buffer: squeezeWhitespace preserves newlines (only horizontal ws)" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("a\nb");
    b.cursor_byte = 1;
    const r = try b.squeezeWhitespace();
    try std.testing.expectEqual(@as(?EditResult, null), r);
    try std.testing.expectEqualStrings("a\nb", b.slice());
}

test "buffer: findUnsafeByte catches C0, DEL, ESC, newlines" {
    try std.testing.expectEqual(@as(?usize, null), findUnsafeByte("hello world"));
    try std.testing.expectEqual(@as(?usize, null), findUnsafeByte(""));
    try std.testing.expectEqual(@as(?usize, null), findUnsafeByte("café"));
    try std.testing.expectEqual(@as(?usize, 5), findUnsafeByte("hello\nworld"));
    try std.testing.expectEqual(@as(?usize, 5), findUnsafeByte("hello\rworld"));
    try std.testing.expectEqual(@as(?usize, 0), findUnsafeByte("\x1b[2J"));
    try std.testing.expectEqual(@as(?usize, 3), findUnsafeByte("foo\x07bar"));
    try std.testing.expectEqual(@as(?usize, 3), findUnsafeByte("foo\x7fbar"));
    // Tab is currently unsafe (no tab-rendering support yet).
    try std.testing.expectEqual(@as(?usize, 1), findUnsafeByte("a\tb"));
}

test "buffer: byteLen matches insertText growth" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 0), b.byteLen());
    try b.insertText("hello");
    try std.testing.expectEqual(@as(usize, 5), b.byteLen());
    try b.insertText("é"); // 2-byte UTF-8
    try std.testing.expectEqual(@as(usize, 7), b.byteLen());
}

test "buffer: cursorByte + setCursorByteAtClusterBoundary" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("café");
    try std.testing.expectEqual(b.byteLen(), b.cursorByte());

    // 0, 1, 2, 3 (start of é), 5 (end) are valid; 4 is mid-cluster.
    try b.setCursorByteAtClusterBoundary(0);
    try std.testing.expectEqual(@as(usize, 0), b.cursorByte());
    try b.setCursorByteAtClusterBoundary(3);
    try std.testing.expectEqual(@as(usize, 3), b.cursorByte());
    try b.setCursorByteAtClusterBoundary(5);
    try std.testing.expectEqual(@as(usize, 5), b.cursorByte());

    try std.testing.expectError(error.NotClusterBoundary, b.setCursorByteAtClusterBoundary(4));
    try std.testing.expectError(error.OutOfBounds, b.setCursorByteAtClusterBoundary(99));
}
