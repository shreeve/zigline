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
- **Right prompt (`rprompt`).** Right-aligned prompt text on the
  prompt row (git branch, vi-mode indicator, exit status). Layout-
  aware — must hide if buffer text would collide. Reference:
  `reedline::prompt::Prompt::render_prompt_right`, fish/zsh
  `RPROMPT`.

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

### Quick wins — table-stakes emacs commands

The following are emacs defaults shipped by readline / rustyline /
isocline / bestline that zigline doesn't yet have. Each is a small
`Buffer` method + a keymap entry; missing them is the difference
between "feels like readline" and "feels like an alpha." Ship as a
batch when convenient.

- **Transpose chars (`Ctrl-T`).** Swap previous and current chars.
  Reference: `rustyline/src/line_buffer.rs::transpose_chars`.
- **Transpose words (`M-t`).** Swap previous and current words.
  Reference: `rustyline/src/line_buffer.rs::transpose_words`.
- **Word case ops (`M-c` capitalize, `M-u` upper, `M-l` lower).**
  Operate on the word at/after cursor, advancing cursor past it.
  Reference: `rustyline/src/line_buffer.rs::edit_word(WordAction::*)`.
- **Quoted insert (`Ctrl-V` / `Ctrl-Q`).** Read next byte literally,
  bypassing the keymap, and insert it. Useful for inserting actual
  control bytes. Reference: `readline/bind.c::rl_quoted_insert`.
- **History first/last (`M-<` / `M->`).** Jump to oldest / newest
  history entry. Reference: `readline/funmap.c` mappings.
- **Yank last arg (`M-.` / `M-_`).** Insert the last whitespace-
  separated token from the previous history line. Bash users hit
  this constantly when editing argv across commands. Repeated
  `M-.` cycles back through earlier lines' last args. Reference:
  `readline/bind.c::rl_yank_last_arg`,
  `replxx::ReplxxAction::REPLXX_ACTION_YANK_LAST_ARG`.
- **Squeeze adjacent whitespace (`M-\`).** Collapse runs of
  whitespace around the cursor down to a single space. Small,
  occasionally useful when fixing pasted-in commands.
  Reference: `bestline.c` (search for "squeeze").
- **Mark and point (`Ctrl-Space` set mark, `Ctrl-X Ctrl-X` swap).**
  Set a position, jump back to it, swap cursor with mark. Standard
  emacs editing primitive that pairs well with kill-region. ~30
  lines: one stored cursor position on `Editor`, two action
  variants. Reference: `bestline.c` (search for "mark").

### Bigger features

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
- **Numeric arguments.** `M-3 C-f` for "move 3 words." Same machinery
  vi-mode repeat counts will need.
- **Custom key bindings.** `Keymap` is currently swap-only; expose a
  binding-table API so apps can override individual keys without
  forking the keymap.
- **Configurable word-boundary policy.** Currently word movement is
  whitespace-based; emacs uses `[A-Za-z0-9_]+`; vi has its own.
- **Subword movement.** Cursor moves and word kills inside
  `camelCase` and `snake_case` identifiers. `helloWorld` is two
  subwords; `hello_world` is two subwords. Common request from
  REPL users editing code. Reference:
  `replxx::ReplxxAction::*_SUBWORD_*`.
- **Sexp navigation (`Ctrl-M-F` / `Ctrl-M-B`).** Move forward/
  backward by parenthesized expression. Useful in REPLs for
  Lisp-flavored syntax (zigline is the line editor for slash;
  shells with paren-sensitive constructs benefit too).
  Reference: `bestline.c` "FORWARD EXPR" / "BACKWARD EXPR".
- **History common-prefix search.** Type a partial command,
  press Up — only history entries starting with that prefix
  scroll. Fish/zsh have this; users expect it once they've used
  it. Distinct from reverse-i-search (different UX). Reference:
  `replxx::REPLXX_ACTION_HISTORY_COMMON_PREFIX_SEARCH`.
- **Overwrite mode toggle (`Insert` key).** Toggle between insert
  and overwrite modes (overwrite = each typed char replaces the
  one under cursor). Classic editor behavior. Renderer needs a
  flag for cursor shape (block in overwrite, bar in insert).
  Reference: `replxx::REPLXX_ACTION_TOGGLE_OVERWRITE_MODE`.
- **Completion-while-typing.** Filter candidates as the user types
  more characters. Requires async or at least debounced completion.
- **Completion behavior knobs.** Once we have the multi-column
  menu, surface the variants other libraries expose: double-tab
  mode (Tab once = LCP, Tab twice = list), immediate-completion
  mode (Tab = first match, no LCP step), complete-on-empty
  (Tab on empty buffer shows all options), beep-on-ambiguous
  (terminal bell on ambiguous Tab), pagination cutoff
  (page after N candidates). All `Options` toggles. Reference:
  `replxx_set_double_tab_completion`, `_immediate_completion`,
  `_complete_on_empty`, `_beep_on_ambiguous_completion`,
  `_completion_count_cutoff`.
- **Hint debounce.** When hints ship, expose a "wait N ms after
  last keystroke before invoking the hint hook" knob so quick
  typing doesn't show stale hints. Reference:
  `replxx_set_hint_delay`.
- **Multi-line indent.** When buffer wraps onto a continuation
  row, indent the wrapped portion to align under the prompt
  width. Visual polish; small renderer change. Reference:
  `replxx_set_indent_multiline`.
- **Automatic history compaction.** `History.compact()` exists and
  is exposed for callers who want to invoke it periodically; consider
  invoking it automatically on `deinit` or when the file grows past a
  threshold.
- **Mask mode for password input.** `Options.mask_input` flag (or
  `Editor.maskMode(bool)`) that renders every grapheme as `*` while
  the buffer holds the real bytes. Returns real bytes on accept.
  Reference: `linenoise.c::maskmode` flag plumbed through
  `refreshSingleLine` / `refreshMultiLine`.
- **Buffer preload.** `Editor.preloadBuffer(text)` inserts text into
  the next `readLine`'s buffer before the input loop starts. Useful
  for "edit this previous command" / "fill in defaults" workflows.
  Reference: `linenoise.c::linenoisePreloadBuffer`.
- **Brace-matching highlight helper.** Built-in `HighlightHook`
  helper exposed as `zigline.builtin.brace_matcher`. When cursor
  is on (or just past) `(` `[` `{`, walks the buffer, finds the
  matching close, emits a reverse-video `HighlightSpan`. Apps opt
  in by setting `Options.highlight = brace_matcher`. Reference:
  `isocline/src/highlight.c::highlight_match_braces`.
- **Visual selection.** Shift-arrow / Shift-Home/End select a
  range; subsequent kill / yank / case ops operate on the
  selection. Adds a "selection" state to `Buffer` and selection-
  aware action arms. Substantial; post-v1.0 unless demanded.
  Reference: `reedline/src/core_editor/editor.rs` SelectMode.

## API

- **Multiplexing API (`editStart` / `editFeed` / `editStop`).**
  Today `readLine` is blocking-only. Splitting it into start /
  feed-with-available-bytes / stop lets applications integrate
  zigline into their own event loop (`select` / `poll` / `epoll`),
  mixing terminal input with sockets, IPC, timers. Pairs with
  `Editor.print` (below) for the "print to screen while user is
  typing" use case. Reference: `linenoise.c::linenoiseEditStart`,
  `linenoiseEditFeed`, `linenoiseEditStop`. Architectural change;
  v0.3 or beyond.
- **Async-safe `Editor.print` / `printAbove`.** Print text above
  the prompt without disrupting editing. Internally finalizes the
  rendered block, writes the message, re-renders. Pairs with the
  multiplexing API for shells with background tasks. Reference:
  `linenoise.c::linenoiseHide` / `linenoiseShow`,
  `reedline::external_printer::ExternalPrinter`,
  `isocline::ic_print`.
- **Async stop.** `Editor.asyncStop()` thread-safe poke of the
  self-pipe to interrupt a blocking `readLine` from another
  thread. We have the self-pipe; this would be a public ~20 line
  shim. Useful for daemon REPLs and integration test timeouts.
  Reference: `isocline::ic_async_stop`.
- **Programmatic key-press injection.** `Editor.injectKeyPress(KeyEvent)`
  pushes an event into the input pipeline as if the user typed it.
  Useful for testing (drive integration tests deterministically
  without PTY) and for chord-macro features. Reference:
  `replxx_emulate_key_press`.
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
- **History load throughput.** `History.load` currently does
  per-line allocation. Bestline's note says they made history
  loading 10x faster vs linenoise; the trick is mmap + slice,
  no per-entry copy. Worth profiling before optimizing.
  Reference: `bestline.c` (search for "history" + read the load
  routine).

## Documentation

- **API reference.** Doc-comment every public symbol; build doc
  generation into CI.
- **Migration guide for slash.** Step-by-step guide for replacing
  slash's embedded line editor with zigline.
- **Comparison page.** "How zigline differs from linenoise / readline /
  rustyline / reedline" — useful for users evaluating.

## Bugs / known issues to track once code lands

- (To be populated during v0.1 implementation as edge cases surface.)
