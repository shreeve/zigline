//! Highlight — semantic spans, not raw ANSI.
//!
//! See SPEC.md §6 (highlight integration) and §7 (hook types).
//! Applications return `[]HighlightSpan` from a `HighlightHook`.
//! The renderer owns SGR generation — turning spans into ANSI escape
//! sequences — so that diff rendering stays tractable in v0.2 and
//! theme support is feasible later.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const HighlightSpan = struct {
    /// Inclusive byte offset into the buffer.
    start: usize,
    /// Exclusive byte offset into the buffer.
    end: usize,
    style: Style,
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,
};

pub const Color = union(enum) {
    /// 8-color basic palette — broadest terminal compatibility.
    basic: BasicColor,
    /// Bright variant of a basic color.
    bright: BasicColor,
    /// 256-color palette index.
    indexed: u8,
    /// 24-bit truecolor.
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const BasicColor = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
};

/// Snapshot passed to a `HighlightHook`. Borrowed; valid only for
/// the duration of `highlightFn`. Mirrors `CompletionRequest` and
/// `CustomActionRequest` for cross-hook consistency.
pub const HighlightRequest = struct {
    /// Buffer contents at hook-call time.
    buffer: []const u8,
    /// Cursor byte offset. Always at a grapheme cluster boundary.
    /// Cursor-sensitive highlights — bracket matching, current-word
    /// emphasis, unclosed-string warnings — read this field.
    cursor_byte: usize,
};

pub const HighlightHook = struct {
    ctx: *anyopaque,
    /// Called by the editor before each render. The hook returns
    /// spans allocated from the supplied `allocator`; the editor
    /// frees the span slice after rendering.
    highlightFn: *const fn (
        ctx: *anyopaque,
        allocator: Allocator,
        request: HighlightRequest,
    ) anyerror![]HighlightSpan,

    pub fn highlight(
        self: HighlightHook,
        allocator: Allocator,
        request: HighlightRequest,
    ) anyerror![]HighlightSpan {
        return self.highlightFn(self.ctx, allocator, request);
    }
};

test "highlight: types compile" {
    const s = Style{ .fg = .{ .basic = .red }, .bold = true };
    _ = s;
}
