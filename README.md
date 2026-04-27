# zigline

A grapheme-aware terminal line editor for Zig CLIs and REPLs. Multi-row
wrap, persistent history, tab completion, syntax highlighting hooks,
bracketed paste — all in a small library that stays out of your way.

```zig
const std = @import("std");
const zigline = @import("zigline");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var editor = try zigline.Editor.init(alloc, .{});
    defer editor.deinit();

    while (true) {
        const result = try editor.readLine(zigline.Prompt.plain("$ "));
        switch (result) {
            .line => |line| {
                defer alloc.free(line);
                std.debug.print("got: {s}\n", .{line});
            },
            .interrupt => continue,
            .eof => break,
        }
    }
    return 0;
}
```

See `examples/with_history.zig`, `examples/with_completion.zig`,
`examples/with_highlight.zig`, and `examples/with_custom_action.zig`
for the hook-based extension points.

## What zigline gets right

- **Grapheme-aware.** Cursor moves cluster-by-cluster (UAX #29 via the
  [`zg`](https://codeberg.org/atman/zg) library). `café` is four
  graphemes, not five bytes. ZWJ family emoji and regional-indicator
  flags advance the cursor as one unit, with correct cell width.
- **Wrap-aware.** Multi-row repaint that handles terminal width
  changes and the autowrap-corner edge case correctly.
- **Hookable.** A completion provider returns explicit replacement
  ranges; a syntax highlighter returns semantic spans (the renderer
  emits ANSI). Both are a struct with a `ctx` and a function pointer —
  no globals, no init dance.
- **Tested.** Unit tests for the buffer, layout math, key parser, and
  paste sanitization; PTY-driven tests for the line-editor surface,
  including UTF-8 round-trip, history recall, and completion insertion.

## What zigline does not do

- Parse escape sequences. It emits them; a terminal emulator
  interprets them.
- Own the screen. It draws the prompt + input line + a single-line
  completion notice. Above and below are the application's.
- Know about shells. [slash](https://github.com/shreeve/slash) is the
  shell that uses zigline; zigline knows nothing about jobs or pipes.

## Status

v0.1. Targets Zig 0.16. Depends on `zg` for grapheme cluster
boundaries and East Asian Width data; no other dependencies.

See [`SPEC.md`](SPEC.md) for the design constitution, [`FUTURE.md`](FUTURE.md)
for deferred work.

## License

MIT — see [`LICENSE`](LICENSE).
