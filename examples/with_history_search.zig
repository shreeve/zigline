//! zigline example: reverse-incremental history search via
//! `Options.transient_input` and `Action.transient_input_open`
//! (Ctrl-R).
//!
//! A small fixed-list "history" backs the search; the hook performs
//! substring matching and remembers a per-query cursor that advances
//! on each `.next` event so Ctrl-R repeated cycles through matches.
//!
//! Build and run:
//!   zig build run-with_history_search
//!
//! Try it:
//!   - Type something, then press Ctrl-R to enter search mode.
//!   - Type "git" — the most-recent matching entry appears as a
//!     dimmed preview after your query.
//!   - Press Ctrl-R again to cycle to the next older match.
//!   - Press Enter to accept the match into the main buffer.
//!     The line is NOT submitted; press Enter again to run.
//!   - Press Esc or Ctrl-G to abort and restore the original buffer.

const std = @import("std");
const zigline = @import("zigline");

const fake_history = [_][]const u8{
    "ls -la",
    "git status",
    "git log --oneline",
    "git checkout main",
    "echo hello world",
    "cd /tmp && ls",
    "grep -r TODO src/",
    "make test",
    "git push origin main",
    "vim README.md",
};

const SearchCtx = struct {
    /// Buffer for status text — kept here so the hook can return a
    /// borrowed slice valid until the next call.
    status_buf: [128]u8 = undefined,
    /// Most-recently-rendered query, used to decide whether to reset
    /// the cycle index on `.next`.
    last_query: [128]u8 = undefined,
    last_query_len: usize = 0,
    /// Index into the matches array; advances on `.next`.
    cycle: usize = 0,
};

fn searchUpdate(
    ctx: *anyopaque,
    request: zigline.TransientInputRequest,
) anyerror!zigline.TransientInputResult {
    const self: *SearchCtx = @ptrCast(@alignCast(ctx));

    switch (request.event) {
        .opened => {
            self.cycle = 0;
            self.last_query_len = 0;
            const status = try std.fmt.bufPrint(
                &self.status_buf,
                "(reverse-i-search): ",
                .{},
            );
            return .{ .preview = null, .status = status };
        },
        .aborted => {
            // Best-effort cleanup. Nothing to free — borrowed strings.
            return .{ .preview = null, .status = null };
        },
        .query_changed => {
            // Reset cycle whenever query changes.
            self.cycle = 0;
            if (request.query.len <= self.last_query.len) {
                @memcpy(self.last_query[0..request.query.len], request.query);
                self.last_query_len = request.query.len;
            }
        },
        .next => {
            self.cycle += 1;
        },
    }

    // Walk newest → oldest, picking the (cycle+1)th match.
    var matches_seen: usize = 0;
    var match_idx: ?usize = null;
    var i: usize = fake_history.len;
    while (i > 0) {
        i -= 1;
        if (request.query.len == 0 or std.mem.indexOf(u8, fake_history[i], request.query) != null) {
            if (matches_seen == self.cycle) {
                match_idx = i;
                break;
            }
            matches_seen += 1;
        }
    }

    if (match_idx) |idx| {
        const status = try std.fmt.bufPrint(
            &self.status_buf,
            "(reverse-i-search) `{s}': ",
            .{request.query},
        );
        return .{ .preview = fake_history[idx], .status = status };
    }

    // No (more) matches — wrap cycle back to 0 so subsequent Ctrl-R
    // doesn't drift into infinity, and indicate failing state.
    self.cycle = 0;
    const status = try std.fmt.bufPrint(
        &self.status_buf,
        "(failing-i-search) `{s}': ",
        .{request.query},
    );
    return .{ .preview = null, .status = status };
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var search_ctx: SearchCtx = .{};
    const hook: zigline.TransientInputHook = .{
        .ctx = @ptrCast(&search_ctx),
        .updateFn = searchUpdate,
    };

    var editor = try zigline.Editor.init(alloc, .{ .transient_input = hook });
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("search> "));
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
