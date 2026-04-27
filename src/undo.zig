//! Undo / redo manager.
//!
//! Adapted from `rustyline/src/undo.rs` (MIT, kkawakam et al.):
//! the change-set / undo-stack / redo-stack model and the
//! consecutive-edit coalescing pattern. The Zig port is simpler:
//! just `Insert` and `Delete` ops (no `Replace` and no Begin/End
//! markers — we coalesce by adjacency instead). Each op owns its
//! text via the allocator; the changeset frees on drop.
//!
//! Coalescing (so typing "hello" undoes to empty in one shot rather
//! than five):
//!   - Two `Insert` ops merge if the new one's `idx` equals the
//!     previous insert's `idx + text.len` (i.e. cursor advanced
//!     into the inserted text).
//!   - Two `Delete` ops merge for forward delete (`idx` matches the
//!     previous delete's `idx`) or backward delete (`idx + text.len`
//!     matches the previous delete's `idx`). The merged text keeps
//!     document order.
//!   - Coalescing is skipped after any non-edit action (cursor move,
//!     completion, paste, etc.) — the editor calls `breakSequence`
//!     to mark such boundaries.
//!
//! The redo stack is cleared on every new edit (rustyline-standard
//! linear undo, not branching).

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Op = union(enum) {
    insert: Edit,
    delete: Edit,
};

pub const Edit = struct {
    /// Byte offset in the buffer where the edit happened.
    idx: usize,
    /// Text inserted (for `insert`) or removed (for `delete`).
    /// Allocator-owned by the changeset.
    text: []u8,
};

pub const Changeset = struct {
    allocator: Allocator,
    undos: std.ArrayListUnmanaged(Op) = .empty,
    redos: std.ArrayListUnmanaged(Op) = .empty,
    /// True when the next edit is allowed to coalesce with the
    /// previous one. Reset by `breakSequence`.
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
    /// previous one (e.g. after a cursor move).
    pub fn breakSequence(self: *Changeset) void {
        self.coalesce = false;
    }

    pub fn isEmpty(self: *const Changeset) bool {
        return self.undos.items.len == 0;
    }

    pub fn canRedo(self: *const Changeset) bool {
        return self.redos.items.len > 0;
    }

    fn freeOp(self: *Changeset, op: Op) void {
        switch (op) {
            .insert => |e| self.allocator.free(e.text),
            .delete => |e| self.allocator.free(e.text),
        }
    }

    /// Record an insert. Coalesces with the previous undo entry when
    /// it's a contiguous insert.
    pub fn recordInsert(self: *Changeset, idx: usize, text: []const u8) !void {
        try self.dropRedos();
        if (text.len == 0) return;
        if (self.coalesce and self.undos.items.len > 0) {
            const last_idx = self.undos.items.len - 1;
            const last = self.undos.items[last_idx];
            if (last == .insert and last.insert.idx + last.insert.text.len == idx) {
                const merged = try self.allocator.alloc(u8, last.insert.text.len + text.len);
                @memcpy(merged[0..last.insert.text.len], last.insert.text);
                @memcpy(merged[last.insert.text.len..], text);
                self.allocator.free(last.insert.text);
                self.undos.items[last_idx] = .{ .insert = .{ .idx = last.insert.idx, .text = merged } };
                self.coalesce = true;
                return;
            }
        }
        const owned = try self.allocator.dupe(u8, text);
        try self.undos.append(self.allocator, .{ .insert = .{ .idx = idx, .text = owned } });
        self.coalesce = true;
    }

    /// Record a deletion. Coalesces with the previous delete when it
    /// looks like the same logical action (forward-delete chain or
    /// backspace chain).
    pub fn recordDelete(self: *Changeset, idx: usize, text: []const u8) !void {
        try self.dropRedos();
        if (text.len == 0) return;
        if (self.coalesce and self.undos.items.len > 0) {
            const last_idx = self.undos.items.len - 1;
            const last = self.undos.items[last_idx];
            if (last == .delete) {
                const lt = last.delete;
                // Forward delete chain: same idx (we're deleting the
                // char that just slid into our position).
                if (idx == lt.idx) {
                    const merged = try self.allocator.alloc(u8, lt.text.len + text.len);
                    @memcpy(merged[0..lt.text.len], lt.text);
                    @memcpy(merged[lt.text.len..], text);
                    self.allocator.free(lt.text);
                    self.undos.items[last_idx] = .{ .delete = .{ .idx = lt.idx, .text = merged } };
                    self.coalesce = true;
                    return;
                }
                // Backspace chain: new delete ended exactly where
                // the previous one started.
                if (idx + text.len == lt.idx) {
                    const merged = try self.allocator.alloc(u8, text.len + lt.text.len);
                    @memcpy(merged[0..text.len], text);
                    @memcpy(merged[text.len..], lt.text);
                    self.allocator.free(lt.text);
                    self.undos.items[last_idx] = .{ .delete = .{ .idx = idx, .text = merged } };
                    self.coalesce = true;
                    return;
                }
            }
        }
        const owned = try self.allocator.dupe(u8, text);
        try self.undos.append(self.allocator, .{ .delete = .{ .idx = idx, .text = owned } });
        self.coalesce = true;
    }

    fn dropRedos(self: *Changeset) !void {
        for (self.redos.items) |op| self.freeOp(op);
        self.redos.clearRetainingCapacity();
    }

    /// Pop the most-recent undoable op and yield it for the caller
    /// to apply (the changeset doesn't know how to mutate the
    /// buffer; that's the editor's job). The popped op is moved to
    /// the redo stack — caller must call `commitUndoApplied` after
    /// successfully applying it.
    ///
    /// Returns null if there's nothing to undo.
    pub fn popUndo(self: *Changeset) ?Op {
        if (self.undos.items.len == 0) return null;
        const op = self.undos.pop().?;
        self.coalesce = false;
        return op;
    }

    /// Caller calls this after successfully applying an undo, to
    /// transfer ownership to the redo stack.
    pub fn commitUndoApplied(self: *Changeset, op: Op) !void {
        try self.redos.append(self.allocator, op);
    }

    /// Symmetric pop for redo.
    pub fn popRedo(self: *Changeset) ?Op {
        if (self.redos.items.len == 0) return null;
        return self.redos.pop().?;
    }

    /// Caller calls this after successfully applying a redo to
    /// transfer ownership back to the undo stack.
    pub fn commitRedoApplied(self: *Changeset, op: Op) !void {
        try self.undos.append(self.allocator, op);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "changeset: empty has nothing to undo" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    try std.testing.expect(cs.isEmpty());
    try std.testing.expectEqual(@as(?Op, null), cs.popUndo());
}

test "changeset: single insert can be undone" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "x");
    try std.testing.expect(!cs.isEmpty());
    const op = cs.popUndo().?;
    switch (op) {
        .insert => |e| {
            try std.testing.expectEqual(@as(usize, 0), e.idx);
            try std.testing.expectEqualStrings("x", e.text);
        },
        else => return error.TestUnexpectedResult,
    }
    try cs.commitUndoApplied(op);
    try std.testing.expect(cs.canRedo());
}

test "changeset: consecutive inserts coalesce" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "h");
    try cs.recordInsert(1, "e");
    try cs.recordInsert(2, "l");
    try cs.recordInsert(3, "l");
    try cs.recordInsert(4, "o");
    try std.testing.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.popUndo().?;
    defer cs.allocator.free(op.insert.text);
    switch (op) {
        .insert => |e| {
            try std.testing.expectEqual(@as(usize, 0), e.idx);
            try std.testing.expectEqualStrings("hello", e.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "changeset: breakSequence stops coalescing" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "ab");
    cs.breakSequence();
    try cs.recordInsert(2, "cd");
    try std.testing.expectEqual(@as(usize, 2), cs.undos.items.len);
}

test "changeset: backspace chain coalesces" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    // "hello", cursor at 5; backspace deletes 'o' (idx 4), then 'l'
    // (idx 3), then 'l' (idx 2), then 'e' (idx 1), then 'h' (idx 0).
    try cs.recordDelete(4, "o");
    try cs.recordDelete(3, "l");
    try cs.recordDelete(2, "l");
    try cs.recordDelete(1, "e");
    try cs.recordDelete(0, "h");
    try std.testing.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.popUndo().?;
    defer cs.allocator.free(op.delete.text);
    switch (op) {
        .delete => |e| {
            try std.testing.expectEqual(@as(usize, 0), e.idx);
            try std.testing.expectEqualStrings("hello", e.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "changeset: forward-delete chain coalesces" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    // "hello", cursor at 0; Ctrl-D repeated: each delete returns
    // the same idx (0) because the next char slides into position.
    try cs.recordDelete(0, "h");
    try cs.recordDelete(0, "e");
    try cs.recordDelete(0, "l");
    try std.testing.expectEqual(@as(usize, 1), cs.undos.items.len);
    const op = cs.popUndo().?;
    defer cs.allocator.free(op.delete.text);
    try std.testing.expectEqualStrings("hel", op.delete.text);
}

test "changeset: new edit after undo drops the redo stack" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "abc");
    {
        const op = cs.popUndo().?;
        try cs.commitUndoApplied(op);
    }
    try std.testing.expect(cs.canRedo());
    try cs.recordInsert(0, "x");
    try std.testing.expect(!cs.canRedo());
}

test "changeset: clear frees all ops" {
    var cs = Changeset.init(std.testing.allocator);
    defer cs.deinit();
    try cs.recordInsert(0, "abc");
    try cs.recordInsert(3, "def");
    try cs.recordDelete(6, "x");
    cs.clear();
    try std.testing.expect(cs.isEmpty());
    try std.testing.expect(!cs.canRedo());
}
