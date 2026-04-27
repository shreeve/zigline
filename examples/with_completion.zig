//! zigline example with a fixed-list completion hook. Type any prefix
//! of "hello", "world", "wonderful" and press Tab.
//!
//! Build and run:
//!   zig build run-with_completion

const std = @import("std");
const zigline = @import("zigline");

const candidates = [_][]const u8{ "hello", "world", "wonderful" };

fn complete(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    request: zigline.CompletionRequest,
) anyerror!zigline.CompletionResult {
    _ = ctx;
    const buf = request.buffer[0..request.cursor_byte];

    var word_start: usize = request.cursor_byte;
    while (word_start > 0 and buf[word_start - 1] != ' ') word_start -= 1;
    const prefix = buf[word_start..];

    var matches: std.ArrayListUnmanaged(zigline.Candidate) = .empty;
    errdefer matches.deinit(allocator);

    for (candidates) |c| {
        if (std.mem.startsWith(u8, c, prefix)) {
            try matches.append(allocator, .{
                .insert = try allocator.dupe(u8, c),
                .kind = .plain,
                .append = ' ',
            });
        }
    }

    return .{
        .replacement_start = word_start,
        .replacement_end = request.cursor_byte,
        .candidates = try matches.toOwnedSlice(allocator),
    };
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    const hook = zigline.CompletionHook{
        .ctx = @ptrFromInt(0xdeadbeef),
        .completeFn = complete,
    };

    var editor = try zigline.Editor.init(alloc, .{ .completion = hook });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("complete> "));
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
