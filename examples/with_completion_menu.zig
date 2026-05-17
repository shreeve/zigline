//! zigline example exercising the multi-column completion menu
//! (SPEC.md §6.5). The hook returns three git-flag-shaped candidates
//! with descriptions, so on Tab the editor opens the descriptive
//! single-column menu, highlights the first candidate in reverse
//! video, and renders the descriptions in dim style alongside.
//!
//! Build and run:
//!   zig build run-with_completion_menu
//!
//! Try:
//!   --<Tab>           menu opens; preview applies "--abbrev "
//!   <Down><Tab>       cycle; preview applies the next candidate
//!   <Enter>           accept current preview
//!   <Esc>             cancel; pre-menu buffer restored

const std = @import("std");
const zigline = @import("zigline");

const Cand = struct {
    insert: []const u8,
    description: []const u8,
};

const cands = [_]Cand{
    .{ .insert = "--abbrev", .description = "show only a partial prefix" },
    .{ .insert = "--abbrev-commit", .description = "Show a prefix that names the object uniquely" },
    .{ .insert = "--after", .description = "Show commits more recent than a specific date" },
    .{ .insert = "--all", .description = "Pretend as if all the refs in refs/ are listed" },
    .{ .insert = "--author", .description = "Limit the commits output to ones with author lines" },
};

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

    for (cands) |c| {
        if (std.mem.startsWith(u8, c.insert, prefix)) {
            try matches.append(allocator, .{
                .insert = try allocator.dupe(u8, c.insert),
                .description = try allocator.dupe(u8, c.description),
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
        .ctx = @ptrFromInt(0xfeedface),
        .completeFn = complete,
    };

    var editor = try zigline.Editor.init(alloc, .{ .completion = hook });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("menu> "));
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
