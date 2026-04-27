//! Keymap — KeyEvent → Action mapping.
//!
//! See SPEC.md §5. Default emacs-style keymap. Applications can swap
//! in alternative keymaps by constructing a `Keymap` with a different
//! `lookupFn`.

const std = @import("std");

const input = @import("input.zig");
const actions = @import("actions.zig");

pub const KeyEvent = input.KeyEvent;
pub const KeyCode = input.KeyCode;
pub const Action = actions.Action;

pub const Keymap = struct {
    lookupFn: *const fn (key: KeyEvent) ?Action,

    pub fn lookup(self: Keymap, key: KeyEvent) ?Action {
        return self.lookupFn(key);
    }

    pub fn defaultEmacs() Keymap {
        return .{ .lookupFn = emacsLookup };
    }
};

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
        .arrow_right => return if (key.mods.ctrl) Action.move_word_right else Action.move_right,
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
            'f' => .move_right,
            'h' => .delete_backward,
            'k' => .kill_to_end,
            'l' => .clear_screen,
            'n' => .history_next,
            'p' => .history_prev,
            'u' => .kill_to_start,
            'w' => .kill_word_backward,
            'z' => .suspend_self,
            else => null,
        };
    }
    if (mods.alt) {
        return switch (c) {
            'b' => .move_word_left,
            'f' => .move_word_right,
            'd' => .kill_word_forward,
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
