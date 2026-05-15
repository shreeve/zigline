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
    history_first,
    history_last,
    /// Insert the last whitespace-separated token of the most-
    /// recently-accepted history entry at the cursor. Repeated
    /// invocations cycle back through earlier entries.
    yank_last_arg,

    // Completion.
    complete,
    /// Accept the active virtual hint. If no hint is active, behaves
    /// like `move_right` so Right Arrow / Ctrl-F keep normal movement.
    accept_hint,

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

    // Kill ring. The kill_* actions above (kill_to_start /
    // kill_to_end / kill_word_backward / kill_word_forward) push
    // the deleted text onto the ring; these two pull it back.
    yank,
    yank_pop,

    // Undo / redo within the current line's edit history. Each
    // `accept_line` clears the history so undo never crosses lines.
    undo,
    redo,

    // In-place text transforms — emacs-style buffer ops with no
    // kill-ring interaction. Each is one undo step.
    /// Swap the cluster ending at the cursor with the cluster
    /// starting at the cursor. At end-of-buffer, swap the last two.
    transpose_chars,
    /// Uppercase the first ASCII letter of the word at/after cursor;
    /// lowercase the rest. Cursor lands past the word.
    capitalize_word,
    /// Uppercase every ASCII letter in the word at/after cursor.
    upper_case_word,
    /// Lowercase every ASCII letter in the word at/after cursor.
    lower_case_word,
    /// Delete every horizontal-whitespace byte adjacent to the
    /// cursor (matches emacs `delete-horizontal-space`).
    squeeze_whitespace,

    /// Insert the next received byte literally, bypassing the
    /// keymap. Useful for typing actual control bytes (`Ctrl-V Ctrl-A`
    /// inserts `\x01`). One key event of "raw" mode.
    quoted_insert,

    // Application-defined extension. The keymap returns
    // `.custom = id` for app-specific keystrokes; the editor invokes
    // `Options.custom_action` (if set) and applies the returned
    // `CustomActionResult` (insert / replace / accept / cancel /
    // no-op). The `id` is opaque to zigline — apps assign their own
    // numeric labels.
    custom: u32,
};

test "actions: tagged union compiles" {
    const a: Action = .move_left;
    _ = a;
    const b: Action = .{ .insert_text = "hi" };
    _ = b;
}
