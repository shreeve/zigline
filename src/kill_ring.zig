//! Kill ring — multi-slot kill history with `Ctrl-Y` yank and `M-y`
//! yank-pop semantics (emacs-style).
//!
//! Adapted from `rustyline/src/kill_ring.rs` (MIT, kkawakam et al.):
//! the action-state machine that coalesces consecutive kills into one
//! ring slot, and the yank-pop replacement-length bookkeeping. The
//! Zig port owns its strings (allocator-allocated `[]u8`) instead of
//! `String`, and uses a ring-grown-lazily `ArrayListUnmanaged` rather
//! than a fixed `Vec` with a separate length.
//!
//! Behavior:
//!   - `kill(text, mode)` after a previous kill → coalesces into the
//!     current slot (`.append` puts text at the end; `.prepend` at
//!     the front, used for backward kills like Ctrl-W).
//!   - `kill(text, mode)` after any non-kill action → advances to a
//!     fresh slot (cycling once we're at capacity), pushes `text`.
//!   - `yank()` returns the current slot's text; sets last action to
//!     yank, recording the yanked length so a follow-up `yankPop` can
//!     replace it.
//!   - `yankPop()` after a yank or yank-pop steps backwards through
//!     the ring and returns the replacement bookkeeping. Returns null
//!     if the previous action wasn't a yank — apps should treat that
//!     as "ignore the M-y press."
//!   - `reset()` resets the action state. The editor calls this on
//!     every non-kill, non-yank action so the next kill starts a fresh
//!     ring slot.
//!
//! Capacity 0 disables the kill ring entirely; `kill` and `yank` no-op.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Mode = enum { append, prepend };

pub const Action = union(enum) {
    other,
    kill,
    /// Length of the most-recently-yanked text. The editor needs
    /// this to compute the byte range to replace on yank-pop.
    yank: usize,
};

pub const YankPop = struct {
    /// Length (bytes) of the yanked text the caller should replace.
    prev_len: usize,
    /// Fresh text to insert in its place.
    text: []const u8,
};

pub const KillRing = struct {
    allocator: Allocator,
    slots: std.ArrayListUnmanaged([]u8) = .empty,
    capacity: usize,
    index: usize = 0,
    last_action: Action = .other,

    pub fn init(allocator: Allocator, capacity: usize) KillRing {
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *KillRing) void {
        for (self.slots.items) |s| self.allocator.free(s);
        self.slots.deinit(self.allocator);
    }

    /// Reset the action-tracking state. Called by the editor on
    /// every non-kill, non-yank action so the next kill starts a
    /// fresh slot rather than coalescing.
    pub fn reset(self: *KillRing) void {
        self.last_action = .other;
    }

    /// Push or coalesce killed text. After a previous `kill` the new
    /// text merges into the current slot; otherwise advances the ring
    /// (cycling at capacity) and stores the new text in a fresh slot.
    pub fn kill(self: *KillRing, text: []const u8, mode: Mode) !void {
        // Capacity 0 disables the ring. We still record the action
        // so subsequent kills are coalesced semantically (even
        // though there's no slot to write into).
        if (self.capacity == 0) {
            self.last_action = .kill;
            return;
        }

        // The two paths share a state-update discipline: do the
        // allocation FIRST, then mutate `self.slots` and only then
        // set `self.last_action`. If allocation fails, `last_action`
        // stays at its prior value so a subsequent retry still
        // coalesces or starts fresh as appropriate.
        switch (self.last_action) {
            .kill => {
                // Coalesce into the current slot. Build the new
                // buffer first so an OOM leaves the slot untouched.
                const old = self.slots.items[self.index];
                const new_buf = try self.allocator.alloc(u8, old.len + text.len);
                switch (mode) {
                    .append => {
                        @memcpy(new_buf[0..old.len], old);
                        @memcpy(new_buf[old.len..], text);
                    },
                    .prepend => {
                        @memcpy(new_buf[0..text.len], text);
                        @memcpy(new_buf[text.len..], old);
                    },
                }
                self.allocator.free(old);
                self.slots.items[self.index] = new_buf;
                // last_action was already `.kill`; no change.
            },
            else => {
                if (self.slots.items.len == 0) {
                    // First-ever kill: dupe + push, then set state.
                    const owned = try self.allocator.dupe(u8, text);
                    errdefer self.allocator.free(owned);
                    try self.slots.append(self.allocator, owned);
                } else if (self.index + 1 == self.capacity) {
                    // Ring full and at end — wrap to slot 0. Stage
                    // the dupe BEFORE freeing the old so an OOM
                    // doesn't lose the prior slot.
                    const owned = try self.allocator.dupe(u8, text);
                    self.allocator.free(self.slots.items[0]);
                    self.slots.items[0] = owned;
                    self.index = 0;
                } else {
                    // Advance to next slot. Stage everything before
                    // touching `self.index` so an OOM leaves the
                    // ring's logical position unchanged.
                    const new_idx = self.index + 1;
                    if (new_idx < self.slots.items.len) {
                        const owned = try self.allocator.dupe(u8, text);
                        self.allocator.free(self.slots.items[new_idx]);
                        self.slots.items[new_idx] = owned;
                    } else {
                        const owned = try self.allocator.dupe(u8, text);
                        errdefer self.allocator.free(owned);
                        try self.slots.append(self.allocator, owned);
                    }
                    self.index = new_idx;
                }
                // Slot update succeeded; record the action only now.
                self.last_action = .kill;
            },
        }
    }

    /// Return the current slot's text, or null if the ring is empty.
    /// Sets last_action so a subsequent yank-pop can replace what
    /// was just inserted.
    pub fn yank(self: *KillRing) ?[]const u8 {
        if (self.slots.items.len == 0) return null;
        const text = self.slots.items[self.index];
        self.last_action = .{ .yank = text.len };
        return text;
    }

    /// Step back through the ring after a yank. Returns the
    /// replacement bookkeeping, or null if the previous action
    /// wasn't a yank.
    pub fn yankPop(self: *KillRing) ?YankPop {
        const prev_len = switch (self.last_action) {
            .yank => |n| n,
            else => return null,
        };
        if (self.slots.items.len == 0) return null;

        if (self.index == 0) {
            self.index = self.slots.items.len - 1;
        } else {
            self.index -= 1;
        }
        const text = self.slots.items[self.index];
        self.last_action = .{ .yank = text.len };
        return .{ .prev_len = prev_len, .text = text };
    }
};

// =============================================================================
// Tests — port of rustyline/src/kill_ring.rs test cases.
// =============================================================================

test "kill_ring: capacity 0 disables but still tracks action state" {
    var kr = KillRing.init(std.testing.allocator, 0);
    defer kr.deinit();

    try kr.kill("text", .append);
    try std.testing.expectEqual(@as(usize, 0), kr.slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), kr.index);
    switch (kr.last_action) {
        .kill => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(?[]const u8, null), kr.yank());
}

test "kill_ring: one kill" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .append);
    try std.testing.expectEqual(@as(usize, 0), kr.index);
    try std.testing.expectEqual(@as(usize, 1), kr.slots.items.len);
    try std.testing.expectEqualStrings("word1", kr.slots.items[0]);
}

test "kill_ring: consecutive kills append into one slot" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .append);
    try kr.kill(" word2", .append);
    try std.testing.expectEqual(@as(usize, 0), kr.index);
    try std.testing.expectEqual(@as(usize, 1), kr.slots.items.len);
    try std.testing.expectEqualStrings("word1 word2", kr.slots.items[0]);
}

test "kill_ring: consecutive backward kills prepend" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .prepend);
    try kr.kill("word2 ", .prepend);
    try std.testing.expectEqual(@as(usize, 0), kr.index);
    try std.testing.expectEqual(@as(usize, 1), kr.slots.items.len);
    try std.testing.expectEqualStrings("word2 word1", kr.slots.items[0]);
}

test "kill_ring: reset between kills advances slot" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .append);
    kr.reset();
    try kr.kill("word2", .append);
    try std.testing.expectEqual(@as(usize, 1), kr.index);
    try std.testing.expectEqual(@as(usize, 2), kr.slots.items.len);
    try std.testing.expectEqualStrings("word1", kr.slots.items[0]);
    try std.testing.expectEqualStrings("word2", kr.slots.items[1]);
}

test "kill_ring: many kills cycle through capacity" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .append);
    kr.reset();
    try kr.kill("word2", .append);
    kr.reset();
    try kr.kill("word3", .append);
    kr.reset();
    try kr.kill("word4", .append);
    // index should be 1 (we wrapped), and the two slots hold the
    // most-recent two distinct kills.
    try std.testing.expectEqual(@as(usize, 1), kr.index);
    try std.testing.expectEqual(@as(usize, 2), kr.slots.items.len);
    try std.testing.expectEqualStrings("word3", kr.slots.items[0]);
    try std.testing.expectEqualStrings("word4", kr.slots.items[1]);
}

test "kill_ring: yank returns most recent kill" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .append);
    kr.reset();
    try kr.kill("word2", .append);

    try std.testing.expectEqualStrings("word2", kr.yank().?);
    switch (kr.last_action) {
        .yank => |n| try std.testing.expectEqual(@as(usize, 5), n),
        else => return error.TestUnexpectedResult,
    }
}

test "kill_ring: yank_pop cycles backwards" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();

    try kr.kill("word1", .append);
    kr.reset();
    try kr.kill("longword2", .append);

    // No yank-pop without a preceding yank.
    try std.testing.expectEqual(@as(?YankPop, null), kr.yankPop());

    _ = kr.yank();
    {
        const pop = kr.yankPop().?;
        try std.testing.expectEqual(@as(usize, 9), pop.prev_len); // "longword2"
        try std.testing.expectEqualStrings("word1", pop.text);
    }
    {
        const pop = kr.yankPop().?;
        try std.testing.expectEqual(@as(usize, 5), pop.prev_len); // "word1"
        try std.testing.expectEqualStrings("longword2", pop.text);
    }
}

test "kill_ring: yank_pop after non-yank returns null" {
    var kr = KillRing.init(std.testing.allocator, 2);
    defer kr.deinit();
    try kr.kill("word1", .append);
    try std.testing.expectEqual(@as(?YankPop, null), kr.yankPop());
}
