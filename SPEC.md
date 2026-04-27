# zigline — Specification

> A grapheme-aware terminal line editor for Zig CLIs and REPLs.
> Multi-row wrap, history, tab completion, and syntax highlighting hooks.

This document is the design constitution for zigline. It is meant to be
**updated as implementation reveals reality**, not preserved as a
frozen artifact. When the code disagrees with this spec, the code wins
and the spec gets revised in the same commit.

The audience is the implementer (human or AI) bringing zigline up. It
captures the load-bearing decisions — module split, ownership graph,
buffer model, render algorithm, public API — so the implementer's
judgment fills the rest.

---

## §0 Scope and non-scope

### What zigline IS

A line editor: a library that reads one logical line of input from a
terminal, with cursor editing, history, completion, and syntax
highlighting. The bytes the user sees on the terminal stay correct
under multibyte text, multi-row wrap, and arbitrary terminal width.

The library is consumed by Zig programs that want a polished
interactive prompt without rolling their own. The first consumer is
[slash](https://github.com/shreeve/slash), a Unix shell. Later
consumers are any Zig CLI that wants real interactive editing — a
database client, a build dashboard, a custom REPL.

### What zigline IS NOT

- A terminal emulator. We **emit** the escape sequences a terminal
  emulator interprets. We do not parse and render them ourselves.
- A general TUI framework. zigline draws one prompt + one input line
  + an optional completion menu. It does not own the screen.
- A shell. Slash is the shell that uses zigline; zigline knows nothing
  about shell parsing, jobs, or pipes.
- A C library with stable ABI. zigline targets Zig consumers; if a C
  binding ever ships, it's a separate concern with its own surface.
- An async event loop. zigline runs synchronously inside the caller's
  thread, blocking on `read`. Async-completion support is a v0.2+
  consideration with its own design pass.

### Design philosophy

> **Does this improve correctness on the user-visible surface, the
> ergonomics of the public API, or the testability of the codebase?
> If not, do not build it.**

Three axes that gate every feature:

- **Correctness on the user-visible surface.** What the user sees is
  contracted. Mis-rendered cursor, dropped bytes, broken UTF-8 — all
  bugs, all blockers.
- **Ergonomics of the public API.** Embedding zigline should feel
  natural to a Zig developer. Allocator threading, error sets, hook
  signatures all matter.
- **Testability.** Every behavior has a PTY-driven or unit test.
  Behaviors without tests don't ship.

When these conflict — e.g. a fast diff renderer that's hard to test —
the spec defers the harder thing to a later milestone, ships the simpler
correct thing now.

---

## §1 Architecture

### The execution pipeline

```
keystrokes → Input → KeyEvent → Keymap → Action → Editor → Buffer mutation
                                                       ↓
                                    Completion / Highlight / History hooks
                                                       ↓
                                         Renderer → terminal bytes
```

Each arrow is a defined boundary with a defined type at its endpoints.
No layer reaches across; an `Action` never inspects a `KeyEvent`'s
escape-sequence bytes, a `Renderer` never reads from the input fd.

### Modules

```
zigline/
├── src/
│   ├── root.zig          # public re-exports; the package entry point
│   ├── editor.zig        # Editor — orchestration, action dispatch
│   ├── buffer.zig        # Buffer — bytes + grapheme index + cursor
│   ├── grapheme.zig      # grapheme segmentation + display width
│   ├── input.zig         # byte stream → KeyEvent / PasteEvent / ResizeEvent
│   ├── keymap.zig        # KeyEvent → Action mapping; defaults
│   ├── actions.zig       # Action enum + Action dispatcher contract
│   ├── renderer.zig      # Buffer + state → terminal bytes
│   ├── terminal.zig      # raw mode, size query, fd ownership, terminal modes
│   ├── history.zig       # in-memory navigation + persistent flat file
│   ├── completion.zig    # CompletionHook + CompletionRequest/Result types
│   ├── highlight.zig     # HighlightHook + HighlightSpan/Style types
│   └── prompt.zig        # Prompt type (bytes + display width)
├── examples/
│   ├── minimal.zig       # smallest possible usage (~30 lines)
│   ├── with_history.zig  # adds persistent history
│   ├── with_completion.zig
│   └── with_highlight.zig
├── tests/
│   ├── pty_tests.zig     # end-to-end through a real PTY
│   └── unit/             # per-module unit tests live alongside modules
├── build.zig
├── build.zig.zon
├── README.md
├── SPEC.md               # this document
└── LICENSE
```

### Ownership graph

- `Editor` owns `Buffer`, `Renderer`, `Terminal`, `Keymap`, and
  references to caller-owned `History`, `CompletionHook`,
  `HighlightHook`.
- `Buffer` owns the byte storage and the grapheme index.
- `Renderer` owns the previous-frame state needed for repainting
  (`last_rows`, `last_cursor_row`).
- `Terminal` owns the raw-mode lifecycle (saved termios), fd handles
  (borrowed from caller), and bracketed-paste state.
- `History` owns its in-memory entries and persistence path. The
  caller may construct a `History` separately and pass it into
  `Editor.init` so multiple editor sessions can share history.
- Hooks are caller-owned. The library borrows them for the lifetime
  of `Editor`.

### What the modules don't do

- `Editor` doesn't read bytes (that's `Input`/`Terminal`).
- `Buffer` doesn't render (that's `Renderer`).
- `Keymap` doesn't execute (it produces an `Action`; `Editor`
  executes).
- `Renderer` doesn't compute display width (that's `grapheme.zig`).
- `Highlight` hooks don't emit ANSI escape sequences directly; they
  return semantic `HighlightSpan` values and the renderer generates SGR.

This separation is the load-bearing invariant of the library. It's
what makes diff-based rendering tractable in v0.2 and theme support
trivial later.

---

## §2 Glossary

- **Byte offset.** Index into a `[]u8` buffer.
- **Grapheme cluster** (or just **grapheme** or **cluster**). One
  user-perceived character per Unicode UAX #29. May span multiple
  bytes (UTF-8) and multiple code points (combining marks, ZWJ
  sequences, regional indicators).
- **Display width** (or **cell width**). Number of terminal cells a
  grapheme occupies: 0 (combining mark), 1 (ASCII, most Latin), or
  2 (CJK ideographs, most emoji). Resolved via `zg`.
- **Cursor.** A byte offset into the buffer that always sits on a
  grapheme boundary.
- **Frame.** One render cycle's output: prompt + buffer state +
  cursor position, expressed as a sequence of terminal-row contents.
- **Logical row.** A row in the rendered frame.
- **Visual row.** A row on the actual terminal.
- **Wrap.** The point where a logical row exceeds terminal width and
  spills onto the next visual row. v0.1 logical = visual after wrap.
- **Action.** A named editor command (e.g. `move_left`,
  `delete_backward`, `accept_line`). Produced by the keymap, executed
  by the editor.
- **Hook.** A caller-supplied callback the editor invokes at defined
  points (completion, highlight). Each hook is a struct with
  `ctx: *anyopaque` and a function pointer.

---

## §3 Buffer model

### Storage

```zig
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    /// Grapheme cluster index, recomputed lazily on edit. Each entry
    /// describes a contiguous run of bytes that forms one cluster.
    clusters: std.ArrayListUnmanaged(Cluster) = .empty,
    /// Byte offset of the cursor. Always at a cluster boundary.
    cursor_byte: usize = 0,
    /// Whether `clusters` reflects current `bytes`. Edits set this
    /// false; `clusters()` computes if needed.
    clusters_valid: bool = true,
};

pub const Cluster = struct {
    byte_start: usize,
    byte_end: usize,
    /// Display width in terminal cells: 0, 1, or 2.
    width: u8,
};
```

### Invariants

1. `cursor_byte <= bytes.items.len`.
2. `cursor_byte` is always a valid cluster boundary (either 0, or
   equal to some `cluster.byte_end`).
3. `bytes` is valid UTF-8 (see §3.4).
4. `clusters` covers every byte in `bytes` exactly once when
   `clusters_valid` is true.
5. `clusters[i].byte_end == clusters[i+1].byte_start` for adjacent
   clusters; `clusters[0].byte_start == 0`;
   `clusters[last].byte_end == bytes.items.len`.

### Edit operations

The buffer exposes a small, fully grapheme-safe edit API:

- `insertText(self, bytes: []const u8) !void` — insert at cursor;
  bytes must be valid UTF-8; updates cursor to point past inserted
  text. Re-segments around insertion point.
- `deleteBackwardCluster(self) void` — delete the cluster ending at
  cursor; cursor moves to where that cluster started. No-op at
  cursor_byte == 0.
- `deleteForwardCluster(self) void` — delete the cluster starting at
  cursor. No-op at end of buffer.
- `moveLeftCluster(self) void` — cursor jumps to the previous cluster
  boundary.
- `moveRightCluster(self) void` — cursor jumps to the next cluster
  boundary.
- `moveLeftWord(self) void` / `moveRightWord(self) void` — cursor
  jumps over a whitespace-delimited "word." Word delimiters are
  ASCII whitespace + a small fixed punctuation set; the policy is
  fixed for v0.1, configurable later.
- `killToStart(self) void` / `killToEnd(self) void` — delete from
  cursor to bounds.
- `killWordBackward(self) void` / `killWordForward(self) void`.
- `replaceAll(self, text: []const u8) !void` — replace the entire
  buffer (used by history recall).
- `clear(self) void` — empty the buffer.
- `slice(self) []const u8` — borrow the bytes (caller must not edit
  during borrow).

### UTF-8 policy

zigline's buffer holds **valid UTF-8 only**. The behavior on invalid
input is documented:

- **Typed input** that decodes as invalid UTF-8 is dropped (the input
  layer never produces invalid sequences from key events; `KeyEvent`
  text payloads are always valid UTF-8).
- **Pasted input** that contains invalid bytes: each maximal invalid
  byte run is replaced with `U+FFFD` (the Unicode replacement
  character) at the input boundary, before reaching the buffer.
- **`replaceAll` / `insertText` callers** must pass valid UTF-8;
  passing invalid UTF-8 returns `error.InvalidUtf8` and the buffer is
  unmodified.

This is a deliberate scope limit. Shells that want to handle arbitrary
byte filenames (Linux allows non-UTF-8 paths) must escape them at the
shell layer before they reach zigline. The library does not pretend
to handle arbitrary byte data; that's a different problem.

### Grapheme integration

zigline depends on the [`zg`](https://codeberg.org/atman/zg) library
for grapheme cluster boundary detection and East Asian Width data.
The integration lives entirely in `grapheme.zig`:

```zig
pub fn segment(allocator: Allocator, bytes: []const u8) ![]Cluster;
pub fn clusterWidth(cluster_bytes: []const u8) u8;
```

Re-segmentation runs O(n) over the buffer on each edit. For human-typed
buffers (rarely > 1 KB), this is microseconds. If profiling later
shows it matters, an incremental segmenter is a v0.2+ optimization.

### Width policy

```zig
pub const WidthPolicy = struct {
    /// East Asian "ambiguous" width characters (e.g. U+00A0). False
    /// means width 1; true means width 2. Default false; `LANG=ja_JP`
    /// users typically want true.
    ambiguous_is_wide: bool = false,
    /// Display width of a TAB character. Tabs in the buffer are
    /// rendered as spaces up to the next multiple. v0.1 forbids
    /// tabs in the buffer outright (the typer can't enter one);
    /// this is a v0.2 consideration.
    tab_width: u8 = 8,
};
```

For v0.1, `WidthPolicy` exists but ambiguous-width rendering follows
a single fixed default (false). Configurable in v0.2.

---

## §4 Input model

### KeyEvent

The input layer reads from the terminal and produces typed events:

```zig
pub const Event = union(enum) {
    key: KeyEvent,
    paste: []const u8,        // bracketed paste payload
    resize,                    // SIGWINCH delivered (or polled)
    eof,                       // stdin closed
    error_: anyerror,          // fatal parse / read failure
};

pub const KeyEvent = struct {
    code: KeyCode,
    mods: Modifiers = .{},
};

pub const KeyCode = union(enum) {
    char: u21,                 // a single Unicode scalar value
    text: []const u8,          // a multi-byte text run (e.g. a paste-like burst)
    function: u8,              // F1..F12
    enter,
    tab,
    backspace,
    delete,
    escape,
    home,
    end,
    page_up,
    page_down,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    insert,
    unknown: []const u8,       // bytes we couldn't parse
};

pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};
```

### Escape sequence parsing

Real terminals emit escape sequences for arrow keys, function keys,
modified keys, and bracketed paste. The input parser is a small state
machine over byte-at-a-time reads:

- **Direct byte path.** `\x20`–`\x7e` and `\x80+` UTF-8 sequences map
  to `char` (or `text` for multi-byte clusters).
- **C0 controls.** `\x00`–`\x1f` map to named keys (Ctrl-A → `char='a'
  + ctrl`, Backspace → `backspace`, Tab → `tab`, Enter → `enter`,
  ESC → enter escape state).
- **DEL.** `\x7f` → `backspace` (terminal convention).
- **Escape state.** ESC followed by:
  - `[` → CSI sequence, parse parameters until final byte
  - `O` → SS3 sequence, parse single final byte (function keys on
    some terminals)
  - any other char → Alt-modified key
  - timeout or stand-alone ESC → `escape` key event
- **CSI sequences** to parse:
  - `\x1b[A`–`\x1b[D` → arrows
  - `\x1b[1;5D` → arrow with modifiers
  - `\x1b[H`, `\x1b[F` → Home/End
  - `\x1b[3~` → Delete
  - `\x1b[5~`, `\x1b[6~` → PageUp/Down
  - `\x1b[1~`, `\x1b[7~` → Home; `\x1b[4~`, `\x1b[8~` → End
  - `\x1b[200~` ... `\x1b[201~` → bracketed paste payload
  - unknown CSI → emit `KeyCode.unknown` with the full sequence

The parser must tolerate partial sequences (read returns mid-sequence)
by buffering and returning to the read loop.

### UTF-8 input decoding

Multi-byte UTF-8 input is **decoded at the input layer**, not byte-by-byte
inserted into the buffer. The parser:

1. Reads first byte; if `< 0x80`, emits `char` and returns.
2. If `0x80–0xbf` (continuation byte without start), drops it (invalid
   start; emit nothing).
3. If `0xc2–0xf4` (valid start), reads expected continuation bytes;
   emits `char: u21` if the resulting code point is valid Unicode and
   not a surrogate; otherwise drops.
4. Pasted runs of valid UTF-8 may be coalesced into `text: []const u8`
   for efficiency.

### Bracketed paste

zigline enables bracketed paste mode (`\x1b[?2004h`) when entering
raw mode and disables it on exit. The input parser recognizes the
paste markers and emits a single `paste` event with the unescaped
payload.

The application policy decides what to do with paste:
- `accept` mode (default) — paste is inserted into the buffer at
  cursor; embedded newlines become spaces.
- `multiline` mode — paste with newlines submits each line in
  sequence (v0.2+; not in v0.1 surface).
- `raw` mode — paste is inserted including newlines; the application
  is responsible for re-prompting (v0.2+).

For v0.1, only `accept` ships.

### Resize

The library does not install its own SIGWINCH handler by default
(that's application policy, and zigline is embedded). Instead, the
renderer queries terminal size on every render via `TIOCGWINSZ`. If
the terminal width changed since the last render, the renderer
forces a full repaint and resets `last_rows`/`last_cursor_row`.

If the application wants explicit resize events, it can install a
SIGWINCH handler that calls `Editor.notifyResize()` — the editor sets
a flag the next render checks. Optional, not required.

---

## §5 Action model

The keymap maps `KeyEvent → Action`. The editor executes actions.
Splitting these lets keymaps be tested against a fixed action set,
and lets applications customize keybindings without touching editor
internals.

```zig
pub const Action = union(enum) {
    // text editing
    insert_text: []const u8,
    delete_backward,
    delete_forward,
    kill_to_start,
    kill_to_end,
    kill_word_backward,
    kill_word_forward,

    // cursor movement
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_to_start,
    move_to_end,

    // history
    history_prev,
    history_next,

    // completion
    complete,

    // line lifecycle
    accept_line,        // submit the current buffer
    cancel_line,        // discard buffer, return interrupt to caller
    eof,                // signal EOF (Ctrl-D on empty buffer)

    // display
    clear_screen,
    redraw,

    // future-extensible escape hatch — applications can define their
    // own actions via a separate `custom: u32` channel mapped via
    // app-supplied keymap entries (v0.2).
};
```

### Action dispatch contract

`Editor.dispatch(action: Action) !DispatchOutcome` is the single
internal entry point that mutates editor state in response to an
action. It returns one of:

```zig
pub const DispatchOutcome = union(enum) {
    /// Action was applied; continue the read loop.
    continue_,
    /// Line was accepted; readLine should return it.
    accepted: []u8,
    /// Line was cancelled (Ctrl-C); readLine should return interrupt.
    cancelled,
    /// Caller signaled EOF on empty buffer.
    eof,
};
```

Dispatch handles the line-lifecycle terminals (`accept_line`,
`cancel_line`, `eof`) — those don't mutate buffer state in a normal
way; they end the read.

### §5.1 Keymap and binding-table (v1.0)

The v0.x `Keymap` is a single function pointer:

```zig
pub const Keymap = struct {
    lookupFn: *const fn (KeyEvent) ?Action,

    pub fn lookup(self: Keymap, key: KeyEvent) ?Action {
        return self.lookupFn(key);
    }

    pub fn defaultEmacs() Keymap { ... }
};
```

This shape stays exactly as is — STABILITY.md commits to it. The v1.0
binding-table is an **additive** overlay, optional, opt-in:

```zig
pub const Keymap = struct {
    lookupFn: *const fn (KeyEvent) ?Action,
    /// Optional multi-key binding overlay. Consulted before
    /// `lookupFn`. `null` preserves v0.x behavior exactly.
    bindings: ?*BindingTable = null,
    ...
};
```

When `bindings` is non-null, dispatch consults it first (see §5.2);
the legacy `lookupFn` is the fall-through for unbound single keys.
This composes cleanly with the consumer-side fall-through pattern
slash already uses: their `keymapLookup` returns `?Action`, falling
through to `defaultEmacs()` for anything they didn't bind.

```zig
/// Mutable storage for `[]KeyEvent → Action` bindings, including
/// multi-key sequences. Owned by the application; passed to
/// `Keymap.bindings`. Not allocator-tied to the editor — apps can
/// reuse one binding-table across multiple editor instances.
pub const BindingTable = struct {
    pub fn init(allocator: Allocator) BindingTable;
    pub fn deinit(self: *BindingTable) void;

    /// Bind a sequence to an action. Last bind wins on conflict;
    /// no error is returned if `seq` shadows an existing binding.
    /// Returns the previous action if any (for "save and restore"
    /// patterns).
    pub fn bind(
        self: *BindingTable,
        seq: []const KeyEvent,
        action: Action,
    ) !?Action;

    /// Remove a binding. Returns true if a binding was removed,
    /// false if `seq` wasn't bound.
    pub fn unbind(self: *BindingTable, seq: []const KeyEvent) bool;

    /// Resolve a sequence against the binding-table.
    pub fn lookup(
        self: *const BindingTable,
        seq: []const KeyEvent,
    ) Result;

    pub const Result = union(enum) {
        /// No binding starts with this prefix. Editor falls back to
        /// the legacy `lookupFn` for the first event in the sequence
        /// and re-processes the remainder.
        none,
        /// One or more bindings start with this prefix; no exact
        /// match yet. Editor buffers and waits for the next event.
        partial,
        /// Exact match. Editor dispatches the action and clears the
        /// pending buffer.
        bound: Action,
    };
};
```

**Key sequences as `[]const KeyEvent`.** No string-grammar parser
in the v1.0 surface (e.g., no `KeySequence.parse("C-x C-e")` helper).
Apps build sequences with literal `KeyEvent` values; the keymap-
configuration layer is the app's responsibility. Adding a parser is
a v1.x non-breaking addition if demand surfaces.

**Storage is implementation detail** — a radix-trie keyed by
encoded `KeyEvent` (per `rustyline/src/binding.rs::encode`) is the
expected default, but the API contract is the `Result` enum, not the
storage shape.

**Mutability.** `bind`/`unbind` are mutators. Apps may rebind
between `readLine` calls. The dispatcher reads the table during a
`readLine`; mutating during `readLine` is undefined. Single-thread
expectation; no locks. The `BindingTable` doc-comment in `keymap.zig`
states this explicitly so future embedders don't accidentally
violate it.

**Discovery.** Out of scope for v1.0. Apps that need to dump
bindings (F1 help overlay, etc.) keep their own bookkeeping;
`BindingTable` is write-then-read, not introspectable.

**Not in scope (the discipline that keeps this from sloping):**

- Modal keymaps. Vi-mode insert vs normal stays a separate
  `FUTURE.md` feature; the binding-table doesn't make it easier or
  harder.
- Keyboard macros / chord recording. Separate concept.
- inputrc-style config file parsing. Apps build their own parser
  if they want one.
- Layered/stacked keymaps with priority. Apps compose by chaining
  fall-through functions, as slash already does.
- Conflict-resolution UI. Last-bind-wins, no warnings.
- Runtime thread-safety. Single-thread expectation, documented.

If any of those become real requests post-v1.0, they ship as
separate features. The binding-table itself is bounded.

### §5.2 Dispatch state machine for multi-key sequences

When `Keymap.bindings != null`, the dispatch loop maintains a
small per-`readLine` event buffer:

```zig
pending_keys: std.ArrayListUnmanaged(KeyEvent) = .empty,
```

**Precedence: bindings first, lookupFn as fallback.** When both are
set and a binding sequence starts with the same key as a `lookupFn`
single-key action, the binding-table wins for that prefix. The
`lookupFn` is consulted only when:

- the buffered prefix is exactly one event long AND the binding-
  table reports `.none` (no multi-key binding starts with this
  event), OR
- the buffered prefix is being replayed after a `.none` mismatch
  (the first event of the failed sequence is dispatched via
  `lookupFn`).

Practical implication: a key K cannot simultaneously trigger a
single-key action (via `lookupFn`) AND start a multi-key sequence
(via `bindings`). Apps with a prefix key choose one role for it.
This matches readline / emacs / bash. (A configurable chord-
resolve timeout would let K mean both depending on what comes
after; that's deferred to post-v1.0 — see `FUTURE.md`.)

On each `KeyEvent`:

1. **Append** the event to `pending_keys`.
2. **Lookup** `bindings.lookup(pending_keys.items)`:
   - `.bound = action` → dispatch `action`, clear `pending_keys`.
   - `.partial` → continue (wait for next event).
   - `.none` →
     - If `pending_keys.len == 1`: this single event has no multi-
       key binding. Fall through to `lookupFn(event)` for the legacy
       single-key path. Dispatch any returned action. Clear
       `pending_keys`.
     - If `pending_keys.len > 1`: the buffered prefix didn't
       resolve. Dispatch the **first** event via `lookupFn` (as a
       singleton), then **re-process** the remaining events through
       this state machine. Clear `pending_keys` only after replay
       completes. (Matches readline's "abandoned chord" behavior;
       preserves user input — a binding miss never silently drops
       keystrokes.)

**Non-key events resolve partial sequences as singletons.**
Bracketed paste, resize, EOF, error — none of these can extend a
key chord. If `pending_keys` is non-empty when one arrives:

1. Resolve the buffered prefix as if a non-matching key had
   arrived (the `.none` + `len > 1` branch above).
2. Then process the non-key event normally.

**Timeout policy.** None in v1.0. The editor waits indefinitely for
the next event after a `.partial`. Bash and emacs do the same;
configurable timeout is post-v1.0 (already in `FUTURE.md` as
`Options.timeouts.chord_resolve_ms`).

**Interaction with `quoted_insert` (`Ctrl-V`/`Ctrl-Q`).**
`quoted_insert` is a single-key action that flips `Editor.quoted_
insert_pending`. The next event bypasses *both* the binding-table
and `lookupFn` and is inserted literally. If `quoted_insert_pending`
is set when the next event arrives, the binding-table is not
consulted; `pending_keys` is cleared.

**Interaction with `Action.custom`.** Custom actions are bound
exactly like built-in actions: `table.bind(seq, .{ .custom = 7 })`.
The dispatcher resolves the sequence then routes to
`handleCustomAction(7)` as it does today for single-key custom
bindings.

**Memory bound on `pending_keys`.** Capped at 8 events. Beyond
that, the buffer is force-resolved as singletons-and-replay (same
as `.none + len > 1`). No real keymap binds sequences longer than
3-4 events; the cap is paranoia.

**Cooked-mode fallback.** No keymap; the binding-table is not
consulted. Cooked-mode reads delegate to the kernel discipline.

### §5.3 Migration path for existing consumers

Consumers on v0.x `Keymap` (function pointer only) keep working
unchanged. The new field defaults to `null`; opting in is explicit:

```zig
// v0.x — still works in v1.0:
var editor = try Editor.init(alloc, .{
    .keymap = .{ .lookupFn = myLookup },
});

// v1.0 — multi-key bindings:
var bindings = BindingTable.init(alloc);
defer bindings.deinit();
_ = try bindings.bind(&[_]KeyEvent{
    .{ .code = .{ .char = 'x' }, .mods = .{ .ctrl = true } },
    .{ .code = .{ .char = 'e' }, .mods = .{ .ctrl = true } },
}, .{ .custom = ACTION_EDIT_IN_EDITOR });

var editor = try Editor.init(alloc, .{
    .keymap = .{
        .lookupFn = myLookup,
        .bindings = &bindings,
    },
});
```

No breaking changes; `lookupFn` semantics preserved verbatim.

---

## §6 Render model

### v0.1 — full repaint

Inherited from slash's working algorithm, with grapheme-aware width
and contained row clearing:

```
1. Query terminal width via TIOCGWINSZ (fall back to 80).
2. From state saved by the previous render, climb back to the top
   row of the prior render block:
     - emit \x1b[Nx;A] to move up N rows (N = last_cursor_row)
     - emit \r to column 0
3. Clear the prior render block, row by row:
     - for each prior row:
       - emit \x1b[K (clear to EOL)
       - emit \x1b[B (cursor down) if not last row
     - climb back up to top
   The \x1b[K-per-row pattern is more contained than \x1b[J (which
   clears through end of screen) — important when the application
   has output below the prompt.
4. Write the prompt bytes (already display-width-counted by caller).
5. Write the buffer:
   - walk clusters from byte 0 to byte_len
   - for each cluster, emit any color/style changes (from highlight
     spans), then the cluster bytes
   - reset SGR state at end
6. Phantom newline edge case: if total display columns is an exact
   multiple of terminal width, emit \n\r so the cursor's logical
   row matches the terminal's view.
7. Move cursor from end position to desired (cursor_row, cursor_col).
8. Save new last_rows, last_cursor_row.
```

### v0.1 — width math

```
total_cols      = prompt.width + sum(cluster.width for c in clusters)
new_rows        = max(1, ceil_div(total_cols, term_cols))
cursor_pos_cols = prompt.width + sum(cluster.width for c in clusters[0..cursor_cluster_idx])
new_cur_row     = cursor_pos_cols / term_cols
new_cur_col     = cursor_pos_cols % term_cols
```

`prompt.width` is provided by the caller in the `Prompt` value, so
escapes in the prompt don't break the math.

### v0.2 — row-granular diff

A row-level diff is the next milestone, not v0.1. The architecture
described in this spec is designed to make it tractable: `Renderer`
maintains a "previous frame" as a vector of `RenderRow` values, and
the new frame is computed independently. The diff is per-row:

- unchanged row → no output
- changed row → cursor to row start, full row write, `\x1b[K`
- removed rows → clear them
- added rows → write them at the bottom

Cell-level diff (the readline approach) is v0.3+ if profiling shows
need.

### What the renderer doesn't emit

- Application output (stdout / stderr from the user's commands). The
  renderer owns the **prompt + input line + completion menu** rows
  only.
- Cursor visibility toggles (`\x1b[?25l` / `\x1b[?25h`). The renderer
  may use these around its repaint to suppress flicker, but they
  always pair.
- Alt-screen entry/exit. Not in v0.1; reserved for v0.2 completion
  menus that need scrolling.

### Highlight integration

Highlight spans come from the application via a hook. The renderer
applies them during step 5:

```zig
pub const HighlightSpan = struct {
    /// Inclusive byte offsets into the buffer.
    start: usize,
    end: usize,
    style: Style,
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,
};

pub const Color = union(enum) {
    /// 8-color basic palette (black, red, green, yellow, blue,
    /// magenta, cyan, white) — broadest terminal compat.
    basic: enum { black, red, green, yellow, blue, magenta, cyan, white },
    /// Bright variant of a basic color.
    bright: enum { black, red, green, yellow, blue, magenta, cyan, white },
    /// 256-color palette index (0..255).
    indexed: u8,
    /// 24-bit truecolor.
    rgb: struct { r: u8, g: u8, b: u8 },
};
```

The renderer:
1. Sorts spans by `start`, validates non-overlapping (overlap is
   invalid; renderer logs and ignores the later span).
2. Validates each `start`/`end` is a cluster boundary (else logs and
   clamps to nearest boundary).
3. Walks clusters; at each span boundary, emits the SGR transition.
4. Resets SGR at end of buffer.

Applications that prefer the easier "raw ANSI" path can use a
convenience adapter `highlight.rawAnsiHook` that wraps an
ANSI-emitting function and returns it as a single-span no-op
(rendering ANSI passthrough). This is documented as a foot-gun and
discouraged; the spans API is primary.

---

## §7 Public API

### The `Editor` type

```zig
pub const Editor = struct {
    pub fn init(allocator: Allocator, options: Options) !Editor;
    pub fn deinit(self: *Editor) void;

    /// Read one logical line. Blocks until accept / cancel / eof.
    /// The returned slice is allocator-owned; caller frees on success.
    pub fn readLine(self: *Editor, prompt: Prompt) !ReadLineResult;

    /// Application hook to signal a terminal resize from a SIGWINCH
    /// handler. Optional — renderer queries TIOCGWINSZ each render.
    pub fn notifyResize(self: *Editor) void;
};

pub const ReadLineResult = union(enum) {
    line: []u8,
    eof,
    interrupt,
};

pub const Options = struct {
    /// Defaults to STDIN_FILENO; tests can pass a PTY slave fd.
    input_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    output_fd: std.posix.fd_t = std.posix.STDOUT_FILENO,

    /// Owns raw-mode lifecycle? Default yes; pass `.disabled` if the
    /// caller has already entered raw mode.
    raw_mode: RawModePolicy = .enter_and_leave,

    /// Optional persistent history. Caller-owned.
    history: ?*History = null,

    /// Keybindings. Defaults to emacs-style.
    keymap: Keymap = Keymap.defaultEmacs(),

    /// Optional callbacks.
    completion: ?CompletionHook = null,
    highlight: ?HighlightHook = null,

    /// Width handling.
    width_policy: WidthPolicy = .{},

    /// Bracketed paste behavior.
    paste: PastePolicy = .accept,
};

pub const RawModePolicy = enum {
    enter_and_leave,
    assume_already_raw,
    disabled,
};

pub const PastePolicy = enum {
    accept,
};
```

### The `Prompt` type

```zig
pub const Prompt = struct {
    /// The prompt's printable bytes, including any embedded ANSI
    /// escape sequences. May be multi-byte UTF-8.
    bytes: []const u8,
    /// Display width in terminal cells. Caller computes this; for
    /// pure-ASCII prompts it equals `bytes.len`.
    width: usize,

    pub fn plain(bytes: []const u8) Prompt {
        return .{ .bytes = bytes, .width = bytes.len };
    }

    /// Helper for the common case: caller has UTF-8 bytes with no
    /// embedded ANSI; library computes width via grapheme.
    pub fn fromUtf8(bytes: []const u8) !Prompt;
};
```

### The hook types

```zig
pub const CompletionHook = struct {
    ctx: *anyopaque,
    completeFn: *const fn (
        ctx: *anyopaque,
        allocator: Allocator,
        request: CompletionRequest,
    ) anyerror!CompletionResult,
};

pub const CompletionRequest = struct {
    /// Snapshot of the buffer at hook-call time.
    buffer: []const u8,
    /// Cursor byte offset.
    cursor_byte: usize,
};

pub const CompletionResult = struct {
    /// Byte range in the buffer to replace with one of `candidates`.
    /// Must be a valid grapheme range; cluster-aligned.
    replacement_start: usize,
    replacement_end: usize,
    /// Candidates, allocator-owned (the same allocator passed to
    /// completeFn). The editor frees them after use.
    candidates: []Candidate,
};

pub const Candidate = struct {
    /// The text to insert if this candidate is chosen.
    insert: []const u8,
    /// Optional display label (defaults to `insert`). Useful for
    /// command-name completion where the inserted form differs from
    /// the displayed form.
    display: ?[]const u8 = null,
    /// Optional one-line description shown in the menu.
    description: ?[]const u8 = null,
    /// Optional kind hint for menu styling (file, dir, command, var).
    kind: CandidateKind = .plain,
    /// Character to append after insertion (e.g. '/' for directories,
    /// ' ' for completed commands).
    append: ?u8 = null,
};

pub const CandidateKind = enum { plain, file, directory, command, variable };

pub const HighlightRequest = struct {
    /// Snapshot of the buffer at hook-call time. Borrowed; valid
    /// only for the duration of `highlightFn`.
    buffer: []const u8,
    /// Cursor byte offset. Always at a grapheme cluster boundary.
    /// Cursor-sensitive highlights — bracket matching, current-word
    /// emphasis, unclosed-string warnings — read this field.
    cursor_byte: usize,
};

pub const HighlightHook = struct {
    ctx: *anyopaque,
    highlightFn: *const fn (
        ctx: *anyopaque,
        allocator: Allocator,
        request: HighlightRequest,
    ) anyerror![]HighlightSpan,
};
```

`HighlightRequest` mirrors `CompletionRequest` and
`CustomActionRequest`. The struct shape is the long-term shape: new
optional fields (terminal width, render column, in-flight action
info) ship as v0.x non-breaking additions when needed.

### Error model

For v0.1, hooks return `anyerror`; library entry points return
domain-specific error sets:

```zig
pub const InitError = error{ OutOfMemory, NotATty, TermiosFailed, ... };
pub const ReadLineError = error{ ReadFailed, InvalidUtf8, OutOfMemory, ... };
```

`anyerror` from a hook is propagated through `readLine` as
`ReadLineError.HookFailed`. The editor logs the original via an
optional `Options.diagnostic_fn` (v0.2 — for v0.1, errors are
swallowed with the hook's failure mode being "no candidates" or
"no spans").

### Allocator contract

- `Editor` is parameterized on a single allocator; that allocator
  backs the buffer, history (if owned), and any temporary scratch.
- Hooks receive an allocator from the editor that's valid until the
  next hook invocation. Hook-allocated values are freed by the editor
  after use.
- Returned `line` from `readLine` is allocated from `Editor`'s
  allocator. Caller frees.

### Threading model

- `Editor` is not thread-safe. One thread per editor instance.
- The editor blocks on `read` from `input_fd`. Async support is a
  v0.2+ design.

---

## §8 History

```zig
pub const History = struct {
    pub fn init(allocator: Allocator, options: HistoryOptions) !History;
    pub fn deinit(self: *History) void;

    /// Append a line. Dedup policy applied per `options.dedupe`.
    pub fn append(self: *History, line: []const u8) !void;
    /// Persist any unflushed entries to disk (called on each append
    /// by default; controllable via options).
    pub fn flush(self: *History) !void;

    /// Cursor navigation; `current` is the user's in-progress edit
    /// for snapshot/restore on Down past the end.
    pub fn previous(self: *History, current: []const u8) ?[]const u8;
    pub fn next(self: *History) ?[]const u8;
    pub fn resetCursor(self: *History) void;
};

pub const HistoryOptions = struct {
    /// Path to the persistent history file. Null means in-memory only.
    path: ?[]const u8 = null,
    /// Maximum entries kept in memory. Older entries are pruned on
    /// flush. Zero means unbounded.
    max_entries: usize = 1000,
    /// Duplicate handling.
    dedupe: enum {
        none,        // every line appended verbatim
        adjacent,    // skip exact duplicate of last line
        all,         // remove earlier matches when a duplicate appends
    } = .adjacent,
};
```

The persistent format is one line per entry, plain text, UTF-8.
v0.1 does not store metadata (timestamp, exit code, cwd); a
metadata-rich format is a v0.2+ option.

---

## §9 Termios and signals

### Raw-mode lifecycle

`Terminal.enterRawMode` saves current termios, applies:

- `ICANON` off (byte-at-a-time)
- `ECHO` off (the renderer echoes)
- `ISIG` **off** — Ctrl-C/Ctrl-Z arrive as bytes (0x03, 0x1a) so the
  editor's keymap can map them to `cancel_line` / app-defined
  actions. This is the right default for a line editor: the typical
  app wants Ctrl-C to clear the in-progress line, not to kill the
  process. Shells that genuinely need kernel signal delivery (so
  SIGINT can interrupt blocking child syscalls in their pipeline)
  opt in via `signal_policy` (v0.2).
- `IXON` off (Ctrl-S/Ctrl-Q don't suspend output)
- `ICRNL` off (CR not auto-translated to NL on input)
- `MIN=1`, `TIME=0` (read returns as soon as 1 byte is available)

Bracketed paste mode is enabled (`\x1b[?2004h`).

`Terminal.leaveRawMode` restores the saved termios and disables
bracketed paste.

### Signal policy

zigline does not install signal handlers by default. The application
installs whatever it wants:

- A shell wants SIGINT to interrupt blocking reads (so the editor's
  read returns EINTR and the buffer clears).
- A REPL embedded in another program may want SIGINT to terminate.

If the application wants help, an opt-in `Options.signal_policy =
.shell_friendly` installs:

- SIGINT: no-op handler (so read() returns EINTR; the editor clears
  the in-flight buffer and emits a fresh prompt).
- SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU: ignored (so terminal-generated
  signals don't suspend the shell from the prompt).
- SIGWINCH: optional handler that flags `notifyResize`.

For v0.1, only `.none` (no handlers) and `.shell_friendly` are
defined.

### Recovery on panic

Raw mode is restored via `defer raw.leave()` in `readLine`. The
library does not install a panic handler — that's caller policy.
If the caller cares about restoring termios on panic, they can wrap
the editor in their own recovery:

```zig
defer terminal.leaveRawMode();
const result = try editor.readLine(prompt);
```

(Note: `Editor.readLine` already does this internally; the example
above is for callers using lower-level Terminal APIs directly.)

---

## §10 Testing strategy

### Layers

1. **Unit tests** — per-module in `src/<module>.zig` test blocks.
   Covers buffer edits, grapheme segmentation, width math, key
   parser, action dispatch, history dedup. No PTY required.
2. **PTY-driven tests** — in `tests/pty_tests.zig`. A test harness
   forks a child process running an example zigline program, hooks
   up a pseudo-terminal, drives keystrokes through the master end,
   asserts on the rendered output. Mirrors slash's PTY harness.
3. **Property tests** (v0.2+) — for the renderer: arbitrary buffers
   + arbitrary cursor positions + arbitrary terminal widths should
   produce output that, when consumed by a virtual terminal, places
   the cursor at the expected (row, col).

### What must be tested in v0.1

- **Buffer:** insert / delete at boundaries / over multibyte text
  (incl. `é`, `あ`, ZWJ emoji `👨‍👩‍👧`, regional indicators `🇯🇵`).
- **Cursor:** moves stop at cluster boundaries; right-at-end is no-op.
- **Width math:** total_cols and cursor_pos under varied content.
- **Key parser:** every CSI sequence in §4, plus partial-read
  resilience (sequence split across two read calls).
- **Renderer:** repaint produces correct output for one-row, exact-
  width, and wrapped buffers.
- **History:** dedup variants, cursor save/restore on Up/Down.
- **End-to-end PTY:** echo, line entry, history recall, completion
  insert, Ctrl-C cancel, Ctrl-D EOF.

### CI

`zig build test` runs all unit + PTY tests. PTY tests skip cleanly
on platforms without `posix_openpt` (we target macOS + Linux).

---

## §11 Versioning and stability

### v0.1 scope

Everything required to replace slash's embedded line editor with
zigline and have slash work strictly better than today (UTF-8 width
correct, bracketed paste, cleaner internal API). v0.1 is the
scaffolded API + lifted code, not a polish target.

### v0.2 scope

The two named blockers between zigline-as-it-ships-today and a
real v1.0 commitment. Both are concrete features with reference
implementations in `misc/`; both are bounded scope.

- ✅ **Binding-table API on `Keymap`** (§5.1, §5.2) — shipped in
  v0.2.0. Multi-key sequences (`Ctrl-X Ctrl-E`, `Ctrl-X Ctrl-X`,
  etc.) via the optional `BindingTable` overlay; `Keymap.lookupFn`
  shape preserved.
- ✅ **One real-world consumer release cycle** — slash 1.0.0
  shipped with zigline v0.1.5 embedded; v0.1.6 + v0.2.0 land into
  slash via the same path-dep mechanism with no observed
  regressions.
- ⏳ **Multi-column completion menu UI**. Replaces the v0.x single-
  line space-separated placeholder with a columnar layout sized
  to terminal width, paged for overflow, keyboard-navigable.
  Reference: `reedline/src/menu/columnar_menu.rs::create_string`.
  We lift the layout math; we don't lift the trait abstraction
  (zigline ships one menu type, not three).

### v0.x continuing additions (non-breaking)

These ship in v0.1.x and v0.2.x as they're written. Each is
additive and obeys the v1.0 stability surface in `STABILITY.md`.

- Row-granular diff renderer.
- Configurable `WidthPolicy` (ambiguous-width policy wired
  through to the segmenter).
- Validator hook ("is this expression complete?").
- Hints / fish-style autosuggestions (renders through the
  existing `HighlightHook`).
- Mask mode for password input.
- `Editor.preloadBuffer` helper.
- Brace-matching highlight helper as a built-in `HighlightHook`.
- Per-`Options` knobs for completion behavior (double-tab,
  immediate, beep-on-ambiguous, count-cutoff).
- `Editor.print` / `printAbove` for async-safe output above the
  prompt; `Editor.asyncStop` for cross-thread interrupt.

These don't gate v1.0 — they ship as ready and the version bumps
as they land. v1.0 = v0.x + binding-table + menu + slash release
cycle done.

### v1.0 surface freeze

When the three v0.2 items above are done, we tag v1.0.0. From that
point on:

- Symbols listed in `STABILITY.md` are locked: removing a public
  symbol, changing a signature, adding a required field, or
  adding a tagged-union variant requires a v2.0 major bump.
- Behavior documented in this SPEC is binding. Changing observable
  behavior (cursor lands at end vs middle, `:cq` triggers no_op
  vs accept_line, etc.) requires a v2.0 bump.
- The `STABILITY.md` "experimental in v1.x" set (e.g.
  `Diagnostic.Kind` variants, `KillRing`/`Changeset` internals)
  may evolve in minor releases.

### v0.3 and beyond (post-v1.0)

- Cell-level diff renderer (if profiling justifies).
- Multi-line text-area mode (cursor moves between rows of a buffer
  containing `\n`).
- vi-mode keymap. Builds on the binding-table primitive.
- Async completion.
- Mouse support.
- Reverse-incremental history search (Ctrl-R UI).
- Visual selection.
- Configurable parser timeouts (including chord-resolution
  timeout for the binding-table state machine).
- Theme system / config.
- Multiplexing API (`editStart`/`editFeed`/`editStop`) for
  applications integrating zigline into their own event loop.

### Stability promises

- v0.x: no compatibility promises. The API will move (within the
  shape documented in `STABILITY.md`).
- v1.0: SemVer applies. Breaking changes require a major bump.
- The SPEC.md document is part of the API contract: behavior
  documented here is binding from v1.0 onward.

---

## §12 Out of scope for v0.1

Stated explicitly so an implementer doesn't have to guess:

- Diff-based redisplay (full repaint only).
- vi-mode, modal editing.
- Multi-line text-area mode (single logical line per readLine).
- Async completion / completion-while-typing.
- Mouse input.
- Alt-screen for completion menus.
- Customizable themes / color palettes (single fixed palette).
- Screen-reader / accessibility hooks.
- Windows native (POSIX only; WSL inherits Linux).
- C ABI / FFI surface.
- History search modes (Ctrl-R reverse-incremental search).
- Customizable word-boundary policy.
- Tab in the buffer (typing Tab triggers completion, never inserts).
- Bracketed-paste modes other than `accept`.
- Application-defined custom actions.

These are tracked for v0.2+ in the FUTURE.md (created during v0.1
implementation).

---

## §13 Repo skeleton

```
zigline/
├── .gitignore
├── LICENSE                  # MIT
├── README.md                # one-paragraph what + how
├── SPEC.md                  # this document
├── FUTURE.md                # deferred items, v0.2+ tracker
├── build.zig                # builds lib + examples + tests
├── build.zig.zon            # package manifest; depends on `zg`
├── src/
│   ├── root.zig
│   ├── editor.zig
│   ├── buffer.zig
│   ├── grapheme.zig
│   ├── input.zig
│   ├── keymap.zig
│   ├── actions.zig
│   ├── renderer.zig
│   ├── terminal.zig
│   ├── history.zig
│   ├── completion.zig
│   ├── highlight.zig
│   └── prompt.zig
├── examples/
│   ├── minimal.zig
│   ├── with_history.zig
│   ├── with_completion.zig
│   └── with_highlight.zig
└── tests/
    └── pty_tests.zig
```

### Dependencies

- **zg** ([codeberg.org/atman/zg](https://codeberg.org/atman/zg)) —
  Unicode grapheme + width data. Pinned at v0.13 or current
  compatible version.

No other dependencies. v0.1 targets Zig 0.16.

---

## §14 Implementation notes (extraction hazards from slash)

The slash editor is a working prototype but several behaviors must
**not** carry forward into zigline:

- **Byte-stepping cursor.** `editor.cursor += 1` after a typed byte
  breaks multi-byte UTF-8. Replace with `buffer.moveRightCluster`
  driven by the action dispatcher.
- **Sentinel return bytes.** `0x03` for Ctrl-C / `0x04` for Ctrl-D
  in the slash `readLine` becomes the typed `ReadLineResult` union.
- **Hardcoded fd 0/1.** Replace with `Options.input_fd`/`output_fd`.
- **Prompt byte length as width.** `self.prompt.len` becomes
  `prompt.width` (caller-computed).
- **Raw ANSI from highlighter.** Slash's highlighter emits SGR
  directly. zigline highlighter returns spans; renderer emits SGR.
- **Bracket of `\x01..\x02`** for non-printable spans in the prompt.
  Don't use this; `Prompt.width` is the correct API.
- **Naive escape parsing.** Slash reads 2 bytes after ESC and stops.
  Replace with a proper CSI / SS3 / paste state machine.
- **Heuristic completion context detection.** Slash's
  `identifyCompletionContext` walks back through buffer bytes.
  zigline's `CompletionHook` returns explicit replacement ranges;
  the application owns context.
- **`std.c.write` direct calls without partial-write loop.** Replace
  with a `writeAll` helper that loops on EINTR / partial writes.
- **`u32` for byte offsets.** Use `usize` throughout the public API.
- **History dedup that persists duplicates anyway.** The slash code
  has a logic bug here. Define and test the dedup contract.

---

## §15 Implementation order

A suggested order that keeps the project compilable end-to-end at
each step:

1. **Skeleton.** Create `src/root.zig` with public re-exports and
   stubs for every module. `build.zig`, `build.zig.zon`. Add `zg`
   dependency. Verify `zig build` succeeds.
2. **Buffer + Grapheme.** Implement `Buffer` and `grapheme.zig`.
   Unit tests for cluster boundaries and width.
3. **Input.** Key parser. Unit tests for every CSI sequence.
4. **Terminal.** Raw mode, size query, bracketed paste enable/disable.
5. **Renderer.** Full repaint with the §6 algorithm. Unit tests for
   width math; PTY tests for output.
6. **Keymap + Actions.** Default emacs keymap. Action dispatcher in
   `Editor`.
7. **History.** Append/dedup/persist; navigation cursor.
8. **Editor.** Wire it all together. Top-level `readLine`.
9. **Completion + Highlight hook plumbing.** With one example each.
10. **Examples.** `minimal.zig`, `with_history.zig`,
    `with_completion.zig`, `with_highlight.zig`.
11. **PTY tests.** Port slash's PTY harness; add UTF-8 / wrap /
    bracketed paste cases.
12. **README polish.** One paragraph + a 20-line code sample.
13. **Slash adapter.** Replace slash's `repl.zig` with a thin wrapper
    that registers slash's highlighter + completer with zigline.
    Ship it.

---

## §16 The one rule

When in doubt, ask:

> Does this change improve correctness on the user-visible surface,
> the ergonomics of the public API, or the testability of the
> codebase?

If the answer is no on all three, do not build it. If it's yes on
one and no on the other two, write down why the trade is worth it in
the commit message.
