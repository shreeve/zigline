//! Renderer — Buffer + state → terminal bytes.
//!
//! See SPEC.md §6. Full-repaint with grapheme-aware width math; the
//! wrap-aware algorithm and the phantom-newline edge case are lifted
//! from slash's `LineEditor.render` (src/repl.zig). Differences:
//!   - prompt width comes from `Prompt.width`, not `prompt.bytes.len`
//!     (so escapes in the prompt don't break column accounting).
//!   - cursor is byte-offset into the buffer; we walk clusters to
//!     compute the cursor's column, not raw byte count.
//!   - highlight is span-based: spans are sorted, validated, and
//!     SGR is emitted at boundaries.
//!   - prior-block clearing is per-row `\x1b[K` (contained), not the
//!     `\x1b[J` clear-to-EOS slash used (which nukes app output below).
//!   - writes go through `Terminal.writeAll` (handles partial writes /
//!     EINTR), not bare `std.c.write`.
//!   - the column math is split out into `Layout.compute` so it's
//!     unit-testable without a real terminal.
//!
//! Row-granular diff is the next milestone (FUTURE.md).

const std = @import("std");

const buffer_mod = @import("buffer.zig");
const grapheme = @import("grapheme.zig");
const highlight = @import("highlight.zig");
const prompt_mod = @import("prompt.zig");
const terminal_mod = @import("terminal.zig");

pub const Allocator = std.mem.Allocator;

/// Result of the per-render width math: where everything sits in
/// terminal cells. Pulled out as a value so it's unit-testable without
/// instantiating a real terminal. See SPEC.md §6.
pub const Layout = struct {
    /// Total display columns of prompt + buffer.
    total_cols: usize,
    /// Display columns of prompt + buffer up to the cursor.
    cursor_cols: usize,
    /// Number of terminal rows the rendered frame occupies.
    rows: usize,
    /// Cursor's row within the frame (0-indexed from prompt start).
    cursor_row: usize,
    /// Cursor's column within `cursor_row`.
    cursor_col: usize,
    /// True if `total_cols` is an exact multiple of `term_cols` —
    /// the autowrap-corner case where the terminal hasn't yet
    /// committed to the next row, and we have to emit `\n\r` to
    /// pin the cursor to a known position.
    needs_phantom_nl: bool,

    pub fn compute(
        prompt_width: usize,
        clusters: []const buffer_mod.Cluster,
        cursor_byte: usize,
        term_cols: usize,
    ) Layout {
        std.debug.assert(term_cols > 0);

        var prebuf: usize = 0;
        var bufw: usize = 0;
        for (clusters) |c| {
            if (c.byte_start < cursor_byte) prebuf += c.width;
            bufw += c.width;
        }
        const total = prompt_width + bufw;
        const cursor = prompt_width + prebuf;
        const rows = if (total == 0) 1 else (total + term_cols - 1) / term_cols;
        const cur_row = if (cursor == 0) 0 else cursor / term_cols;
        const cur_col = cursor % term_cols;
        return .{
            .total_cols = total,
            .cursor_cols = cursor,
            .rows = rows,
            .cursor_row = cur_row,
            .cursor_col = cur_col,
            .needs_phantom_nl = total > 0 and total % term_cols == 0,
        };
    }
};

pub const Renderer = struct {
    allocator: Allocator,
    terminal: *terminal_mod.Terminal,
    width_policy: grapheme.WidthPolicy,

    /// State carried across renders for repaint correctness.
    last_rows: usize = 0,
    last_cursor_row: usize = 0,
    last_term_cols: u16 = 0,
    force_repaint: bool = true,

    /// Scratch output buffer; reused across renders to avoid
    /// per-keystroke allocation. 64 KB is plenty for any humanly-
    /// typed line at typical terminal widths.
    out_buf: [65536]u8 = undefined,

    pub fn init(
        allocator: Allocator,
        terminal: *terminal_mod.Terminal,
        width_policy: grapheme.WidthPolicy,
    ) Renderer {
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .width_policy = width_policy,
        };
    }

    pub fn invalidate(self: *Renderer) void {
        self.force_repaint = true;
        self.last_rows = 0;
        self.last_cursor_row = 0;
    }

    /// Repaint the prompt + buffer + cursor.
    pub fn render(
        self: *Renderer,
        prompt: prompt_mod.Prompt,
        buffer: *buffer_mod.Buffer,
        spans: []const highlight.HighlightSpan,
    ) !void {
        try buffer.ensureClusters();
        const size = self.terminal.querySize();
        const cols: usize = if (size.cols == 0) 80 else size.cols;
        if (self.last_term_cols != size.cols) self.invalidate();
        self.last_term_cols = size.cols;

        const layout = Layout.compute(
            prompt.width,
            buffer.clusters.items,
            buffer.cursor_byte,
            cols,
        );

        var w = std.Io.Writer.fixed(&self.out_buf);

        // Step 1 — climb to the top of the previous render.
        if (self.last_cursor_row > 0) {
            try w.print("\x1b[{d}A", .{self.last_cursor_row});
        }
        try w.writeByte('\r');

        // Step 2 — clear the prior block row-by-row. Per-row `\x1b[K`
        // is contained: it doesn't touch anything below, which matters
        // when the application has printed output beneath the prompt
        // (slash's `\x1b[J` would have nuked that output).
        if (self.last_rows > 0) {
            var i: usize = 0;
            while (i < self.last_rows) : (i += 1) {
                try w.writeAll("\x1b[K");
                if (i + 1 < self.last_rows) try w.writeAll("\x1b[B");
            }
            if (self.last_rows > 1) {
                try w.print("\x1b[{d}A", .{self.last_rows - 1});
            }
            try w.writeByte('\r');
        }

        // Step 3 — write prompt + buffer (with optional spans).
        try w.writeAll(prompt.bytes);
        try writeBuffer(&w, buffer, spans);

        // Step 4 — phantom-newline fix for the autowrap edge case.
        if (layout.needs_phantom_nl) try w.writeAll("\n\r");

        // Step 5 — move cursor to (cursor_row, cursor_col).
        const end_row: usize = if (layout.needs_phantom_nl) layout.rows else layout.rows - 1;
        if (end_row > layout.cursor_row) {
            try w.print("\x1b[{d}A", .{end_row - layout.cursor_row});
        } else if (layout.cursor_row > end_row) {
            try w.print("\x1b[{d}B", .{layout.cursor_row - end_row});
        }
        try w.writeByte('\r');
        if (layout.cursor_col > 0) {
            try w.print("\x1b[{d}C", .{layout.cursor_col});
        }

        const bytes = w.buffered();
        try self.terminal.writeAll(bytes);

        self.last_rows = layout.rows;
        self.last_cursor_row = layout.cursor_row;
        self.force_repaint = false;
    }

    /// Move cursor below the rendered area and emit a newline. Called
    /// at the end of `readLine` so subsequent program output starts on
    /// a fresh row.
    pub fn finalize(self: *Renderer) !void {
        // Move from last_cursor_row to last_rows, then \r\n.
        if (self.last_rows > self.last_cursor_row + 1) {
            var b: [16]u8 = undefined;
            const s = std.fmt.bufPrint(
                &b,
                "\x1b[{d}B",
                .{self.last_rows - self.last_cursor_row - 1},
            ) catch "";
            try self.terminal.writeAll(s);
        }
        try self.terminal.writeAll("\r\n");
        self.last_rows = 0;
        self.last_cursor_row = 0;
    }
};

/// Walk buffer clusters, emitting SGR transitions at span boundaries.
/// Spans must be pre-sorted by `start`. Overlapping spans are not
/// validated here; the caller (Editor) sorts and dedupes before
/// passing them in.
fn writeBuffer(
    w: *std.Io.Writer,
    buffer: *buffer_mod.Buffer,
    spans: []const highlight.HighlightSpan,
) !void {
    if (spans.len == 0) {
        try w.writeAll(buffer.slice());
        return;
    }

    const bytes = buffer.slice();
    var i: usize = 0;
    var span_idx: usize = 0;
    var active: ?highlight.Style = null;

    while (i < bytes.len) {
        // Close any active span whose end is at or before i.
        if (active != null and span_idx <= spans.len) {
            const cur = spans[span_idx - 1];
            if (i >= cur.end) {
                try w.writeAll("\x1b[0m");
                active = null;
            }
        }
        // Open the next span if its start is here.
        if (span_idx < spans.len and spans[span_idx].start == i) {
            const sp = spans[span_idx];
            if (active != null) try w.writeAll("\x1b[0m");
            try writeSgrOpen(w, sp.style);
            active = sp.style;
            span_idx += 1;
        }
        try w.writeByte(bytes[i]);
        i += 1;
    }
    if (active != null) try w.writeAll("\x1b[0m");
}

fn writeSgrOpen(w: *std.Io.Writer, style: highlight.Style) !void {
    try w.writeAll("\x1b[");
    var first = true;
    if (style.bold) {
        if (!first) try w.writeAll(";");
        try w.writeAll("1");
        first = false;
    }
    if (style.dim) {
        if (!first) try w.writeAll(";");
        try w.writeAll("2");
        first = false;
    }
    if (style.italic) {
        if (!first) try w.writeAll(";");
        try w.writeAll("3");
        first = false;
    }
    if (style.underline) {
        if (!first) try w.writeAll(";");
        try w.writeAll("4");
        first = false;
    }
    if (style.fg) |fg| {
        if (!first) try w.writeAll(";");
        try writeColorCode(w, fg, true);
        first = false;
    }
    if (style.bg) |bg| {
        if (!first) try w.writeAll(";");
        try writeColorCode(w, bg, false);
        first = false;
    }
    if (first) try w.writeAll("0");
    try w.writeAll("m");
}

fn writeColorCode(w: *std.Io.Writer, c: highlight.Color, fg: bool) !void {
    const base: u8 = if (fg) 30 else 40;
    const bright_base: u8 = if (fg) 90 else 100;
    switch (c) {
        .basic => |b| try w.print("{d}", .{base + @as(u8, @intFromEnum(b))}),
        .bright => |b| try w.print("{d}", .{bright_base + @as(u8, @intFromEnum(b))}),
        .indexed => |idx| try w.print("{d};5;{d}", .{ base + 8, idx }),
        .rgb => |rgb| try w.print("{d};2;{d};{d};{d}", .{ base + 8, rgb.r, rgb.g, rgb.b }),
    }
}

test "renderer: writeBuffer no spans" {
    var b = buffer_mod.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("hello");

    var out: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeBuffer(&w, &b, &.{});
    try std.testing.expectEqualStrings("hello", w.buffered());
}

test "renderer: writeBuffer single span" {
    var b = buffer_mod.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("hello");

    const spans = [_]highlight.HighlightSpan{
        .{ .start = 0, .end = 5, .style = .{ .fg = .{ .basic = .red } } },
    };

    var out: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeBuffer(&w, &b, &spans);
    const got = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[0m") != null);
}

// =============================================================================
// Layout / width-math tests — see SPEC.md §6 width math.
//
// These tests work by hand-building a `[]Cluster` (no buffer required)
// so the math is exercised in isolation from the terminal.
// =============================================================================

fn cluster1(start: usize, end: usize) buffer_mod.Cluster {
    return .{ .byte_start = start, .byte_end = end, .width = 1 };
}

fn cluster2(start: usize, end: usize) buffer_mod.Cluster {
    return .{ .byte_start = start, .byte_end = end, .width = 2 };
}

test "layout: empty buffer, empty prompt, one row" {
    const lay = Layout.compute(0, &.{}, 0, 80);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_col);
    try std.testing.expect(!lay.needs_phantom_nl);
}

test "layout: short ASCII line on wide terminal" {
    // Prompt "$ " (2) + "hello" (5) = 7 cells; cursor at end.
    const cs = [_]buffer_mod.Cluster{
        cluster1(0, 1), cluster1(1, 2), cluster1(2, 3), cluster1(3, 4), cluster1(4, 5),
    };
    const lay = Layout.compute(2, &cs, 5, 80);
    try std.testing.expectEqual(@as(usize, 7), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 7), lay.cursor_col);
    try std.testing.expect(!lay.needs_phantom_nl);
}

test "layout: cursor mid-line lands on right column" {
    const cs = [_]buffer_mod.Cluster{
        cluster1(0, 1), cluster1(1, 2), cluster1(2, 3), cluster1(3, 4), cluster1(4, 5),
    };
    // Cursor after "hel" (cursor_byte=3) with prompt width 2 → col 5.
    const lay = Layout.compute(2, &cs, 3, 80);
    try std.testing.expectEqual(@as(usize, 5), lay.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_row);
}

test "layout: exact-width line triggers phantom newline" {
    // 8-col terminal; "$ " (2) + "abcdef" (6) = 8 cells exactly.
    var cs: [6]buffer_mod.Cluster = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) cs[i] = cluster1(i, i + 1);
    const lay = Layout.compute(2, &cs, 6, 8);
    try std.testing.expectEqual(@as(usize, 8), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
    try std.testing.expect(lay.needs_phantom_nl);
}

test "layout: wrapped buffer occupies multiple rows" {
    // 10-col terminal, prompt "> " (2), 18 ASCII chars.
    var cs: [18]buffer_mod.Cluster = undefined;
    var i: usize = 0;
    while (i < 18) : (i += 1) cs[i] = cluster1(i, i + 1);
    const lay = Layout.compute(2, &cs, 18, 10);
    // total = 20, ceil(20/10) = 2 rows, but the trailing column is
    // exactly at the boundary → phantom-nl, the terminal hasn't
    // committed to row 1, so we treat it as 2 rows + nl correction.
    try std.testing.expectEqual(@as(usize, 20), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 2), lay.rows);
    try std.testing.expectEqual(@as(usize, 2), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_col);
    try std.testing.expect(lay.needs_phantom_nl);
}

test "layout: wide CJK clusters count as 2 cells each" {
    // 20-col terminal, no prompt, 5 CJK clusters of width 2 each.
    const cs = [_]buffer_mod.Cluster{
        cluster2(0, 3), cluster2(3, 6), cluster2(6, 9), cluster2(9, 12), cluster2(12, 15),
    };
    const lay = Layout.compute(0, &cs, 9, 20);
    // 10 columns total, cursor after 3 clusters = 6 cells.
    try std.testing.expectEqual(@as(usize, 10), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 6), lay.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
}

test "layout: cursor on second visual row past wrap" {
    // 5-col terminal, no prompt, 8 ASCII clusters; cursor at byte 7.
    var cs: [8]buffer_mod.Cluster = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) cs[i] = cluster1(i, i + 1);
    const lay = Layout.compute(0, &cs, 7, 5);
    // 8 cells / 5 per row → 2 rows; cursor at col 7 / 5 = row 1, col 2.
    try std.testing.expectEqual(@as(usize, 2), lay.rows);
    try std.testing.expectEqual(@as(usize, 1), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), lay.cursor_col);
    try std.testing.expect(!lay.needs_phantom_nl);
}
