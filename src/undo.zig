//! Undo / redo manager.
//!
//! Adapted from `rustyline/src/undo.rs` (MIT, kkawakam et al.):
//! the change-set / undo-stack / redo-stack model and the
//! consecutive-edit coalescing pattern. The Zig port is simpler:
//! three op variants (`Insert`, `Delete`, `Replace`) instead of
//! rustyline's Begin/End markers — composite operations like yank-pop
//! and completion record as a single `Replace`.
//!
//! Each op carries `cursor_before` and `cursor_after` so undo and
//! redo restore the cursor as the user expects (e.g. forward-delete
//! chains leave cursor at the original position; backspace chains at
//! the right edge of the restored text).
//!
//! Coalescing (so typing "hello" undoes to empty in one shot rather
//! than five):
//!   - Two `Insert` ops merge when the new one's `idx` equals the
//!     previous insert's `idx + text.len` (cursor advanced into the
//!     inserted text).
//!   - Two `Delete` ops merge for forward-delete (`idx == prev.idx`)
//!     or backspace (`idx + text.len == prev.idx`) chains.
//!   - `Replace` ops never coalesce — they're atomic by design.
//!   - The editor calls `breakSequence` to mark non-edit boundaries
//!     (cursor moves) AND compound-op boundaries (yank, paste,
//!     completion) so adjacent typing doesn't merge into them.
//!
//! Apply API: callers `peekUndo()` / `peekRedo()` (borrow), apply on
//! the buffer, then `acceptUndo()` / `acceptRedo()` to commit.
//! Failure between peek and accept leaves the op on its original
//! stack — no ownership-transfer leak window. The redo stack is
//! cleared only on a *successfully recorded* new edit, so a no-op
//! record or a failed record doesn't destroy redo history.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Op = union(enum) {
    insert: Insert,
    delete: Delete,
    replace: Replace,
};

pub const Insert = struct {
    idx: usize,
    text: []u8,
    cursor_before: usize,
    cursor_after: usize,
};

pub const Delete = struct {
    idx: usize,
    text: []u8,
    cursor_before: usize,
    cursor_after: usize,
};

pub const Replace = struct {
    idx: usize,
    old: []u8,
    new: []u8,
    cursor_before: usize,
    cursor_after: usize,
};

pub const Changeset = struct {
    allocator: Allocator,
    undos: std.ArrayListUnmanaged(Op) = .empty,
    redos: std.ArrayListUnmanaged(Op) = .empty,
    /// True when the next edit is allowed to coalesce with the
    /// previous one. Reset by `breakSequence`, by `peekUndo` /
    /// `acceptUndo` / `peekRedo` / `acceptRedo`, and after any
    /// `Replace` record.
    coalesce: bool = false,

    pub fn init(allocator: Allocator) Changeset {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Changeset) void {
        self.clear();
        self.undos.deinit(self.allocator);
        self.redos.deinit(self.allocator);
    }

    /// Drop both stacks and free their text. Called on accept_line —
    /// each new line gets a fresh undo history.
    pub fn clear(self: *Changeset) void {
        for (self.undos.items) |op| self.freeOp(op);
        for (self.redos.items) |op| self.freeOp(op);
        self.undos.clearRetainingCapacity();
        self.redos.clearRetainingCapacity();
        self.coalesce = false;
    }

    /// Mark a boundary so the next edit doesn't merge with the
    /// previous one (e.g. after a cursor move, a paste, or any
    /// compound action like yank that should be its own undo step).
    pub fn breakSequence(self: *Changeset) void {
        self.coalesce = false;
    }

    pub fn isEmpty(self: *const Changeset) bool {
        return self.undos.items.len == 0;
    }

    pub fn canUndo(self: *const Changeset) bool {
        return self.undos.items.len > 0;
    }

    pub fn canRedo(self: *const Changeset) bool {
        return self.redos.items.len > 0;
    }

    fn freeOp(self: *Changeset, op: Op) void {
        switch (op) {
            .insert => |e| self.allocator.free(e.text),
            .delete => |e| self.allocator.free(e.text),
            .replace => |e| {
                self.allocator.free(e.old);
                self.allocator.free(e.new);
            },
        }
    }

    fn dropRedos(self: *Changeset) void {
        for (self.redos.items) |op| self.freeOp(op);
        self.redos.clearRetainingCapacity();
    }

    /// Record an insert. Coalesces with the previous undo entry when
    /// it's a contiguous insert. Empty `text` is a no-op (does not
    /// touch the redo stack).
    pub fn recordInsert(
        self: *Changeset,
        idx: usize,
        text: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) !void {
        if (text.len == 0) return;
        if (self.coalesce and self.undos.items.len > 0) {
            const last_idx = self.undos.items.len - 1;
            const last = self.undos.items[last_idx];
            if (last == .insert and last.insert.idx + last.insert.text.len == idx) {
                const merged = try self.allocator.alloc(u8, last.insert.text.len + text.len);
                errdefer self.allocator.free(merged);
                @memcpy(merged[0..last.insert.text.len], last.insert.text);
                @memcpy(merged[last.insert.text.len..], text);
                self.allocator.free(last.insert.text);
                self.undos.items[last_idx] = .{ .insert = .{
                    .idx = last.insert.idx,
                    .text = merged,
                    .cursor_before = last.insert.cursor_before,
                    .cursor_after = cursor_after,
                } };
                self.dropRedos();
                self.coalesce = true;
                return;
            }
        }
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.undos.append(self.allocator, .{ .insert = .{
            .idx = idx,
            .text = owned,
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        } });
        self.dropRedos();
        self.coalesce = true;
    }

    /// Record a deletion. Coalesces with the previous delete when it
    /// looks like the same logical action (forward-delete chain or
    /// backspace chain). Empty `text` is a no-op.
    pub fn recordDelete(
        self: *Changeset,
        idx: usize,
        text: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) !void {
        if (text.len == 0) return;
        if (self.coalesce and self.undos.items.len > 0) {
            const last_idx = self.undos.items.len - 1;
            const last = self.undos.items[last_idx];
            if (last == .delete) {
                const lt = last.delete;
                // Forward-delete chain: same idx (next char slides in).
                if (idx == lt.idx) {
                    const merged = try self.allocator.alloc(u8, lt.text.len + text.len);
                    errdefer self.allocator.free(merged);
                    @memcpy(merged[0..lt.text.len], lt.text);
                    @memcpy(merged[lt.text.len..], text);
                    self.allocator.free(lt.text);
                    self.undos.items[last_idx] = .{ .delete = .{
                        .idx = lt.idx,
                        .text = merged,
                        .cursor_before = lt.cursor_before,
                        .cursor_after = cursor_after,
                    } };
                    self.dropRedos();
                    self.coalesce = true;
                    return;
                }
                // Backspace chain: new delete ends where prev started.
                if (idx + text.len == lt.idx) {
                    const merged = try self.allocator.alloc(u8, text.len + lt.text.len);
                    errdefer self.allocator.free(merged);
                    @memcpy(merged[0..text.len], text);
                    @memcpy(merged[text.len..], lt.text);
                    self.allocator.free(lt.text);
                    self.undos.items[last_idx] = .{ .delete = .{
                        .idx = idx,
                        .text = merged,
                        .cursor_before = lt.cursor_before,
                        .cursor_after = cursor_after,
                    } };
                    self.dropRedos();
                    self.coalesce = true;
                    return;
                }
            }
        }
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.undos.append(self.allocator, .{ .delete = .{
            .idx = idx,
            .text = owned,
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        } });
        self.dropRedos();
        self.coalesce = true;
    }

    /// Record an atomic substitution: `[idx..idx+old.len)` is replaced
    /// by `new`. Used for yank-pop and completion. Never coalesces.
    pub fn recordReplace(
        self: *Changeset,
        idx: usize,
        old: []const u8,
        new: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) !void {
        if (old.len == 0 and new.len == 0) return;
        const old_owned = try self.allocator.dupe(u8, old);
        errdefer self.allocator.free(old_owned);
        const new_owned = try self.allocator.dupe(u8, new);
        errdefer self.allocator.free(new_owned);
        try self.undos.append(self.allocator, .{ .replace = .{
            .idx = idx,
            .old = old_owned,
            .new = new_owned,
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        } });
        self.dropRedos();
        self.coalesce = false; // Replace is atomic
    }

    /// Borrow the most-recent undoable op for the caller to apply.
    /// Returns null if nothing to undo. The op stays on the stack;
    /// caller must call `acceptUndo` after a successful apply or do
    /// nothing on failure (no leak window).
    pub fn peekUndo(self: *const Changeset) ?*const Op {
        if (self.undos.items.len == 0) return null;
        return &self.undos.items[self.undos.items.len - 1];
    }

    /// Move the most-recent undo entry to the redo stack. Caller
    /// invokes this after successfully applying the op the
    /// `peekUndo` borrowed. Atomic: redo append must succeed before
    /// the undo stack is shrunk, so OOM here leaves both stacks
    /// unchanged.
    pub fn acceptUndo(self: *Changeset) !void {
        if (self.undos.items.len == 0) return;
        const last = self.undos.items[self.undos.items.len - 1];
        try self.redos.append(self.allocator, last);
        _ = self.undos.pop();
        self.coalesce = false;
    }

    pub fn peekRedo(self: *const Changeset) ?*const Op {
        if (self.redos.items.len == 0) return null;
        return &self.redos.items[self.redos.items.len - 1];
    }

    pub fn acceptRedo(self: *Changeset) !void {
        if (self.redos.items.len == 0) return;
        const last = self.redos.items[self.redos.items.len - 1];
        try self.undos.append(self.allocator, last);
        _ = self.redos.pop();
        self.coalesce = false;
    }
};

// =============================================================================
// Tests
// =============================================================================

const tt = std.testing;

test "changeset: empty has nothing to undo" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try tt.expect(cs.isEmpty());
    try tt.expectEqual(@as(?*const Op, null), cs.peekUndo());
}

test "changeset: single insert with cursor positions" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "x", 0, 1);
    const op = cs.peekUndo().?;
    switch (op.*) {
        .insert => |e| {
            try tt.expectEqual(@as(usize, 0), e.idx);
            try tt.expectEqualStrings("x", e.text);
            try tt.expectEqual(@as(usize, 0), e.cursor_before);
            try tt.expectEqual(@as(usize, 1), e.cursor_after);
        },
        else => return error.TestUnexpectedResult,
    }
    try cs.acceptUndo();
    try tt.expect(cs.canRedo());
    try tt.expect(!cs.canUndo());
}

test "changeset: consecutive inserts coalesce; cursor_before is first, cursor_after is latest" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "h", 0, 1);
    try cs.recordInsert(1, "e", 1, 2);
    try cs.recordInsert(2, "l", 2, 3);
    try cs.recordInsert(3, "l", 3, 4);
    try cs.recordInsert(4, "o", 4, 5);
    try tt.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.peekUndo().?;
    switch (op.*) {
        .insert => |e| {
            try tt.expectEqual(@as(usize, 0), e.idx);
            try tt.expectEqualStrings("hello", e.text);
            try tt.expectEqual(@as(usize, 0), e.cursor_before);
            try tt.expectEqual(@as(usize, 5), e.cursor_after);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "changeset: breakSequence stops coalescing" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "ab", 0, 2);
    cs.breakSequence();
    try cs.recordInsert(2, "cd", 2, 4);
    try tt.expectEqual(@as(usize, 2), cs.undos.items.len);
}

test "changeset: backspace chain coalesces with cursor preserved" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    // "hello", cursor at 5; backspace deletes 'o'(4), 'l'(3), 'l'(2),
    // 'e'(1), 'h'(0). Cursor moves 5→4→3→2→1→0.
    try cs.recordDelete(4, "o", 5, 4);
    try cs.recordDelete(3, "l", 4, 3);
    try cs.recordDelete(2, "l", 3, 2);
    try cs.recordDelete(1, "e", 2, 1);
    try cs.recordDelete(0, "h", 1, 0);
    try tt.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.peekUndo().?;
    switch (op.*) {
        .delete => |e| {
            try tt.expectEqual(@as(usize, 0), e.idx);
            try tt.expectEqualStrings("hello", e.text);
            try tt.expectEqual(@as(usize, 5), e.cursor_before);
            try tt.expectEqual(@as(usize, 0), e.cursor_after);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "changeset: forward-delete chain coalesces (cursor stays put)" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    // "hello", cursor at 0; Ctrl-D repeated: cursor stays at 0.
    try cs.recordDelete(0, "h", 0, 0);
    try cs.recordDelete(0, "e", 0, 0);
    try cs.recordDelete(0, "l", 0, 0);
    try tt.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.peekUndo().?;
    switch (op.*) {
        .delete => |e| {
            try tt.expectEqualStrings("hel", e.text);
            try tt.expectEqual(@as(usize, 0), e.cursor_before);
            try tt.expectEqual(@as(usize, 0), e.cursor_after);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "changeset: replace records as a single op (atomic)" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordReplace(2, "old", "new", 5, 5);
    try tt.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.peekUndo().?;
    switch (op.*) {
        .replace => |e| {
            try tt.expectEqual(@as(usize, 2), e.idx);
            try tt.expectEqualStrings("old", e.old);
            try tt.expectEqualStrings("new", e.new);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "changeset: replace doesn't coalesce with surrounding inserts" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "a", 0, 1);
    try cs.recordReplace(1, "x", "yy", 1, 3);
    try cs.recordInsert(3, "b", 3, 4);
    try tt.expectEqual(@as(usize, 3), cs.undos.items.len);
}

test "changeset: empty record is a no-op AND does not drop redos" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "abc", 0, 3);
    try cs.acceptUndo();
    try tt.expect(cs.canRedo());

    // Empty record must NOT clear the redo history.
    try cs.recordInsert(0, "", 0, 0);
    try cs.recordDelete(0, "", 0, 0);
    try cs.recordReplace(0, "", "", 0, 0);
    try tt.expect(cs.canRedo());
    try tt.expectEqual(@as(usize, 0), cs.undos.items.len);
}

test "changeset: new edit after undo drops the redo stack" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "abc", 0, 3);
    try cs.acceptUndo();
    try tt.expect(cs.canRedo());
    try cs.recordInsert(0, "x", 0, 1);
    try tt.expect(!cs.canRedo());
}

test "changeset: peek doesn't transfer ownership; failed apply leaves op on stack" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "abc", 0, 3);

    // Caller peeks, "fails to apply" by returning early without
    // calling acceptUndo, then re-peeks: op is still there.
    {
        const op = cs.peekUndo().?;
        try tt.expect(op.* == .insert);
        // Simulate apply failure: don't call acceptUndo.
    }
    try tt.expect(cs.canUndo());
    try tt.expect(!cs.canRedo());
}

test "changeset: acceptRedo resets coalescing too" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "a", 0, 1);
    try cs.acceptUndo();
    try cs.acceptRedo();
    // After acceptRedo, a new insert at cursor_after of the redone
    // op must NOT coalesce with the redone op.
    try cs.recordInsert(1, "b", 1, 2);
    try tt.expectEqual(@as(usize, 2), cs.undos.items.len);
}

test "changeset: clear frees all ops including replace" {
    var cs = Changeset.init(tt.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "abc", 0, 3);
    try cs.recordReplace(3, "def", "ghi", 3, 6);
    try cs.recordDelete(6, "x", 6, 6);
    cs.clear();
    try tt.expect(cs.isEmpty());
    try tt.expect(!cs.canRedo());
}
