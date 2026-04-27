# zigline — Future work

Items deferred from v0.1, captured so they're not lost. As items ship,
delete them from this file. When the file is empty, all the deferred
work is done.

This file is a complement to SPEC.md, not a replacement. SPEC §11 lists
the high-level milestones (v0.1 / v0.2 / v0.3); this file is the
concrete bullet list.

> Items are flat bullets — no numbering, ship in whichever order makes
> sense. As items ship, **delete the bullet** in the same commit.

## Renderer

- **Row-granular diff renderer.** Track the previous frame as a
  `[]RenderRow`; on next render, diff per-row and emit only the
  changed rows. Unchanged rows skip output entirely. SSH-friendly,
  flicker-free. Architecture is in place via `last_rows` /
  `last_cursor_row`; this is the natural v0.2 milestone.
- **Cell-level diff renderer.** Only if profiling shows row-granular
  is insufficient.
- **Cursor visibility hide/show around repaint.** `\x1b[?25l` / `\x1b[?25h`
  to suppress cursor flicker during multi-step repaints.

## Input

- **Bracketed paste with newline payloads.** `PastePolicy.multiline`
  splits the paste into accepted lines. `PastePolicy.raw` returns
  the paste as a single line including newlines.
- **Modified-key parsing.** Ctrl-Left / Alt-. / Shift-Tab variants
  via the CSI 1;mod sequences.
- **Mouse input.** SGR mouse mode (`\x1b[?1006h`) for click-to-position-
  cursor.
- **Configurable parser timeouts.** ESC / CSI body / UTF-8
  continuation timeouts are hardcoded at 50ms. Cross-network terminals
  with packetization delays >50ms misread CSI sequences as bare ESC.
  Surface the three values via `Options.timeouts` (sub-struct so
  they evolve independently).

## Editor / UX

- **vi-mode keymap.** Modal editing with normal/insert/visual states.
  Reference: `readline/vi_mode.c` for the state machine, `rustyline/src/keymap.rs`
  + `command.rs` for the cleaner Rust factoring.
- **Reverse-incremental history search.** Ctrl-R style overlay UI
  with separate search prompt, failed-search retention, repeat-Ctrl-R
  for older matches, Ctrl-G abort with line restore. Reference:
  `readline/isearch.c`.
- **Frecency history sort.** Frequency × recency weighted ranking
  for history navigation, especially for fzf-style history overlays.
- **History metadata.** Timestamp, exit code, cwd, duration per entry.
  Requires a richer file format than one-line-per-entry.
- **Multi-line text-area mode.** Buffer can contain `\n`; cursor
  moves between rows of one logical entry. Useful for pasting code
  blocks into a REPL. Requires bigger render rework.
- **Validator hook.** "Is this expression complete?" callback so a
  REPL can decide whether Enter accepts the line or inserts a newline.
  Pairs with multi-line text-area mode. Reference: `rustyline/src/validate.rs`,
  `reedline/src/validator/`.
- **Hints (ghost text).** Right-of-cursor suggestion rendering. Fish-
  style. Reference: `reedline/src/hinter/`.
- **Undo / redo.** Emacs `C-_` and vi `u`. Reference: `rustyline/src/undo.rs`.
- **Kill ring with `M-y` yank-pop.** Multi-slot kill history; current
  Ctrl-W / Ctrl-U / Ctrl-K just discard. Reference: `rustyline/src/kill_ring.rs`,
  `replxx/src/killring.hxx`.
- **Numeric arguments.** `M-3 C-f` for "move 3 words." Same machinery
  vi-mode repeat counts will need.
- **Custom key bindings.** `Keymap` is currently swap-only; expose a
  binding-table API so apps can override individual keys without
  forking the keymap.
- **Configurable word-boundary policy.** Currently word movement is
  whitespace-based; emacs uses `[A-Za-z0-9_]+`; vi has its own.
- **Completion-while-typing.** Filter candidates as the user types
  more characters. Requires async or at least debounced completion.
- **Atomic history under concurrent processes.** `persistAppend` is
  EINTR/partial-write safe but two shells writing the same file race.
  Reference: `readline/histfile.c` for file-locking, `rustyline/src/history.rs`
  for tmp+rename.
- **`dedupe=.all` history-file compaction.** Currently dedup is
  applied at load and append in memory; the on-disk file still grows
  duplicates. Periodic atomic rewrite (`tmp + fsync + rename`) would
  reconcile.

## API

- **Custom actions.** Application-defined `Action.custom: u32` channel
  so apps can wire keys to behaviors zigline doesn't know about.
- **Async completion.** Completion provider returns a future / token
  the editor polls; UX shows "computing…" while in flight.
- **Narrower error sets.** v0.1 hooks return `anyerror`; tighten to
  `error{ HookFailed }` plus typed inner errors per hook category.
- **Incremental grapheme segmenter.** Currently re-segment the whole
  buffer on every edit (O(n)). For large pasted content, an
  incremental segmenter would cut work. Not a v0.1 concern.

## Width / Unicode

- **Configurable ambiguous-width policy.** `WidthPolicy.ambiguous_is_wide`
  exists in the type but isn't read anywhere in v0.1; wire it through.
- **Tab rendering.** Currently tabs aren't allowed in the buffer
  (Tab triggers completion). v0.2+ might allow tabs in pasted content
  rendered as spaces up to the next stop.
- **Variation selector handling.** Ensure `U+FE0F` doesn't break
  width calculations on adjacent code points.
- **Locale-aware width.** Some terminals respect `LC_CTYPE` for
  ambiguous-width; honor it via env-driven default.

## Terminal

- **Capability detection.** `infocmp`-style probe of terminal
  capabilities, fallback when not present (e.g. no truecolor).
- **`NO_COLOR` env.** Honor [no-color.org](https://no-color.org/)
  convention.
- **`COLORTERM=truecolor`.** Detect for 24-bit color decisions.
- **`TERM=dumb` fallback.** Skip cursor-motion escapes entirely on
  dumb terminals; degrade to plain echo. Useful for emacs `M-x shell`
  and CI logs.
- **`signal_policy=.shell_friendly`.** Lets the application opt into
  kernel SIGINT delivery so the shell's own SIGINT handler can
  interrupt blocking child syscalls in a pipeline. Reference:
  `readline/signals.c` + `rltty.c`.
- **Self-pipe wakeup hook for application-installed signals.** We
  install our own SIGWINCH/SIGTSTP/SIGCONT handlers; if the
  application has its own (e.g. for SIGUSR1), they need a way to
  also poke our self-pipe. Expose `Editor.notifyResize` semantics
  generically.
- **Windows native (cmd.exe, Windows Terminal).** Currently POSIX-only.
- **Alt-screen for completion menus.** Long candidate lists could
  pop into the alt-screen, scroll, return on selection.
- **Rich completion menu UI.** Multi-column / paged / keyboard-
  navigable menu rather than the current single-line space-separated
  list. Reference: `reedline/src/menu/` for a modern model that
  separates source / candidate model / replacement range / layout /
  selection / painter.
- **Title-bar updates.** `\x1b]0;TITLE\x07` integration as a hook.

## Tests

- **Property tests.** Random buffer + cursor + width + arbitrary
  edits → assert renderer output places cursor at expected (row,
  col) when consumed by a virtual terminal model.
- **Differential tests.** Run zigline alongside readline / linenoise /
  rustyline on the same input stream; assert observable behavior
  matches where intended (and document where it deliberately
  doesn't).
- **Fuzzing of the input parser.** Random byte streams should never
  panic the parser; should always emit either a valid event or
  `unknown`.

## Distribution

- **`zig fetch --save` documentation.** Once the package is in the
  Zig package index, the install steps in the README get explicit.
- **CI.** GitHub Actions running `zig build test` on macOS + Linux
  for the supported Zig versions.
- **Examples as integration smoke.** Each example builds and runs in
  CI under a PTY harness.

## Performance

- **Latency budget.** Define a target keystroke-to-repaint latency
  (e.g. ≤1ms p99). Measure. Optimize if exceeded.
- **Allocation profile.** Per-keystroke allocation count target
  (e.g. ≤1 small alloc per keystroke). Measure with a tracking
  allocator. Reduce if over budget.
- **Startup cost.** Time from `Editor.init` to first prompt.
  Target ≤10ms cold (without history file load).

## Documentation

- **API reference.** Doc-comment every public symbol; build doc
  generation into CI.
- **Migration guide for slash.** Step-by-step guide for replacing
  slash's embedded line editor with zigline.
- **Comparison page.** "How zigline differs from linenoise / readline /
  rustyline / reedline" — useful for users evaluating.

## Bugs / known issues to track once code lands

- (To be populated during v0.1 implementation as edge cases surface.)
