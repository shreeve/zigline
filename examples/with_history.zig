//! zigline example with persistent history.
//!
//! Build and run:
//!   zig build run-with_history
//!
//! The history file path is taken from argv[1]; if absent it defaults
//! to `/tmp/zigline_history`. The path-as-argument form lets the PTY
//! test harness point each test at a fresh tmpfile.

const std = @import("std");
const zigline = @import("zigline");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const history_path: []const u8 = if (args.len >= 2) args[1] else "/tmp/zigline_history";

    var history = try zigline.History.init(alloc, .{
        .path = history_path,
        .max_entries = 1000,
        .dedupe = .adjacent,
    });
    defer history.deinit();

    var editor = try zigline.Editor.init(alloc, .{ .history = &history });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("> "));
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
