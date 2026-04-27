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

pub const HighlightHook = struct {
    ctx: *anyopaque,
    /// Called by the editor before each render. The `buffer` slice
    /// is the current buffer bytes; the hook returns spans
    /// allocated from the supplied `allocator`. The editor frees
    /// the span slice after rendering.
    highlightFn: *const fn (
        ctx: *anyopaque,
        allocator: Allocator,
        buffer: []const u8,
    ) anyerror![]HighlightSpan,

    pub fn highlight(
        self: HighlightHook,
        allocator: Allocator,
        buffer: []const u8,
    ) anyerror![]HighlightSpan {
        return self.highlightFn(self.ctx, allocator, buffer);
    }
};

test "highlight: types compile" {
    const s = Style{ .fg = .{ .basic = .red }, .bold = true };
    _ = s;
}
