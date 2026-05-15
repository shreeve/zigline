//! zigline example with a static ghost-text hint hook.
//!
//! For every prefix of "hello world" you've typed, the editor draws
//! the missing suffix in dim ghost text. Right Arrow / Ctrl-F accepts
//! the hint as if you'd typed it; Enter without accepting submits
//! only what you actually typed.
//!
//! Build and run:
//!   zig build run-with_hint
//!
//! This is the test fixture for the PTY autosuggestion test; real
//! Slash usage would back the hook with a history scan.

const std = @import("std");
const zigline = @import("zigline");

const target = "hello world";

fn suggest(
    ctx: *anyopaque,
    request: zigline.HintRequest,
) anyerror!?zigline.HintResult {
    _ = ctx;
    if (request.cursor_byte == 0) return null;
    const prefix = request.buffer[0..request.cursor_byte];
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const suffix = target[prefix.len..];
    if (suffix.len == 0) return null;
    return zigline.HintResult{ .text = suffix };
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    const hook = zigline.HintHook{
        .ctx = @ptrFromInt(0xdeadbeef),
        .hintFn = suggest,
    };

    var editor = try zigline.Editor.init(alloc, .{ .hint = hook });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("hint> "));
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
