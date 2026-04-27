//! zigline example: application-defined custom actions.
//!
//! Two bindings are added beyond the emacs defaults:
//!
//!   `Ctrl-T`         uppercase the current buffer in place
//!   `Ctrl-X`         open the buffer in `$EDITOR` (vi if unset)
//!
//! The first demonstrates a pure-buffer transform (`replace_buffer`).
//! The second is the canonical "edit-in-EDITOR" pattern: the hook
//! pauses raw mode, spawns the editor, reads the result back, then
//! returns `replace_buffer` so the new contents become the line.
//!
//! Build and run:
//!   zig build run-with_custom_action

const std = @import("std");
const zigline = @import("zigline");

// `std.c` exposes most of POSIX in 0.16 but not these. Declare the
// minimum we need; the example links libc unconditionally via
// `lib_mod.linkSystemLibrary("c", ...)` in `build.zig`.
extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const ActionId = enum(u32) {
    uppercase = 1,
    edit_in_editor = 2,
};

fn keymapLookup(key: zigline.KeyEvent) ?zigline.Action {
    if (key.mods.ctrl) {
        switch (key.code) {
            .char => |c| switch (c) {
                't' => return zigline.Action{ .custom = @intFromEnum(ActionId.uppercase) },
                'x' => return zigline.Action{ .custom = @intFromEnum(ActionId.edit_in_editor) },
                else => {},
            },
            else => {},
        }
    }
    return zigline.Keymap.defaultEmacs().lookup(key);
}

fn customAction(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    id: u32,
    request: zigline.CustomActionRequest,
    action_ctx: zigline.CustomActionContext,
) anyerror!zigline.CustomActionResult {
    _ = ctx;
    return switch (@as(ActionId, @enumFromInt(id))) {
        .uppercase => blk: {
            const upper = try allocator.alloc(u8, request.buffer.len);
            for (request.buffer, 0..) |b, i| upper[i] = std.ascii.toUpper(b);
            break :blk .{ .replace_buffer = upper };
        },
        .edit_in_editor => editInEditor(allocator, request, action_ctx),
    };
}

fn editInEditor(
    allocator: std.mem.Allocator,
    request: zigline.CustomActionRequest,
    action_ctx: zigline.CustomActionContext,
) anyerror!zigline.CustomActionResult {
    var path_buf: [128]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zigline-{d}.txt", .{std.c.getpid()});
    {
        const fd = std.c.open(tmp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = std.c.close(fd);
        var off: usize = 0;
        while (off < request.buffer.len) {
            const n = std.c.write(fd, request.buffer.ptr + off, request.buffer.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }
    defer _ = std.c.unlink(tmp_path.ptr);

    // `withCookedMode` brackets the spawn with pause + resume. Any
    // failure to re-enter raw mode is propagated, not silently
    // swallowed (`defer ... catch {}` is the trap to avoid).
    try action_ctx.withCookedMode(tmp_path, spawnEditor);

    const fd = std.c.open(tmp_path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try bytes.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    var content = try bytes.toOwnedSlice(allocator);
    // Editors append varying amounts of trailing whitespace: vi
    // adds a single `\n`; some emit `\r\n`; some emit a double
    // `\n`. Strip them all so the buffer round-trip is clean.
    while (content.len > 0 and (content[content.len - 1] == '\n' or
        content[content.len - 1] == '\r'))
    {
        content = try allocator.realloc(content, content.len - 1);
    }
    return .{ .replace_buffer = content };
}

/// Fork + execvp `$EDITOR` (or `vi` if unset) to edit `tmp_path`,
/// then wait. Runs while the terminal is in cooked mode so the
/// editor sees a normal TTY.
fn spawnEditor(tmp_path: [:0]const u8) anyerror!void {
    const editor_cmd = std.c.getenv("EDITOR") orelse "vi";
    const cmd_z: [*:0]const u8 = @ptrCast(editor_cmd);
    var argv = [_:null]?[*:0]const u8{ cmd_z, tmp_path.ptr };
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = execvp(cmd_z, &argv);
        std.c._exit(127);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(child, &status, 0);
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var editor = try zigline.Editor.init(alloc, .{
        .keymap = .{ .lookupFn = keymapLookup },
        .custom_action = .{ .ctx = @ptrFromInt(0xa1b2c3), .invokeFn = customAction },
    });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("custom> "));
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
