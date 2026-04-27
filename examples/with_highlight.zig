//! zigline example with a trivial highlighter that paints the first
//! whitespace-delimited word in green and the rest in default color.
//!
//! Build and run:
//!   zig build run-with_highlight

const std = @import("std");
const zigline = @import("zigline");

fn highlight(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    buffer: []const u8,
) anyerror![]zigline.HighlightSpan {
    _ = ctx;

    var spans: std.ArrayListUnmanaged(zigline.HighlightSpan) = .empty;
    errdefer spans.deinit(allocator);

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
