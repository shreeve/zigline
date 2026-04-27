//! Editor — orchestration + action dispatch.
//!
//! See SPEC.md §7. The Editor owns the buffer, renderer, terminal,
//! and reader; it borrows the history (if any) and hooks. Its
//! single user-facing method is `readLine`.

const std = @import("std");

const actions_mod = @import("actions.zig");
const buffer_mod = @import("buffer.zig");
const completion_mod = @import("completion.zig");
const grapheme = @import("grapheme.zig");
const highlight_mod = @import("highlight.zig");
const history_mod = @import("history.zig");
const input_mod = @import("input.zig");
const keymap_mod = @import("keymap.zig");
const kill_ring_mod = @import("kill_ring.zig");
const prompt_mod = @import("prompt.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal.zig");
const undo_mod = @import("undo.zig");

pub const Allocator = std.mem.Allocator;

pub const ReadLineResult = union(enum) {
    line: []u8,
    eof,
    interrupt,
};

pub const RawModePolicy = enum {
    enter_and_leave,
    assume_already_raw,
    disabled,
};

pub const PastePolicy = enum {
    accept,
};

/// Categorized diagnostic delivered to `Options.diagnostic_fn` when
/// a hook fails or a hook returns invalid data. The library degrades
/// gracefully — a failing highlighter just produces no spans, a
/// failing completer produces no candidates — but the failure is
/// observable so embedders aren't debugging in the dark.
pub const Diagnostic = struct {
    pub const Kind = enum {
        completion_hook_failed,
        completion_invalid_range,
        completion_invalid_candidate,
        highlight_hook_failed,
        history_append_failed,
        render_failed,
    };

    kind: Kind,
    err: ?anyerror = null,
    /// Optional human-readable detail. Borrowed; valid only for the
    /// duration of the callback.
    detail: ?[]const u8 = null,
};

pub const DiagnosticHook = struct {
    ctx: *anyopaque,
    fn_: *const fn (ctx: *anyopaque, diag: Diagnostic) void,

    pub fn report(self: DiagnosticHook, diag: Diagnostic) void {
        self.fn_(self.ctx, diag);
    }
};

pub const Options = struct {
    input_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    output_fd: std.posix.fd_t = std.posix.STDOUT_FILENO,
    raw_mode: RawModePolicy = .enter_and_leave,
    history: ?*history_mod.History = null,
    keymap: keymap_mod.Keymap = keymap_mod.Keymap.defaultEmacs(),
    completion: ?completion_mod.CompletionHook = null,
    highlight: ?highlight_mod.HighlightHook = null,
    width_policy: grapheme.WidthPolicy = .{},
    paste: PastePolicy = .accept,
    /// Optional callback invoked when a hook fails or returns
    /// invalid data. Library behavior stays nonfatal; this is a
    /// debugging surface for embedders. Not called in hot paths
    /// when nothing has gone wrong.
    diagnostic: ?DiagnosticHook = null,
    /// Number of slots in the kill ring (`Ctrl-K` / `Ctrl-U` /
    /// `Ctrl-W` / `M-d` push, `Ctrl-Y` yanks, `M-y` cycles). Set to
    /// 0 to disable kill-ring tracking entirely; the kill actions
    /// still delete text but won't be recoverable via yank.
    kill_ring_capacity: usize = 32,
};

/// The line editor.
///
/// Lifetime: construct with `init`, free with `deinit`. The struct is
/// **not copyable** — copying duplicates ownership of the internal
/// allocations (buffer bytes, reader scratch, history snapshots), and
/// both copies will try to free them. Treat the value returned by
/// `init` like a `*Editor`: take its address, pass it around as a
/// pointer.
///
/// Thread safety: not thread-safe. One thread per editor instance.
///
/// Internal field access: the public fields below are exposed for
/// advanced cases (e.g. wiring an alternative reader) and to enable
/// in-tree testing. Treat them as semi-private — invariants between
/// fields are not always documented and may change between versions.
pub const Editor = struct {
    allocator: Allocator,
    options: Options,
    buffer: buffer_mod.Buffer,
    terminal: terminal_mod.Terminal,
    renderer: renderer_mod.Renderer,
    reader: input_mod.Reader,
    kill_ring: kill_ring_mod.KillRing,
    changeset: undo_mod.Changeset,
    /// Byte offset of the most-recent yank, so `M-y` (yank-pop) knows
    /// where to splice the replacement. Invalidated by any non-yank
    /// action (the kill ring's `last_action` reset handles that).
    last_yank_start: usize = 0,
    /// Used by the cooked-mode (non-TTY) read path to remember the
    /// "second half" of a CRLF that crossed the boundary between two
    /// `readLine` invocations.
    cooked_pending_lf: bool = false,

    pub fn init(allocator: Allocator, options: Options) !Editor {
        return .{
            .allocator = allocator,
            .options = options,
            .buffer = blk: {
                var b = buffer_mod.Buffer.init(allocator);
                b.width_policy = options.width_policy;
                break :blk b;
            },
            .terminal = terminal_mod.Terminal.init(options.input_fd, options.output_fd),
            .renderer = renderer_mod.Renderer.init(allocator, options.width_policy),
            .reader = input_mod.Reader.init(allocator, options.input_fd),
            .kill_ring = kill_ring_mod.KillRing.init(allocator, options.kill_ring_capacity),
            .changeset = undo_mod.Changeset.init(allocator),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.renderer.deinit();
        self.reader.deinit();
        self.kill_ring.deinit();
        self.changeset.deinit();
    }

    /// Block until the user accepts, cancels, or sends EOF.
    /// Returned `line` is allocator-owned; caller frees on `.line`.
    pub fn readLine(self: *Editor, prompt: prompt_mod.Prompt) !ReadLineResult {
        // Cooked-mode fallback: stdin isn't a TTY, so we can't drive the
        // line editor. Read a line via the kernel discipline.
        if (self.options.raw_mode == .disabled or !self.terminal.isInputTty()) {
            return self.readLineCooked(prompt);
        }

        if (self.options.raw_mode == .enter_and_leave) {
            try self.terminal.enterRawMode();
        }
        defer {
            self.reader.setSignalPipe(-1);
            if (self.options.raw_mode == .enter_and_leave) self.terminal.leaveRawMode();
        }

        // Wire the signal self-pipe into the reader so SIGWINCH /
        // SIGTSTP-resume / app-initiated `notifyResize` wakes our
        // blocked `read()`.
        self.reader.setSignalPipe(self.terminal.signalPipeFd());

        self.buffer.clear();
        self.renderer.markFresh();
        // Each new line starts with a fresh action chain — old ring
        // contents are preserved (so M-y still works on the new
        // line) but the next kill won't coalesce with whatever was
        // killed on the previous line.
        self.kill_ring.reset();
        // Undo history is per-line: starting a new line drops any
        // leftover edits from the previous one.
        self.changeset.clear();
        try self.render(prompt);

        while (true) {
            const ev = self.reader.next();
            switch (ev) {
                .eof => {
                    try self.renderer.finalize(&self.terminal);
                    if (self.options.history) |h| h.resetCursor();
                    return .eof;
                },
                .error_ => |e| {
                    try self.renderer.finalize(&self.terminal);
                    return e;
                },
                .resize => try self.render(prompt),
                .paste => |payload| {
                    try self.handlePaste(payload);
                    try self.render(prompt);
                },
                .key => |kev| {
                    if (try self.handleKey(kev, prompt)) |result| {
                        if (self.options.history) |h| h.resetCursor();
                        return result;
                    }
                    try self.render(prompt);
                },
            }
        }
    }

    /// Application hook to signal a terminal resize. Writes a wake
    /// byte to the editor's self-pipe so a blocked `read()` returns
    /// immediately and the next render picks up the new dimensions.
    /// Async-signal-safe (one `write()` to a non-blocking pipe), so
    /// it's fine to invoke from a SIGWINCH handler the application
    /// installed itself, e.g. when zigline's own handler isn't
    /// active for some reason.
    pub fn notifyResize(self: *Editor) void {
        _ = self;
        terminal_mod.pokeActiveSignalPipe();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    fn render(self: *Editor, prompt: prompt_mod.Prompt) !void {
        var span_buf: ?[]highlight_mod.HighlightSpan = null;
        defer if (span_buf) |sb| self.allocator.free(sb);

        var spans: []const highlight_mod.HighlightSpan = &.{};
        if (self.options.highlight) |hh| {
            if (hh.highlight(self.allocator, self.buffer.slice())) |g| {
                span_buf = g;
                spans = g;
            } else |err| {
                self.diag(.{ .kind = .highlight_hook_failed, .err = err });
            }
        }
        try self.renderer.render(&self.terminal, prompt, &self.buffer, spans);
    }

    fn diag(self: *Editor, d: Diagnostic) void {
        if (self.options.diagnostic) |dh| dh.report(d);
    }

    /// Tag identifying which kill operation; controls the kill-ring
    /// coalescing direction (`.append` for forward kills, `.prepend`
    /// for backward kills).
    const KillKind = enum {
        kill_to_start,
        kill_to_end,
        kill_word_backward,
        kill_word_forward,
    };

    fn dispatchKill(self: *Editor, kind: KillKind) !void {
        const cursor_before = self.buffer.cursor_byte;
        const killed_opt: ?[]u8 = switch (kind) {
            .kill_to_start => try self.buffer.killToStart(),
            .kill_to_end => try self.buffer.killToEnd(),
            .kill_word_backward => try self.buffer.killWordBackward(),
            .kill_word_forward => try self.buffer.killWordForward(),
        };
        const killed = killed_opt orelse return;
        defer self.allocator.free(killed);

        const undo_idx = switch (kind) {
            .kill_to_start, .kill_word_backward => cursor_before - killed.len,
            .kill_to_end, .kill_word_forward => cursor_before,
        };
        self.recordDeleteOrDiag(undo_idx, killed, cursor_before, self.buffer.cursor_byte);

        const mode: kill_ring_mod.Mode = switch (kind) {
            .kill_to_start, .kill_word_backward => .prepend,
            .kill_to_end, .kill_word_forward => .append,
        };
        self.kill_ring.kill(killed, mode) catch |err| {
            self.diag(.{ .kind = .render_failed, .err = err, .detail = "kill_ring push failed" });
        };
    }

    fn handleYank(self: *Editor) !void {
        const text = self.kill_ring.yank() orelse return;
        const cursor_before = self.buffer.cursor_byte;
        self.last_yank_start = cursor_before;
        // Yank is a compound action — break the coalescing chain so
        // typing immediately before or after it stays in its own
        // undo step.
        self.changeset.breakSequence();
        try self.buffer.insertText(text);
        self.recordInsertOrDiag(cursor_before, text, cursor_before, self.buffer.cursor_byte);
        self.changeset.breakSequence();
    }

    fn handleYankPop(self: *Editor) !void {
        const pop = self.kill_ring.yankPop() orelse return;
        const start = self.last_yank_start;
        const end = start + pop.prev_len;
        if (end > self.buffer.bytes.items.len) return;
        const old = try self.allocator.dupe(u8, self.buffer.bytes.items[start..end]);
        defer self.allocator.free(old);
        const cursor_before = self.buffer.cursor_byte;
        try self.replaceRangeAt(start, end, pop.text);
        // Single Replace op so one Ctrl-_ undoes the whole yank-pop.
        self.recordReplaceOrDiag(start, old, pop.text, cursor_before, self.buffer.cursor_byte);
        self.last_yank_start = start;
    }

    fn handleUndo(self: *Editor) !void {
        const op_ptr = self.changeset.peekUndo() orelse return;
        // Apply on a stack-local copy of the op fields so the borrow
        // stays valid even if `replaceRangeAt` would (somehow)
        // observe stack state.
        const op = op_ptr.*;
        switch (op) {
            .insert => |e| {
                const end = std.math.add(usize, e.idx, e.text.len) catch return;
                if (end > self.buffer.bytes.items.len) return;
                try self.replaceRangeAt(e.idx, end, "");
                self.buffer.cursor_byte = e.cursor_before;
            },
            .delete => |e| {
                if (e.idx > self.buffer.bytes.items.len) return;
                try self.replaceRangeAt(e.idx, e.idx, e.text);
                self.buffer.cursor_byte = e.cursor_before;
            },
            .replace => |e| {
                const end = std.math.add(usize, e.idx, e.new.len) catch return;
                if (end > self.buffer.bytes.items.len) return;
                try self.replaceRangeAt(e.idx, end, e.old);
                self.buffer.cursor_byte = e.cursor_before;
            },
        }
        // Commit on success. If the redo append OOMs, the buffer is
        // already mutated but the op stays on undos — best-effort
        // degradation that's strictly better than a leak.
        self.changeset.acceptUndo() catch |err| {
            self.diag(.{ .kind = .render_failed, .err = err, .detail = "acceptUndo failed" });
        };
    }

    fn handleRedo(self: *Editor) !void {
        const op_ptr = self.changeset.peekRedo() orelse return;
        const op = op_ptr.*;
        switch (op) {
            .insert => |e| {
                if (e.idx > self.buffer.bytes.items.len) return;
                try self.replaceRangeAt(e.idx, e.idx, e.text);
                self.buffer.cursor_byte = e.cursor_after;
            },
            .delete => |e| {
                const end = std.math.add(usize, e.idx, e.text.len) catch return;
                if (end > self.buffer.bytes.items.len) return;
                try self.replaceRangeAt(e.idx, end, "");
                self.buffer.cursor_byte = e.cursor_after;
            },
            .replace => |e| {
                const end = std.math.add(usize, e.idx, e.old.len) catch return;
                if (end > self.buffer.bytes.items.len) return;
                try self.replaceRangeAt(e.idx, end, e.new);
                self.buffer.cursor_byte = e.cursor_after;
            },
        }
        self.changeset.acceptRedo() catch |err| {
            self.diag(.{ .kind = .render_failed, .err = err, .detail = "acceptRedo failed" });
        };
    }

    /// Best-effort record helpers: if recording fails (OOM), the
    /// edit has already happened, so we surface the failure via the
    /// diagnostic hook and continue. The buffer state is correct;
    /// just that one edit isn't undoable.
    fn recordInsertOrDiag(
        self: *Editor,
        idx: usize,
        text: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) void {
        self.changeset.recordInsert(idx, text, cursor_before, cursor_after) catch |err| {
            self.diag(.{ .kind = .render_failed, .err = err, .detail = "undo record (insert) failed" });
        };
    }

    fn recordDeleteOrDiag(
        self: *Editor,
        idx: usize,
        text: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) void {
        self.changeset.recordDelete(idx, text, cursor_before, cursor_after) catch |err| {
            self.diag(.{ .kind = .render_failed, .err = err, .detail = "undo record (delete) failed" });
        };
    }

    fn recordReplaceOrDiag(
        self: *Editor,
        idx: usize,
        old: []const u8,
        new: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) void {
        self.changeset.recordReplace(idx, old, new, cursor_before, cursor_after) catch |err| {
            self.diag(.{ .kind = .render_failed, .err = err, .detail = "undo record (replace) failed" });
        };
    }

    fn handleKey(
        self: *Editor,
        kev: input_mod.KeyEvent,
        prompt: prompt_mod.Prompt,
    ) !?ReadLineResult {
        // Default-insert: printable char with no keymap binding.
        const action = self.options.keymap.lookup(kev) orelse {
            switch (kev.code) {
                .char => |cp| {
                    if (cp < 0x20) return null;
                    // Typing breaks the kill-ring coalescing chain
                    // exactly like any non-kill action through
                    // dispatch — without this, two `Ctrl-U` kills
                    // separated only by typing would coalesce into
                    // one slot.
                    self.kill_ring.reset();
                    try self.insertCharRecorded(cp);
                },
                .text => |t| {
                    self.kill_ring.reset();
                    const cursor_before = self.buffer.cursor_byte;
                    try self.buffer.insertText(t);
                    self.recordInsertOrDiag(cursor_before, t, cursor_before, self.buffer.cursor_byte);
                },
                else => {},
            }
            return null;
        };

        return self.dispatch(action, prompt);
    }

    fn dispatch(
        self: *Editor,
        action: actions_mod.Action,
        prompt: prompt_mod.Prompt,
    ) !?ReadLineResult {
        // Any non-kill, non-yank action breaks the kill-ring's
        // coalescing chain — the next `Ctrl-W` after a cursor move
        // starts a fresh ring slot rather than appending to the
        // previous kill.
        switch (action) {
            .kill_to_start, .kill_to_end, .kill_word_backward, .kill_word_forward => {},
            .yank, .yank_pop => {},
            else => self.kill_ring.reset(),
        }
        // Cursor moves and other non-edit actions break undo
        // coalescing too, so the next edit starts a fresh group.
        switch (action) {
            .insert_text,
            .delete_backward,
            .delete_forward,
            .kill_to_start,
            .kill_to_end,
            .kill_word_backward,
            .kill_word_forward,
            .yank,
            .yank_pop,
            .complete,
            .undo,
            .redo,
            => {},
            else => self.changeset.breakSequence(),
        }
        switch (action) {
            .insert_text => |t| {
                const cursor_before = self.buffer.cursor_byte;
                try self.buffer.insertText(t);
                self.recordInsertOrDiag(cursor_before, t, cursor_before, self.buffer.cursor_byte);
            },
            .delete_backward => {
                const cursor_before = self.buffer.cursor_byte;
                if (try self.buffer.deleteBackwardCluster()) |range| {
                    defer self.allocator.free(range.bytes);
                    self.recordDeleteOrDiag(range.idx, range.bytes, cursor_before, self.buffer.cursor_byte);
                }
            },
            .delete_forward => {
                const cursor_before = self.buffer.cursor_byte;
                if (try self.buffer.deleteForwardCluster()) |range| {
                    defer self.allocator.free(range.bytes);
                    self.recordDeleteOrDiag(range.idx, range.bytes, cursor_before, self.buffer.cursor_byte);
                }
            },
            .kill_to_start => try self.dispatchKill(.kill_to_start),
            .kill_to_end => try self.dispatchKill(.kill_to_end),
            .kill_word_backward => try self.dispatchKill(.kill_word_backward),
            .kill_word_forward => try self.dispatchKill(.kill_word_forward),
            .move_left => try self.buffer.moveLeftCluster(),
            .move_right => try self.buffer.moveRightCluster(),
            .move_word_left => try self.buffer.moveLeftWord(),
            .move_word_right => try self.buffer.moveRightWord(),
            .move_to_start => self.buffer.moveToStart(),
            .move_to_end => self.buffer.moveToEnd(),
            .history_prev => {
                if (self.options.history) |h| {
                    if (h.previous(self.buffer.slice())) |entry| {
                        try self.buffer.replaceAll(entry);
                        // History recall is not part of the line's
                        // edit history — wipe undo so Ctrl-_ doesn't
                        // unwind a recalled line into the previous
                        // one's history.
                        self.changeset.clear();
                    }
                }
            },
            .history_next => {
                if (self.options.history) |h| {
                    if (h.next()) |entry| {
                        try self.buffer.replaceAll(entry);
                        self.changeset.clear();
                    }
                }
            },
            .complete => try self.handleComplete(prompt),
            .accept_line => {
                try self.renderer.finalize(&self.terminal);
                const out = try self.buffer.take();
                self.changeset.clear();
                if (self.options.history) |h| {
                    if (out.len > 0) {
                        h.append(out) catch |err| {
                            self.diag(.{ .kind = .history_append_failed, .err = err });
                        };
                    }
                }
                return ReadLineResult{ .line = out };
            },
            .cancel_line => {
                // Move past the rendered block so "^C" doesn't print
                // mid-prompt when the cursor was on a leading row.
                try self.renderer.finalize(&self.terminal);
                try self.terminal.writeAll("^C\r\n");
                self.buffer.clear();
                self.changeset.clear();
                self.renderer.markFresh();
                return ReadLineResult{ .interrupt = {} };
            },
            .eof => {
                if (self.buffer.isEmpty()) {
                    try self.renderer.finalize(&self.terminal);
                    return ReadLineResult{ .eof = {} };
                }
                const cursor_before = self.buffer.cursor_byte;
                if (try self.buffer.deleteForwardCluster()) |range| {
                    defer self.allocator.free(range.bytes);
                    self.recordDeleteOrDiag(range.idx, range.bytes, cursor_before, self.buffer.cursor_byte);
                }
            },
            .clear_screen => {
                try self.terminal.writeAll("\x1b[H\x1b[2J");
                self.renderer.markFresh();
                self.kill_ring.reset();
            },
            // `redraw` re-runs the render with current cached state —
            // the prior block gets cleared row-by-row and rewritten.
            // Don't markFresh here: we want the climb-and-clear.
            .redraw => {},
            .yank => try self.handleYank(),
            .yank_pop => try self.handleYankPop(),
            .undo => try self.handleUndo(),
            .redo => try self.handleRedo(),
            .suspend_self => {
                // Move past the rendered block so the user lands at
                // a fresh row in their shell, then raise SIGTSTP.
                // The signal handler restores termios, re-raises
                // with default disposition (process actually stops),
                // and on resume re-enters raw mode + writes to the
                // self-pipe. The next reader.next() picks up the
                // pipe wake and returns .resize, which triggers a
                // render — visually identical to a SIGWINCH.
                try self.renderer.finalize(&self.terminal);
                self.renderer.markFresh();
                _ = std.c.raise(.TSTP);
            },
        }
        return null;
    }

    fn insertChar(self: *Editor, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.buffer.insertText(buf[0..len]);
    }

    fn insertCharRecorded(self: *Editor, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        const cursor_before = self.buffer.cursor_byte;
        try self.buffer.insertText(buf[0..len]);
        self.recordInsertOrDiag(cursor_before, buf[0..len], cursor_before, self.buffer.cursor_byte);
    }

    fn handlePaste(self: *Editor, payload: []const u8) !void {
        // PastePolicy.accept: insert payload, replacing newlines with
        // spaces (the editor handles only single logical lines).
        const sanitized = try sanitizePaste(self.allocator, payload);
        defer self.allocator.free(sanitized);
        if (sanitized.len == 0) return;
        // Paste is a logical-action boundary — typing immediately
        // before or after the paste shouldn't merge into it as a
        // single coalesced insert.
        self.kill_ring.reset();
        self.changeset.breakSequence();
        const cursor_before = self.buffer.cursor_byte;
        try self.buffer.insertText(sanitized);
        self.recordInsertOrDiag(cursor_before, sanitized, cursor_before, self.buffer.cursor_byte);
        self.changeset.breakSequence();
    }

    fn handleComplete(self: *Editor, prompt: prompt_mod.Prompt) !void {
        _ = prompt;
        const hook = self.options.completion orelse return;
        const result = hook.complete(self.allocator, .{
            .buffer = self.buffer.slice(),
            .cursor_byte = self.buffer.cursor_byte,
        }) catch |err| {
            self.diag(.{ .kind = .completion_hook_failed, .err = err });
            return;
        };
        defer {
            for (result.candidates) |c| {
                self.allocator.free(c.insert);
                if (c.display) |d| self.allocator.free(d);
                if (c.description) |d| self.allocator.free(d);
            }
            self.allocator.free(result.candidates);
        }

        // Validate the replacement range against the live buffer.
        // A buggy hook returning out-of-range, inverted, or
        // mid-cluster bounds must never crash the editor or break
        // the buffer's UTF-8 / grapheme invariants.
        const buf_len = self.buffer.bytes.items.len;
        if (result.replacement_start > result.replacement_end or
            result.replacement_end > buf_len)
        {
            self.diag(.{ .kind = .completion_invalid_range, .detail = "start>end or end>len" });
            return;
        }
        try self.buffer.ensureClusters();
        if (!isClusterBoundary(self.buffer.clusters.items, buf_len, result.replacement_start) or
            !isClusterBoundary(self.buffer.clusters.items, buf_len, result.replacement_end))
        {
            self.diag(.{ .kind = .completion_invalid_range, .detail = "endpoint not on cluster boundary" });
            return;
        }

        if (result.candidates.len == 0) return;

        if (result.candidates.len == 1) {
            try self.applyCandidate(result.candidates[0], result.replacement_start, result.replacement_end);
            return;
        }

        // Multiple matches: insert longest common prefix, then list.
        const lcp_full = longestCommonPrefix(result.candidates);
        const common = utf8TruncateToBoundary(lcp_full);
        const current = self.buffer.slice()[result.replacement_start..result.replacement_end];

        if (common.len > current.len and std.unicode.utf8ValidateSlice(common)) {
            const old = try self.allocator.dupe(u8, current);
            defer self.allocator.free(old);
            const cursor_before = self.buffer.cursor_byte;
            try self.replaceRangeAt(result.replacement_start, result.replacement_end, common);
            self.recordReplaceOrDiag(
                result.replacement_start,
                old,
                common,
                cursor_before,
                self.buffer.cursor_byte,
            );
            self.changeset.breakSequence();
        } else {
            // Move past the rendered block so the candidate list
            // doesn't print mid-prompt when the cursor is on a
            // leading row of a multi-row buffer.
            try self.renderer.finalize(&self.terminal);
            for (result.candidates, 0..) |c, i| {
                const label = c.display orelse c.insert;
                try self.writeCompletionLabel(label);
                if (i + 1 < result.candidates.len) try self.terminal.writeAll("  ");
            }
            try self.terminal.writeAll("\r\n");
            self.renderer.markFresh();
        }
    }

    /// Print a candidate's display label, replacing control bytes
    /// (C0, DEL, and C1) with '?'. Filenames and other user-
    /// controlled data can embed CSI/ESC bytes — rendering them raw
    /// would let a malicious filename redraw the user's terminal.
    /// We also reject bytes 0x80..0x9f (the C1 control range) and
    /// any byte that isn't valid as part of a UTF-8 sequence we'd
    /// otherwise pass through; for v0.1 the safe-bytes set is
    /// 0x20..0x7e plus valid UTF-8 multi-byte runs.
    fn writeCompletionLabel(self: *Editor, label: []const u8) !void {
        var safe: std.ArrayListUnmanaged(u8) = .empty;
        defer safe.deinit(self.allocator);
        try safe.ensureUnusedCapacity(self.allocator, label.len);
        var i: usize = 0;
        while (i < label.len) {
            const b = label[i];
            if (b < 0x20 or b == 0x7f) {
                safe.appendAssumeCapacity('?');
                i += 1;
                continue;
            }
            if (b < 0x80) {
                safe.appendAssumeCapacity(b);
                i += 1;
                continue;
            }
            // Multi-byte UTF-8: validate the whole sequence; if
            // valid AND the codepoint isn't C1, pass through. C1
            // (U+0080–U+009F) maps to one '?'.
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
                safe.appendAssumeCapacity('?');
                i += 1;
                continue;
            };
            if (i + seq_len > label.len) {
                safe.appendAssumeCapacity('?');
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(label[i .. i + seq_len]) catch {
                safe.appendAssumeCapacity('?');
                i += 1;
                continue;
            };
            if (cp >= 0x80 and cp <= 0x9f) {
                safe.appendAssumeCapacity('?');
            } else {
                safe.appendSliceAssumeCapacity(label[i .. i + seq_len]);
            }
            i += seq_len;
        }
        try self.terminal.writeAll(safe.items);
    }

    fn applyCandidate(
        self: *Editor,
        cand: completion_mod.Candidate,
        start: usize,
        end: usize,
    ) !void {
        // Reject malformed candidates before touching the buffer so
        // the caller gets either a clean replacement or no change.
        if (!std.unicode.utf8ValidateSlice(cand.insert)) {
            self.diag(.{ .kind = .completion_invalid_candidate, .detail = "insert is not valid UTF-8" });
            return;
        }
        if (cand.append) |c| {
            if (c >= 0x80 or c < 0x20) {
                self.diag(.{ .kind = .completion_invalid_candidate, .detail = "append byte is not ASCII printable" });
                return;
            }
        }

        const old = if (end > start)
            try self.allocator.dupe(u8, self.buffer.bytes.items[start..end])
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(old);
        const cursor_before = self.buffer.cursor_byte;
        try self.replaceRangeAt(start, end, cand.insert);
        if (cand.append) |c| {
            var b: [1]u8 = .{c};
            try self.buffer.insertText(&b);
        }
        // Whole completion (replacement + optional append) records
        // as one Replace op, so a single Ctrl-_ unwinds it.
        const new_text_len = cand.insert.len + @as(usize, if (cand.append != null) 1 else 0);
        const new_text = self.buffer.bytes.items[start .. start + new_text_len];
        self.recordReplaceOrDiag(start, old, new_text, cursor_before, self.buffer.cursor_byte);
        self.changeset.breakSequence();
    }

    fn replaceRangeAt(
        self: *Editor,
        start: usize,
        end: usize,
        text: []const u8,
    ) !void {
        // Replace [start..end] with text. Cursor lands at start + text.len.
        const old = self.buffer.bytes.items;
        var rebuilt = std.ArrayListUnmanaged(u8).empty;
        defer rebuilt.deinit(self.allocator);
        try rebuilt.appendSlice(self.allocator, old[0..start]);
        try rebuilt.appendSlice(self.allocator, text);
        try rebuilt.appendSlice(self.allocator, old[end..]);
        try self.buffer.replaceAll(rebuilt.items);
        self.buffer.cursor_byte = start + text.len;
    }

    /// Cooked-mode read for non-TTY input (pipes, scripts). The line
    /// editor isn't usable here (no escapes, no cursor), but callers
    /// still want their `readLine` to work end-to-end. We:
    ///   - normalize \r\n / \r → \n line termination
    ///   - drop other C0 controls + DEL silently
    ///   - treat 0x04 (Ctrl-D) on an empty in-progress line as EOF
    ///   - validate the accepted line as UTF-8 (returns
    ///     `error.InvalidUtf8` if malformed)
    fn readLineCooked(self: *Editor, prompt: prompt_mod.Prompt) !ReadLineResult {
        // Only echo the prompt when stdout is a TTY. When zigline is
        // embedded in a script that pipes its output, prompts would
        // otherwise contaminate the machine-readable stream — and
        // any embedded ANSI in the prompt would be ugly noise in a
        // log file. Other libraries (readline, isocline) take the
        // same approach.
        if (self.terminal.isOutputTty()) {
            try self.terminal.writeAll(prompt.bytes);
        }
        self.buffer.clear();
        var byte: [1]u8 = undefined;
        while (true) {
            const n = std.c.read(self.options.input_fd, &byte, 1);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return error.ReadFailed;
            }
            if (n == 0) {
                if (self.buffer.isEmpty()) return .eof;
                return self.acceptCookedLine();
            }
            const c = byte[0];

            // If the last `readLine` ended on a `\r` and a `\n` is
            // queued up, swallow it once and forget. Anything else
            // resets the flag and proceeds normally.
            if (self.cooked_pending_lf) {
                self.cooked_pending_lf = false;
                if (c == '\n') continue;
            }

            // CRLF and bare CR both terminate a line as LF does. We
            // remember a trailing CR so the LF that may follow it on
            // the next read isn't taken as an extra empty line.
            if (c == '\r') {
                self.cooked_pending_lf = true;
                return self.acceptCookedLine();
            }
            if (c == '\n') return self.acceptCookedLine();

            // Ctrl-D on empty line behaves like EOF, matching the
            // raw-mode keymap. Past that, append; control bytes and
            // DEL are dropped to keep parity with paste sanitization.
            if (c == 0x04 and self.buffer.isEmpty()) return .eof;
            if (c == 0x7f or c < 0x20) continue;
            try self.buffer.bytes.append(self.allocator, c);
        }
    }

    fn acceptCookedLine(self: *Editor) !ReadLineResult {
        if (!std.unicode.utf8ValidateSlice(self.buffer.bytes.items)) {
            self.buffer.clear();
            return error.InvalidUtf8;
        }
        return ReadLineResult{ .line = try self.buffer.take() };
    }
};

fn longestCommonPrefix(cands: []completion_mod.Candidate) []const u8 {
    if (cands.len == 0) return "";
    var n: usize = cands[0].insert.len;
    for (cands[1..]) |c| {
        const m = @min(n, c.insert.len);
        var i: usize = 0;
        while (i < m and cands[0].insert[i] == c.insert[i]) : (i += 1) {}
        n = i;
        if (n == 0) break;
    }
    return cands[0].insert[0..n];
}

/// True iff `byte_off` is a valid grapheme cluster boundary in the
/// buffer of length `buf_len` whose clusters are `clusters`. The end-
/// of-buffer offset is always a boundary; the start is too.
fn isClusterBoundary(
    clusters: []const buffer_mod.Cluster,
    buf_len: usize,
    byte_off: usize,
) bool {
    if (byte_off == 0) return true;
    if (byte_off == buf_len) return true;
    for (clusters) |c| {
        if (c.byte_start == byte_off) return true;
        if (c.byte_start > byte_off) return false;
    }
    return false;
}

/// Trim `bytes` so it ends on a UTF-8 scalar boundary. The byte-level
/// LCP can leave us mid-codepoint when two candidates share leading
/// bytes of different multi-byte chars; inserting that into the
/// buffer would violate the UTF-8 invariant.
fn utf8TruncateToBoundary(bytes: []const u8) []const u8 {
    var i = bytes.len;
    while (i > 0) {
        const c = bytes[i - 1];
        if (c < 0x80) return bytes[0..i]; // ASCII byte; safe boundary after
        if (c >= 0xC0) {
            // Lead byte: check whether the run is a complete sequence.
            const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
                i -= 1;
                continue;
            };
            if (i - 1 + seq_len <= bytes.len) {
                if (std.unicode.utf8Decode(bytes[i - 1 .. i - 1 + seq_len])) |_| {
                    return bytes[0 .. i - 1 + seq_len];
                } else |_| {}
            }
            i -= 1;
            continue;
        }
        // Continuation byte (0x80-0xBF) — back up further.
        i -= 1;
    }
    return bytes[0..0];
}

/// Sanitize a bracketed-paste payload before inserting it into the
/// buffer. Per SPEC §3.4 + §4 (PastePolicy.accept):
///   - newline / CR → single space (the editor handles one logical line)
///   - C0 control codes (0x00–0x1f) and DEL (0x7f) are dropped
///   - 0x20–0x7e and 0x80+ pass through
///   - then any maximal invalid UTF-8 byte run is replaced with
///     U+FFFD (the Unicode replacement character) so the buffer's
///     UTF-8 invariant holds.
/// Caller frees the returned slice.
fn sanitizePaste(allocator: Allocator, payload: []const u8) ![]u8 {
    var stripped: std.ArrayListUnmanaged(u8) = .empty;
    defer stripped.deinit(allocator);
    try stripped.ensureUnusedCapacity(allocator, payload.len);
    for (payload) |b| {
        if (b == '\n' or b == '\r') {
            stripped.appendAssumeCapacity(' ');
        } else if (b == 0x7f or b < 0x20) {
            // drop C0 controls + DEL
        } else {
            stripped.appendAssumeCapacity(b);
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    const bytes = stripped.items;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len) {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            break;
        }
        if (std.unicode.utf8Decode(bytes[i .. i + seq_len])) |_| {
            try out.appendSlice(allocator, bytes[i .. i + seq_len]);
            i += seq_len;
        } else |_| {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "editor: longestCommonPrefix" {
    var cands = [_]completion_mod.Candidate{
        .{ .insert = "hello" },
        .{ .insert = "help" },
        .{ .insert = "hex" },
    };
    try std.testing.expectEqualStrings("he", longestCommonPrefix(&cands));
}

test "editor: utf8TruncateToBoundary keeps complete scalars" {
    // "café" — last char is 2-byte é (0xC3 0xA9).
    try std.testing.expectEqualStrings("café", utf8TruncateToBoundary("café"));
    // Truncated mid-é (only 0xC3) → trim back to "caf".
    try std.testing.expectEqualStrings("caf", utf8TruncateToBoundary("caf\xC3"));
    // 3-byte char with only 2 bytes → trim back.
    try std.testing.expectEqualStrings("a", utf8TruncateToBoundary("a\xE3\x81"));
    // Pure ASCII unaffected.
    try std.testing.expectEqualStrings("hello", utf8TruncateToBoundary("hello"));
    // Empty → empty.
    try std.testing.expectEqualStrings("", utf8TruncateToBoundary(""));
}

// =============================================================================
// Diagnostic-callback wiring test.
// =============================================================================

const DiagTestCtx = struct {
    count: usize = 0,
    last_kind: ?Diagnostic.Kind = null,

    fn cb(ctx: *anyopaque, d: Diagnostic) void {
        const self: *DiagTestCtx = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_kind = d.kind;
    }

    fn hook(self: *DiagTestCtx) DiagnosticHook {
        return .{
            .ctx = @ptrCast(self),
            .fn_ = cb,
        };
    }
};

fn invertedRangeCompleter(
    _: *anyopaque,
    alloc: Allocator,
    _: completion_mod.CompletionRequest,
) anyerror!completion_mod.CompletionResult {
    const cands = try alloc.alloc(completion_mod.Candidate, 1);
    cands[0] = .{ .insert = try alloc.dupe(u8, "x") };
    return .{
        .replacement_start = 5,
        .replacement_end = 0, // invalid: end < start
        .candidates = cands,
    };
}

test "editor: invalid completion range fires diagnostic, leaves buffer untouched" {
    var diag_ctx: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .completion = .{
            .ctx = @ptrFromInt(0xDEAD),
            .completeFn = invertedRangeCompleter,
        },
        .diagnostic = diag_ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("hello");
    const before = try std.testing.allocator.dupe(u8, editor.buffer.slice());
    defer std.testing.allocator.free(before);

    try editor.handleComplete(prompt_mod.Prompt.plain("$ "));

    try std.testing.expect(diag_ctx.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .completion_invalid_range),
        diag_ctx.last_kind,
    );
    try std.testing.expectEqualStrings(before, editor.buffer.slice());
}

fn invalidUtf8Completer(
    _: *anyopaque,
    alloc: Allocator,
    _: completion_mod.CompletionRequest,
) anyerror!completion_mod.CompletionResult {
    const cands = try alloc.alloc(completion_mod.Candidate, 1);
    cands[0] = .{ .insert = try alloc.dupe(u8, "\xFF\xFE") };
    return .{
        .replacement_start = 0,
        .replacement_end = 0,
        .candidates = cands,
    };
}

test "editor: invalid candidate UTF-8 fires diagnostic, leaves buffer untouched" {
    var diag_ctx: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .completion = .{
            .ctx = @ptrFromInt(0xDEAD),
            .completeFn = invalidUtf8Completer,
        },
        .diagnostic = diag_ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("hi");
    try editor.handleComplete(prompt_mod.Prompt.plain("$ "));

    try std.testing.expect(diag_ctx.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .completion_invalid_candidate),
        diag_ctx.last_kind,
    );
    try std.testing.expectEqualStrings("hi", editor.buffer.slice());
}

test "editor: isClusterBoundary catches mid-cluster offsets" {
    // "café" at byte 4 is mid-é (cluster spans [3, 5)).
    var b = buffer_mod.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insertText("café");
    try b.ensureClusters();
    const buf_len = b.bytes.items.len;

    try std.testing.expect(isClusterBoundary(b.clusters.items, buf_len, 0));
    try std.testing.expect(isClusterBoundary(b.clusters.items, buf_len, 1));
    try std.testing.expect(isClusterBoundary(b.clusters.items, buf_len, 3));
    try std.testing.expect(isClusterBoundary(b.clusters.items, buf_len, 5));
    try std.testing.expect(!isClusterBoundary(b.clusters.items, buf_len, 4)); // mid-é
}

test "editor: sanitizePaste replaces newlines with spaces" {
    const got = try sanitizePaste(std.testing.allocator, "ls -l\nrm -rf /\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("ls -l rm -rf / ", got);
}

test "editor: sanitizePaste drops C0 controls and DEL" {
    const got = try sanitizePaste(std.testing.allocator, "a\x01b\x07c\x7fd\x1fe");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("abcde", got);
}

test "editor: sanitizePaste preserves valid multi-byte UTF-8" {
    const got = try sanitizePaste(std.testing.allocator, "café — 中");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("café — 中", got);
}

test "editor: sanitizePaste replaces invalid UTF-8 with FFFD" {
    // Lone 0xC3 followed by 0x20 — invalid 2-byte start, FFFD it.
    const got = try sanitizePaste(std.testing.allocator, "a\xC3 b");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a\xEF\xBF\xBD b", got);
}
