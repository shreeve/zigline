//! Transient input mode — editor-owned overlay for reverse-incremental
//! history search and similar "type a query, see a preview, accept or
//! abort" UX patterns.
//!
//! The application binds `Action.transient_input_open` (Ctrl-R by
//! default) to enter the mode. While active, the editor:
//!
//!   - Routes typed printable bytes into a separate **query** buffer
//!     (NOT the main editor buffer).
//!   - Calls the configured `TransientInputHook` to translate query
//!     state into a *preview* (the would-be replacement) plus an
//!     optional *status* prefix (e.g. `(reverse-i-search): `).
//!   - Renders the overlay as `status + query + preview` on the
//!     prompt row, reusing the main renderer (status acts as the
//!     prompt, query as the buffer, preview as a dim ghost-text
//!     suffix). Width math, wrap, phantom-newline, and stale-frame
//!     clearing all reuse the standard renderer machinery.
//!   - On Enter: if a preview is present (including an explicitly
//!     empty replacement), replaces the main buffer with it as a
//!     single undoable Replace step, exits the mode. The line is
//!     NOT submitted; the user must press Enter again to run.
//!   - On Esc / Ctrl-G: calls the hook with `.aborted` (best-effort)
//!     and exits without modifying the main buffer.
//!   - On Ctrl-C: exits the mode and cancels the line via the same
//!     path as a normal `cancel_line`.
//!
//! The main editor buffer is never mutated during transient mode
//! (only on accept). The hook is consultative: zigline owns the UI
//! state and the keystrokes; the application owns ranking and
//! match selection.
//!
//! Lifetime contract: `preview` and `status` slices in
//! `TransientInputResult` are borrowed from the hook and only need to
//! live until the call returns. The editor copies into its own
//! transient state.
//!
//! Validation: hook-supplied `preview` and `status` must be valid
//! UTF-8 with no control bytes (same `findUnsafeByte` policy as
//! completion and hint hooks). Failures are field-level:
//!
//!   - **Invalid `preview`**: dropped (no preview rendered; Enter
//!     becomes a no-op), `status` is still applied.
//!   - **Invalid `status`**: fall back to the editor default
//!     `(reverse-i-search): `, `preview` is still applied.
//!   - Either failure routes a `transient_input_invalid_text`
//!     diagnostic.
//!
//! A hook that **returns an error** is a different category: the
//! editor routes `transient_input_hook_failed` and **leaves the
//! previous cached preview/status in place**. Rationale: a transient
//! glitch (network blip during a hook that consults a remote ranker,
//! a one-off allocation failure) shouldn't visually wipe the user's
//! last good match. The hook gets to recover on the next event.
//!
//! Keymap policy: while transient mode is active, the editor uses an
//! internal whitelist key handler (typed bytes / Backspace / Delete /
//! Left / Right / Home / End / Ctrl-A / Ctrl-E / Ctrl-H / Ctrl-R /
//! Ctrl-G / Esc / Enter / Ctrl-C). The application's normal keymap
//! (including any `BindingTable` overlay or custom-action bindings)
//! is **not consulted** during transient mode. Embedders that need
//! to alter transient-mode key handling should do so in their hook
//! (e.g. by mapping a typed character to a meta-command in the
//! query) rather than via the keymap.

const std = @import("std");

pub const TransientInputEvent = enum {
    /// Ctrl-R was just dispatched; transient mode just opened. Query
    /// is empty. Hook should return whatever it wants to seed the
    /// initial preview/status with (typically null preview + a
    /// default status).
    opened,
    /// User typed or deleted in the query. Hook should re-search
    /// against the current query and return the new top match.
    query_changed,
    /// User pressed Ctrl-R again while transient mode is already
    /// open. Hook should advance to the *next* match for the
    /// current query (older, in standard reverse-i-search semantics).
    next,
    /// User pressed Esc / Ctrl-G to abort. Hook is notified
    /// best-effort so it can clean up internal state. The editor
    /// has already decided to exit; hook errors do NOT prevent
    /// abort.
    aborted,
};

pub const TransientInputRequest = struct {
    /// Snapshot of the main editor buffer at hook-call time. The
    /// main buffer is never mutated during transient mode, so this
    /// equals `Editor.buffer.slice()` for the duration of the mode.
    /// Borrowed; valid only for the duration of `updateFn`.
    original_buffer: []const u8,
    /// Cursor byte offset in `original_buffer` at the moment Ctrl-R
    /// was pressed. Slash uses this to determine whether the user
    /// invoked search from mid-line vs end-of-line.
    original_cursor_byte: usize,
    /// Current query buffer contents. Borrowed.
    query: []const u8,
    /// Cursor byte offset in `query`.
    query_cursor_byte: usize,
    /// What triggered this hook invocation.
    event: TransientInputEvent,
};

pub const TransientInputResult = struct {
    /// Selected preview text (the would-be replacement of the main
    /// buffer if the user accepts). Three states:
    ///
    ///   - `null`         → no match. Render no preview. Enter is a
    ///                      no-op; user stays in transient mode.
    ///   - `""`  (empty)  → an explicitly empty replacement. Render
    ///                      no preview text. Enter accepts and
    ///                      clears the main buffer.
    ///   - non-empty      → render dimmed after the query. Enter
    ///                      accepts.
    ///
    /// Borrowed; editor copies into its own state.
    preview: ?[]const u8 = null,
    /// Optional status text to render as the prompt prefix in
    /// transient mode (e.g. `(reverse-i-search): ` or
    /// `(failing-i-search) `). `null` → editor uses the default
    /// `(reverse-i-search): `. Borrowed; editor copies.
    status: ?[]const u8 = null,
};

pub const TransientInputHook = struct {
    ctx: *anyopaque,
    /// Called by the editor on transient-mode events. No allocator
    /// argument — returned slices are borrowed and the editor copies
    /// them. Hook implementations should keep scratch storage on
    /// `ctx` valid until the call returns.
    updateFn: *const fn (
        ctx: *anyopaque,
        request: TransientInputRequest,
    ) anyerror!TransientInputResult,

    pub fn update(
        self: TransientInputHook,
        request: TransientInputRequest,
    ) anyerror!TransientInputResult {
        return self.updateFn(self.ctx, request);
    }
};

test "transient: types compile" {
    const r = TransientInputResult{ .preview = "match", .status = "(reverse-i-search): " };
    try std.testing.expectEqualStrings("match", r.preview.?);
    try std.testing.expectEqualStrings("(reverse-i-search): ", r.status.?);
}

test "transient: null vs empty preview is distinguishable" {
    const a = TransientInputResult{ .preview = null };
    const b = TransientInputResult{ .preview = "" };
    try std.testing.expect(a.preview == null);
    try std.testing.expect(b.preview != null);
    try std.testing.expectEqual(@as(usize, 0), b.preview.?.len);
}
