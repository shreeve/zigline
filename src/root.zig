//! zigline — public entry point.
//!
//! See SPEC.md for the full design specification. This file re-exports
//! the public surface of the library.

const std = @import("std");

// =============================================================================
// Public types — see SPEC.md §7
// =============================================================================

pub const Allocator = std.mem.Allocator;

pub const Editor = @import("editor.zig").Editor;
pub const Options = @import("editor.zig").Options;
pub const ReadLineResult = @import("editor.zig").ReadLineResult;
pub const RawModePolicy = @import("editor.zig").RawModePolicy;
pub const PastePolicy = @import("editor.zig").PastePolicy;

pub const Buffer = @import("buffer.zig").Buffer;
pub const Cluster = @import("buffer.zig").Cluster;

pub const Prompt = @import("prompt.zig").Prompt;

pub const KeyEvent = @import("input.zig").KeyEvent;
pub const KeyCode = @import("input.zig").KeyCode;
pub const Modifiers = @import("input.zig").Modifiers;
pub const Event = @import("input.zig").Event;

pub const Action = @import("actions.zig").Action;
pub const DispatchOutcome = @import("actions.zig").DispatchOutcome;

pub const Keymap = @import("keymap.zig").Keymap;

pub const History = @import("history.zig").History;
pub const HistoryOptions = @import("history.zig").HistoryOptions;

pub const CompletionHook = @import("completion.zig").CompletionHook;
pub const CompletionRequest = @import("completion.zig").CompletionRequest;
pub const CompletionResult = @import("completion.zig").CompletionResult;
pub const Candidate = @import("completion.zig").Candidate;
pub const CandidateKind = @import("completion.zig").CandidateKind;

pub const HighlightHook = @import("highlight.zig").HighlightHook;
pub const HighlightSpan = @import("highlight.zig").HighlightSpan;
pub const Style = @import("highlight.zig").Style;
pub const Color = @import("highlight.zig").Color;

pub const WidthPolicy = @import("grapheme.zig").WidthPolicy;

// =============================================================================
// Test discovery — every per-module test block runs through `zig build test`
// =============================================================================

test {
    _ = @import("editor.zig");
    _ = @import("buffer.zig");
    _ = @import("grapheme.zig");
    _ = @import("input.zig");
    _ = @import("keymap.zig");
    _ = @import("actions.zig");
    _ = @import("renderer.zig");
    _ = @import("terminal.zig");
    _ = @import("history.zig");
    _ = @import("completion.zig");
    _ = @import("highlight.zig");
    _ = @import("prompt.zig");
}
