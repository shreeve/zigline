//! Grapheme — Unicode cluster segmentation + display width.
//!
//! See SPEC.md §3 (buffer model) and §6 (render width math).
//!
//! Backed by the `zg` library (https://codeberg.org/atman/zg) — UAX #29
//! grapheme cluster boundaries plus East Asian Width data, both
//! Unicode 16.0 current. zigline bundles only the `Graphemes` and
//! `DisplayWidth` submodules; everything else (general categories,
//! normalization, casing) is excluded to keep the dependency footprint
//! small.

const std = @import("std");

const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

const Cluster = @import("buffer.zig").Cluster;

pub const Allocator = std.mem.Allocator;

pub const WidthPolicy = struct {
    /// East Asian "ambiguous" width characters: false → 1 cell,
    /// true → 2 cells. **Currently ignored at runtime**: the `zg`
    /// `DisplayWidth` dependency is built with `cjk=false` at the
    /// `build.zig.zon` level, so flipping this field has no effect
    /// until we expose a runtime branch (tracked in `FUTURE.md` as
    /// "Configurable ambiguous-width policy"). The field is kept on
    /// the public type so apps that already set it don't break when
    /// we wire the runtime path through.
    ambiguous_is_wide: bool = false,
    /// Display width of a TAB character. Currently unused — the
    /// buffer rejects tabs at every entry point. Exists for the
    /// post-v1.0 "Tab rendering" item in `FUTURE.md`.
    tab_width: u8 = 8,
};

/// Walk `bytes` and produce a cluster array.
///
/// `bytes` need not be valid UTF-8 — `zg` substitutes U+FFFD for
/// malformed runs per the Unicode "Substitution of Maximal Subparts"
/// algorithm and the iterator stays well-defined. The buffer
/// elsewhere enforces UTF-8 validity, so this is just a robustness
/// guarantee.
///
/// Caller owns the returned slice (allocated from `allocator`).
pub fn segment(
    allocator: Allocator,
    bytes: []const u8,
    policy: WidthPolicy,
) ![]Cluster {
    _ = policy; // honored at zg dependency level; see WidthPolicy doc.

    var out: std.ArrayListUnmanaged(Cluster) = .empty;
    errdefer out.deinit(allocator);

    var it = Graphemes.iterator(bytes);
    while (it.next()) |g| {
        const gb = g.bytes(bytes);
        try out.append(allocator, .{
            .byte_start = g.offset,
            .byte_end = g.offset + gb.len,
            .width = clusterWidthSafe(gb),
        });
    }

    return out.toOwnedSlice(allocator);
}

/// Display width of one cluster's bytes, clamped to `u8`. Non-positive
/// widths (BS/DEL) become 0; the `Buffer` already forbids those bytes
/// so the clamp only matters for hand-rolled callers.
pub fn clusterWidth(cluster_bytes: []const u8, policy: WidthPolicy) u8 {
    _ = policy;
    return clusterWidthSafe(cluster_bytes);
}

/// Total display width of `bytes`. Equivalent to summing
/// `clusterWidth` over each cluster, but `zg`'s `strWidth` has an
/// ASCII fast path so we delegate.
pub fn displayWidth(bytes: []const u8, policy: WidthPolicy) !usize {
    _ = policy;
    return DisplayWidth.strWidth(bytes);
}

fn clusterWidthSafe(gb: []const u8) u8 {
    const w = DisplayWidth.graphemeWidth(gb);
    if (w <= 0) return 0;
    if (w > std.math.maxInt(u8)) return std.math.maxInt(u8);
    return @intCast(w);
}

// =============================================================================
// Tests
// =============================================================================

test "grapheme: ASCII width" {
    try std.testing.expectEqual(@as(usize, 5), try displayWidth("hello", .{}));
}

test "grapheme: CJK width" {
    // 'こんにちは' is 5 hiragana characters; each width 2 == 10 cells.
    try std.testing.expectEqual(@as(usize, 10), try displayWidth("こんにちは", .{}));
}

test "grapheme: combining mark forms one cluster" {
    // "café" with é as e + U+0301 combining acute. zg merges these
    // into a single grapheme; the codepoint fallback would not.
    const out = try segment(std.testing.allocator, "cafe\u{301}", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    // The fourth cluster is 3 bytes (e + 2-byte combining mark)
    // and width 1.
    try std.testing.expectEqual(@as(usize, 3), out[3].byte_end - out[3].byte_start);
    try std.testing.expectEqual(@as(u8, 1), out[3].width);
}

test "grapheme: ZWJ family emoji is one cluster" {
    // 👨‍👩‍👧 = man + ZWJ + woman + ZWJ + girl, 18 bytes UTF-8.
    const out = try segment(std.testing.allocator, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 0), out[0].byte_start);
    try std.testing.expectEqual(@as(usize, 18), out[0].byte_end);
    // ZWJ family is double-wide.
    try std.testing.expect(out[0].width >= 2);
}

test "grapheme: regional indicator pair is one cluster" {
    // 🇯🇵 = U+1F1EF U+1F1F5, two regional indicators glued into the
    // Japanese flag; UAX #29 treats the pair as one cluster.
    const out = try segment(std.testing.allocator, "\u{1F1EF}\u{1F1F5}", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 8), out[0].byte_end);
    try std.testing.expectEqual(@as(u8, 2), out[0].width);
}

test "grapheme: clusterWidth on single emoji" {
    try std.testing.expectEqual(@as(u8, 2), clusterWidth("😊", .{}));
}

test "grapheme: empty input segments to empty" {
    const out = try segment(std.testing.allocator, "", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "grapheme: cluster end-points are contiguous" {
    const out = try segment(std.testing.allocator, "Héllo 😊!", .{});
    defer std.testing.allocator.free(out);
    var prev: usize = 0;
    for (out) |c| {
        try std.testing.expectEqual(prev, c.byte_start);
        prev = c.byte_end;
    }
}
