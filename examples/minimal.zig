//! Minimal zigline example — prompt loop with no extras.
//!
//! Build and run:
//!   zig build run-minimal

const std = @import("std");
const zigline = @import("zigline");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var editor = try zigline.Editor.init(alloc, .{});
    defer editor.deinit();

    while (true) {
        const result = editor.readLine(zigline.Prompt.plain("$ ")) catch |err| {
            std.debug.print("zigline error: {}\n", .{err});
            return err;
        };
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
