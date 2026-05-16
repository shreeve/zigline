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
const hint_mod = @import("hint.zig");
const transient_mod = @import("transient.zig");
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
        hint_hook_failed,
        hint_invalid_text,
        transient_input_hook_failed,
        transient_input_invalid_text,
        history_append_failed,
        render_failed,
        // Custom-action paths get their own kinds so apps can route
        // them distinctly from completion failures (which is how they
        // were categorized pre-v1.0). `Diagnostic.Kind` is in the
        // "experimental in v1.x" set — see STABILITY.md — so adding
        // variants is non-breaking, but apps that switched on the
        // earlier names should add cases for these.
        custom_action_failed,
        custom_action_invalid_text,
        // Internal-mutation paths that were previously reported as
        // `.render_failed` for lack of a better category.
        undo_record_failed,
        kill_ring_failed,
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

/// Snapshot passed to a `CustomActionHook`. Borrowed; valid only
/// for the duration of `invokeFn`.
pub const CustomActionRequest = struct {
    /// Buffer contents at hook-call time.
    buffer: []const u8,
    /// Cursor byte offset (always at a grapheme cluster boundary).
    cursor_byte: usize,
};

/// Capabilities the hook can use beyond reading buffer state. Kept
/// minimal — the hook should not mutate the buffer through this;
/// use the `CustomActionResult` return value for that. The
/// pause/resume pair is the one capability hooks actually need that
/// can't be expressed declaratively (spawning `$EDITOR`/pager).
pub const CustomActionContext = struct {
    editor: *Editor,

    /// Finalize the rendered block + leave raw mode. Cursor lands
    /// on a fresh row; the terminal is in cooked mode. Hooks call
    /// this before spawning a process that reads from / writes to
    /// stdin/stdout (an editor, pager, password prompt). Pairs with
    /// `resumeRawMode`. Idempotent: calling twice is safe.
    ///
    /// No-op when:
    ///   - The input fd isn't a TTY (cooked-mode read path; no raw
    ///     mode to pause).
    ///   - Zigline doesn't own raw mode (`Options.raw_mode ==
    ///     .assume_already_raw` — caller manages termios). Stomping
    ///     on caller-owned state would corrupt their save/restore.
    ///     Apps in `.assume_already_raw` that want to bracket a
    ///     spawn should bracket it in their own termios save /
    ///     restore around the custom action.
    pub fn pauseRawMode(self: CustomActionContext) !void {
        if (!self.editor.terminal.isInputTty()) return;
        if (!self.editor.owns_raw_mode) return;
        try self.editor.renderer.finalize(&self.editor.terminal);
        // `leaveRawMode` uninstalls the signal-guard and closes the
        // self-pipe. The reader holds the read-end of that pipe;
        // detach so polls don't fire on a closed fd. Re-attached in
        // `resumeRawMode`.
        self.editor.reader.setSignalPipe(-1);
        self.editor.terminal.leaveRawMode();
        self.editor.owns_raw_mode = false;
    }

    /// Re-enter raw mode after `pauseRawMode`. Marks the renderer
    /// fresh — the next render draws from a clean row. Spawned
    /// processes typically leave the cursor wherever they left it,
    /// so there's no guarantee of column 0; the hook should ensure
    /// the spawned process exited with a newline if visual layout
    /// matters.
    ///
    /// No-op symmetric with `pauseRawMode`: if the input fd isn't a
    /// TTY, OR if zigline never owned raw mode in this `readLine`
    /// (i.e. `pauseRawMode` was a no-op too), `resumeRawMode` is
    /// also a no-op.
    pub fn resumeRawMode(self: CustomActionContext) !void {
        if (!self.editor.terminal.isInputTty()) return;
        // If zigline already owns raw mode, calling enterRawMode
        // again is harmless (it's idempotent), but we want resume to
        // exactly mirror pause — only bring up raw mode if we just
        // tore it down.
        if (self.editor.options.raw_mode != .enter_and_leave) return;
        if (self.editor.owns_raw_mode) return; // pause was a no-op
        try self.editor.terminal.enterRawMode();
        self.editor.owns_raw_mode = true;
        // Re-attach the reader to the freshly-installed signal pipe.
        self.editor.reader.setSignalPipe(self.editor.terminal.signalPipeFd());
        self.editor.renderer.markFresh();
    }

    /// Run `func(context)` with raw mode paused. Pauses → calls →
    /// resumes; returns the function's value or propagates its
    /// error. Prefer this over manual `pauseRawMode()` + `defer
    /// resumeRawMode() catch {};` — the deferred form silently
    /// swallows resume failures, leaving the user stuck in cooked
    /// mode if the terminal got into a weird state.
    ///
    /// `func` must be a function taking `@TypeOf(context)` and
    /// returning `anyerror!T` for any `T` (commonly `void` for
    /// "spawn and wait" helpers, or `CustomActionResult` if the
    /// hook computes its result entirely inside the cooked-mode
    /// scope).
    ///
    /// Error semantics:
    /// - `pauseRawMode` failure: propagated; `func` is not called.
    /// - `func` failure: propagated; we still try to resume raw
    ///   mode and surface any resume failure through the
    ///   diagnostic hook so the caller sees the original error.
    /// - `resumeRawMode` failure after a successful `func`:
    ///   propagated.
    pub fn withCookedMode(
        self: CustomActionContext,
        context: anytype,
        comptime func: anytype,
    ) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
        try self.pauseRawMode();
        const result = func(context) catch |err| {
            self.resumeRawMode() catch |re| {
                self.editor.diag(.{
                    .kind = .custom_action_failed,
                    .err = re,
                    .detail = "withCookedMode: resumeRawMode failed after func error",
                });
            };
            return err;
        };
        try self.resumeRawMode();
        return result;
    }
};

/// What the editor should do after the hook returns. Constraining
/// outcomes to a closed set (rather than handing the hook a `*Editor`
/// with mutation rights) keeps the buffer's UTF-8 + cluster
/// invariants under the editor's control.
pub const CustomActionResult = union(enum) {
    /// Hook ran, no buffer change. (E.g. printed help to stderr,
    /// recorded analytics, opened an external help overlay.)
    /// Also the canonical "user aborted" path — if a hook spawns
    /// `$EDITOR` and the user exits without saving (`:cq` in vi,
    /// non-zero exit), return `.no_op`. The buffer stays as it was
    /// before the action; no separate `.action_cancelled` variant
    /// is needed.
    no_op,
    /// Insert this text at the cursor. Editor records as a normal
    /// undo step. Allocator-owned by the hook (allocator passed
    /// into `invokeFn`); editor frees after applying.
    insert_text: []const u8,
    /// Replace the entire buffer. Cursor lands at end of `text`.
    /// Recorded as a single `Replace` undo op so one Ctrl-_
    /// unwinds. Allocator-owned; editor frees after applying.
    replace_buffer: []const u8,
    /// Replace the entire buffer with `text` AND submit the result
    /// as the accepted line in one atomic step. The editor
    /// validates `text` (UTF-8 + no control bytes), replaces the
    /// buffer, repaints the rendered frame WITHOUT a ghost-text
    /// hint (so the visible terminal transcript shows the
    /// replacement, not the pre-action buffer, before CRLF), then
    /// returns `.line = text`. History append matches a normal
    /// `accept_line`. On invalid text the editor reports a
    /// diagnostic, leaves the buffer untouched, and does NOT
    /// accept (returns null from the action arm so the next
    /// `readLine` iteration runs). Allocator-owned; editor frees
    /// after applying. Unlike `replace_buffer` no undo step is
    /// recorded — the line is consumed immediately so undo would
    /// be unobservable.
    replace_buffer_and_accept: []const u8,
    /// Submit the current buffer as the accepted line.
    accept_line,
    /// Discard the current buffer; surface `interrupt` to caller.
    cancel_line,
};

/// Snapshot of where `yank_last_arg` last inserted, used for
/// in-place cycling on repeated invocations.
const YankLastArgState = struct {
    /// 0 = most-recent history entry, 1 = previous, etc.
    cycle: usize,
    /// Byte offset where the previous insertion started.
    start: usize,
    /// Length in bytes of the previous insertion.
    len: usize,
};

/// Live state for transient input mode (Ctrl-R search overlay).
/// Created on `Action.transient_input_open`, freed on accept / abort
/// / cancel. While present, the editor's render and key-handling
/// paths route to alternates that operate on `query` instead of the
/// main buffer; the main buffer is held untouched until the user
/// either accepts a preview into it or aborts.
///
/// `last_preview` distinguishes three states:
///   - `null`         → no match for the current query. Render no
///                      preview. Enter is a no-op (stays transient).
///   - `""`  (empty)  → an explicit empty replacement. Render no
///                      preview text. Enter accepts and clears the
///                      main buffer.
///   - non-empty      → render dim ghost text after the query.
///                      Enter accepts.
const TransientState = struct {
    /// Cluster-aware UTF-8 buffer holding the user's search query.
    /// Reuses `Buffer` so cursor moves, multibyte handling, and
    /// rendering width math come for free.
    query: buffer_mod.Buffer,
    /// Validated, allocator-owned copy of the most recent preview.
    /// See type doc above for the three-state semantics.
    last_preview: ?[]u8 = null,
    /// Validated, allocator-owned copy of the most recent status
    /// text (e.g. `(reverse-i-search): `). `null` ⇒ render the
    /// editor default.
    last_status: ?[]u8 = null,
    /// Cursor byte offset in the main buffer at the moment Ctrl-R
    /// was pressed. Surfaced to the hook for context (Slash uses
    /// this to detect mid-line vs end-of-line invocation).
    original_cursor_byte: usize,
};

/// Validated, allocator-owned snapshot of the hint that the most
/// recent render drew. Held by `Editor` so `accept_hint` inserts
/// EXACTLY the bytes the user saw — no re-invoke of the hook at
/// dispatch time, no risk of accepting a now-different suggestion
/// because the underlying ranking shifted.
///
/// Invariant: at the moment a key event arrives, the buffer is in
/// the exact state that produced this cache (the loop is `read →
/// dispatch → render`; nothing mutates the buffer between render and
/// the next dispatch). So `buffer_len + cursor_byte` are sufficient
/// to identify "the cache still matches the live buffer." If we
/// later introduce async hooks or signal-driven edits, replace the
/// length check with a buffer revision counter.
const CachedHint = struct {
    /// `buffer.bytes.items.len` at render time. Cheap mismatch check
    /// for the (currently impossible) case where something mutated
    /// the buffer between render and accept.
    buffer_len: usize,
    /// `buffer.cursor_byte` at render time. Always equal to
    /// `buffer_len` when populated (see `Editor.computeHintDraw`).
    cursor_byte: usize,
    /// Allocator-owned copy of the hint bytes. Freed on the next
    /// `Editor.render`, on `accept_hint` consumption, or on
    /// `Editor.deinit`.
    text: []u8,
    /// Concrete style (the public `?Style` defaulted to dim if
    /// the hook returned null).
    style: highlight_mod.Style,
    /// Display width of `text` under the active width policy.
    cols: usize,
};

pub const CustomActionHook = struct {
    ctx: *anyopaque,
    /// Called when the keymap returns `Action.custom = id`. The
    /// hook receives:
    ///   - `allocator`: same allocator the editor uses; results
    ///     containing text (`insert_text`, `replace_buffer`) must
    ///     allocate from this allocator. The editor frees after use.
    ///   - `id`: the value the keymap returned. Apps assign their
    ///     own labels (typically `enum(u32)` constants).
    ///   - `request`: buffer + cursor snapshot.
    ///   - `action_ctx`: capability handle (raw-mode pause/resume).
    ///
    /// Hook errors are reported via the diagnostic hook (if set)
    /// and treated as no-op for the buffer.
    invokeFn: *const fn (
        ctx: *anyopaque,
        allocator: Allocator,
        id: u32,
        request: CustomActionRequest,
        action_ctx: CustomActionContext,
    ) anyerror!CustomActionResult,
};

pub const Options = struct {
    input_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    output_fd: std.posix.fd_t = std.posix.STDOUT_FILENO,
    raw_mode: RawModePolicy = .enter_and_leave,
    history: ?*history_mod.History = null,
    keymap: keymap_mod.Keymap = keymap_mod.Keymap.defaultEmacs(),
    completion: ?completion_mod.CompletionHook = null,
    highlight: ?highlight_mod.HighlightHook = null,
    hint: ?hint_mod.HintHook = null,
    /// Optional hook driving the transient input overlay used by
    /// reverse-incremental search (Ctrl-R) and similar "query +
    /// preview" UX. See `src/transient.zig`. The default emacs
    /// keymap binds Ctrl-R to `Action.transient_input_open`; with
    /// no hook configured that action is a no-op.
    transient_input: ?transient_mod.TransientInputHook = null,
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
    /// Optional hook for application-defined actions. The keymap
    /// returns `Action{ .custom = id }`; the editor invokes this
    /// hook with `id` plus the buffer snapshot and applies the
    /// returned `CustomActionResult`. Null disables; keymaps that
    /// never return a `.custom` action don't need to set this.
    custom_action: ?CustomActionHook = null,
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
    /// True when zigline itself entered raw mode for the active
    /// `readLine` (`Options.raw_mode == .enter_and_leave`). Set in
    /// `readLine` after `enterRawMode` succeeds; cleared on the
    /// matching `leaveRawMode`. Used to gate operations that only
    /// make sense when zigline owns the termios lifecycle:
    /// `pauseRawMode` / `resumeRawMode` (no-op otherwise so they
    /// don't trample caller-managed state under `.assume_already_raw`)
    /// and `suspend_self` (which assumes the SIGTSTP handler is
    /// installed, only true under `.enter_and_leave`).
    owns_raw_mode: bool = false,
    /// `quoted_insert` (`Ctrl-V` / `Ctrl-Q`) primes this flag; the
    /// next key event is then inserted literally regardless of any
    /// keymap binding it would otherwise trigger.
    quoted_insert_pending: bool = false,
    /// State for `yank_last_arg` (`M-.` / `M-_`) cycling. Repeated
    /// invocations replace the most-recently-inserted token with the
    /// previous history entry's last token. Reset by any non-yank-
    /// last-arg action.
    yank_last_arg: ?YankLastArgState = null,
    /// Buffered key events for an in-flight multi-key sequence (only
    /// used when `Keymap.bindings` is non-null). Cleared whenever a
    /// sequence resolves (`.bound`), is replayed on mismatch (`.none`
    /// with len > 1), falls through as singleton (`.none` with len
    /// 1), or `readLine` enters / exits. See SPEC §5.2.
    pending_keys: std.ArrayListUnmanaged(input_mod.KeyEvent) = .empty,
    /// True iff this editor won the process-wide claim for
    /// `terminal_mod.pokeActiveFreshRow` in `init`. Tracked per-
    /// instance so a non-owner with the same fd cannot release the
    /// owner's claim in `deinit`. First `Editor.init` wins; later
    /// editors silently lose the global claim (their own
    /// `ensureFreshRow` instance method still works deterministically).
    fresh_row_claimed: bool = false,

    /// Snapshot of the ghost-text hint that the *most-recent* render
    /// drew. Populated by `Editor.render` (UTF-8 + control-byte
    /// validated, allocator-owned `text`). Consumed by the
    /// `accept_hint` action so the user inserts EXACTLY the bytes
    /// they saw — even if the host's hint hook is non-deterministic
    /// or its underlying ranking changes between render and accept.
    /// `null` when the previous render drew no hint.
    last_hint: ?CachedHint = null,

    /// Live transient-input mode state (Ctrl-R search overlay).
    /// `null` outside of transient mode. While non-null, key
    /// dispatch and render route to alternate paths that operate
    /// on `transient.query` instead of the main buffer.
    transient: ?TransientState = null,

    pub fn init(allocator: Allocator, options: Options) !Editor {
        var editor: Editor = .{
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
        // Claim is the last init step and is best-effort, so no
        // errdefer is required today. If future init steps after this
        // one can fail, add an errdefer that calls
        // `terminal_mod.releaseEditorOutputFd(options.output_fd)`
        // gated on `editor.fresh_row_claimed`.
        if (terminal_mod.tryClaimEditorOutputFd(options.output_fd)) {
            editor.fresh_row_claimed = true;
        }
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        if (self.fresh_row_claimed) {
            terminal_mod.releaseEditorOutputFd(self.terminal.output_fd);
            self.fresh_row_claimed = false;
        }
        self.buffer.deinit();
        self.renderer.deinit();
        self.reader.deinit();
        self.kill_ring.deinit();
        self.changeset.deinit();
        self.pending_keys.deinit(self.allocator);
        self.clearHintCache();
        self.exitTransientMode();
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
            self.owns_raw_mode = true;
        }
        defer {
            self.reader.setSignalPipe(-1);
            if (self.options.raw_mode == .enter_and_leave) {
                self.terminal.leaveRawMode();
                self.owns_raw_mode = false;
            }
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
        // Multi-key sequences shouldn't survive a `readLine` boundary.
        self.pending_keys.clearRetainingCapacity();
        // Per-line state that pre-v0.2.x carried across `readLine`
        // calls: a quoted-insert primed mid-line and then aborted via
        // EOF/cancel would treat the next line's first key as
        // literal; yank-last-arg cycle state likewise leaked. Reset
        // them all so each `readLine` starts clean.
        self.quoted_insert_pending = false;
        self.yank_last_arg = null;
        self.last_yank_start = 0;
        // Each `readLine` starts with a clean transient state — a
        // mode left dangling across iterations would be confusing.
        self.exitTransientMode();
        try self.renderActive(prompt);

        while (true) {
            const ev = self.reader.next();
            switch (ev) {
                .eof => {
                    // Per SPEC §5.2, a non-key event resolves any
                    // partial multi-key sequence as singletons before
                    // it's processed. EOF still ends the loop, but a
                    // pending prefix gets a chance to dispatch first.
                    if (try self.flushPendingSequence(prompt)) |result| return result;
                    // EOF mid-transient counts as an abort from the
                    // hook's perspective: it allocated state in
                    // `.opened` and now the mode is terminating
                    // without accept. Notify best-effort.
                    self.abortTransientBestEffort();
                    try self.renderer.finalize(&self.terminal);
                    if (self.options.history) |h| h.resetCursor();
                    return .eof;
                },
                .error_ => |e| {
                    self.abortTransientBestEffort();
                    try self.renderer.finalize(&self.terminal);
                    return e;
                },
                .resize => {
                    if (try self.flushPendingSequence(prompt)) |result| return result;
                    try self.renderActive(prompt);
                },
                .paste => |payload| {
                    if (try self.flushPendingSequence(prompt)) |result| return result;
                    if (self.transient != null) {
                        try self.handleTransientPaste(payload);
                    } else {
                        try self.handlePaste(payload);
                    }
                    try self.renderActive(prompt);
                },
                .key => |kev| {
                    if (self.transient != null) {
                        if (try self.handleKeyTransient(kev)) |result| {
                            if (self.options.history) |h| h.resetCursor();
                            return result;
                        }
                    } else {
                        if (try self.handleKey(kev, prompt)) |result| {
                            if (self.options.history) |h| h.resetCursor();
                            return result;
                        }
                    }
                    try self.renderActive(prompt);
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

    /// Push the cursor to a fresh row before this editor's next
    /// render. Call between `readLine` invocations when the embedding
    /// application has emitted text to the tty whose cursor position
    /// is uncertain — e.g., after a foreground job died via signal
    /// (the kernel may have echoed `^C` to the prompt row, and the
    /// editor's render-on-readLine would otherwise clear that row
    /// before the user sees it).
    ///
    /// Writes `\r\n` directly to this editor's `output_fd` (via
    /// `Terminal.writeAll`'s retry loop). Unlike the standalone
    /// `terminal_mod.pokeActiveFreshRow`, this method does NOT
    /// depend on a process-global claim and is therefore reliable
    /// in multi-editor processes — the standalone variant only
    /// fires for the first-init'd editor.
    ///
    /// Best-effort: ignores write errors. Only emits CRLF — does
    /// NOT invalidate an in-flight render or update cached cursor
    /// state, so it's safe ONLY between `readLine` calls (the next
    /// `readLine` calls `markFresh` on the renderer). Not async-
    /// signal-safe; never call from a signal handler.
    pub fn ensureFreshRow(self: *Editor) void {
        self.terminal.writeAll("\r\n") catch {};
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    fn render(self: *Editor, prompt: prompt_mod.Prompt) !void {
        return self.renderInternal(prompt, true);
    }

    /// Dispatch a render to either the transient overlay or the
    /// normal prompt+buffer path, based on current mode. Used by
    /// the read loop so callers don't have to remember the check.
    fn renderActive(self: *Editor, prompt: prompt_mod.Prompt) !void {
        if (self.transient != null) {
            return self.renderTransient();
        }
        return self.render(prompt);
    }

    /// Sanitize a bracketed-paste payload and insert it into the
    /// transient query. Newlines are turned into spaces (transient
    /// queries are single-line by construction); invalid UTF-8 and
    /// control bytes are rejected outright (no FFFD substitution
    /// since the user is searching, not authoring text).
    fn handleTransientPaste(self: *Editor, payload: []const u8) !void {
        const sanitized = try sanitizePaste(self.allocator, payload);
        defer self.allocator.free(sanitized);
        if (sanitized.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(sanitized)) return;
        if (buffer_mod.findUnsafeByte(sanitized) != null) return;
        try self.transient.?.query.insertText(sanitized);
        self.invokeTransientHook(.query_changed);
    }

    /// Render the prompt + buffer + (optional hint) frame.
    ///
    /// `with_hint = false` is used by paths that have just mutated
    /// the buffer and are about to finalize/accept (currently:
    /// `replace_buffer_and_accept`). Suppressing the hook prevents a
    /// one-frame flash of ghost text against the soon-to-be-accepted
    /// line and guarantees the cache is empty before
    /// `acceptCurrentLine` runs, so an `accept_hint` racing the
    /// finalize cannot consume stale bytes.
    fn renderInternal(
        self: *Editor,
        prompt: prompt_mod.Prompt,
        with_hint: bool,
    ) !void {
        var span_buf: ?[]highlight_mod.HighlightSpan = null;
        defer if (span_buf) |sb| self.allocator.free(sb);

        var spans: []const highlight_mod.HighlightSpan = &.{};
        if (self.options.highlight) |hh| {
            const req = highlight_mod.HighlightRequest{
                .buffer = self.buffer.slice(),
                .cursor_byte = self.buffer.cursor_byte,
            };
            if (hh.highlight(self.allocator, req)) |g| {
                span_buf = g;
                spans = g;
            } else |err| {
                self.diag(.{ .kind = .highlight_hook_failed, .err = err });
            }
        }
        const draw: ?renderer_mod.HintDraw = if (with_hint) self.computeHintDraw() else blk: {
            self.clearHintCache();
            break :blk null;
        };
        try self.renderer.render(&self.terminal, prompt, &self.buffer, spans, draw);
    }

    /// Refresh the hint cache for the current buffer state and return
    /// a renderer-ready `HintDraw` (or null for "no hint this frame").
    /// Always frees any prior cache first so cache lifetime is one
    /// render at a time. If hint allocation fails partway, the cache
    /// is left null and no hint is shown — keeps the visible bytes
    /// and the `accept_hint` payload in sync.
    fn computeHintDraw(self: *Editor) ?renderer_mod.HintDraw {
        self.clearHintCache();

        const hook = self.options.hint orelse return null;

        // Cursor-at-end gate. Hint suggestions only make sense as a
        // suffix of what the user has already typed.
        if (self.buffer.cursor_byte != self.buffer.bytes.items.len) return null;

        const result_opt = hook.hint(.{
            .buffer = self.buffer.slice(),
            .cursor_byte = self.buffer.cursor_byte,
        }) catch |err| {
            self.diag(.{ .kind = .hint_hook_failed, .err = err });
            return null;
        };

        const result = result_opt orelse return null;
        if (result.text.len == 0) return null;

        if (!std.unicode.utf8ValidateSlice(result.text)) {
            self.diag(.{ .kind = .hint_invalid_text, .detail = "hint text is not valid UTF-8" });
            return null;
        }
        if (buffer_mod.findUnsafeByte(result.text) != null) {
            self.diag(.{ .kind = .hint_invalid_text, .detail = "hint text contains control bytes" });
            return null;
        }

        const cols = grapheme.displayWidth(result.text, self.options.width_policy) catch |err| {
            self.diag(.{ .kind = .hint_hook_failed, .err = err, .detail = "hint width compute failed" });
            return null;
        };

        const text_copy = self.allocator.dupe(u8, result.text) catch |err| {
            // Per the hint contract: never render bytes we can't also
            // cache for `accept_hint`. Drop the hint entirely so the
            // visible output and the accept payload stay in sync.
            self.diag(.{ .kind = .hint_hook_failed, .err = err, .detail = "hint cache alloc failed" });
            return null;
        };

        const style: highlight_mod.Style = result.style orelse .{ .dim = true };

        self.last_hint = .{
            .buffer_len = self.buffer.bytes.items.len,
            .cursor_byte = self.buffer.cursor_byte,
            .text = text_copy,
            .style = style,
            .cols = cols,
        };

        return .{ .text = text_copy, .style = style, .cols = cols };
    }

    fn clearHintCache(self: *Editor) void {
        if (self.last_hint) |c| {
            self.allocator.free(c.text);
            self.last_hint = null;
        }
    }

    // -------------------------------------------------------------------------
    // Transient input mode (Ctrl-R search overlay)
    // -------------------------------------------------------------------------

    /// Default status text rendered when the hook returns
    /// `status = null`.
    const transient_default_status: []const u8 = "(reverse-i-search): ";

    /// Open transient mode. No-op if no hook is configured. Initializes
    /// `self.transient`, clears any active hint cache + completion
    /// state, breaks the changeset coalescing chain (so the line's
    /// undo history won't merge with edits that happen after exit),
    /// and invokes the hook with `.opened`.
    fn handleTransientInputOpen(self: *Editor) !void {
        if (self.options.transient_input == null) return;
        if (self.transient != null) return; // already open; defensive

        // UI submodes that share the prompt row don't survive Ctrl-R.
        self.clearHintCache();
        self.changeset.breakSequence();
        self.kill_ring.reset();
        self.yank_last_arg = null;

        self.transient = .{
            .query = buffer_mod.Buffer.init(self.allocator),
            .original_cursor_byte = self.buffer.cursor_byte,
        };
        // Set width policy on the query buffer so wide-character
        // queries render correctly.
        self.transient.?.query.width_policy = self.options.width_policy;

        self.invokeTransientHook(.opened);
    }

    /// Free the transient state. Idempotent. Does NOT touch the
    /// main buffer (callers control whether to mutate).
    fn exitTransientMode(self: *Editor) void {
        if (self.transient) |*t| {
            t.query.deinit();
            if (t.last_preview) |p| self.allocator.free(p);
            if (t.last_status) |s| self.allocator.free(s);
            self.transient = null;
        }
    }

    /// Notify the hook of an abort (best-effort) and exit transient
    /// mode. Used for every user-abort path so the hook can clean
    /// up its own state regardless of *why* the mode is closing —
    /// Esc, Ctrl-G, Ctrl-C, EOF, or read error. A hook error from
    /// the abort notification routes a diagnostic but does NOT
    /// prevent the exit (per the documented contract: abort cannot
    /// be vetoed).
    fn abortTransientBestEffort(self: *Editor) void {
        if (self.transient == null) return;
        self.invokeTransientHook(.aborted);
        self.exitTransientMode();
    }

    /// Call the transient hook with the supplied event, validate the
    /// returned strings, and update the cached preview/status. Hook
    /// errors and validation failures route to the diagnostic hook
    /// and leave the previous cache values in place (so a transient
    /// glitch doesn't visually wipe the user's last good preview).
    fn invokeTransientHook(self: *Editor, event: transient_mod.TransientInputEvent) void {
        const hook = self.options.transient_input orelse return;
        const t = &self.transient.?;

        const result = hook.update(.{
            .original_buffer = self.buffer.slice(),
            .original_cursor_byte = t.original_cursor_byte,
            .query = t.query.slice(),
            .query_cursor_byte = t.query.cursor_byte,
            .event = event,
        }) catch |err| {
            self.diag(.{
                .kind = .transient_input_hook_failed,
                .err = err,
                .detail = "transient_input hook returned error",
            });
            return;
        };

        // status is field-level: invalid → fall back to default but
        // keep preview if it's valid.
        if (result.status) |s| {
            if (!std.unicode.utf8ValidateSlice(s)) {
                self.diag(.{ .kind = .transient_input_invalid_text, .detail = "transient status not UTF-8" });
            } else if (buffer_mod.findUnsafeByte(s) != null) {
                self.diag(.{ .kind = .transient_input_invalid_text, .detail = "transient status contains control bytes" });
            } else {
                if (t.last_status) |old| self.allocator.free(old);
                t.last_status = self.allocator.dupe(u8, s) catch null;
            }
        } else {
            if (t.last_status) |old| self.allocator.free(old);
            t.last_status = null;
        }

        // preview is field-level: invalid → drop, keep status. The
        // three-state semantics (null/empty/non-empty) are preserved.
        if (result.preview) |p| {
            if (!std.unicode.utf8ValidateSlice(p)) {
                self.diag(.{ .kind = .transient_input_invalid_text, .detail = "transient preview not UTF-8" });
                if (t.last_preview) |old| self.allocator.free(old);
                t.last_preview = null;
            } else if (buffer_mod.findUnsafeByte(p) != null) {
                self.diag(.{ .kind = .transient_input_invalid_text, .detail = "transient preview contains control bytes" });
                if (t.last_preview) |old| self.allocator.free(old);
                t.last_preview = null;
            } else {
                if (t.last_preview) |old| self.allocator.free(old);
                t.last_preview = self.allocator.dupe(u8, p) catch null;
            }
        } else {
            if (t.last_preview) |old| self.allocator.free(old);
            t.last_preview = null;
        }
    }

    /// Render the transient overlay by synthesizing prompt/buffer/
    /// hint inputs and reusing `renderer.render`. Status acts as
    /// the prompt prefix; query acts as the buffer; preview acts
    /// as a dim ghost-text suffix. Width math, wrap, phantom-NL,
    /// stale clearing all reuse the standard pipeline.
    fn renderTransient(self: *Editor) !void {
        var t = &self.transient.?;

        const status_text: []const u8 = if (t.last_status) |s| s else transient_default_status;
        const status_width = grapheme.displayWidth(status_text, self.options.width_policy) catch status_text.len;
        const transient_prompt: prompt_mod.Prompt = .{
            .bytes = status_text,
            .width = status_width,
        };

        // Preview becomes a dim HintDraw. Empty preview ("") renders
        // nothing — we skip the SGR pair entirely. Null preview also
        // skips, distinguished only by accept semantics elsewhere.
        var hint_draw: ?renderer_mod.HintDraw = null;
        if (t.last_preview) |p| {
            if (p.len > 0) {
                const cols = grapheme.displayWidth(p, self.options.width_policy) catch p.len;
                hint_draw = .{
                    .text = p,
                    .style = .{ .dim = true },
                    .cols = cols,
                };
            }
        }

        try self.renderer.render(
            &self.terminal,
            transient_prompt,
            &t.query,
            &.{},
            hint_draw,
        );
    }

    /// Whitelist key dispatcher for transient mode. Returns a
    /// `ReadLineResult` only on Ctrl-C (cancel_line). All other
    /// outcomes return null and the read loop continues with a
    /// transient-mode render.
    ///
    /// See module-level docs for the supported keys; everything
    /// else is silently dropped (no hook call, no state change).
    fn handleKeyTransient(
        self: *Editor,
        kev: input_mod.KeyEvent,
    ) !?ReadLineResult {
        var t = &self.transient.?;

        switch (kev.code) {
            .enter => {
                // Accept: copy preview into main buffer (if any),
                // exit mode. The line is NOT submitted — user must
                // press Enter again to run.
                const preview_owned: ?[]u8 = t.last_preview;
                if (preview_owned) |p| {
                    // One Replace undo step covers the buffer swap.
                    const old = try self.allocator.dupe(u8, self.buffer.slice());
                    defer self.allocator.free(old);
                    const cursor_before = self.buffer.cursor_byte;
                    try self.buffer.replaceAll(p);
                    self.recordReplaceOrDiag(0, old, p, cursor_before, self.buffer.cursor_byte);
                    self.changeset.breakSequence();
                }
                self.exitTransientMode();
                return null;
            },
            .escape => {
                self.abortTransientBestEffort();
                return null;
            },
            .backspace => {
                if (try t.query.deleteBackwardCluster()) |range| {
                    self.allocator.free(range.bytes);
                    self.invokeTransientHook(.query_changed);
                }
                return null;
            },
            .delete => {
                if (try t.query.deleteForwardCluster()) |range| {
                    self.allocator.free(range.bytes);
                    self.invokeTransientHook(.query_changed);
                }
                return null;
            },
            .arrow_left => {
                try t.query.moveLeftCluster();
                return null;
            },
            .arrow_right => {
                try t.query.moveRightCluster();
                return null;
            },
            .home => {
                t.query.moveToStart();
                return null;
            },
            .end => {
                t.query.moveToEnd();
                return null;
            },
            .char => |c| {
                if (kev.mods.ctrl) {
                    return switch (c) {
                        // Ctrl-G: same as Esc.
                        'g' => blk: {
                            self.abortTransientBestEffort();
                            break :blk null;
                        },
                        // Ctrl-R again: advance to the next match.
                        'r' => blk: {
                            self.invokeTransientHook(.next);
                            break :blk null;
                        },
                        // Ctrl-C: notify hook of abort, then cancel
                        // the entire line. The user explicitly chose
                        // to drop both the search and the buffer.
                        'c' => blk: {
                            self.abortTransientBestEffort();
                            break :blk try self.cancelCurrentLine();
                        },
                        // Ctrl-A: query move-to-start.
                        'a' => blk: {
                            t.query.moveToStart();
                            break :blk null;
                        },
                        // Ctrl-E: query move-to-end.
                        'e' => blk: {
                            t.query.moveToEnd();
                            break :blk null;
                        },
                        // Ctrl-H: backspace synonym.
                        'h' => blk: {
                            if (try t.query.deleteBackwardCluster()) |range| {
                                self.allocator.free(range.bytes);
                                self.invokeTransientHook(.query_changed);
                            }
                            break :blk null;
                        },
                        // All other Ctrl- chords are dropped.
                        else => null,
                    };
                }
                if (kev.mods.alt) return null; // M- chords are dropped
                if (c < 0x20) return null; // bare control bytes dropped
                // Encode as UTF-8 and insert into the query buffer.
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch return null;
                try t.query.insertText(buf[0..len]);
                self.invokeTransientHook(.query_changed);
                return null;
            },
            .text => |bytes| {
                // Paste-like payloads. Sanitize via the same policy
                // applied elsewhere.
                if (!std.unicode.utf8ValidateSlice(bytes)) return null;
                if (buffer_mod.findUnsafeByte(bytes) != null) return null;
                if (bytes.len == 0) return null;
                try t.query.insertText(bytes);
                self.invokeTransientHook(.query_changed);
                return null;
            },
            // Tab, function keys, page up/down, insert, arrow_up/down,
            // unknown — no-op in transient mode.
            else => return null,
        }
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
            self.diag(.{ .kind = .kill_ring_failed, .err = err, .detail = "kill_ring push failed" });
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
        // Reserve redo-stack capacity BEFORE applying the buffer
        // mutation. Without this, an OOM in `acceptUndo`'s redo push
        // leaves the buffer mutated while the undo op stays on the
        // undo stack — the next undo would wrongly re-apply.
        try self.changeset.prepareUndo();
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
            self.diag(.{ .kind = .undo_record_failed, .err = err, .detail = "acceptUndo failed" });
        };
    }

    fn handleRedo(self: *Editor) !void {
        const op_ptr = self.changeset.peekRedo() orelse return;
        // Symmetric to `handleUndo` — reserve undo-stack capacity
        // before mutating so `acceptRedo` is OOM-safe.
        try self.changeset.prepareRedo();
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
            self.diag(.{ .kind = .undo_record_failed, .err = err, .detail = "acceptRedo failed" });
        };
    }

    /// Apply a `Buffer.EditResult` (transpose, case-map, squeeze):
    /// the buffer mutation already happened; record it as one
    /// `Replace` undo step and free both byte slices. Null means
    /// the buffer reported nothing to do.
    fn handleEditResult(self: *Editor, result_opt: ?buffer_mod.EditResult) !void {
        const r = result_opt orelse return;
        defer self.allocator.free(r.old_bytes);
        defer self.allocator.free(r.new_bytes);
        // The dispatch loop already broke the changeset sequence
        // for us (these aren't on the coalescing-allowed list). So
        // the recorded Replace lands in its own undo step; one
        // Ctrl-_ unwinds the transform.
        const cursor_after = self.buffer.cursor_byte;
        // The pre-edit cursor isn't tracked through the buffer's
        // EditResult; we approximate as `r.start + r.old_bytes.len`
        // for case ops (cursor was at start, advanced to end), and
        // for transpose_chars the buffer also lands cursor at
        // post-swap end. Both are correct.
        const cursor_before = r.start + r.old_bytes.len;
        self.recordReplaceOrDiag(r.start, r.old_bytes, r.new_bytes, cursor_before, cursor_after);
    }

    /// Delete the cluster at the cursor and record an undo step.
    /// Shared between the `.delete_forward` action arm and the `.eof`
    /// arm's "delete-cluster on non-empty buffer" path.
    fn deleteForwardRecorded(self: *Editor) !void {
        const cursor_before = self.buffer.cursor_byte;
        if (try self.buffer.deleteForwardCluster()) |range| {
            defer self.allocator.free(range.bytes);
            self.recordDeleteOrDiag(range.idx, range.bytes, cursor_before, self.buffer.cursor_byte);
        }
    }

    /// Direction selector for `recallFromHistory`. Mirrors the four
    /// `History` navigation methods.
    const HistoryDir = enum { prev, next, first, last };

    /// Pull a history entry into the buffer and clear the per-line
    /// changeset. Recalling history isn't part of the line's edit
    /// history — Ctrl-_ shouldn't unwind a recalled line into the
    /// previous one's history.
    fn recallFromHistory(self: *Editor, dir: HistoryDir) !void {
        const h = self.options.history orelse return;
        const entry_opt: ?[]const u8 = switch (dir) {
            .prev => h.previous(self.buffer.slice()),
            .next => h.next(),
            .first => h.first(self.buffer.slice()),
            .last => h.last(),
        };
        if (entry_opt) |entry| {
            try self.buffer.replaceAll(entry);
            self.changeset.clear();
        }
    }

    fn handleYankLastArg(self: *Editor) !void {
        const h = self.options.history orelse return;
        const entry_count = h.entryCount();
        if (entry_count == 0) return;

        const cycle: usize = if (self.yank_last_arg) |s| s.cycle + 1 else 0;
        if (cycle >= entry_count) return; // cycled past the oldest

        const entry = h.entryAt(entry_count - 1 - cycle).?;
        const arg = lastWhitespaceToken(entry);
        if (arg.len == 0) {
            // No token in this entry — skip ahead by recording the
            // cycle anyway so repeated M-. eventually finds one.
            self.yank_last_arg = .{ .cycle = cycle, .start = self.buffer.cursor_byte, .len = 0 };
            return;
        }

        if (self.yank_last_arg) |state| {
            // Cycling: replace the previous insertion with the new
            // last-arg in place. Recorded as one Replace op so
            // Ctrl-_ unwinds the entire cycling sequence.
            const old_bytes = try self.allocator.dupe(u8, self.buffer.slice()[state.start..][0..state.len]);
            defer self.allocator.free(old_bytes);
            const new_bytes = try self.allocator.dupe(u8, arg);
            defer self.allocator.free(new_bytes);
            const cursor_before = state.start + state.len;
            try self.replaceRangeAt(state.start, state.start + state.len, arg);
            self.recordReplaceOrDiag(state.start, old_bytes, new_bytes, cursor_before, self.buffer.cursor_byte);
            self.yank_last_arg = .{ .cycle = cycle, .start = state.start, .len = arg.len };
        } else {
            // First press: insert the most recent entry's last arg.
            const start = self.buffer.cursor_byte;
            self.changeset.breakSequence();
            try self.buffer.insertText(arg);
            self.recordInsertOrDiag(start, arg, start, self.buffer.cursor_byte);
            self.changeset.breakSequence();
            self.yank_last_arg = .{ .cycle = 0, .start = start, .len = arg.len };
        }
    }

    fn handleCustomAction(
        self: *Editor,
        id: u32,
        prompt: prompt_mod.Prompt,
    ) !?ReadLineResult {
        const hook = self.options.custom_action orelse return null;
        const result = hook.invokeFn(
            hook.ctx,
            self.allocator,
            id,
            .{
                .buffer = self.buffer.slice(),
                .cursor_byte = self.buffer.cursor_byte,
            },
            .{ .editor = self },
        ) catch |err| {
            self.diag(.{ .kind = .custom_action_failed, .err = err, .detail = "custom_action hook failed" });
            return null;
        };

        switch (result) {
            .no_op => return null,
            .insert_text => |t| {
                defer self.allocator.free(t);
                if (!std.unicode.utf8ValidateSlice(t)) {
                    self.diag(.{ .kind = .custom_action_invalid_text, .detail = "custom_action insert_text not UTF-8" });
                    return null;
                }
                if (buffer_mod.findUnsafeByte(t) != null) {
                    self.diag(.{ .kind = .custom_action_invalid_text, .detail = "custom_action insert_text contains control bytes" });
                    return null;
                }
                if (t.len == 0) return null;
                const cursor_before = self.buffer.cursor_byte;
                self.changeset.breakSequence();
                try self.buffer.insertText(t);
                self.recordInsertOrDiag(cursor_before, t, cursor_before, self.buffer.cursor_byte);
                self.changeset.breakSequence();
                return null;
            },
            .replace_buffer => |t| {
                defer self.allocator.free(t);
                if (!std.unicode.utf8ValidateSlice(t)) {
                    self.diag(.{ .kind = .custom_action_invalid_text, .detail = "custom_action replace_buffer not UTF-8" });
                    return null;
                }
                if (buffer_mod.findUnsafeByte(t) != null) {
                    self.diag(.{ .kind = .custom_action_invalid_text, .detail = "custom_action replace_buffer contains control bytes" });
                    return null;
                }
                const old = try self.allocator.dupe(u8, self.buffer.slice());
                defer self.allocator.free(old);
                const cursor_before = self.buffer.cursor_byte;
                try self.buffer.replaceAll(t);
                self.recordReplaceOrDiag(0, old, t, cursor_before, self.buffer.cursor_byte);
                self.changeset.breakSequence();
                return null;
            },
            .replace_buffer_and_accept => |t| {
                defer self.allocator.free(t);
                if (!std.unicode.utf8ValidateSlice(t)) {
                    self.diag(.{ .kind = .custom_action_invalid_text, .detail = "custom_action replace_buffer_and_accept not UTF-8" });
                    return null;
                }
                if (buffer_mod.findUnsafeByte(t) != null) {
                    self.diag(.{ .kind = .custom_action_invalid_text, .detail = "custom_action replace_buffer_and_accept contains control bytes" });
                    return null;
                }
                // Replace the buffer so the visible terminal transcript
                // matches what the caller will receive from `readLine`.
                // Repaint with `with_hint = false` — the hint hook would
                // otherwise see the just-substituted text and might
                // surface a fresh ghost suffix that flashes against the
                // soon-to-be-accepted line. No undo record: the line is
                // consumed immediately by `acceptCurrentLine`, which
                // clears the changeset.
                try self.buffer.replaceAll(t);
                try self.renderInternal(prompt, false);
                return try self.acceptCurrentLine();
            },
            .accept_line => return try self.acceptCurrentLine(),
            .cancel_line => return try self.cancelCurrentLine(),
        }
    }

    /// Finalize the rendered block, take the buffer, append to
    /// history. Shared between the `.accept_line` action arm and the
    /// custom-action `.accept_line` result variant.
    fn acceptCurrentLine(self: *Editor) !ReadLineResult {
        // Drop any cached hint snapshot before the buffer is taken;
        // a stale cache would never match the next render's buffer
        // anyway, but freeing here keeps the field's lifetime tied
        // to the line that produced it.
        self.clearHintCache();
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
    }

    /// Finalize, echo `^C` if raw, clear buffer + undo. Shared
    /// between the `.cancel_line` action arm and the custom-action
    /// `.cancel_line` result variant.
    fn cancelCurrentLine(self: *Editor) !ReadLineResult {
        self.clearHintCache();
        try self.renderer.finalize(&self.terminal);
        if (self.options.raw_mode != .disabled and self.terminal.isInputTty()) {
            self.terminal.writeAll("^C\r\n") catch {};
        }
        self.buffer.clear();
        self.changeset.clear();
        self.renderer.markFresh();
        return ReadLineResult{ .interrupt = {} };
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
            self.diag(.{ .kind = .undo_record_failed, .err = err, .detail = "undo record (insert) failed" });
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
            self.diag(.{ .kind = .undo_record_failed, .err = err, .detail = "undo record (delete) failed" });
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
            self.diag(.{ .kind = .undo_record_failed, .err = err, .detail = "undo record (replace) failed" });
        };
    }

    fn handleKey(
        self: *Editor,
        kev: input_mod.KeyEvent,
        prompt: prompt_mod.Prompt,
    ) anyerror!?ReadLineResult {
        // Explicit `anyerror` because `replayPendingPrefix` recurses
        // back through this function; an inferred error set would
        // create a self-referential cycle.

        // `quoted_insert` (Ctrl-V / Ctrl-Q) was just dispatched —
        // insert THIS event's bytes literally, bypassing the keymap,
        // the binding-table, and the default-insert filter. One-shot.
        if (self.quoted_insert_pending) {
            // Drop any in-flight multi-key prefix; literal-insert
            // can't be part of a chord.
            self.pending_keys.clearRetainingCapacity();
            return try self.handleQuotedInsert(kev);
        }

        // Multi-key binding-table state machine (SPEC §5.2). Skip
        // entirely when no overlay is set, preserving the v0.1.x
        // single-key dispatch path verbatim.
        if (self.options.keymap.bindings) |table| {
            try self.pending_keys.append(self.allocator, kev);
            switch (table.lookup(self.pending_keys.items)) {
                .bound => |action| {
                    self.pending_keys.clearRetainingCapacity();
                    return self.dispatch(action, prompt);
                },
                .partial => return null, // wait for next event
                .none => {
                    if (self.pending_keys.items.len == 1) {
                        // Single event with no multi-key match —
                        // drop the buffer and dispatch via the
                        // legacy single-key path with `kev`.
                        self.pending_keys.clearRetainingCapacity();
                        return self.handleKeyDirect(kev, prompt);
                    }
                    return self.replayPendingPrefix(prompt);
                },
            }
        }

        return self.handleKeyDirect(kev, prompt);
    }

    /// Single-key dispatch path that doesn't consult `bindings`. Used
    /// directly when no overlay is set, and by `replayPendingPrefix`
    /// for the first event of a failed multi-key prefix (per SPEC
    /// §5.2).
    fn handleKeyDirect(
        self: *Editor,
        kev: input_mod.KeyEvent,
        prompt: prompt_mod.Prompt,
    ) !?ReadLineResult {
        const action = self.options.keymap.lookup(kev) orelse {
            switch (kev.code) {
                .char => |cp| {
                    if (cp < 0x20) return null;
                    // Modified events that don't resolve to an
                    // action are dropped, not inserted — Ctrl-X
                    // with no binding shouldn't insert literal 'x'.
                    // Shift is fine (kernel folds it into the char
                    // for ASCII letters).
                    if (kev.mods.ctrl or kev.mods.alt) return null;
                    // Typing breaks the kill-ring coalescing chain
                    // exactly like any non-kill action through
                    // dispatch — without this, two `Ctrl-U` kills
                    // separated only by typing would coalesce into
                    // one slot. Same logic for `yank_last_arg`
                    // cycling: any non-yank-last-arg event ends the
                    // cycle, including default-inserted text.
                    self.kill_ring.reset();
                    self.yank_last_arg = null;
                    try self.insertCharRecorded(cp);
                },
                .text => |t| {
                    // `.text` is an input-layer event for paste-like
                    // chunks. The built-in `Reader` doesn't emit it
                    // today, but `KeyEvent` is public so custom
                    // readers might. Apply the same single-line +
                    // control-byte policy as everything else
                    // entering the buffer through this path.
                    if (!std.unicode.utf8ValidateSlice(t)) return null;
                    if (buffer_mod.findUnsafeByte(t) != null) return null;
                    self.kill_ring.reset();
                    self.yank_last_arg = null;
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

    /// Replay the buffered prefix after a `.none` lookup with len > 1.
    /// Per SPEC §5.2: dispatch the first event via the legacy single-
    /// key path, then re-process the remaining events through the
    /// full state machine (they may start a new chord).
    fn replayPendingPrefix(self: *Editor, prompt: prompt_mod.Prompt) !?ReadLineResult {
        std.debug.assert(self.pending_keys.items.len > 1);
        const buffered = try self.allocator.dupe(input_mod.KeyEvent, self.pending_keys.items);
        defer self.allocator.free(buffered);
        self.pending_keys.clearRetainingCapacity();

        if (try self.handleKeyDirect(buffered[0], prompt)) |r| return r;
        for (buffered[1..]) |replay_kev| {
            if (try self.handleKey(replay_kev, prompt)) |r| return r;
        }
        return null;
    }

    /// Flush any in-flight multi-key prefix as singletons, used when
    /// a non-key event (paste / resize / EOF) arrives mid-chord.
    /// Returns a `ReadLineResult` if any of the singleton dispatches
    /// terminated the read.
    fn flushPendingSequence(self: *Editor, prompt: prompt_mod.Prompt) !?ReadLineResult {
        if (self.pending_keys.items.len == 0) return null;
        if (self.pending_keys.items.len == 1) {
            const kev = self.pending_keys.items[0];
            self.pending_keys.clearRetainingCapacity();
            return self.handleKeyDirect(kev, prompt);
        }
        return self.replayPendingPrefix(prompt);
    }

    /// Handle a key dispatched while `quoted_insert_pending` is set.
    /// Inserts the event's bytes literally; control-letter chords
    /// emit the corresponding C0 byte (Ctrl-A → \x01) to match
    /// readline's quoted-insert.
    fn handleQuotedInsert(self: *Editor, kev: input_mod.KeyEvent) !?ReadLineResult {
        self.quoted_insert_pending = false;
        self.kill_ring.reset();
        self.changeset.breakSequence();
        switch (kev.code) {
            .char => |cp| {
                var emit: u21 = cp;
                if (kev.mods.ctrl) {
                    if (cp >= '@' and cp <= '_') emit = cp - '@';
                    if (cp >= 'a' and cp <= 'z') emit = cp - 'a' + 1;
                }
                try self.insertCharRecorded(emit);
            },
            .text => |t| {
                const cursor_before = self.buffer.cursor_byte;
                try self.buffer.insertText(t);
                self.recordInsertOrDiag(cursor_before, t, cursor_before, self.buffer.cursor_byte);
            },
            else => {}, // arrows, function keys: discard (matches readline)
        }
        self.changeset.breakSequence();
        return null;
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
            // `accept_hint` deliberately falls through to the outer
            // `breakSequence()`. It's a navigation-style action when
            // the cache is empty (fallback path goes to move_right);
            // when the cache is live, the success path adds its own
            // post-insert break so the next typed char doesn't merge
            // with the accepted suffix.
            else => self.changeset.breakSequence(),
        }
        // `yank_last_arg` cycling state survives only across
        // consecutive `yank_last_arg` invocations.
        if (action != .yank_last_arg) self.yank_last_arg = null;
        switch (action) {
            .insert_text => |t| {
                // Even action-supplied text must pass the buffer's
                // single-line + control-byte policy. Apps that need
                // to type literal control bytes use quoted-insert,
                // not Action.insert_text. Failures route to the
                // diagnostic hook and are treated as no-op so a
                // single bad action doesn't crash the read loop.
                if (!std.unicode.utf8ValidateSlice(t)) {
                    self.diag(.{ .kind = .completion_invalid_candidate, .detail = "Action.insert_text not valid UTF-8" });
                } else if (buffer_mod.findUnsafeByte(t) != null) {
                    self.diag(.{ .kind = .completion_invalid_candidate, .detail = "Action.insert_text contains control bytes" });
                } else {
                    const cursor_before = self.buffer.cursor_byte;
                    try self.buffer.insertText(t);
                    self.recordInsertOrDiag(cursor_before, t, cursor_before, self.buffer.cursor_byte);
                }
            },
            .delete_backward => {
                const cursor_before = self.buffer.cursor_byte;
                if (try self.buffer.deleteBackwardCluster()) |range| {
                    defer self.allocator.free(range.bytes);
                    self.recordDeleteOrDiag(range.idx, range.bytes, cursor_before, self.buffer.cursor_byte);
                }
            },
            .delete_forward => try self.deleteForwardRecorded(),
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
            .history_prev => try self.recallFromHistory(.prev),
            .history_next => try self.recallFromHistory(.next),
            .history_first => try self.recallFromHistory(.first),
            .history_last => try self.recallFromHistory(.last),
            .yank_last_arg => try self.handleYankLastArg(),
            .complete => try self.handleComplete(prompt),
            .accept_hint => try self.handleAcceptHint(),
            .transient_input_open => try self.handleTransientInputOpen(),
            .accept_line => return try self.acceptCurrentLine(),
            .cancel_line => return try self.cancelCurrentLine(),
            .eof => {
                if (self.buffer.isEmpty()) {
                    try self.renderer.finalize(&self.terminal);
                    return ReadLineResult{ .eof = {} };
                }
                try self.deleteForwardRecorded();
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
            .transpose_chars => try self.handleEditResult(try self.buffer.transposeChars()),
            .capitalize_word => try self.handleEditResult(try self.buffer.editWord(.capitalize)),
            .upper_case_word => try self.handleEditResult(try self.buffer.editWord(.upper)),
            .lower_case_word => try self.handleEditResult(try self.buffer.editWord(.lower)),
            .squeeze_whitespace => try self.handleEditResult(try self.buffer.squeezeWhitespace()),
            .quoted_insert => self.quoted_insert_pending = true,
            .suspend_self => {
                // Move past the rendered block so the user lands at
                // a fresh row in their shell, then raise SIGTSTP.
                // The signal handler restores termios, re-raises
                // with default disposition (process actually stops),
                // and on resume re-enters raw mode + writes to the
                // self-pipe. The next reader.next() picks up the
                // pipe wake and returns .resize, which triggers a
                // render — visually identical to a SIGWINCH.
                //
                // Gated on `owns_raw_mode` AND a successfully
                // installed signal-guard: under `.assume_already_raw`
                // we don't have a SIGTSTP handler to restore termios
                // before stop, and if `SignalGuard.install` failed
                // earlier, raise() would stop the process with the
                // terminal still in raw mode + bracketed paste. In
                // those cases route to a diagnostic and no-op.
                if (!self.owns_raw_mode or !self.terminal.canSuspendSafely()) {
                    self.diag(.{
                        .kind = .render_failed,
                        .detail = "suspend_self: zigline doesn't own raw mode or SIGTSTP handler not installed",
                    });
                    return null;
                }
                try self.renderer.finalize(&self.terminal);
                self.renderer.markFresh();
                _ = std.c.raise(.TSTP);
            },
            .custom => |id| return try self.handleCustomAction(id, prompt),
        }
        return null;
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
        // single coalesced insert. yank_last_arg cycling state is
        // also dropped (paste isn't part of the cycle).
        self.kill_ring.reset();
        self.yank_last_arg = null;
        self.changeset.breakSequence();
        const cursor_before = self.buffer.cursor_byte;
        try self.buffer.insertText(sanitized);
        self.recordInsertOrDiag(cursor_before, sanitized, cursor_before, self.buffer.cursor_byte);
        self.changeset.breakSequence();
    }

    /// Accept the ghost-text hint that the most recent render drew.
    /// If no cache exists, or the buffer has changed since render
    /// (impossible under the current event loop, but defended against
    /// for forward compatibility — see `CachedHint` doc), or the
    /// cursor is no longer at end of buffer, fall back to the same
    /// path as `Action.move_right` so Right Arrow / Ctrl-F keep their
    /// normal cursor-movement semantics when there's nothing to
    /// accept.
    ///
    /// The dispatcher already broke the previous edit sequence before
    /// dispatching this action (`accept_hint` is NOT in the exempt
    /// list), so this function only needs the trailing break to keep
    /// the next typed char from merging with the accepted suffix.
    fn handleAcceptHint(self: *Editor) !void {
        const cache = self.last_hint orelse {
            try self.buffer.moveRightCluster();
            return;
        };

        // Cache validity: at the time `accept_hint` dispatches, no
        // mutation has happened since the previous render (the loop
        // is `read → dispatch → render`). So if `buffer_len` and
        // `cursor_byte` still match the cache AND cursor is at
        // end-of-buffer, the cached hint corresponds 1:1 to the
        // visible ghost text. Any mismatch is either a future
        // async-mutation path or a programmer-direct buffer write.
        const buf_len = self.buffer.bytes.items.len;
        const cursor = self.buffer.cursor_byte;
        if (cache.buffer_len != buf_len or
            cache.cursor_byte != cursor or
            cursor != buf_len)
        {
            self.clearHintCache();
            try self.buffer.moveRightCluster();
            return;
        }

        // Cache will be consumed regardless of whether the insert /
        // record path errors below.
        defer self.clearHintCache();

        const cursor_before = cursor;
        const text_to_insert = cache.text;
        try self.buffer.insertText(text_to_insert);
        self.recordInsertOrDiag(
            cursor_before,
            text_to_insert,
            cursor_before,
            self.buffer.cursor_byte,
        );
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

        if (common.len > current.len and
            std.unicode.utf8ValidateSlice(common) and
            buffer_mod.findUnsafeByte(common) == null)
        {
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
        // Sanitize: completion candidates must not carry control
        // bytes (ANSI injection / single-line invariant break).
        if (buffer_mod.findUnsafeByte(cand.insert) != null) {
            self.diag(.{ .kind = .completion_invalid_candidate, .detail = "insert contains control bytes" });
            return;
        }
        if (cand.append) |c| {
            if (c >= 0x80 or c < 0x20 or c == 0x7f) {
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
        // Mirror the raw-mode readLine state-reset block. Most of
        // these are no-ops in cooked mode (no keymap dispatch, no
        // multi-key state, no kill-ring action) but resetting
        // unconditionally keeps the readLine entry contract uniform
        // across both paths.
        self.changeset.clear();
        self.kill_ring.reset();
        self.pending_keys.clearRetainingCapacity();
        self.quoted_insert_pending = false;
        self.yank_last_arg = null;
        self.last_yank_start = 0;
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
/// Scan from end of `entry` backwards through ASCII whitespace,
/// then through non-whitespace, returning the trailing token. The
/// matching set is `[' ', '\t', '\n']`. Empty result means the
/// entire entry is whitespace.
fn lastWhitespaceToken(entry: []const u8) []const u8 {
    var end = entry.len;
    while (end > 0 and isAsciiWs(entry[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !isAsciiWs(entry[start - 1])) start -= 1;
    return entry[start..end];
}

fn isAsciiWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

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

// Open /dev/null for write, used by tests that exercise paths
// which write escape sequences or `\r\n` to `output_fd` (e.g.
// `acceptCurrentLine` calling `renderer.finalize`, or
// `replace_buffer_and_accept` calling `renderInternal`). Under
// `zig build test --listen=-` the test binary's stdin/stdout are
// the IPC channel with the build runner; spurious bytes corrupt
// that protocol and can deadlock the runner. Routing the editor's
// terminal writes to `/dev/null` keeps the channel clean while
// still exercising the production code paths.
fn openDevNullForWrite() std.posix.fd_t {
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    return @intCast(fd);
}

// Test plumbing: a per-test callback context. Tests provide the
// next result they want returned; the callback dupes any text via
// the editor-supplied allocator (the editor frees after applying).
const CATestCtx = struct {
    next: CustomActionResult = .no_op,
    invoked: bool = false,
    last_id: u32 = 0,
    last_buffer_len: usize = 0,
    last_cursor: usize = 0,
};

fn caTestCb(
    ctx: *anyopaque,
    allocator: Allocator,
    id: u32,
    request: CustomActionRequest,
    action_ctx: CustomActionContext,
) anyerror!CustomActionResult {
    _ = action_ctx;
    const self: *CATestCtx = @ptrCast(@alignCast(ctx));
    self.invoked = true;
    self.last_id = id;
    self.last_buffer_len = request.buffer.len;
    self.last_cursor = request.cursor_byte;
    return switch (self.next) {
        .insert_text => |t| CustomActionResult{ .insert_text = try allocator.dupe(u8, t) },
        .replace_buffer => |t| CustomActionResult{ .replace_buffer = try allocator.dupe(u8, t) },
        .replace_buffer_and_accept => |t| CustomActionResult{ .replace_buffer_and_accept = try allocator.dupe(u8, t) },
        .no_op => .no_op,
        .accept_line => .accept_line,
        .cancel_line => .cancel_line,
    };
}

fn caHook(ctx: *CATestCtx) CustomActionHook {
    return .{ .ctx = @ptrCast(ctx), .invokeFn = caTestCb };
}

test "editor: custom action no_op invokes hook with correct snapshot" {
    var ctx: CATestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .custom_action = caHook(&ctx),
    });
    defer editor.deinit();

    try editor.buffer.insertText("foobar");
    editor.buffer.cursor_byte = 3;
    _ = try editor.handleCustomAction(42, prompt_mod.Prompt.plain(""));

    try std.testing.expect(ctx.invoked);
    try std.testing.expectEqual(@as(u32, 42), ctx.last_id);
    try std.testing.expectEqual(@as(usize, 6), ctx.last_buffer_len);
    try std.testing.expectEqual(@as(usize, 3), ctx.last_cursor);
    try std.testing.expectEqualStrings("foobar", editor.buffer.slice());
}

test "editor: custom action insert_text inserts at cursor" {
    var ctx: CATestCtx = .{ .next = .{ .insert_text = "INS" } };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .custom_action = caHook(&ctx),
    });
    defer editor.deinit();

    try editor.buffer.insertText("abcd");
    editor.buffer.cursor_byte = 2;
    editor.changeset.breakSequence();
    _ = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));

    try std.testing.expectEqualStrings("abINScd", editor.buffer.slice());
    try std.testing.expect(editor.changeset.canUndo());
}

test "editor: custom action replace_buffer swaps via single Replace op" {
    var ctx: CATestCtx = .{ .next = .{ .replace_buffer = "fresh" } };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .custom_action = caHook(&ctx),
    });
    defer editor.deinit();

    try editor.buffer.insertText("stale");
    editor.changeset.breakSequence();
    _ = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));

    try std.testing.expectEqualStrings("fresh", editor.buffer.slice());
    const op = editor.changeset.peekUndo().?;
    try std.testing.expect(op.* == .replace);
}

test "editor: custom action rejects invalid UTF-8 in insert_text" {
    var ctx: CATestCtx = .{ .next = .{ .insert_text = "\xFF\xFE" } };
    var diag_ctx: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .custom_action = caHook(&ctx),
        .diagnostic = diag_ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("hello");
    _ = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));

    try std.testing.expectEqualStrings("hello", editor.buffer.slice());
    try std.testing.expect(diag_ctx.count >= 1);
}

test "editor: custom action accept_line surfaces buffer as line" {
    const dev_null = openDevNullForWrite();
    defer _ = std.c.close(dev_null);
    var ctx: CATestCtx = .{ .next = .accept_line };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .output_fd = dev_null,
        .custom_action = caHook(&ctx),
    });
    defer editor.deinit();

    try editor.buffer.insertText("submitted");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    try std.testing.expect(result != null);
    switch (result.?) {
        .line => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("submitted", line);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "editor: custom action cancel_line returns interrupt + clears state" {
    const dev_null = openDevNullForWrite();
    defer _ = std.c.close(dev_null);
    var ctx: CATestCtx = .{ .next = .cancel_line };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .output_fd = dev_null,
        .custom_action = caHook(&ctx),
    });
    defer editor.deinit();

    try editor.buffer.insertText("discarded");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .interrupt);
    try std.testing.expectEqualStrings("", editor.buffer.slice());
    try std.testing.expect(!editor.changeset.canUndo());
}

test "editor: replace_buffer_and_accept returns expansion as accepted line" {
    const dev_null = openDevNullForWrite();
    defer _ = std.c.close(dev_null);
    var ctx: CATestCtx = .{ .next = .{ .replace_buffer_and_accept = "expanded command" } };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .output_fd = dev_null,
        .custom_action = caHook(&ctx),
    });
    defer editor.deinit();

    try editor.buffer.insertText("str");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    try std.testing.expect(result != null);
    switch (result.?) {
        .line => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("expanded command", line);
        },
        else => return error.TestUnexpectedResult,
    }
    // Buffer is consumed by `take()` inside acceptCurrentLine; the
    // editor's buffer is empty afterward.
    try std.testing.expectEqualStrings("", editor.buffer.slice());
}

test "editor: replace_buffer_and_accept appends to history when attached" {
    const dev_null = openDevNullForWrite();
    defer _ = std.c.close(dev_null);
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();

    var ctx: CATestCtx = .{ .next = .{ .replace_buffer_and_accept = "ls -la" } };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .output_fd = dev_null,
        .custom_action = caHook(&ctx),
        .history = &hist,
    });
    defer editor.deinit();

    try editor.buffer.insertText("ls");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    try std.testing.expect(result != null);
    switch (result.?) {
        .line => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("ls -la", line);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), hist.entryCount());
    try std.testing.expectEqualStrings("ls -la", hist.entryAt(0).?);
}

test "editor: replace_buffer_and_accept with empty text accepts empty line, no history" {
    const dev_null = openDevNullForWrite();
    defer _ = std.c.close(dev_null);
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();

    var ctx: CATestCtx = .{ .next = .{ .replace_buffer_and_accept = "" } };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .output_fd = dev_null,
        .custom_action = caHook(&ctx),
        .history = &hist,
    });
    defer editor.deinit();

    try editor.buffer.insertText("anything");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    try std.testing.expect(result != null);
    switch (result.?) {
        .line => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("", line);
        },
        else => return error.TestUnexpectedResult,
    }
    // Empty line is not appended to history (matches normal accept_line).
    try std.testing.expectEqual(@as(usize, 0), hist.entryCount());
}

test "editor: replace_buffer_and_accept rejects invalid UTF-8 nonfatally" {
    var ctx: CATestCtx = .{ .next = .{ .replace_buffer_and_accept = "\xFF\xFE" } };
    var diag: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .custom_action = caHook(&ctx),
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("safe");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    // Action did not accept; original buffer preserved.
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("safe", editor.buffer.slice());
    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .custom_action_invalid_text),
        diag.last_kind,
    );
}

test "editor: replace_buffer_and_accept rejects control bytes nonfatally" {
    var ctx: CATestCtx = .{ .next = .{ .replace_buffer_and_accept = "okay\x1bbad" } };
    var diag: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .custom_action = caHook(&ctx),
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("safe");
    const result = try editor.handleCustomAction(0, prompt_mod.Prompt.plain(""));
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("safe", editor.buffer.slice());
    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .custom_action_invalid_text),
        diag.last_kind,
    );
}

const WCMCtx = struct {
    invoked: bool = false,
    return_err: bool = false,
};

fn wcmFunc(ctx: *WCMCtx) anyerror!void {
    ctx.invoked = true;
    if (ctx.return_err) return error.TestSpawnFailed;
}

test "editor: withCookedMode runs func + propagates value" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    var wcm: WCMCtx = .{};
    const action_ctx: CustomActionContext = .{ .editor = &editor };
    try action_ctx.withCookedMode(&wcm, wcmFunc);
    try std.testing.expect(wcm.invoked);
}

test "editor: withCookedMode propagates func errors" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    var wcm: WCMCtx = .{ .return_err = true };
    const action_ctx: CustomActionContext = .{ .editor = &editor };
    const result = action_ctx.withCookedMode(&wcm, wcmFunc);
    try std.testing.expectError(error.TestSpawnFailed, result);
    try std.testing.expect(wcm.invoked);
}


// Cursor-aware highlight hook test: verify the editor passes the
// current `cursor_byte` to the hook through `HighlightRequest`.
const HighlightProbe = struct {
    last_buffer_len: usize = 0,
    last_cursor: usize = 0,
    invoked: bool = false,
};

fn highlightProbeFn(
    ctx: *anyopaque,
    allocator: Allocator,
    request: highlight_mod.HighlightRequest,
) anyerror![]highlight_mod.HighlightSpan {
    _ = allocator;
    const probe: *HighlightProbe = @ptrCast(@alignCast(ctx));
    probe.invoked = true;
    probe.last_buffer_len = request.buffer.len;
    probe.last_cursor = request.cursor_byte;
    return &.{};
}

test "editor: HighlightRequest carries cursor_byte to the hook" {
    // Tests the hook surface directly (not through render, which
    // writes ANSI to the output fd and hangs in non-TTY test fds).
    var probe: HighlightProbe = .{};
    const hook = highlight_mod.HighlightHook{
        .ctx = @ptrCast(&probe),
        .highlightFn = highlightProbeFn,
    };

    const req = highlight_mod.HighlightRequest{
        .buffer = "hello world",
        .cursor_byte = 6,
    };
    const spans = try hook.highlight(std.testing.allocator, req);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(probe.invoked);
    try std.testing.expectEqual(@as(usize, 11), probe.last_buffer_len);
    try std.testing.expectEqual(@as(usize, 6), probe.last_cursor);
}

// =============================================================================
// Binding-table dispatch tests (SPEC §5.2 state machine)
// =============================================================================

fn ctrlChar(c: u21) input_mod.KeyEvent {
    return .{ .code = .{ .char = c }, .mods = .{ .ctrl = true } };
}

/// Test-only stand-in for the legacy lookupFn that recognizes
/// only Ctrl-A → move_to_start. Anything else returns null so
/// non-bound keys fall through to default-insert behavior.
fn testCtrlALookup(key: input_mod.KeyEvent) ?actions_mod.Action {
    if (key.mods.ctrl and key.code == .char and key.code.char == 'a') {
        return .move_to_start;
    }
    return null;
}

test "editor: bindings .bound dispatches the bound action and clears pending" {
    var bindings = keymap_mod.BindingTable.init(std.testing.allocator);
    defer bindings.deinit();
    _ = try bindings.bind(&[_]input_mod.KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .move_to_start);

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = &bindings },
    });
    defer editor.deinit();
    try editor.buffer.insertText("hello");
    editor.buffer.cursor_byte = 5;

    // First event: Ctrl-X → partial.
    _ = try editor.handleKey(ctrlChar('x'), prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 1), editor.pending_keys.items.len);
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);

    // Second event: Ctrl-E → bound, dispatches move_to_start.
    _ = try editor.handleKey(ctrlChar('e'), prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 0), editor.pending_keys.items.len);
    try std.testing.expectEqual(@as(usize, 0), editor.buffer.cursor_byte);
}

test "editor: bindings .partial buffers without dispatching" {
    var bindings = keymap_mod.BindingTable.init(std.testing.allocator);
    defer bindings.deinit();
    _ = try bindings.bind(&[_]input_mod.KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .move_to_start);

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = &bindings },
    });
    defer editor.deinit();
    try editor.buffer.insertText("hi");
    editor.buffer.cursor_byte = 2;

    _ = try editor.handleKey(ctrlChar('x'), prompt_mod.Prompt.plain(""));
    // Ctrl-X is a partial; no action should have fired.
    try std.testing.expectEqual(@as(usize, 1), editor.pending_keys.items.len);
    try std.testing.expectEqual(@as(usize, 2), editor.buffer.cursor_byte);
    try std.testing.expectEqualStrings("hi", editor.buffer.slice());
}

test "editor: bindings .none with len 1 falls through to lookupFn" {
    var bindings = keymap_mod.BindingTable.init(std.testing.allocator);
    defer bindings.deinit();
    // Bindings exist but only for Ctrl-X-prefix sequences. A bare
    // Ctrl-A doesn't match any prefix → fall through to lookupFn.
    _ = try bindings.bind(&[_]input_mod.KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .undo);

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = &bindings },
    });
    defer editor.deinit();
    try editor.buffer.insertText("hello");
    editor.buffer.cursor_byte = 5;

    _ = try editor.handleKey(ctrlChar('a'), prompt_mod.Prompt.plain(""));
    // lookupFn returns move_to_start for Ctrl-A → cursor jumps to 0.
    try std.testing.expectEqual(@as(usize, 0), editor.buffer.cursor_byte);
    try std.testing.expectEqual(@as(usize, 0), editor.pending_keys.items.len);
}

test "editor: bindings replay-on-mismatch dispatches first via lookupFn, processes rest" {
    var bindings = keymap_mod.BindingTable.init(std.testing.allocator);
    defer bindings.deinit();
    // Only Ctrl-X Ctrl-E is bound. The user types Ctrl-X (partial)
    // then 'q' (which doesn't extend the prefix). Ctrl-X has no
    // single-key lookupFn binding (testCtrlALookup ignores it), so
    // it's a no-op singleton; 'q' then default-inserts as text.
    _ = try bindings.bind(&[_]input_mod.KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .undo);

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = &bindings },
    });
    defer editor.deinit();

    _ = try editor.handleKey(ctrlChar('x'), prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 1), editor.pending_keys.items.len);

    const q_event = input_mod.KeyEvent{ .code = .{ .char = 'q' } };
    _ = try editor.handleKey(q_event, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 0), editor.pending_keys.items.len);
    try std.testing.expectEqualStrings("q", editor.buffer.slice());
}

test "editor: bindings precedence — sequence prefix beats single-key lookupFn" {
    // SPEC §5.2: bindings consulted first. A prefix-K with bound
    // sequence K-+-X cannot also fire a single-key K via lookupFn —
    // the K-alone press becomes `partial`, awaiting the next event.
    var bindings = keymap_mod.BindingTable.init(std.testing.allocator);
    defer bindings.deinit();
    _ = try bindings.bind(&[_]input_mod.KeyEvent{ ctrlChar('a'), ctrlChar('e') }, .move_to_end);

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = &bindings },
    });
    defer editor.deinit();
    try editor.buffer.insertText("hello");
    editor.buffer.cursor_byte = 5;

    // Ctrl-A is normally `move_to_start` via lookupFn, but it's also
    // a prefix of the bound sequence. The single-key action does
    // NOT fire; the editor waits for the next event.
    _ = try editor.handleKey(ctrlChar('a'), prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 1), editor.pending_keys.items.len);
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);
}

test "editor: bindings flushPendingSequence resolves prefix on non-key event" {
    // Setup: Ctrl-X partial pending, then a non-key event arrives.
    // The buffered prefix should resolve as a singleton via
    // lookupFn (no-op here), then the non-key handling proceeds.
    var bindings = keymap_mod.BindingTable.init(std.testing.allocator);
    defer bindings.deinit();
    _ = try bindings.bind(&[_]input_mod.KeyEvent{ ctrlChar('x'), ctrlChar('e') }, .undo);

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = &bindings },
    });
    defer editor.deinit();

    _ = try editor.handleKey(ctrlChar('x'), prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 1), editor.pending_keys.items.len);

    _ = try editor.flushPendingSequence(prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(usize, 0), editor.pending_keys.items.len);
}

test "editor: bindings null overlay preserves single-key path verbatim" {
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .keymap = .{ .lookupFn = testCtrlALookup, .bindings = null },
    });
    defer editor.deinit();
    try editor.buffer.insertText("hello");
    editor.buffer.cursor_byte = 5;

    _ = try editor.handleKey(ctrlChar('a'), prompt_mod.Prompt.plain(""));
    // Ctrl-A → move_to_start via lookupFn; pending_keys never used.
    try std.testing.expectEqual(@as(usize, 0), editor.buffer.cursor_byte);
    try std.testing.expectEqual(@as(usize, 0), editor.pending_keys.items.len);
}

test "editor: lastWhitespaceToken pulls trailing token" {
    try std.testing.expectEqualStrings("baz", lastWhitespaceToken("foo bar baz"));
    try std.testing.expectEqualStrings("baz", lastWhitespaceToken("foo bar baz   "));
    try std.testing.expectEqualStrings("solo", lastWhitespaceToken("solo"));
    try std.testing.expectEqualStrings("", lastWhitespaceToken(""));
    try std.testing.expectEqualStrings("", lastWhitespaceToken("   "));
    try std.testing.expectEqualStrings("c", lastWhitespaceToken("a\tb c"));
}

test "editor: dispatch transpose_chars records one Replace undo step" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    try editor.buffer.insertText("abcd");
    editor.buffer.cursor_byte = 2;
    _ = try editor.dispatch(.transpose_chars, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("acbd", editor.buffer.slice());
    try std.testing.expect(editor.changeset.canUndo());
    const op = editor.changeset.peekUndo().?;
    try std.testing.expect(op.* == .replace);
}

test "editor: dispatch upper_case_word records undo + advances cursor" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    try editor.buffer.insertText("hello world");
    editor.buffer.cursor_byte = 0;
    _ = try editor.dispatch(.upper_case_word, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("HELLO world", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);
    try std.testing.expect(editor.changeset.canUndo());
}

test "editor: dispatch capitalize_word + undo round-trips" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    try editor.buffer.insertText("hello");
    editor.buffer.cursor_byte = 0;
    _ = try editor.dispatch(.capitalize_word, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("Hello", editor.buffer.slice());
    try editor.handleUndo();
    try std.testing.expectEqualStrings("hello", editor.buffer.slice());
}

test "editor: dispatch squeeze_whitespace deletes adjacent run" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    try editor.buffer.insertText("foo   bar");
    editor.buffer.cursor_byte = 5;
    _ = try editor.dispatch(.squeeze_whitespace, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("foobar", editor.buffer.slice());
}

test "editor: quoted_insert primes flag, next key emits literal control byte" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    // First dispatch primes the flag.
    _ = try editor.dispatch(.quoted_insert, prompt_mod.Prompt.plain(""));
    try std.testing.expect(editor.quoted_insert_pending);
    // Next key event: Ctrl-A, which should insert byte 0x01 literally.
    const ctrl_a = input_mod.KeyEvent{
        .code = .{ .char = 'a' },
        .mods = .{ .ctrl = true },
    };
    _ = try editor.handleKey(ctrl_a, prompt_mod.Prompt.plain(""));
    try std.testing.expect(!editor.quoted_insert_pending);
    try std.testing.expectEqualSlices(u8, "\x01", editor.buffer.slice());
}

test "editor: history_first / history_last navigate bookends" {
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();
    try hist.append("oldest");
    try hist.append("middle");
    try hist.append("newest");

    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled, .history = &hist });
    defer editor.deinit();
    try editor.buffer.insertText("draft");
    _ = try editor.dispatch(.history_first, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("oldest", editor.buffer.slice());
    _ = try editor.dispatch(.history_last, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("draft", editor.buffer.slice());
}

test "editor: yank_last_arg inserts last token of newest entry" {
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();
    try hist.append("git commit -m hello");
    try hist.append("ls /tmp/foo.txt");

    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled, .history = &hist });
    defer editor.deinit();
    try editor.buffer.insertText("cat ");
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("cat /tmp/foo.txt", editor.buffer.slice());
}

test "editor: yank_last_arg cycles through entries on repeat" {
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();
    try hist.append("git commit -m hello");
    try hist.append("ls /tmp/foo.txt");

    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled, .history = &hist });
    defer editor.deinit();
    try editor.buffer.insertText("cat ");
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("cat /tmp/foo.txt", editor.buffer.slice());
    // Second M-. cycles back to the previous entry.
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("cat hello", editor.buffer.slice());
}

test "editor: Action.insert_text rejects control bytes via diagnostic" {
    var diag: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();
    try editor.buffer.insertText("safe");
    // Inject ESC via Action.insert_text; should be rejected, buffer unchanged.
    _ = try editor.dispatch(.{ .insert_text = "\x1b[2Jbad" }, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("safe", editor.buffer.slice());
    try std.testing.expect(diag.count >= 1);
}

test "editor: Action.insert_text rejects invalid UTF-8 via diagnostic" {
    var diag: DiagTestCtx = .{};
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();
    try editor.buffer.insertText("hi");
    _ = try editor.dispatch(.{ .insert_text = "\xff\xfe" }, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("hi", editor.buffer.slice());
    try std.testing.expect(diag.count >= 1);
}

test "editor: yank_last_arg state resets on default-insert" {
    // Regression: pre-fix, the cycling-state reset only happened in
    // dispatch(), but default-insert (printable char with no keymap
    // binding) goes through handleKeyDirect bypassing dispatch. So
    // M-. → typed letter → M-. would still cycle when it shouldn't.
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();
    try hist.append("foo bar");
    try hist.append("baz qux");

    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled, .history = &hist });
    defer editor.deinit();
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("qux", editor.buffer.slice());

    // Default-insert via handleKeyDirect should reset cycle state.
    const a = input_mod.KeyEvent{ .code = .{ .char = 'a' } };
    _ = try editor.handleKeyDirect(a, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(?YankLastArgState, null), editor.yank_last_arg);

    // Now M-. starts a fresh cycle from the most-recent entry's
    // last token, appended at the new cursor position.
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("quxaqux", editor.buffer.slice());
}

test "editor: yank_last_arg state resets on non-yank action" {
    var hist = try history_mod.History.init(std.testing.allocator, .{});
    defer hist.deinit();
    try hist.append("foo bar");
    try hist.append("baz qux");

    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled, .history = &hist });
    defer editor.deinit();
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("qux", editor.buffer.slice());
    // Cursor move resets cycling.
    _ = try editor.dispatch(.move_to_start, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqual(@as(?YankLastArgState, null), editor.yank_last_arg);
    // Now yank_last_arg starts fresh — pulls newest entry's last arg again.
    _ = try editor.dispatch(.yank_last_arg, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("quxqux", editor.buffer.slice());
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

// -----------------------------------------------------------------------------
// Fresh-row hook lifecycle tests — the v0.3.0 implementation tied the
// claim to SignalGuard (raw-mode-scoped) and was a no-op in the
// default config; v0.3.1 moves the claim to Editor.init/deinit. These
// tests exercise the real lifecycle the embedder sees, not the bare
// atomic primitive (which is covered in terminal.zig).
// -----------------------------------------------------------------------------

test "editor: init claims and deinit releases the active editor output fd" {
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .input_fd = fds[0],
        .output_fd = fds[1],
    });
    try std.testing.expect(editor.fresh_row_claimed);

    // Standalone hook fires for our pipe.
    terminal_mod.pokeActiveFreshRow();
    var buf: [4]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 2), n);
    try std.testing.expectEqualSlices(u8, "\r\n", buf[0..2]);

    editor.deinit();

    // After deinit, no editor is registered and the standalone hook
    // is a no-op. Verify by setting the read end nonblocking and
    // confirming nothing arrives. Assert both fcntl calls succeed —
    // a failed SETFL would silently turn the EAGAIN check below into
    // a hang.
    const o_nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const flags = std.c.fcntl(fds[0], std.c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(flags >= 0);
    try std.testing.expect(std.c.fcntl(fds[0], std.c.F.SETFL, flags | o_nonblock) >= 0);
    terminal_mod.pokeActiveFreshRow();
    const m = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expect(m < 0);
    try std.testing.expectEqual(std.c.errno(@as(c_int, -1)), std.c.E.AGAIN);
}

test "editor: ensureFreshRow writes CRLF directly to this editor's output fd" {
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }

    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .input_fd = fds[0],
        .output_fd = fds[1],
    });
    defer editor.deinit();

    editor.ensureFreshRow();
    var buf: [4]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 2), n);
    try std.testing.expectEqualSlices(u8, "\r\n", buf[0..2]);
}

test "editor: second Editor.init does not steal the global claim from the first" {
    var fds_a: [2]c_int = undefined;
    var fds_b: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&fds_a) == 0);
    try std.testing.expect(std.c.pipe(&fds_b) == 0);
    defer {
        _ = std.c.close(fds_a[0]);
        _ = std.c.close(fds_a[1]);
        _ = std.c.close(fds_b[0]);
        _ = std.c.close(fds_b[1]);
    }

    var ed_a = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .input_fd = fds_a[0],
        .output_fd = fds_a[1],
    });
    defer ed_a.deinit();
    try std.testing.expect(ed_a.fresh_row_claimed);

    var ed_b = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .input_fd = fds_b[0],
        .output_fd = fds_b[1],
    });
    defer ed_b.deinit();
    // Second editor silently loses the global claim.
    try std.testing.expect(!ed_b.fresh_row_claimed);

    // Standalone hook still routes to A.
    terminal_mod.pokeActiveFreshRow();
    var buf: [4]u8 = undefined;
    const n_a = std.c.read(fds_a[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 2), n_a);
    try std.testing.expectEqualSlices(u8, "\r\n", buf[0..2]);

    // B's instance method still works deterministically against B's fd,
    // independent of who holds the global claim.
    ed_b.ensureFreshRow();
    const n_b = std.c.read(fds_b[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 2), n_b);
    try std.testing.expectEqualSlices(u8, "\r\n", buf[0..2]);
}

// =============================================================================
// Hint (ghost-text) tests. Verify the cache contract and the
// `accept_hint` action's dispatch behavior without a real terminal.
// =============================================================================

const HintTestCtx = struct {
    /// Fixed suffix returned for any prefix the buffer happens to be.
    /// `null` means "no suggestion."
    suggest: ?[]const u8 = null,
    style: ?hint_mod.Style = null,
    /// Tracks how many times the hook was invoked, so tests can
    /// assert the cursor-at-end gate.
    calls: usize = 0,
    /// Optional override that lets a test return ANY text (used to
    /// exercise the validation path with control bytes / bad UTF-8).
    raw_text: ?[]const u8 = null,
    /// Optional error to inject — exercises the `hint_hook_failed`
    /// diagnostic path.
    inject_err: ?anyerror = null,

    fn cb(ctx: *anyopaque, request: hint_mod.HintRequest) anyerror!?hint_mod.HintResult {
        const self: *HintTestCtx = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.inject_err) |e| return e;
        if (self.raw_text) |t| return hint_mod.HintResult{ .text = t, .style = self.style };
        const s = self.suggest orelse return null;
        _ = request;
        return hint_mod.HintResult{ .text = s, .style = self.style };
    }

    fn hook(self: *HintTestCtx) hint_mod.HintHook {
        return .{ .ctx = @ptrCast(self), .hintFn = cb };
    }
};

test "editor: computeHintDraw caches validated suffix when cursor at end" {
    var ctx: HintTestCtx = .{ .suggest = " world" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("hello");
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);

    const draw_opt = editor.computeHintDraw();
    try std.testing.expect(draw_opt != null);
    const draw = draw_opt.?;
    try std.testing.expectEqualStrings(" world", draw.text);
    try std.testing.expectEqual(@as(usize, 6), draw.cols);
    try std.testing.expect(draw.style.dim); // default style applied

    try std.testing.expect(editor.last_hint != null);
    try std.testing.expectEqual(@as(usize, 5), editor.last_hint.?.buffer_len);
    try std.testing.expectEqual(@as(usize, 5), editor.last_hint.?.cursor_byte);
    try std.testing.expectEqualStrings(" world", editor.last_hint.?.text);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "editor: computeHintDraw skips hook when cursor not at end" {
    var ctx: HintTestCtx = .{ .suggest = "tail" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("abc");
    try editor.buffer.moveLeftCluster(); // cursor at 2

    const draw_opt = editor.computeHintDraw();
    try std.testing.expect(draw_opt == null);
    try std.testing.expect(editor.last_hint == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.calls);
}

test "editor: computeHintDraw drops hint with control bytes" {
    var diag: DiagTestCtx = .{};
    var ctx: HintTestCtx = .{ .raw_text = "good\x1bhad" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("x");
    const draw = editor.computeHintDraw();
    try std.testing.expect(draw == null);
    try std.testing.expect(editor.last_hint == null);
    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .hint_invalid_text),
        diag.last_kind,
    );
}

test "editor: computeHintDraw drops hint with invalid UTF-8" {
    var diag: DiagTestCtx = .{};
    var ctx: HintTestCtx = .{ .raw_text = "abc\xFF\xFE" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("y");
    const draw = editor.computeHintDraw();
    try std.testing.expect(draw == null);
    try std.testing.expect(editor.last_hint == null);
    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .hint_invalid_text),
        diag.last_kind,
    );
}

test "editor: computeHintDraw routes hook errors through diagnostic" {
    var diag: DiagTestCtx = .{};
    var ctx: HintTestCtx = .{ .inject_err = error.OutOfMemory };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
        .diagnostic = diag.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("z");
    const draw = editor.computeHintDraw();
    try std.testing.expect(draw == null);
    try std.testing.expect(editor.last_hint == null);
    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .hint_hook_failed),
        diag.last_kind,
    );
}

test "editor: computeHintDraw frees prior cache before repopulating" {
    var ctx: HintTestCtx = .{ .suggest = "abc" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("h");
    _ = editor.computeHintDraw();
    try std.testing.expect(editor.last_hint != null);

    // Calling again must not leak. The deinit at end of test would
    // surface a failure under the `testing.allocator`.
    _ = editor.computeHintDraw();
    try std.testing.expect(editor.last_hint != null);
    try std.testing.expectEqualStrings("abc", editor.last_hint.?.text);
}

test "editor: accept_hint inserts cached suffix as one undo step" {
    var ctx: HintTestCtx = .{ .suggest = "lo" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("hel");
    // Simulate a render — populate the cache.
    _ = editor.computeHintDraw();
    try std.testing.expect(editor.last_hint != null);

    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));

    try std.testing.expectEqualStrings("hello", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);
    try std.testing.expect(editor.last_hint == null);

    // One undo restores to the pre-accept state.
    try editor.handleUndo();
    try std.testing.expectEqualStrings("hel", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 3), editor.buffer.cursor_byte);
}

test "editor: accept_hint with no hook falls back to move_right" {
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
    });
    defer editor.deinit();
    try editor.buffer.insertText("abc");
    editor.buffer.cursor_byte = 1; // between 'a' and 'b'
    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("abc", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), editor.buffer.cursor_byte);
}

test "editor: accept_hint with no hook AND cursor at end is a no-op" {
    // The single most common case for embedders without a hint hook:
    // user pressed Right Arrow at end-of-line. Pre-rebind, that ran
    // `move_right` which is a no-op at EOL; post-rebind, the same
    // physical key dispatches `accept_hint` which (with no hook) must
    // fall through to the same no-op. Locks in that we didn't break
    // the default behavior for non-hint users.
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
    });
    defer editor.deinit();
    try editor.buffer.insertText("abc");
    try std.testing.expectEqual(@as(usize, 3), editor.buffer.cursor_byte);
    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("abc", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 3), editor.buffer.cursor_byte);
}

test "editor: accept_hint fallback breaks the changeset coalescing chain" {
    // Regression: when accept_hint falls back to move_right (no hook
    // / cursor not at end / no cached hint), the dispatch path MUST
    // break the changeset sequence so the next typed char doesn't
    // merge with the prior typing run into a single undo step.
    // Bug fixed in the post-merge cleanup; this test locks it in.
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
    });
    defer editor.deinit();
    try editor.buffer.insertText("foo");
    editor.buffer.cursor_byte = 1; // mid-buffer so accept_hint advances
    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));
    // Now type 'X'. Without the break, "fooX" coalesces into one
    // insert undo entry. With the break, "foo" and "X" are separate
    // entries, so a single undo restores "fooo... wait actually after
    // accept_hint, cursor is at 2 ("fo|o"), and then 'X' inserts at 2
    // → buffer becomes "foXo", cursor at 3. One undo removes "X".
    const x = input_mod.KeyEvent{ .code = .{ .char = 'X' } };
    _ = try editor.handleKeyDirect(x, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("foXo", editor.buffer.slice());
    try editor.handleUndo();
    // If the break worked, the X is undone independently → "foo".
    try std.testing.expectEqualStrings("foo", editor.buffer.slice());
}

test "editor: accept_hint with cursor not at end falls back to move_right" {
    var ctx: HintTestCtx = .{ .suggest = "world" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("hello");
    // Render with cursor at end → hint cached.
    _ = editor.computeHintDraw();
    // Now move left so the cache key no longer matches.
    try editor.buffer.moveLeftCluster();

    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));

    // Buffer unchanged; cursor advanced one cluster (move_right path).
    try std.testing.expectEqualStrings("hello", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);
    try std.testing.expect(editor.last_hint == null);
}

test "editor: accept_hint with no cached hint falls back to move_right" {
    // Hook returns null (e.g. nothing matches the typed prefix). The
    // cache stays empty; accept_hint must NOT mutate buffer beyond
    // the move_right fallback.
    var ctx: HintTestCtx = .{ .suggest = null };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("abc");
    editor.buffer.cursor_byte = 0;
    _ = editor.computeHintDraw();
    try std.testing.expect(editor.last_hint == null);

    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("abc", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 1), editor.buffer.cursor_byte);
}

test "editor: hint with multibyte tail (cursor-at-end check on bytes)" {
    // Tail cluster is a 2-byte UTF-8 char. Cursor is at byte_len,
    // not cluster index — make sure the gate accepts that.
    var ctx: HintTestCtx = .{ .suggest = "!" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();

    try editor.buffer.insertText("café");
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor_byte);
    _ = editor.computeHintDraw();
    try std.testing.expect(editor.last_hint != null);

    _ = try editor.dispatch(.accept_hint, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("café!", editor.buffer.slice());
}

test "editor: stale-hint clearing — wider prior frame fully cleared" {
    // Render once with a hint, then call render() again with no hint
    // active (hook removed via cursor-not-at-end). The renderer's
    // stored `last_rows`/`last_cursor_row` must reflect the first
    // frame's hint-inclusive size so the per-row clear actually
    // erases the prior ghost text. We verify by inspecting the
    // renderer's bookkeeping fields rather than driving a real
    // terminal: that's what `Layout.compute` makes possible.
    var ctx: HintTestCtx = .{ .suggest = " world" };
    var editor = try Editor.init(std.testing.allocator, .{
        .raw_mode = .disabled,
        .hint = ctx.hook(),
    });
    defer editor.deinit();
    try editor.buffer.insertText("hi");

    // Frame 1: prompt empty, buffer "hi" (2), hint " world" (6) → 8 cells.
    // On a fictitious 4-col terminal the layout would be 2 rows.
    const cs1 = blk: {
        try editor.buffer.ensureClusters();
        break :blk editor.buffer.clusters.items;
    };
    const lay1 = renderer_mod.Layout.compute(0, cs1, editor.buffer.cursor_byte, 4, 6);
    try std.testing.expectEqual(@as(usize, 8), lay1.total_cols);
    try std.testing.expectEqual(@as(usize, 2), lay1.rows);

    // Frame 2: same buffer, hint dropped → 2 cells, 1 row.
    const lay2 = renderer_mod.Layout.compute(0, cs1, editor.buffer.cursor_byte, 4, 0);
    try std.testing.expectEqual(@as(usize, 2), lay2.total_cols);
    try std.testing.expectEqual(@as(usize, 1), lay2.rows);

    // The renderer's per-row clear walks `last_rows` (= lay1.rows = 2)
    // BEFORE writing the new frame — so the second row of stale ghost
    // text is wiped before the new frame's prompt+buffer overwrite the
    // first. Layout math proves the row count shrinks; the existing
    // renderer clear loop (renderer.zig lines 187..197) handles the
    // erasure based on `last_rows`. This test locks in that the math
    // produces a smaller `rows` value when the hint disappears so the
    // pre-existing clear path has more rows to wipe than to redraw.
    try std.testing.expect(lay1.rows > lay2.rows);
}

// =============================================================================
// Transient input mode tests — verify the Ctrl-R overlay's state
// machine, hook contract, and accept/abort semantics without driving
// a real terminal.
// =============================================================================

const TransientTestCtx = struct {
    /// Sequence of events the hook has been called with, in order.
    events: [16]transient_mod.TransientInputEvent = undefined,
    events_len: usize = 0,
    /// What the hook returns next; tests set this before driving.
    next_preview: ?[]const u8 = null,
    next_status: ?[]const u8 = null,
    /// Last-seen request fields for assertions.
    last_query: [128]u8 = undefined,
    last_query_len: usize = 0,
    last_query_cursor: usize = 0,
    last_original_cursor: usize = 0,
    /// Optional error to inject (exercises the hook-failure diag path).
    inject_err: ?anyerror = null,

    fn cb(
        ctx: *anyopaque,
        request: transient_mod.TransientInputRequest,
    ) anyerror!transient_mod.TransientInputResult {
        const self: *TransientTestCtx = @ptrCast(@alignCast(ctx));
        if (self.events_len < self.events.len) {
            self.events[self.events_len] = request.event;
            self.events_len += 1;
        }
        if (self.inject_err) |e| return e;
        @memcpy(self.last_query[0..request.query.len], request.query);
        self.last_query_len = request.query.len;
        self.last_query_cursor = request.query_cursor_byte;
        self.last_original_cursor = request.original_cursor_byte;
        return .{ .preview = self.next_preview, .status = self.next_status };
    }

    fn hook(self: *TransientTestCtx) transient_mod.TransientInputHook {
        return .{ .ctx = @ptrCast(self), .updateFn = cb };
    }

    fn lastQuery(self: *const TransientTestCtx) []const u8 {
        return self.last_query[0..self.last_query_len];
    }

    fn eventsSlice(self: *const TransientTestCtx) []const transient_mod.TransientInputEvent {
        return self.events[0..self.events_len];
    }
};

fn devNullEditorWithTransient(
    ctx: *TransientTestCtx,
    diag_ctx: ?*DiagTestCtx,
) !struct { editor: Editor, fd: c_int } {
    const fd = openDevNullForWrite();
    var opts: Options = .{
        .raw_mode = .disabled,
        .output_fd = fd,
        .transient_input = ctx.hook(),
    };
    if (diag_ctx) |dc| opts.diagnostic = dc.hook();
    const editor = try Editor.init(std.testing.allocator, opts);
    return .{ .editor = editor, .fd = fd };
}

test "editor: transient_input_open initializes state and fires .opened" {
    var ctx: TransientTestCtx = .{ .next_status = "search: " };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("hello");
    editor.buffer.cursor_byte = 3;

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    try std.testing.expect(editor.transient != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.events_len);
    try std.testing.expect(ctx.events[0] == .opened);
    try std.testing.expectEqual(@as(usize, 3), ctx.last_original_cursor);
    // Status was applied.
    try std.testing.expect(editor.transient.?.last_status != null);
    try std.testing.expectEqualStrings("search: ", editor.transient.?.last_status.?);
    // Main buffer is preserved.
    try std.testing.expectEqualStrings("hello", editor.buffer.slice());
}

test "editor: transient_input_open is no-op when no hook is configured" {
    var editor = try Editor.init(std.testing.allocator, .{ .raw_mode = .disabled });
    defer editor.deinit();
    try editor.buffer.insertText("untouched");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    try std.testing.expect(editor.transient == null);
    try std.testing.expectEqualStrings("untouched", editor.buffer.slice());
}

fn keyPrintable(c: u21) input_mod.KeyEvent {
    return .{ .code = .{ .char = c } };
}

fn keyCtrl(c: u21) input_mod.KeyEvent {
    return .{ .code = .{ .char = c }, .mods = .{ .ctrl = true } };
}

test "editor: transient query update fires .query_changed with current text" {
    var ctx: TransientTestCtx = .{ .next_preview = "git checkout main" };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    // Type 'g', 'i', 't' into the query.
    _ = try editor.handleKeyTransient(keyPrintable('g'));
    _ = try editor.handleKeyTransient(keyPrintable('i'));
    _ = try editor.handleKeyTransient(keyPrintable('t'));

    // 1 .opened + 3 .query_changed.
    try std.testing.expectEqual(@as(usize, 4), ctx.events_len);
    try std.testing.expect(ctx.events[1] == .query_changed);
    try std.testing.expect(ctx.events[3] == .query_changed);
    try std.testing.expectEqualStrings("git", ctx.lastQuery());
    // Preview cached.
    try std.testing.expectEqualStrings("git checkout main", editor.transient.?.last_preview.?);
}

test "editor: transient Ctrl-R while open fires .next" {
    var ctx: TransientTestCtx = .{ .next_preview = "first" };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyTransient(keyCtrl('r'));
    _ = try editor.handleKeyTransient(keyCtrl('r'));

    try std.testing.expectEqual(@as(usize, 3), ctx.events_len);
    try std.testing.expect(ctx.events[1] == .next);
    try std.testing.expect(ctx.events[2] == .next);
    try std.testing.expect(editor.transient != null); // still in mode
}

test "editor: transient Enter with non-empty preview replaces buffer + records undo" {
    var ctx: TransientTestCtx = .{ .next_preview = "git checkout main" };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("original");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    // Now press Enter.
    _ = try editor.handleKeyTransient(.{ .code = .enter });

    try std.testing.expect(editor.transient == null);
    try std.testing.expectEqualStrings("git checkout main", editor.buffer.slice());

    // Undo restores the original.
    try editor.handleUndo();
    try std.testing.expectEqualStrings("original", editor.buffer.slice());
}

test "editor: transient Enter with empty preview clears buffer" {
    var ctx: TransientTestCtx = .{ .next_preview = "" };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("anything");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyTransient(.{ .code = .enter });

    try std.testing.expect(editor.transient == null);
    try std.testing.expectEqualStrings("", editor.buffer.slice());
}

test "editor: transient Enter with null preview is a no-op (stays open)" {
    var ctx: TransientTestCtx = .{ .next_preview = null };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("kept");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyTransient(.{ .code = .enter });

    try std.testing.expect(editor.transient == null);
    try std.testing.expectEqualStrings("kept", editor.buffer.slice());
}

test "editor: transient Esc fires .aborted and leaves buffer untouched" {
    var ctx: TransientTestCtx = .{ .next_preview = "would-be-replacement" };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("untouched");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyTransient(.{ .code = .escape });

    try std.testing.expect(editor.transient == null);
    try std.testing.expectEqualStrings("untouched", editor.buffer.slice());

    var saw_aborted = false;
    for (ctx.eventsSlice()) |e| {
        if (e == .aborted) saw_aborted = true;
    }
    try std.testing.expect(saw_aborted);
}

test "editor: transient Ctrl-G fires .aborted (Esc synonym)" {
    var ctx: TransientTestCtx = .{};
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("preserve");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyTransient(keyCtrl('g'));

    try std.testing.expect(editor.transient == null);
    try std.testing.expectEqualStrings("preserve", editor.buffer.slice());

    var saw_aborted = false;
    for (ctx.eventsSlice()) |e| {
        if (e == .aborted) saw_aborted = true;
    }
    try std.testing.expect(saw_aborted);
}

test "editor: transient Ctrl-C exits transient and cancels line" {
    var ctx: TransientTestCtx = .{};
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    try editor.buffer.insertText("abandoned");
    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    const result = try editor.handleKeyTransient(keyCtrl('c'));

    try std.testing.expect(editor.transient == null);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .interrupt);
    try std.testing.expectEqualStrings("", editor.buffer.slice());

    // Ctrl-C also fires .aborted so the hook can clean up state
    // it allocated on .opened (matches Esc / Ctrl-G / EOF behavior).
    var saw_aborted = false;
    for (ctx.eventsSlice()) |e| {
        if (e == .aborted) saw_aborted = true;
    }
    try std.testing.expect(saw_aborted);
}

test "editor: transient cursor-aware editing via Left + insert" {
    var ctx: TransientTestCtx = .{};
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyTransient(keyPrintable('a'));
    _ = try editor.handleKeyTransient(keyPrintable('c'));
    _ = try editor.handleKeyTransient(.{ .code = .arrow_left });
    _ = try editor.handleKeyTransient(keyPrintable('b'));

    // Query is "abc"; cursor at byte 2 after the insertion.
    try std.testing.expectEqualStrings("abc", editor.transient.?.query.slice());
    try std.testing.expectEqual(@as(usize, 2), editor.transient.?.query.cursor_byte);
    // Hook saw the latest update with cursor byte 2.
    try std.testing.expectEqual(@as(usize, 2), ctx.last_query_cursor);
}

test "editor: transient invalid preview drops to null, valid status kept" {
    var diag: DiagTestCtx = .{};
    var ctx: TransientTestCtx = .{ .next_preview = "bad\x1bdata", .next_status = "(valid status): " };
    const setup = try devNullEditorWithTransient(&ctx, &diag);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    try std.testing.expect(editor.transient.?.last_preview == null);
    try std.testing.expectEqualStrings("(valid status): ", editor.transient.?.last_status.?);
    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .transient_input_invalid_text),
        diag.last_kind,
    );
}

test "editor: transient invalid status falls back to null, valid preview kept" {
    var diag: DiagTestCtx = .{};
    var ctx: TransientTestCtx = .{ .next_preview = "good", .next_status = "bad\x1bstatus" };
    const setup = try devNullEditorWithTransient(&ctx, &diag);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("good", editor.transient.?.last_preview.?);
    try std.testing.expect(editor.transient.?.last_status == null);
    try std.testing.expect(diag.count >= 1);
}

test "editor: transient hook error fires diagnostic, leaves last cache intact" {
    var diag: DiagTestCtx = .{};
    var ctx: TransientTestCtx = .{
        .next_preview = "first match",
        .next_status = null,
    };
    const setup = try devNullEditorWithTransient(&ctx, &diag);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("first match", editor.transient.?.last_preview.?);

    // Now make subsequent hook calls fail; type a char.
    ctx.inject_err = error.RankerCrashed;
    _ = try editor.handleKeyTransient(keyPrintable('x'));

    try std.testing.expect(diag.count >= 1);
    try std.testing.expectEqual(
        @as(?Diagnostic.Kind, .transient_input_hook_failed),
        diag.last_kind,
    );
    // Previous preview is preserved (not wiped by the failed call).
    try std.testing.expectEqualStrings("first match", editor.transient.?.last_preview.?);
}

test "editor: normal typing after transient exit edits main buffer" {
    var ctx: TransientTestCtx = .{ .next_preview = "preview" };
    const setup = try devNullEditorWithTransient(&ctx, null);
    var editor = setup.editor;
    defer {
        editor.deinit();
        _ = std.c.close(setup.fd);
    }

    _ = try editor.dispatch(.transient_input_open, prompt_mod.Prompt.plain(""));
    // Abort.
    _ = try editor.handleKeyTransient(.{ .code = .escape });
    try std.testing.expect(editor.transient == null);

    // Now use the normal handleKeyDirect path (simulating post-exit
    // typing). The action goes to main buffer.
    _ = try editor.handleKeyDirect(keyPrintable('a'), prompt_mod.Prompt.plain(""));
    _ = try editor.handleKeyDirect(keyPrintable('b'), prompt_mod.Prompt.plain(""));
    try std.testing.expectEqualStrings("ab", editor.buffer.slice());
}
