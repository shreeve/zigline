//! zigline example: cursor-aware syntax highlighter.
//!
//! Two spans demonstrate both the buffer-only and the cursor-aware
//! halves of the `HighlightRequest` API:
//!
//!   - First whitespace-delimited word: green + bold (buffer-only).
//!   - Everything past the cursor: dim (uses `request.cursor_byte`).
//!
//! Build and run:
//!   zig build run-with_highlight

const std = @import("std");
const zigline = @import("zigline");

fn highlight(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    request: zigline.HighlightRequest,
) anyerror![]zigline.HighlightSpan {
    _ = ctx;
    const buffer = request.buffer;

    var spans: std.ArrayListUnmanaged(zigline.HighlightSpan) = .empty;
    errdefer spans.deinit(allocator);

    // Span 1: first word in green + bold (buffer-only).
    var i: usize = 0;
    while (i < buffer.len and buffer[i] == ' ') : (i += 1) {}
    const word_start = i;
    while (i < buffer.len and buffer[i] != ' ') : (i += 1) {}
    const word_end = i;
    if (word_end > word_start) {
        try spans.append(allocator, .{
            .start = word_start,
            .end = word_end,
            .style = .{ .fg = .{ .basic = .green }, .bold = true },
        });
    }

    // Span 2: everything past the cursor in dim (cursor-aware).
    if (request.cursor_byte < buffer.len) {
        try spans.append(allocator, .{
            .start = request.cursor_byte,
            .end = buffer.len,
            .style = .{ .dim = true },
        });
    }

    return try spans.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    const hook = zigline.HighlightHook{
        .ctx = @ptrFromInt(0xdeadbeef),
        .highlightFn = highlight,
    };

    var editor = try zigline.Editor.init(alloc, .{ .highlight = hook });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("color> "));
        switch (result) {
            .line => |line| {
                defer alloc.free(line);
                std.debug.print("got: {s}\n", .{line});
            },
            .interrupt => continue,
            .eof => break,
        }
    }
    return 0;
}
