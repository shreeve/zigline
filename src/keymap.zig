//! Keymap — KeyEvent → Action mapping.
//!
//! See SPEC.md §5. Default emacs-style keymap. Applications can swap
//! in alternative keymaps by constructing a `Keymap` with a different
//! `lookupFn`. Multi-key sequences (Ctrl-X Ctrl-E and friends) are
//! expressed via the optional `BindingTable` overlay — see §5.1 / §5.2.

const std = @import("std");

const input = @import("input.zig");
const actions = @import("actions.zig");

pub const Allocator = std.mem.Allocator;
pub const KeyEvent = input.KeyEvent;
pub const KeyCode = input.KeyCode;
pub const Action = actions.Action;

pub const Keymap = struct {
    lookupFn: *const fn (key: KeyEvent) ?Action,
    /// Optional multi-key binding overlay. The dispatcher consults
    /// this first; `lookupFn` is the fall-through for single keys
    /// that don't match any sequence prefix. `null` preserves the
    /// pre-v0.2 single-key-only behavior. See SPEC.md §5.1 / §5.2.
    bindings: ?*BindingTable = null,

    pub fn lookup(self: Keymap, key: KeyEvent) ?Action {
        return self.lookupFn(key);
    }

    pub fn defaultEmacs() Keymap {
        return .{ .lookupFn = emacsLookup };
    }
};

// =============================================================================
// Binding table — multi-key sequences (SPEC §5.1 / §5.2)
// =============================================================================

/// Maximum events in a bound sequence. Any binding longer than this
/// is rejected at `bind()` time. Real keymaps don't bind sequences
/// of more than 3-4 events; 8 is paranoia.
pub const MAX_SEQUENCE: usize = 8;

/// Outcome of `BindingTable.lookup`. The dispatcher uses this to
/// drive the partial-sequence state machine in §5.2.
pub const BindingResult = union(enum) {
    /// No binding starts with this prefix. Editor falls back to
    /// `lookupFn` for the first event and re-processes the rest.
    none,
    /// One or more bindings start with this prefix; no exact
    /// match yet. Editor buffers and waits for the next event.
    partial,
    /// Exact match. Editor dispatches the action and clears the
    /// pending buffer.
    bound: Action,
};

/// Errors `bind` may return.
pub const BindError = error{
    /// Sequence has zero events; refused.
    EmptySequence,
    /// Sequence exceeds `MAX_SEQUENCE` events.
    SequenceTooLong,
    /// Sequence contains a `KeyCode.text` or `KeyCode.unknown`,
    /// neither of which is bindable.
    UnbindableKey,
    /// New sequence is a prefix of an existing binding, OR an
    /// existing binding is a prefix of the new sequence. Without
    /// chord-resolve timeout (which is post-v1.0; see FUTURE.md),
    /// such combinations make one of the two bindings unreachable.
    /// Per SPEC §5.2 a key K cannot simultaneously trigger a
    /// single-key action AND start a multi-key sequence.
    /// Resolution: pick one role for K; either remove the singleton
    /// binding or remove all sequences that start with it.
    PrefixConflict,
    /// Allocator failure.
    OutOfMemory,
};

/// Mutable storage for `[]KeyEvent → Action` bindings, including
/// multi-key sequences. Owned by the application; passed to
/// `Keymap.bindings`.
///
/// **Single-thread expectation:** the dispatcher reads the table
/// during `readLine`. Mutating during `readLine` is undefined.
/// Mutate between `readLine` calls. No locks; if you need cross-
/// thread access, the caller arranges it.
///
/// **Storage detail:** events are encoded to `u32` (codepoint or
/// reserved named-key/function-key value, plus modifier bits in the
/// high bits). Bindings live in a flat `ArrayList`; lookup is O(n*m)
/// where `n` is the binding count and `m` the sequence length. For
/// realistic keymaps (n ≤ 100, m ≤ 4) the constant is microseconds —
/// no need for a trie.
pub const BindingTable = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        seq: []u32,
        action: Action,
    };

    pub fn init(allocator: Allocator) BindingTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BindingTable) void {
        for (self.entries.items) |entry| self.allocator.free(entry.seq);
        self.entries.deinit(self.allocator);
    }

    /// Bind `seq` to `action`. If `seq` was already bound, replaces
    /// the action and returns the previous one. If no prior binding,
    /// returns null. Returns `error.PrefixConflict` when the new
    /// sequence and an existing binding would make either of the two
    /// unreachable under the v1.0 dispatch model — see the doc on
    /// `BindError.PrefixConflict`.
    pub fn bind(
        self: *BindingTable,
        seq: []const KeyEvent,
        action: Action,
    ) BindError!?Action {
        if (seq.len == 0) return error.EmptySequence;
        if (seq.len > MAX_SEQUENCE) return error.SequenceTooLong;

        var encoded_buf: [MAX_SEQUENCE]u32 = undefined;
        for (seq, 0..) |kev, i| {
            const e = encodeKeyEvent(kev) orelse return error.UnbindableKey;
            encoded_buf[i] = e;
        }
        const new_seq = encoded_buf[0..seq.len];

        // Replace existing if any (exact match — same length + bytes).
        // Replacing isn't a conflict; you can rebind a known sequence.
        for (self.entries.items) |*entry| {
            if (entry.seq.len == new_seq.len and
                std.mem.eql(u32, entry.seq, new_seq))
            {
                const prev = entry.action;
                entry.action = action;
                return prev;
            }
        }

        // Reject prefix conflicts. Two cases:
        //   a) An existing binding is a strict prefix of the new
        //      sequence. The existing one would shadow this new one.
        //   b) The new sequence is a strict prefix of an existing
        //      binding. The new one would shadow the existing.
        // Either way, one of the two is unreachable; refuse.
        for (self.entries.items) |entry| {
            if (entry.seq.len < new_seq.len and
                std.mem.eql(u32, entry.seq, new_seq[0..entry.seq.len]))
            {
                return error.PrefixConflict;
            }
            if (entry.seq.len > new_seq.len and
                std.mem.eql(u32, entry.seq[0..new_seq.len], new_seq))
            {
                return error.PrefixConflict;
            }
        }

        const owned = try self.allocator.dupe(u32, new_seq);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{ .seq = owned, .action = action });
        return null;
    }

    /// Remove `seq` from the table. Returns true if a binding was
    /// removed, false if `seq` wasn't bound.
    pub fn unbind(self: *BindingTable, seq: []const KeyEvent) bool {
        if (seq.len == 0 or seq.len > MAX_SEQUENCE) return false;
        var encoded_buf: [MAX_SEQUENCE]u32 = undefined;
        for (seq, 0..) |kev, i| {
            const e = encodeKeyEvent(kev) orelse return false;
            encoded_buf[i] = e;
        }
        const key = encoded_buf[0..seq.len];

        for (self.entries.items, 0..) |entry, idx| {
            if (entry.seq.len == seq.len and std.mem.eql(u32, entry.seq, key)) {
                self.allocator.free(entry.seq);
                _ = self.entries.swapRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Resolve a buffered prefix against the binding-table.
    pub fn lookup(self: *const BindingTable, seq: []const KeyEvent) BindingResult {
        if (seq.len == 0) return .none;
        if (seq.len > MAX_SEQUENCE) return .none;

        var encoded_buf: [MAX_SEQUENCE]u32 = undefined;
        for (seq, 0..) |kev, i| {
            const e = encodeKeyEvent(kev) orelse return .none;
            encoded_buf[i] = e;
        }
        const key = encoded_buf[0..seq.len];

        // Exact match first (so a leaf wins over its prefix).
        for (self.entries.items) |entry| {
            if (entry.seq.len == key.len and std.mem.eql(u32, entry.seq, key)) {
                return .{ .bound = entry.action };
            }
        }

        // Strict-prefix scan: any entry whose sequence starts with
        // `key` makes this a partial match.
        for (self.entries.items) |entry| {
            if (entry.seq.len > key.len and
                std.mem.eql(u32, entry.seq[0..key.len], key))
            {
                return .partial;
            }
        }

        return .none;
    }

    /// Number of bound sequences. Diagnostic; not load-bearing.
    pub fn count(self: *const BindingTable) usize {
        return self.entries.items.len;
    }
};

// =============================================================================
// KeyEvent ↔ u32 encoding
// =============================================================================

// Named-key codes live just past the Unicode max (0x10FFFF). Function
// keys get their own page so we can grow named keys without colliding.
const NAMED_BASE: u32 = 0x110000;
const FN_BASE: u32 = 0x110100;

const MOD_CTRL: u32 = 0x01000000;
const MOD_ALT: u32 = 0x02000000;
const MOD_SHIFT: u32 = 0x04000000;

/// Encode a `KeyEvent` to a 32-bit value suitable for use as a
/// hash-map / array key. Returns null for events that aren't bindable
/// (`text` paste payloads, `unknown` byte sequences).
pub fn encodeKeyEvent(kev: KeyEvent) ?u32 {
    var base: u32 = switch (kev.code) {
        .char => |c| @as(u32, c),
        .function => |n| FN_BASE + @as(u32, n),
        .text, .unknown => return null,
        .enter => NAMED_BASE + 0,
        .tab => NAMED_BASE + 1,
        .backspace => NAMED_BASE + 2,
        .delete => NAMED_BASE + 3,
        .escape => NAMED_BASE + 4,
        .home => NAMED_BASE + 5,
        .end => NAMED_BASE + 6,
        .page_up => NAMED_BASE + 7,
        .page_down => NAMED_BASE + 8,
        .arrow_up => NAMED_BASE + 9,
        .arrow_down => NAMED_BASE + 10,
        .arrow_left => NAMED_BASE + 11,
        .arrow_right => NAMED_BASE + 12,
        .insert => NAMED_BASE + 13,
    };
    if (kev.mods.ctrl) base |= MOD_CTRL;
    if (kev.mods.alt) base |= MOD_ALT;
    if (kev.mods.shift) base |= MOD_SHIFT;
    return base;
}

/// Reverse of `encodeKeyEvent`. Returns null when the encoded value
/// doesn't decode to a known event (corrupt input). Inverse-exact
/// for every output `encodeKeyEvent` produces.
pub fn decodeKeyEvent(encoded: u32) ?KeyEvent {
    var mods: input.Modifiers = .{};
    if ((encoded & MOD_CTRL) != 0) mods.ctrl = true;
    if ((encoded & MOD_ALT) != 0) mods.alt = true;
    if ((encoded & MOD_SHIFT) != 0) mods.shift = true;
    const base = encoded & ~(MOD_CTRL | MOD_ALT | MOD_SHIFT);

    if (base < FN_BASE) {
        // Codepoint — `char` variant. Validate Unicode range.
        if (base > 0x10FFFF) return null;
        return .{ .code = .{ .char = @intCast(base) }, .mods = mods };
    }
    if (base < NAMED_BASE) {
        const n = base - FN_BASE;
        if (n == 0 or n > 12) return null;
        return .{ .code = .{ .function = @intCast(n) }, .mods = mods };
    }
    const named = base - NAMED_BASE;
    const code: input.KeyCode = switch (named) {
        0 => .enter,
        1 => .tab,
        2 => .backspace,
        3 => .delete,
        4 => .escape,
        5 => .home,
        6 => .end,
        7 => .page_up,
        8 => .page_down,
        9 => .arrow_up,
        10 => .arrow_down,
        11 => .arrow_left,
        12 => .arrow_right,
        13 => .insert,
        else => return null,
    };
    return .{ .code = code, .mods = mods };
}

fn emacsLookup(key: KeyEvent) ?Action {
    // Named keys take priority.
    switch (key.code) {
        .enter => return .accept_line,
        .tab => return .complete,
        .backspace => return if (key.mods.alt) Action.kill_word_backward else Action.delete_backward,
        .delete => return .delete_forward,
        .home => return .move_to_start,
        .end => return .move_to_end,
        .arrow_left => return if (key.mods.ctrl) Action.move_word_left else Action.move_left,
        .arrow_right => return if (key.mods.ctrl) Action.move_word_right else Action.accept_hint,
        .arrow_up => return .history_prev,
        .arrow_down => return .history_next,
        .escape => return null, // bare ESC does nothing in emacs mode
        .char => |c| return charLookup(c, key.mods),
        .function, .text, .insert, .page_up, .page_down, .unknown => return null,
    }
}

fn charLookup(c: u21, mods: input.Modifiers) ?Action {
    if (mods.ctrl) {
        return switch (c) {
            'a' => .move_to_start,
            'b' => .move_left,
            'c' => .cancel_line,
            'd' => .eof,
            'e' => .move_to_end,
            'f' => .accept_hint,
            'h' => .delete_backward,
            'k' => .kill_to_end,
            'l' => .clear_screen,
            'n' => .history_next,
            'p' => .history_prev,
            'q' => .quoted_insert,
            'r' => .transient_input_open,
            't' => .transpose_chars,
            'u' => .kill_to_start,
            'v' => .quoted_insert,
            'w' => .kill_word_backward,
            'y' => .yank,
            'z' => .suspend_self,
            // Ctrl-_ is byte 0x1f, which our input parser dispatches
            // as char='_' with ctrl=true. Standard emacs undo binding.
            '_' => .undo,
            else => null,
        };
    }
    if (mods.alt) {
        return switch (c) {
            'b' => .move_word_left,
            'c' => .capitalize_word,
            'd' => .kill_word_forward,
            'f' => .move_word_right,
            'l' => .lower_case_word,
            'u' => .upper_case_word,
            'y' => .yank_pop,
            '<' => .history_first,
            '>' => .history_last,
            // M-. and M-_ are both bound to yank-last-arg in
            // readline / bash. Bash users hit M-. instinctively;
            // M-_ is the shifted alternative on layouts where M-.
            // is hard to reach.
            '.' => .yank_last_arg,
            '_' => .yank_last_arg,
            '\\' => .squeeze_whitespace,
            else => null,
        };
    }
    // Plain printable char with no binding → editor inserts it as text.
    return null;
}

test "keymap: enter accepts" {
    const km = Keymap.defaultEmacs();
    const ev = KeyEvent{ .code = .enter };
    try std.testing.expect(km.lookup(ev).? == .accept_line);
}

test "keymap: ctrl-a moves to start" {
    const km = Keymap.defaultEmacs();
    const ev = KeyEvent{ .code = .{ .char = 'a' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(km.lookup(ev).? == .move_to_start);
}

test "keymap: ctrl-c cancels" {
    const km = Keymap.defaultEmacs();
    const ev = KeyEvent{ .code = .{ .char = 'c' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(km.lookup(ev).? == .cancel_line);
}

test "keymap: plain char returns null (default-insert)" {
    const km = Keymap.defaultEmacs();
    const ev = KeyEvent{ .code = .{ .char = 'a' } };
    try std.testing.expect(km.lookup(ev) == null);
}

test "keymap: ctrl-arrow does word move" {
    const km = Keymap.defaultEmacs();
    const ev = KeyEvent{ .code = .arrow_left, .mods = .{ .ctrl = true } };
    try std.testing.expect(km.lookup(ev).? == .move_word_left);
}

// =============================================================================
// BindingTable tests
// =============================================================================

fn ctrlChar(c: u21) KeyEvent {
    return .{ .code = .{ .char = c }, .mods = .{ .ctrl = true } };
}

fn altChar(c: u21) KeyEvent {
    return .{ .code = .{ .char = c }, .mods = .{ .alt = true } };
}

test "bindings: encode round-trips distinct events" {
    const a = encodeKeyEvent(.{ .code = .{ .char = 'a' } }).?;
    const ctrl_a = encodeKeyEvent(ctrlChar('a')).?;
    const alt_a = encodeKeyEvent(altChar('a')).?;
    const enter = encodeKeyEvent(.{ .code = .enter }).?;
    const f1 = encodeKeyEvent(.{ .code = .{ .function = 1 } }).?;
    // All four must be distinct.
    try std.testing.expect(a != ctrl_a);
    try std.testing.expect(a != alt_a);
    try std.testing.expect(ctrl_a != alt_a);
    try std.testing.expect(a != enter);
    try std.testing.expect(enter != f1);
}

test "bindings: encode rejects unbindable kinds" {
    try std.testing.expect(encodeKeyEvent(.{ .code = .{ .text = "hi" } }) == null);
    try std.testing.expect(encodeKeyEvent(.{ .code = .{ .unknown = "?" } }) == null);
}

test "bindings: bind + lookup exact match" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const seq = [_]KeyEvent{ ctrlChar('x'), ctrlChar('e') };
    const prev = try t.bind(&seq, .{ .custom = 7 });
    try std.testing.expectEqual(@as(?Action, null), prev);

    const result = t.lookup(&seq);
    try std.testing.expect(result == .bound);
    switch (result) {
        .bound => |a| try std.testing.expect(a == .custom and a.custom == 7),
        else => return error.TestUnexpectedResult,
    }
}

test "bindings: prefix returns partial" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const full = [_]KeyEvent{ ctrlChar('x'), ctrlChar('e') };
    _ = try t.bind(&full, .{ .custom = 7 });

    const prefix = [_]KeyEvent{ctrlChar('x')};
    try std.testing.expect(t.lookup(&prefix) == .partial);
}

test "bindings: unbound returns none" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    _ = try t.bind(&[_]KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .{ .custom = 7 });

    const wrong_prefix = [_]KeyEvent{ctrlChar('z')};
    try std.testing.expect(t.lookup(&wrong_prefix) == .none);

    const wrong_full = [_]KeyEvent{ ctrlChar('x'), ctrlChar('q') };
    try std.testing.expect(t.lookup(&wrong_full) == .none);
}

test "bindings: rebind replaces and returns prior action" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const seq = [_]KeyEvent{ctrlChar('q')};
    _ = try t.bind(&seq, .{ .custom = 1 });
    const prev = try t.bind(&seq, .{ .custom = 2 });
    try std.testing.expect(prev != null);
    try std.testing.expect(prev.?.custom == 1);

    switch (t.lookup(&seq)) {
        .bound => |a| try std.testing.expectEqual(@as(u32, 2), a.custom),
        else => return error.TestUnexpectedResult,
    }
}

test "bindings: unbind removes only the targeted sequence" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const a = [_]KeyEvent{ ctrlChar('x'), ctrlChar('e') };
    const b = [_]KeyEvent{ ctrlChar('x'), ctrlChar('s') };
    _ = try t.bind(&a, .{ .custom = 1 });
    _ = try t.bind(&b, .{ .custom = 2 });

    try std.testing.expect(t.unbind(&a));
    try std.testing.expect(t.lookup(&a) == .none);
    try std.testing.expect(t.lookup(&b) == .bound);
    // Prefix Ctrl-X is still partial because b is still there.
    try std.testing.expect(t.lookup(&[_]KeyEvent{ctrlChar('x')}) == .partial);
}

test "bindings: unbind on missing sequence returns false" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expect(!t.unbind(&[_]KeyEvent{ctrlChar('q')}));
}

test "bindings: empty / overlong / unbindable seq rejected" {
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    try std.testing.expectError(error.EmptySequence, t.bind(&[_]KeyEvent{}, .undo));

    var too_long: [MAX_SEQUENCE + 1]KeyEvent = undefined;
    for (&too_long) |*e| e.* = ctrlChar('x');
    try std.testing.expectError(error.SequenceTooLong, t.bind(&too_long, .undo));

    const text = [_]KeyEvent{.{ .code = .{ .text = "x" } }};
    try std.testing.expectError(error.UnbindableKey, t.bind(&text, .undo));
}

test "bindings: prefix conflict — existing prefix vs new long sequence — refused" {
    // Per SPEC §5.2, a key K cannot simultaneously trigger a
    // single-key action AND start a multi-key sequence. If the user
    // tries to bind both, `bind()` rejects with `PrefixConflict`.
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const x = [_]KeyEvent{ctrlChar('x')};
    const xe = [_]KeyEvent{ ctrlChar('x'), ctrlChar('e') };
    _ = try t.bind(&x, .{ .custom = 1 });
    // Now try to bind Ctrl-X Ctrl-E — `x` would be unreachable.
    try std.testing.expectError(error.PrefixConflict, t.bind(&xe, .{ .custom = 2 }));
}

test "bindings: prefix conflict — existing long vs new prefix — refused" {
    // Reverse direction: the long sequence is bound first, then the
    // user tries to bind the prefix as a singleton. Same outcome.
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const xe = [_]KeyEvent{ ctrlChar('x'), ctrlChar('e') };
    const x = [_]KeyEvent{ctrlChar('x')};
    _ = try t.bind(&xe, .{ .custom = 2 });
    try std.testing.expectError(error.PrefixConflict, t.bind(&x, .{ .custom = 1 }));
}

test "bindings: rebind same sequence is not a prefix conflict" {
    // Replacing an existing binding (exact-length match) is allowed
    // and returns the prior action. Not a PrefixConflict.
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    const x = [_]KeyEvent{ctrlChar('x')};
    _ = try t.bind(&x, .{ .custom = 1 });
    const prev = try t.bind(&x, .{ .custom = 9 });
    try std.testing.expect(prev != null);
    try std.testing.expect(prev.?.custom == 1);
}

test "bindings: non-conflicting siblings ok" {
    // `Ctrl-X Ctrl-E` and `Ctrl-X Ctrl-S` share a prefix but neither
    // is a prefix of the other, so both can coexist.
    var t = BindingTable.init(std.testing.allocator);
    defer t.deinit();

    _ = try t.bind(&[_]KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .{ .custom = 1 });
    _ = try t.bind(&[_]KeyEvent{ ctrlChar('x'), ctrlChar('s') }, .{ .custom = 2 });
    // The shared prefix `Ctrl-X` returns partial.
    try std.testing.expect(t.lookup(&[_]KeyEvent{ctrlChar('x')}) == .partial);
}
