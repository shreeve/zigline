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
const prompt_mod = @import("prompt.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal.zig");

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
};

pub const Editor = struct {
    allocator: Allocator,
    options: Options,
    buffer: buffer_mod.Buffer,
    terminal: terminal_mod.Terminal,
    renderer: renderer_mod.Renderer,
    reader: input_mod.Reader,

    pub fn init(allocator: Allocator, options: Options) !Editor {
        var ed: Editor = .{
            .allocator = allocator,
            .options = options,
            .buffer = buffer_mod.Buffer.init(allocator),
            .terminal = terminal_mod.Terminal.init(options.input_fd, options.output_fd),
            .renderer = undefined,
            .reader = input_mod.Reader.init(allocator, options.input_fd),
        };
        ed.buffer.width_policy = options.width_policy;
        ed.renderer = renderer_mod.Renderer.init(allocator, &ed.terminal, options.width_policy);
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.reader.deinit();
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
        defer if (self.options.raw_mode == .enter_and_leave) self.terminal.leaveRawMode();

        self.buffer.clear();
        self.renderer.invalidate();
        try self.render(prompt);

        while (true) {
            const ev = self.reader.next();
            switch (ev) {
                .eof => {
                    try self.renderer.finalize();
                    if (self.options.history) |h| h.resetCursor();
                    return .eof;
                },
                .error_ => |e| {
                    try self.renderer.finalize();
                    return e;
                },
                .resize => {
                    self.renderer.invalidate();
                    try self.render(prompt);
                },
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

    pub fn notifyResize(self: *Editor) void {
        self.renderer.invalidate();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    fn render(self: *Editor, prompt: prompt_mod.Prompt) !void {
        var span_buf: ?[]highlight_mod.HighlightSpan = null;
        defer if (span_buf) |sb| self.allocator.free(sb);

        var spans: []const highlight_mod.HighlightSpan = &.{};
        if (self.options.highlight) |hh| {
            const got = hh.highlight(self.allocator, self.buffer.slice()) catch null;
            if (got) |g| {
                span_buf = g;
                spans = g;
            }
        }
        try self.renderer.render(prompt, &self.buffer, spans);
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
                    try self.insertChar(cp);
                },
                .text => |t| try self.buffer.insertText(t),
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
        switch (action) {
            .insert_text => |t| try self.buffer.insertText(t),
            .delete_backward => try self.buffer.deleteBackwardCluster(),
            .delete_forward => try self.buffer.deleteForwardCluster(),
            .kill_to_start => try self.buffer.killToStart(),
            .kill_to_end => try self.buffer.killToEnd(),
            .kill_word_backward => try self.buffer.killWordBackward(),
            .kill_word_forward => try self.buffer.killWordForward(),
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
                    }
                }
            },
            .history_next => {
                if (self.options.history) |h| {
                    if (h.next()) |entry| {
                        try self.buffer.replaceAll(entry);
                    }
                }
            },
            .complete => try self.handleComplete(prompt),
            .accept_line => {
                try self.renderer.finalize();
                const out = try self.buffer.take();
                if (self.options.history) |h| {
                    if (out.len > 0) h.append(out) catch {};
                }
                return ReadLineResult{ .line = out };
            },
            .cancel_line => {
                try self.terminal.writeAll("^C\r\n");
                self.buffer.clear();
                self.renderer.invalidate();
                return ReadLineResult{ .interrupt = {} };
            },
            .eof => {
                if (self.buffer.isEmpty()) {
                    try self.renderer.finalize();
                    return ReadLineResult{ .eof = {} };
                }
                try self.buffer.deleteForwardCluster();
            },
            .clear_screen => {
                try self.terminal.writeAll("\x1b[H\x1b[2J");
                self.renderer.invalidate();
            },
            .redraw => self.renderer.invalidate(),
        }
        return null;
    }

    fn insertChar(self: *Editor, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.buffer.insertText(buf[0..len]);
    }

    fn handlePaste(self: *Editor, payload: []const u8) !void {
        // PastePolicy.accept: insert payload, replacing newlines with
        // spaces (the editor handles only single logical lines).
        const sanitized = try sanitizePaste(self.allocator, payload);
        defer self.allocator.free(sanitized);
        try self.buffer.insertText(sanitized);
    }

    fn handleComplete(self: *Editor, prompt: prompt_mod.Prompt) !void {
        _ = prompt;
        const hook = self.options.completion orelse return;
        const result = hook.complete(self.allocator, .{
            .buffer = self.buffer.slice(),
            .cursor_byte = self.buffer.cursor_byte,
        }) catch return;
        defer {
            for (result.candidates) |c| {
                self.allocator.free(c.insert);
                if (c.display) |d| self.allocator.free(d);
                if (c.description) |d| self.allocator.free(d);
            }
            self.allocator.free(result.candidates);
        }

        if (result.candidates.len == 0) return;

        if (result.candidates.len == 1) {
            try self.applyCandidate(result.candidates[0], result.replacement_start, result.replacement_end);
            return;
        }

        // Multiple matches: insert longest common prefix, then list.
        const common = longestCommonPrefix(result.candidates);
        const current = self.buffer.slice()[result.replacement_start..result.replacement_end];
        if (common.len > current.len) {
            try self.replaceRangeAt(result.replacement_start, result.replacement_end, common);
        } else {
            try self.terminal.writeAll("\r\n");
            for (result.candidates, 0..) |c, i| {
                const label = c.display orelse c.insert;
                try self.terminal.writeAll(label);
                if (i + 1 < result.candidates.len) try self.terminal.writeAll("  ");
            }
            try self.terminal.writeAll("\r\n");
            self.renderer.invalidate();
        }
    }

    fn applyCandidate(
        self: *Editor,
        cand: completion_mod.Candidate,
        start: usize,
        end: usize,
    ) !void {
        try self.replaceRangeAt(start, end, cand.insert);
        if (cand.append) |c| {
            var b: [1]u8 = .{c};
            try self.buffer.insertText(&b);
        }
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

    /// Cooked-mode read for non-TTY input (pipes, scripts).
    fn readLineCooked(self: *Editor, prompt: prompt_mod.Prompt) !ReadLineResult {
        try self.terminal.writeAll(prompt.bytes);
        self.buffer.clear();
        var byte: [1]u8 = undefined;
        while (true) {
            const n = std.c.read(self.options.input_fd, &byte, 1);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR) continue;
                return error.ReadFailed;
            }
            if (n == 0) {
                if (self.buffer.isEmpty()) return .eof;
                return ReadLineResult{ .line = try self.buffer.take() };
            }
            const c = byte[0];
            if (c == '\n') return ReadLineResult{ .line = try self.buffer.take() };
            try self.buffer.bytes.append(self.allocator, c);
        }
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
