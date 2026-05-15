//! Hint — virtual suffix text for fish-style autosuggestions.
//!
//! Hints are rendered after the editable buffer but are NOT inserted
//! into `Buffer` unless the user dispatches `Action.accept_hint`.
//! Slash uses this to surface history-based command suggestions.
//!
//! Lifetime contract: the `text` slice in `HintResult` is borrowed
//! from the caller and only needs to live until `hintFn` returns.
//! The editor copies the text into its own cache (so the hint that
//! was rendered is exactly what `accept_hint` inserts, even if the
//! hook's underlying ranking changes between renders).
//!
//! Validation: hint text must be valid UTF-8 with no control bytes.
//! Failures route to the diagnostic hook and the hint is dropped
//! (same policy as completion candidates).
//!
//! Cost note: the hint hook is invoked on every render whose cursor
//! is at end-of-buffer. Hint hooks should be cheap or memoize on
//! their side; debouncing is post-v1.0 (see FUTURE.md).

const std = @import("std");
const highlight = @import("highlight.zig");

pub const Style = highlight.Style;

pub const HintRequest = struct {
    /// Buffer contents at hook-call time. Borrowed; valid only for
    /// the duration of `hintFn`.
    buffer: []const u8,
    /// Cursor byte offset.
    cursor_byte: usize,
};

pub const HintResult = struct {
    /// Virtual suffix to draw after the editable buffer. Borrowed
    /// from the hook; the editor copies before caching for accept.
    text: []const u8,
    /// Optional style override.
    ///
    ///   - `null`        → editor uses the default ghost style
    ///                     (`.{ .dim = true }`).
    ///   - `Style{ ... }` → caller-controlled styling. Pass `.{}`
    ///                     explicitly for an unstyled hint (rare;
    ///                     usually visually indistinguishable from
    ///                     real buffer text).
    style: ?Style = null,
};

pub const HintHook = struct {
    ctx: *anyopaque,
    /// Called by the editor before each render whose cursor is at
    /// end-of-buffer. Return `null` (or a result with empty `text`)
    /// for "no hint."
    hintFn: *const fn (
        ctx: *anyopaque,
        request: HintRequest,
    ) anyerror!?HintResult,

    pub fn hint(
        self: HintHook,
        request: HintRequest,
    ) anyerror!?HintResult {
        return self.hintFn(self.ctx, request);
    }
};

test "hint: types compile" {
    const h = HintResult{ .text = " world" };
    try std.testing.expectEqualStrings(" world", h.text);
    try std.testing.expect(h.style == null);
}

test "hint: explicit style overrides default" {
    const h = HintResult{ .text = "x", .style = .{ .fg = .{ .basic = .cyan } } };
    try std.testing.expect(h.style != null);
    try std.testing.expect(h.style.?.fg != null);
}
