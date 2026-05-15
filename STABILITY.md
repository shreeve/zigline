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
`Buffer.init`, `Buffer.deinit`, `Buffer.slice`, `Buffer.byteLen`,
`Buffer.isEmpty`, `Buffer.insertText`, `Buffer.deleteBackwardCluster`,
`Buffer.deleteForwardCluster`, the cursor-motion methods
(`moveLeftCluster`, `moveRightCluster`, `moveLeftWord`,
`moveRightWord`, `moveToStart`, `moveToEnd`), and the new in-place
transforms (`transposeChars`, `editWord`, `squeezeWhitespace`).
`Cluster` field shape. `EditResult` and `WordCase` types. The
`findUnsafeByte` helper (used at hook boundaries to reject
control-byte injection).

**Prompt.**
`Prompt.plain`, `Prompt.fromUtf8`, the `bytes` / `width` field shape.

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
`CandidateKind`. `HighlightHook`, `HighlightRequest`, `HighlightSpan`,
`Style`, `Color`. `HintHook`, `HintRequest`, `HintResult` (fish-style
ghost-text autosuggestions, post-v0.3.x). `CustomActionHook`,
`CustomActionRequest`, `CustomActionResult`, `CustomActionContext`.
`DiagnosticHook` and `Diagnostic` struct shape.

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

Updated for v0.2.x state. Two of the three original v1.0 blockers
shipped:

1. ⏳ **Multi-column completion menu UI.** Designed in SPEC.md
   §6.5 / §6.6 / §6.7; pending slash review of four open UX
   questions before code lands.
2. ✅ **Binding-table API on `Keymap`** — shipped in v0.2.0. Multi-
   key sequences (`Ctrl-X Ctrl-E`, etc.) via the optional
   `BindingTable` overlay; `lookupFn` shape preserved.
3. ✅ **One real-world consumer release cycle** — slash 1.0.0
   shipped with zigline embedded; v0.1.4 / v0.1.5 / v0.1.6 / v0.2.0
   all integrated through the path-dep mechanism with no observed
   regressions.

Items in `FUTURE.md` not on this list are post-v1.0.

## Recent additions

- **post-v0.3.1 — Ghost-text hint hook (`Options.hint`) + `Action.accept_hint`.**
  New public surface in `src/hint.zig` (`HintHook`, `HintRequest`,
  `HintResult`) re-exported from `root.zig`. `HintResult.style` is
  `?Style`; `null` means "use the editor's default ghost style"
  (`.{ .dim = true }`). `accept_hint` consumes the validated hint
  cached at the most recent render (no re-invoke of the hook at
  dispatch time, so the user always accepts the bytes they saw).
  `Diagnostic.Kind` gains `hint_hook_failed` and `hint_invalid_text`;
  per the experimental-variants policy above, switch statements on
  `Diagnostic.Kind` should already include an `else` branch.

  **Default keymap change.** `Keymap.defaultEmacs` rebinds Right
  Arrow (no ctrl) and `Ctrl-F` to `accept_hint`. `accept_hint` falls
  back to `move_right` when no hint is active or the cursor isn't at
  end-of-buffer, so the observable behavior for embedders that don't
  configure a `HintHook` is identical to v0.3.x. Embedders with
  bespoke keymaps that switched on `Action` are unaffected (they
  produce actions; they don't observe defaults).

## Known issues

- **v0.3.0 — `pokeActiveFreshRow` is a no-op in the default config.**
  The initial implementation tied the process-wide claim to
  `SignalGuard`, which lives only between `enterRawMode` and
  `leaveRawMode`. In the default `.enter_and_leave` raw-mode policy
  the claim is therefore cleared by the time the embedder calls the
  hook *between* `readLine` invocations — exactly when it's needed.
  Under `.assume_raw` the SignalGuard is never installed at all, so
  the claim is never set. Fixed in v0.3.1 by moving the claim to
  `Editor.init` / `Editor.deinit` (lifetime = "an editor instance is
  alive"), which is what the contract advertised. Embedders on
  v0.3.0 should upgrade; the public API surface is unchanged.
