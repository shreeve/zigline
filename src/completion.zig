//! Completion — replacement-range based completion hook.
//!
//! See SPEC.md §7 (hook types). The hook returns an explicit byte
//! range (`replacement_start..replacement_end`) plus a list of
//! candidates. This is more general than suffix-based completion —
//! it supports quoting, word boundaries that aren't whitespace, and
//! candidates whose insert-form differs from their display-form.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const CompletionHook = struct {
    ctx: *anyopaque,
    /// Called by the editor when the user requests completion. The
    /// hook may allocate from `allocator`; the editor frees both
    /// the returned candidate slice and any candidate-owned strings
    /// after applying the chosen candidate.
    completeFn: *const fn (
        ctx: *anyopaque,
        allocator: Allocator,
        request: CompletionRequest,
    ) anyerror!CompletionResult,

    pub fn complete(
        self: CompletionHook,
        allocator: Allocator,
        request: CompletionRequest,
    ) anyerror!CompletionResult {
        return self.completeFn(self.ctx, allocator, request);
    }
};

pub const CompletionRequest = struct {
    /// Snapshot of the buffer at hook-call time. Borrowed; valid
    /// only for the duration of `completeFn`.
    buffer: []const u8,
    /// Cursor byte offset.
    cursor_byte: usize,
};

pub const CompletionResult = struct {
    /// Inclusive byte offset; range to replace with a candidate's
    /// `insert` text. Must align to a grapheme cluster boundary.
    replacement_start: usize,
    /// Exclusive byte offset.
    replacement_end: usize,
    /// Candidates, allocator-owned. Editor frees after use.
    candidates: []Candidate,
};

pub const Candidate = struct {
    /// The text inserted into the buffer if this candidate is chosen.
    insert: []const u8,
    /// Optional display label shown in the menu (defaults to insert).
    display: ?[]const u8 = null,
    /// Optional one-line description.
    description: ?[]const u8 = null,
    /// Hint for menu styling.
    kind: CandidateKind = .plain,
    /// Character to append after insertion (e.g. '/' for directories,
    /// ' ' for completed commands).
    append: ?u8 = null,
};

pub const CandidateKind = enum {
    plain,
    file,
    directory,
    command,
    variable,
};

/// Configuration for the multi-candidate completion menu. See
/// SPEC.md §6.5. Wired into the editor via
/// `Options.completion_menu` (null disables the menu).
pub const CompletionMenuOptions = struct {
    /// Maximum candidate rows visible per page; the menu paginates
    /// past this with `PageUp` / `PageDown` and renders an `(N/M)`
    /// indicator. `null` = auto, `min(terminal_rows / 2, 10)`.
    max_rows: ?usize = null,
    /// When `true` and at least one candidate carries a non-null
    /// `description`, the menu switches to single-column "descriptive"
    /// mode (one candidate per row, description column to the right
    /// in the dim style). When the description column would have
    /// fewer than ~20 cells, the menu falls back to grid mode
    /// regardless of this setting.
    show_descriptions: bool = true,
};

test "completion: types compile" {
    const c = Candidate{ .insert = "ls" };
    _ = c;
}
