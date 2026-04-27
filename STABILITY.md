# zigline — stability commitment

This file lists what zigline promises **not to break** between v1.0 and
v2.0. The promise is real once v1.0 is tagged. Until then the API may
change in any direction; this document describes the **target** shape.

## SemVer rules

A change is **breaking** (and ships as v2.0) if it:

- Removes a public symbol.
- Changes the signature of a public function.
- Adds a required field to a public struct.
- Adds a variant to a public tagged union.
- Changes documented observable behavior.

A change is **non-breaking** (ships as v1.x) if it:

- Adds a new function or type.
- Adds a struct field with a default value.
- Adds a new constant.
- Reorganizes anything that isn't re-exported from `src/root.zig`.
- Fixes a bug whose old behavior wasn't documented.

`src/root.zig` is the single source of truth for "what's public." Anything
you can reach without going through `@import("zigline")` is internal and
may move at any time.

## Stable in v1.0 (the commitment target)

These are locked: once v1.0 ships, nothing here changes incompatibly
before v2.0.

**Editor.**
`Editor.init`, `Editor.deinit`, `Editor.readLine`, `Editor.notifyResize`,
`Options` (field set), `ReadLineResult` (variants `line` / `interrupt` /
`eof`), `RawModePolicy`, `PastePolicy`.

**Buffer.**
`Buffer.init`, `Buffer.deinit`, `Buffer.slice`, `Buffer.cursor_byte`,
`Buffer.isEmpty`, `Buffer.byteLen`, `Buffer.insertText`,
`Buffer.deleteBackwardCluster`, `Buffer.deleteForwardCluster`, the
cursor-motion methods. `Cluster` field shape.

**Prompt.**
`Prompt.plain`, `Prompt.withWidth`, the `bytes` / `display_width` field
shape.

**Input.**
`KeyEvent`, `KeyCode`, `Modifiers`, `Event` — variants locked.

**Keymap / actions.**
`Keymap.lookupFn` shape, `Keymap.defaultEmacs`. `Action` is internal-
impact only (the editor's `dispatch` is the sole consumer); new variants
are non-breaking for applications because applications produce actions,
they don't switch on them.

**History.**
`History.init`, `History.deinit`, `History.append`, `History.compact`,
the cursor-navigation methods, `HistoryOptions` field set.

**Hooks.**
`CompletionHook`, `CompletionRequest`, `CompletionResult`, `Candidate`,
`CandidateKind`. `HighlightHook`, `HighlightSpan`, `Style`, `Color`.
`CustomActionHook`, `CustomActionRequest`, `CustomActionResult`,
`CustomActionContext`. `DiagnosticHook` and `Diagnostic` struct shape.

**Custom-action ID conventions.** `Action.custom: u32` IDs are opaque
to zigline; applications assign their own labels. Recommended
discipline:

- Treat `0` as invalid/unbound. First-party application IDs start at
  `1`.
- If you build a plugin system where third-party code can register
  custom actions, namespace via the top byte (`0xPP_xxxxxx` where
  `PP` is the plugin ID) or a hash of the plugin name. Reserve the
  bottom range (e.g. `< 0x01000000`) for the host application's own
  actions.
- `CustomActionResult.no_op` is the canonical "user aborted" path —
  e.g. when an `$EDITOR` exits non-zero. There is no separate
  `.action_cancelled` variant; the buffer simply stays as it was
  before the action.

**Width / Unicode.**
`WidthPolicy` field set.

## Explicitly experimental in v1.x

Exposed in the public surface but may evolve before v2.0. Apps depending
on these should pin minor versions and migrate at bumps.

- **`Diagnostic.Kind` variants.** New variants ship as we surface more
  failure modes. Apps switching on this should always include an `else`
  branch.
- **`KillRing` and `Changeset` types.** Exposed for advanced cases
  (inspecting kill-ring slots from a custom action; recording app-side
  edits into the per-line undo stack). The internal layout may change if
  the integration patterns don't hold up.
- **`CompletionResult` ownership model.** Currently allocator-owned; may
  move to a callback emit-as-you-go model if per-candidate alloc cost
  shows up in profiles.

## Explicitly internal — not API

Anything not re-exported from `src/root.zig` is internal. Examples:
`src/renderer.zig`, `src/terminal.zig`, `src/grapheme.zig`,
`src/input.zig` parser internals. These move freely.

## Concrete blockers between here and v1.0

From `FUTURE.md`, in priority order:

1. **Multi-column completion menu UI.** The current single-line
   space-separated list is a placeholder for a real menu.
2. **Custom key bindings.** `Keymap` is currently swap-only; v1.0 needs
   a binding-table API so apps can override individual keys without
   forking the keymap.
3. **One real-world consumer integration through a release cycle.**
   [slash](https://github.com/shreeve/slash) is shipping with zigline
   today; the issues it surfaces are what we tighten before v1.0.

Items in `FUTURE.md` not on this list are post-v1.0.
