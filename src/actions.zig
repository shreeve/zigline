//! Actions — the typed editor commands.
//!
//! See SPEC.md §5. Keymaps produce `Action` values; the editor's
//! dispatcher consumes them. Splitting the two layers makes the
//! keymap testable in isolation, and lets applications swap in a
//! different keymap (vi-mode, custom bindings) without touching the
//! editor.

const std = @import("std");

pub const Action = union(enum) {
    // Text editing.
    insert_text: []const u8,
    delete_backward,
    delete_forward,
    kill_to_start,
    kill_to_end,
    kill_word_backward,
    kill_word_forward,

    // Cursor movement.
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_to_start,
    move_to_end,

    // History.
    history_prev,
    history_next,

    // Completion.
    complete,

    // Line lifecycle.
    accept_line,
    cancel_line,
    eof,

    // Display.
    clear_screen,
    redraw,

    // Job control. Suspend self via SIGTSTP — the editor's signal
    // handler restores cooked termios, re-raises with default
    // disposition, and on resume re-enters raw mode + repaints.
    suspend_self,
};

pub const DispatchOutcome = union(enum) {
    /// Action applied; continue the read loop.
    continue_,
    /// Line was accepted; readLine returns this slice.
    accepted: []u8,
    /// Line was cancelled (Ctrl-C); readLine returns interrupt.
    cancelled,
    /// EOF was signaled; readLine returns eof.
    eof,
};

test "actions: tagged union compiles" {
    const a: Action = .move_left;
    _ = a;
    const b: Action = .{ .insert_text = "hi" };
    _ = b;
}
