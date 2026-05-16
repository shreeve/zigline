//! zigline example: mid-prompt notifications via `Editor.printAbove`
//! and `Options.on_wake`.
//!
//! Models the bash/zsh `set -b` UX: a "background event" (here
//! triggered deterministically by the user pressing Ctrl-O) queues a
//! notification, pokes the signal pipe, and the wake hook drains the
//! queue by calling `printAbove`. The user sees the notification
//! appear above the prompt without losing their typed buffer.
//!
//! For the real shell case, swap the Ctrl-O keystroke trigger with a
//! SIGCHLD handler that calls `pokeActiveSignalPipe()` directly.
//! Everything else (queue, drain hook, `printAbove`) stays the same.
//!
//! Build and run:
//!   zig build run-with_print_above
//!
//! Try it: type something, press Ctrl-O — `[bg] event N\n` appears
//! above your in-progress line; cursor is preserved.

const std = @import("std");
const zigline = @import("zigline");

const NotifyQueue = struct {
    /// Fixed-size ring of pending notifications. Real shells would
    /// use a thread-safe queue populated from the SIGCHLD handler;
    /// for the example we keep it single-threaded.
    items: [16][64]u8 = undefined,
    lens: [16]usize = std.mem.zeroes([16]usize),
    head: usize = 0,
    tail: usize = 0,
    counter: u32 = 0,

    fn push(self: *NotifyQueue) void {
        const slot = self.tail % self.items.len;
        self.counter += 1;
        const text = std.fmt.bufPrint(
            &self.items[slot],
            "[bg] event {d}\n",
            .{self.counter},
        ) catch return;
        self.lens[slot] = text.len;
        self.tail += 1;
    }

    fn pop(self: *NotifyQueue) ?[]const u8 {
        if (self.head == self.tail) return null;
        const slot = self.head % self.items.len;
        const len = self.lens[slot];
        self.head += 1;
        return self.items[slot][0..len];
    }
};

fn onWake(ctx: *anyopaque, editor: *zigline.Editor) void {
    const queue: *NotifyQueue = @ptrCast(@alignCast(ctx));
    while (queue.pop()) |msg| {
        editor.printAbove(msg) catch {};
    }
}

const ActionId = enum(u32) {
    fire_notification = 1,
};

fn keymapLookup(key: zigline.KeyEvent) ?zigline.Action {
    // Ctrl-O as the deterministic trigger. (Default emacs has no
    // Ctrl-O binding; readline sometimes uses it for
    // "operate-and-get-next" but zigline leaves it unbound.) We
    // can't use Ctrl-J here because terminals translate \x0a (LF)
    // and \x0d (CR) interchangeably with Enter.
    if (key.mods.ctrl) {
        switch (key.code) {
            .char => |c| if (c == 'o') {
                return zigline.Action{ .custom = @intFromEnum(ActionId.fire_notification) };
            },
            else => {},
        }
    }
    return zigline.Keymap.defaultEmacs().lookup(key);
}

const Slate = struct {
    queue: *NotifyQueue,
};

fn customAction(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    id: u32,
    request: zigline.CustomActionRequest,
    action_ctx: zigline.CustomActionContext,
) anyerror!zigline.CustomActionResult {
    _ = allocator;
    _ = request;
    _ = action_ctx;
    const slate: *Slate = @ptrCast(@alignCast(ctx));
    return switch (@as(ActionId, @enumFromInt(id))) {
        .fire_notification => blk: {
            // Queue a notification and poke the signal pipe so the
            // read loop wakes and drains via `on_wake`. In a real
            // shell the SIGCHLD handler would do exactly this two-
            // step.
            slate.queue.push();
            zigline.pokeActiveSignalPipe();
            break :blk .no_op;
        },
    };
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var queue: NotifyQueue = .{};
    var slate: Slate = .{ .queue = &queue };

    const wake_hook = zigline.WakeHook{
        .ctx = @ptrCast(&queue),
        .onWakeFn = onWake,
    };
    const action_hook = zigline.CustomActionHook{
        .ctx = @ptrCast(&slate),
        .invokeFn = customAction,
    };

    var editor = try zigline.Editor.init(alloc, .{
        .keymap = .{ .lookupFn = keymapLookup },
        .custom_action = action_hook,
        .on_wake = wake_hook,
    });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("notify> "));
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
