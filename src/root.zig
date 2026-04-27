//! zigline — public entry point.
//!
//! Quick start:
//!
//!     var editor = try zigline.Editor.init(alloc, .{});
//!     defer editor.deinit();
//!     while (true) {
//!         const result = try editor.readLine(zigline.Prompt.plain("$ "));
//!         switch (result) {
//!             .line => |line| { defer alloc.free(line); ... },
//!             .interrupt => continue,
//!             .eof => break,
//!         }
//!     }
//!
//! See SPEC.md for the full design specification. This file re-exports
//! the public surface; the docs live next to the types.

const std = @import("std");

// =============================================================================
// Core editor — see SPEC.md §7
// =============================================================================

pub const Allocator = std.mem.Allocator;

/// Top-level line editor. See `editor.zig` for full docs.
pub const Editor = @import("editor.zig").Editor;
/// Options for `Editor.init`. All fields default; the zero-value
/// configuration reads from stdin/stdout in TTY raw mode with an
/// emacs keymap and no history / completion / highlighting.
pub const Options = @import("editor.zig").Options;
/// Outcome of a single `readLine` call: an accepted line (caller
/// frees), an interrupt (Ctrl-C), or an EOF.
pub const ReadLineResult = @import("editor.zig").ReadLineResult;
/// Whether `Editor` should manage termios on entry/exit, or assume
/// the caller has done so.
pub const RawModePolicy = @import("editor.zig").RawModePolicy;
/// How bracketed paste payloads are handled. v0.1 ships only `.accept`
/// (multi-line pastes collapse to space-separated single line).
pub const PastePolicy = @import("editor.zig").PastePolicy;

/// Categorized failure delivered to `Options.diagnostic` when a hook
/// returns an error or invalid data. Library behavior stays
/// nonfatal; this is a debugging surface for embedders.
pub const Diagnostic = @import("editor.zig").Diagnostic;
pub const DiagnosticHook = @import("editor.zig").DiagnosticHook;

// =============================================================================
// Buffer / Prompt / input event types
// =============================================================================

/// Mutable text buffer with grapheme cluster index. Used internally
/// by `Editor` and exposed for callers that want to drive editing
/// without `readLine`.
pub const Buffer = @import("buffer.zig").Buffer;
/// One grapheme cluster: byte range + display width in cells.
pub const Cluster = @import("buffer.zig").Cluster;

/// The prompt value passed to `readLine`. Carries both bytes (which
/// may include ANSI escapes) and the explicit display width — the
/// caller is the only one who can compute width when escapes are
/// embedded.
pub const Prompt = @import("prompt.zig").Prompt;

/// One typed event from the input layer. The keymap consumes these.
pub const KeyEvent = @import("input.zig").KeyEvent;
pub const KeyCode = @import("input.zig").KeyCode;
pub const Modifiers = @import("input.zig").Modifiers;
/// Top-level event union (key / paste / resize / eof / error).
pub const Event = @import("input.zig").Event;

// =============================================================================
// Action dispatch — keymap-customizable behaviors
// =============================================================================

pub const Action = @import("actions.zig").Action;

/// `KeyEvent → Action` mapping. The default is `Keymap.defaultEmacs()`.
/// `Keymap.bindings` (optional) plugs in a `BindingTable` overlay
/// for multi-key sequences.
pub const Keymap = @import("keymap.zig").Keymap;
/// Storage for multi-key bindings (`Ctrl-X Ctrl-E` and friends).
/// Owned by the application; pass via `Keymap.bindings`. See
/// SPEC §5.1 / §5.2.
pub const BindingTable = @import("keymap.zig").BindingTable;
pub const BindingResult = @import("keymap.zig").BindingResult;
pub const BindError = @import("keymap.zig").BindError;
pub const MAX_KEY_SEQUENCE = @import("keymap.zig").MAX_SEQUENCE;
/// Encode a `KeyEvent` to a 32-bit value (codepoint or named-key
/// reserved value, plus modifier bits in the high bits). Returns
/// null for unbindable kinds (`text`, `unknown`). Exposed for apps
/// that want to build their own indices keyed on KeyEvent.
pub const encodeKeyEvent = @import("keymap.zig").encodeKeyEvent;

/// Multi-slot kill ring. Owned by `Editor`; size controlled via
/// `Options.kill_ring_capacity`. Exposed for advanced use cases like
/// inspecting the ring contents from a custom action.
pub const KillRing = @import("kill_ring.zig").KillRing;

/// Per-line undo / redo stack. Owned by `Editor`; reset on each
/// `accept_line`. Exposed for advanced cases where an application
/// wants to record extra edits into the same history.
pub const Changeset = @import("undo.zig").Changeset;

// =============================================================================
// History
// =============================================================================

/// In-memory + persistent flat-file history. Caller-owned; pass into
/// `Options.history` to share one history across multiple editor
/// sessions.
pub const History = @import("history.zig").History;
pub const HistoryOptions = @import("history.zig").HistoryOptions;

// =============================================================================
// Completion + highlight hooks
// =============================================================================

pub const CompletionHook = @import("completion.zig").CompletionHook;
pub const CompletionRequest = @import("completion.zig").CompletionRequest;
pub const CompletionResult = @import("completion.zig").CompletionResult;
pub const Candidate = @import("completion.zig").Candidate;
pub const CandidateKind = @import("completion.zig").CandidateKind;

/// Application-defined action hook. Bind a key to
/// `Action{ .custom = id }` in your keymap, set `Options.custom_action`,
/// and the editor invokes the hook with the buffer snapshot. Returned
/// `CustomActionResult` tells the editor what to do (insert, replace,
/// accept, cancel, no-op). For actions that spawn an external process
/// (open `$EDITOR`, run a pager), use `CustomActionContext.pauseRawMode`
/// + `resumeRawMode` to release/reclaim the terminal around the spawn.
pub const CustomActionHook = @import("editor.zig").CustomActionHook;
pub const CustomActionRequest = @import("editor.zig").CustomActionRequest;
pub const CustomActionResult = @import("editor.zig").CustomActionResult;
pub const CustomActionContext = @import("editor.zig").CustomActionContext;

pub const HighlightHook = @import("highlight.zig").HighlightHook;
/// Snapshot passed to a `HighlightHook`: `buffer` + `cursor_byte`.
/// Mirrors `CompletionRequest` and `CustomActionRequest` for
/// cross-hook consistency. Cursor-sensitive highlights (bracket
/// matching, current-word emphasis) use `cursor_byte`.
pub const HighlightRequest = @import("highlight.zig").HighlightRequest;
/// Semantic span: a byte range + a style. The renderer sorts spans,
/// drops overlaps, snaps endpoints to cluster boundaries, and emits
/// SGR — applications should not encode escape bytes themselves.
pub const HighlightSpan = @import("highlight.zig").HighlightSpan;
pub const Style = @import("highlight.zig").Style;
pub const Color = @import("highlight.zig").Color;

// =============================================================================
// Width / Unicode policy
// =============================================================================

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
    _ = @import("kill_ring.zig");
    _ = @import("undo.zig");
}
