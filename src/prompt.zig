//! Prompt — bytes + display width.
//!
//! See SPEC.md §7. The prompt is a value the caller passes to
//! `readLine`. It's `bytes + width` because the bytes may contain
//! ANSI escape sequences (zero-width SGR transitions) that the
//! library can't safely guess at — only the caller knows the
//! display width.
//!
//! For pure-ASCII prompts, `Prompt.plain` is the fast path.
//! For UTF-8 prompts without embedded ANSI, `Prompt.fromUtf8`
//! computes width via grapheme.

const std = @import("std");

const grapheme = @import("grapheme.zig");

pub const Prompt = struct {
    /// Printable bytes including any embedded ANSI escape sequences.
    /// Borrowed by the editor; must outlive the `readLine` call.
    bytes: []const u8,
    /// Display width in terminal cells. For ASCII == bytes.len.
    width: usize,

    /// Pure-ASCII prompt; width equals byte length.
    pub fn plain(bytes: []const u8) Prompt {
        return .{ .bytes = bytes, .width = bytes.len };
    }

    /// UTF-8 prompt without embedded ANSI; width is computed via
    /// grapheme segmentation.
    pub fn fromUtf8(bytes: []const u8) !Prompt {
        const w = try grapheme.displayWidth(bytes, .{});
        return .{ .bytes = bytes, .width = w };
    }
};

test "prompt: plain ASCII" {
    const p = Prompt.plain("$ ");
    try std.testing.expectEqual(@as(usize, 2), p.width);
}
