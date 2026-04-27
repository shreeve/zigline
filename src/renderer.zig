//! Renderer — Buffer + state → terminal bytes.
//!
//! See SPEC.md §6. Full-repaint with grapheme-aware width math; the
//! wrap-aware algorithm and the phantom-newline edge case are lifted
//! from slash's `LineEditor.render` (src/repl.zig). Differences:
//!   - prompt width comes from `Prompt.width`, not `prompt.bytes.len`
//!     (so escapes in the prompt don't break column accounting).
//!   - cursor is byte-offset into the buffer; we walk clusters to
//!     compute the cursor's column, not raw byte count.
//!   - highlight spans are sorted, validated (non-overlapping, end >
//!     start, in-range), and snapped to cluster boundaries before
//!     SGR emission. Bad spans are dropped, not propagated.
//!   - prior-block clearing is per-row `\x1b[K` (contained), not the
//!     `\x1b[J` clear-to-EOS slash used (which nukes app output below).
//!   - on detected width change, the renderer scrolls past the
//!     reflowed-by-the-terminal old block and starts fresh.
//!   - writes go through `Terminal.writeAll` (handles partial writes /
//!     EINTR), not bare `std.c.write`.
//!   - the column math is split out into `Layout.compute` so it's
//!     unit-testable without a real terminal.
//!   - the renderer holds no pointer to the Terminal — the caller
//!     passes one in to each `render` / `finalize` call. This lets
//!     `Editor` be returned by value from `init` without the classic
//!     intrusive-pointer-into-stack-local hazard.
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
    width_policy: grapheme.WidthPolicy,

    /// State carried across renders for repaint correctness.
    last_rows: usize = 0,
    last_cursor_row: usize = 0,
    last_term_cols: u16 = 0,

    /// Reusable output buffer. Grown lazily; capacity is retained
    /// across renders to amortize allocation cost. For typical lines
    /// this stabilizes at a few KB after the first render.
    out_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// Reusable normalized-span buffer. Same amortization story.
    span_buf: std.ArrayListUnmanaged(highlight.HighlightSpan) = .empty,

    pub fn init(
        allocator: Allocator,
        width_policy: grapheme.WidthPolicy,
    ) Renderer {
        return .{
            .allocator = allocator,
            .width_policy = width_policy,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.out_buf.deinit(self.allocator);
        self.span_buf.deinit(self.allocator);
    }

    /// Tell the renderer that the cursor is at column 0 of a fresh
    /// row AND no rendered block is on screen below it (e.g. because
    /// the caller just wrote "\r\n", "^C\r\n", cleared the screen,
    /// or finished a `readLine` via `finalize`). The next `render`
    /// writes from the current cursor position without trying to
    /// climb up to a prior block.
    pub fn markFresh(self: *Renderer) void {
        self.last_rows = 0;
        self.last_cursor_row = 0;
        self.last_term_cols = 0;
    }

    /// Repaint the prompt + buffer + cursor.
    pub fn render(
        self: *Renderer,
        terminal: *terminal_mod.Terminal,
        prompt: prompt_mod.Prompt,
        buffer: *buffer_mod.Buffer,
        spans: []const highlight.HighlightSpan,
    ) !void {
        try buffer.ensureClusters();
        const size = terminal.querySize();
        const cols: usize = if (size.cols == 0) 80 else size.cols;

        // Width changed since last render: the terminal has already
        // reflowed our prior block in ways we can't reconstruct.
        // Best-effort: emit enough `\r\n`s to land below the bottom
        // of the old block (in the old width), then start fresh.
        // Old content stays in scrollback. Without reflow this is
        // exact; with reflow it's a heuristic, and visual artifacts
        // are accepted as the cost of a mid-edit resize.
        if (self.last_term_cols != 0 and self.last_term_cols != size.cols and self.last_rows > 0) {
            const rows_below = if (self.last_rows > self.last_cursor_row)
                self.last_rows - self.last_cursor_row
            else
                1;
            var i: usize = 0;
            while (i < rows_below) : (i += 1) try terminal.writeAll("\r\n");
            self.last_rows = 0;
            self.last_cursor_row = 0;
        }
        self.last_term_cols = size.cols;

        const layout = Layout.compute(
            prompt.width,
            buffer.clusters.items,
            buffer.cursor_byte,
            cols,
        );

        const normalized = try self.normalizeSpans(buffer, spans);

        self.out_buf.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.out_buf);
        defer self.out_buf = aw.toArrayList();
        const w = &aw.writer;

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
        try writeBuffer(w, buffer, normalized);

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

        try terminal.writeAll(aw.written());

        self.last_rows = layout.rows;
        self.last_cursor_row = layout.cursor_row;
    }

    /// Move cursor below the rendered area and emit a newline. Called
    /// at the end of `readLine` so subsequent program output starts on
    /// a fresh row.
    pub fn finalize(self: *Renderer, terminal: *terminal_mod.Terminal) !void {
        // If the previous render emitted a phantom newline, the cursor
        // is already at column 0 of a fresh row past the content
        // (`last_cursor_row == last_rows`). Adding another `\r\n`
        // would print a needless blank line.
        const at_phantom = self.last_cursor_row >= self.last_rows;
        if (!at_phantom) {
            if (self.last_rows > self.last_cursor_row + 1) {
                var b: [16]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &b,
                    "\x1b[{d}B",
                    .{self.last_rows - self.last_cursor_row - 1},
                ) catch "";
                try terminal.writeAll(s);
            }
            try terminal.writeAll("\r\n");
        }
        self.last_rows = 0;
        self.last_cursor_row = 0;
        self.last_term_cols = 0;
    }

    /// Validate, sort, snap-to-cluster-boundaries, and dedup-overlap
    /// the caller-supplied spans. Returns a slice borrowed from
    /// `self.span_buf` (valid until the next `render`).
    fn normalizeSpans(
        self: *Renderer,
        buffer: *buffer_mod.Buffer,
        in: []const highlight.HighlightSpan,
    ) ![]highlight.HighlightSpan {
        self.span_buf.clearRetainingCapacity();
        if (in.len == 0) return self.span_buf.items;
        const buf_len = buffer.bytes.items.len;

        try self.span_buf.ensureUnusedCapacity(self.allocator, in.len);
        for (in) |sp| {
            if (sp.end <= sp.start) continue; // empty or inverted
            if (sp.start >= buf_len) continue; // wholly past buffer
            const clamped_end = if (sp.end > buf_len) buf_len else sp.end;

            const snap = snapSpanToClusters(buffer.clusters.items, sp.start, clamped_end);
            if (snap.start >= snap.end) continue;
            self.span_buf.appendAssumeCapacity(.{
                .start = snap.start,
                .end = snap.end,
                .style = sp.style,
            });
        }

        // Stable sort by (start, then end). With equal-start spans
        // (which can happen when two distinct inputs snap outward to
        // the same cluster boundary), this guarantees a deterministic
        // "earliest input wins" + "longer span wins on tie" outcome
        // for the dedup-overlap pass below.
        std.mem.sort(highlight.HighlightSpan, self.span_buf.items, {}, struct {
            fn lt(_: void, a: highlight.HighlightSpan, b: highlight.HighlightSpan) bool {
                if (a.start != b.start) return a.start < b.start;
                return a.end > b.end;
            }
        }.lt);

        // Drop overlaps: keep the earliest, drop any whose start <
        // the kept span's end.
        var write_idx: usize = 0;
        var i: usize = 0;
        while (i < self.span_buf.items.len) : (i += 1) {
            const cur = self.span_buf.items[i];
            if (write_idx > 0) {
                const prev = self.span_buf.items[write_idx - 1];
                if (cur.start < prev.end) continue; // overlaps kept span
            }
            self.span_buf.items[write_idx] = cur;
            write_idx += 1;
        }
        self.span_buf.shrinkRetainingCapacity(write_idx);
        return self.span_buf.items;
    }
};

const SnappedRange = struct { start: usize, end: usize };

/// Snap `[start, end)` to cluster boundaries. The start floors to the
/// boundary at-or-before; the end ceils to the boundary at-or-after.
/// This expands the span to cover anything the caller pointed at —
/// the alternative (contract) silently loses requested highlighting.
fn snapSpanToClusters(
    clusters: []const buffer_mod.Cluster,
    start: usize,
    end: usize,
) SnappedRange {
    if (clusters.len == 0) return .{ .start = 0, .end = 0 };

    var snap_start = start;
    for (clusters) |c| {
        if (c.byte_start <= start and start < c.byte_end) {
            snap_start = c.byte_start;
            break;
        }
        if (c.byte_start > start) {
            // start fell exactly on a boundary that we already passed
            // (shouldn't happen with sequential clusters, but defensive).
            snap_start = c.byte_start;
            break;
        }
    }

    var snap_end = end;
    for (clusters) |c| {
        if (c.byte_start < end and end <= c.byte_end) {
            snap_end = c.byte_end;
            break;
        }
    }

    return .{ .start = snap_start, .end = snap_end };
}

/// Walk buffer bytes, emitting SGR transitions at span boundaries.
/// `spans` must be pre-normalized by `Renderer.normalizeSpans`:
/// sorted, non-overlapping, cluster-aligned, in range.
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
        if (active != null and span_idx > 0) {
            const cur = spans[span_idx - 1];
            if (i >= cur.end) {
                try w.writeAll("\x1b[0m");
                active = null;
            }
        }
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
    const lay = Layout.compute(2, &cs, 3, 80);
    try std.testing.expectEqual(@as(usize, 5), lay.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_row);
}

test "layout: exact-width line triggers phantom newline" {
    var cs: [6]buffer_mod.Cluster = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) cs[i] = cluster1(i, i + 1);
    const lay = Layout.compute(2, &cs, 6, 8);
    try std.testing.expectEqual(@as(usize, 8), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
    try std.testing.expect(lay.needs_phantom_nl);
}

test "layout: wrapped buffer occupies multiple rows" {
    var cs: [18]buffer_mod.Cluster = undefined;
    var i: usize = 0;
    while (i < 18) : (i += 1) cs[i] = cluster1(i, i + 1);
    const lay = Layout.compute(2, &cs, 18, 10);
    try std.testing.expectEqual(@as(usize, 20), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 2), lay.rows);
    try std.testing.expectEqual(@as(usize, 2), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_col);
    try std.testing.expect(lay.needs_phantom_nl);
}

test "layout: wide CJK clusters count as 2 cells each" {
    const cs = [_]buffer_mod.Cluster{
        cluster2(0, 3), cluster2(3, 6), cluster2(6, 9), cluster2(9, 12), cluster2(12, 15),
    };
    const lay = Layout.compute(0, &cs, 9, 20);
    try std.testing.expectEqual(@as(usize, 10), lay.total_cols);
    try std.testing.expectEqual(@as(usize, 6), lay.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
}

test "layout: cursor on second visual row past wrap" {
    var cs: [8]buffer_mod.Cluster = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) cs[i] = cluster1(i, i + 1);
    const lay = Layout.compute(0, &cs, 7, 5);
    try std.testing.expectEqual(@as(usize, 2), lay.rows);
    try std.testing.expectEqual(@as(usize, 1), lay.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), lay.cursor_col);
    try std.testing.expect(!lay.needs_phantom_nl);
}

// =============================================================================
// Span normalization tests
// =============================================================================

test "snapSpanToClusters: ASCII boundaries unchanged" {
    const cs = [_]buffer_mod.Cluster{ cluster1(0, 1), cluster1(1, 2), cluster1(2, 3) };
    const r = snapSpanToClusters(&cs, 1, 3);
    try std.testing.expectEqual(@as(usize, 1), r.start);
    try std.testing.expectEqual(@as(usize, 3), r.end);
}

test "snapSpanToClusters: mid-cluster start floors, mid-cluster end ceils" {
    // Three clusters: [0,3) [3,6) [6,7). Span [1, 5) must expand to [0, 6).
    const cs = [_]buffer_mod.Cluster{
        .{ .byte_start = 0, .byte_end = 3, .width = 2 },
        .{ .byte_start = 3, .byte_end = 6, .width = 2 },
        cluster1(6, 7),
    };
    const r = snapSpanToClusters(&cs, 1, 5);
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 6), r.end);
}

test "renderer: normalizeSpans drops empty / out-of-range spans" {
    var rend = Renderer.init(std.testing.allocator, .{});
    defer rend.deinit();

    var b = buffer_mod.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("abcde");
    try b.ensureClusters();

    const in = [_]highlight.HighlightSpan{
        .{ .start = 0, .end = 0, .style = .{} }, // empty → drop
        .{ .start = 3, .end = 2, .style = .{} }, // inverted → drop
        .{ .start = 10, .end = 12, .style = .{} }, // beyond buffer → drop
        .{ .start = 1, .end = 100, .style = .{ .bold = true } }, // end clamps to 5
    };
    const out = try rend.normalizeSpans(&b, &in);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 1), out[0].start);
    try std.testing.expectEqual(@as(usize, 5), out[0].end);
}

test "renderer: normalizeSpans sorts and drops overlaps" {
    var rend = Renderer.init(std.testing.allocator, .{});
    defer rend.deinit();

    var b = buffer_mod.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("abcdefghij");
    try b.ensureClusters();

    const in = [_]highlight.HighlightSpan{
        .{ .start = 6, .end = 9, .style = .{ .bold = true } },
        .{ .start = 0, .end = 3, .style = .{ .italic = true } },
        .{ .start = 2, .end = 5, .style = .{ .underline = true } }, // overlaps the [0,3)
        .{ .start = 7, .end = 8, .style = .{ .dim = true } }, // overlaps the [6,9)
    };
    const out = try rend.normalizeSpans(&b, &in);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(usize, 0), out[0].start);
    try std.testing.expectEqual(@as(usize, 3), out[0].end);
    try std.testing.expectEqual(@as(usize, 6), out[1].start);
    try std.testing.expectEqual(@as(usize, 9), out[1].end);
}

test "renderer: normalizeSpans snaps mid-cluster boundaries outward" {
    var rend = Renderer.init(std.testing.allocator, .{});
    defer rend.deinit();

    var b = buffer_mod.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("café"); // bytes: c(0) a(1) f(2) é(3..5)
    try b.ensureClusters();

    // Span [4, 5) lands mid-é — must expand to [3, 5) so SGR doesn't
    // splice into the middle of a UTF-8 sequence.
    const in = [_]highlight.HighlightSpan{
        .{ .start = 4, .end = 5, .style = .{ .bold = true } },
    };
    const out = try rend.normalizeSpans(&b, &in);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 3), out[0].start);
    try std.testing.expectEqual(@as(usize, 5), out[0].end);
}
