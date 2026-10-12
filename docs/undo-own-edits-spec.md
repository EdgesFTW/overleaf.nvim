# Spec: Undo only reverts this client's own edits

## Status

Draft (2026-10-12). Bug confirmed; nothing implemented.

## Problem

`buffer.apply_remote` writes collaborators' ops into the buffer with
`nvim_buf_set_text`/`set_lines`. Neovim records every buffer change in the undo
tree, so a collaborator's edit becomes an ordinary undo step, and the most recent
one at that.

Reproduced headless on 2026-10-12: the buffer is `one | two | three`. I type
`MINE` on line 3, then a "remote" `nvim_buf_set_text` inserts `THEIRS ` at the
top. The first `u` removes `THEIRS`; only the second `u` removes `MINE`. In the
plugin that first undo is then picked up by `on_lines` → `reconcile` →
`Document:submit_op` like any edit, so it **deletes the collaborator's text on
Overleaf for everyone**.

Skipping remote steps inside Neovim's undo is not enough. Native undo entries
store absolute line numbers and saved line blocks. Once a collaborator inserts or
deletes lines above an older local edit, undoing that edit natively replays it at
the wrong place. Correct "undo my edit" after concurrent remote changes requires
transforming the inverse through the remote ops. That is what Overleaf's web
editor does: its history ignores remote transactions and maps undo through them.

## Goals

- `u` / `<C-r>` (and their counts) undo and redo only this client's edits, at
  their current positions after any remote changes, and send the result as a
  normal local edit.
- No undo path can revert a collaborator's change.
- Behaviour for a single user is indistinguishable from native undo in everyday
  use: the same step granularity, and the cursor lands on the changed text.

## Non-Goals

- Undo tree branches (`g-`, `g+`, `:earlier`, `:later`, undotree.nvim). These
  are disabled or neutralised in Overleaf buffers (see below), not reimplemented.
- Persisting undo across sessions (`undofile`).
- Undoing collaborators' edits on purpose (Overleaf's history panel covers that).

## Design

**1. An OT history per document** (new `lua/overleaf/history.lua`, owned by
`Document`).
- Every local op that `reconcile` produces is recorded on the current undo
  group as `{ ops, inverse }`. The inverse is computed against the content
  before the op (`ot.lua` gets an `invert(ops, content_before)` that turns each
  insert into a delete and back).
- Group boundaries follow Neovim's own: a new group starts when
  `vim.fn.undotree(bufnr).seq_cur` advances to a new undo step, which covers
  insert-mode sessions, normal-mode commands and `<C-g>u` breaks. This keeps the
  granularity users expect. Edits inside one group compose (`ot.compose`).
- Every remote op that `Document:on_remote_op` applies is used to transform
  every stored inverse and op on the undo and redo stacks
  (`ot.transform_ops(inverse, remote, 'left')`), the same operation
  `on_remote_op` already performs for `inflight_op`/`pending_ops`. An entry
  whose inverse becomes empty (the collaborator already deleted that text) is
  dropped.
- Our own ACKed ops do not transform the stack. They are already part of the
  history's linear order.

**2. Undo and redo commands.** `history.undo(doc, count)` pops a group, applies
its inverse to the buffer as a local edit (so it goes through `reconcile` and
`submit_op` and reaches Overleaf like typing does), and pushes the group onto the
redo stack. Before applying, it checks that the ranges still exist in the buffer,
with the same assertion style as `apply_ops`. Redo applies the transformed
forward op. A new local edit clears the redo stack, as in Vim. The cursor goes to
the start of the first changed range.

**3. Key and command coverage** (buffer-local in Overleaf buffers, decision D7):
- Map `u`, `<C-r>` and `U` in normal mode, honouring counts. `U` is treated as
  `u`, since Vim's line-undo has no OT meaning. Visual-mode `u` lowercases text,
  so leave it alone. Add `:Overleaf undo` and `:Overleaf redo`.
- **Make native undo harmless** for whatever is not mapped (`:undo`, `g-`,
  `:earlier`, undotree plugins, other plugins calling `normal! u`). Every time a
  remote op is applied, run it with `undolevels = -1` for that buffer and restore
  it afterwards. Vim clears the undo history at the next change made under
  `undolevels = -1`, which is exactly the remote change. So the native history
  never contains a remote change, and never contains a local change older than
  the last remote one. This prevents both reverting collaborators and stale-offset
  replay. The plugin already uses this trick once at buffer load
  (`buffer.lua:24-31`). Our OT history is unaffected, because it is separate.
  Check experimentally that applying a change under `undolevels=-1` and then
  restoring does not disturb insert-mode state or the cursor.
- When `mode` is `viewing` (buffer not modifiable), undo is a no-op with the
  usual "read-only" message.

**4. Tracked changes (`suggesting` mode).** Undoing your own suggested insertion
must remove that insertion, not add a suggested deletion of it. Undoing a
suggested deletion must restore the text. Verify how Overleaf represents
"retract own suggestion" (the `meta.tc` handling in `node/bridge.js`): the web editor rejects its own tracked
change instead of layering a new one. Send what the web editor sends. This is
the subtle part; it needs a live check in the sandbox with track changes on.

## Tests

- **Unit** (`tests/overleaf/history_spec.lua`): invert/apply round-trips;
  grouping by `seq_cur`; transform of the stack through a remote insert before,
  after and overlapping our edit; an undo whose text the collaborator deleted is
  dropped; redo after remote changes; a new edit clears redo; non-ASCII text.
- **Buffer level**: the headless repro above, through the plugin. `u` removes
  `MINE`, and `THEIRS` stays. With a remote insertion of lines above an older
  local edit, `u` undoes the right text at its new position. `:undo` after a
  remote change does nothing harmful.
- **Live**, LaTeX sandbox only: two headless Neovim clients on the same document
  (both may use the Chrome-extracted cookie). Client A types, client B types
  above it, A presses `u`. A's edit is gone, B's remains, and both clients and a
  fresh `joinDoc` agree. Repeat in suggesting mode.

## Open decisions

- **D7. Coverage:** map `u`/`<C-r>`/`U` and neutralise native undo with the
  `undolevels` trick (recommended)? Or also intercept `:undo`, `g-`, `g+`,
  `:earlier`? That would be more code and more surprise.
- **D8. Granularity:** follow Neovim's undo steps (recommended), or one step per
  OT flush, which is coarser and simpler?

## Decisions taken (advisor, 2026-10-12)

- **D7:** as recommended: map `u`, `<C-r>`, `U` and neutralise native undo.
  Tested on Neovim 0.12.5: applying a change under `undolevels=-1` clears native
  history in normal mode, mid-insert (the insert carries on, and later typing
  becomes a new native step), and on a buffer that is not current.
  - Apply the trick to *every* buffer write that is not local typing:
    - `apply_ops` for remote ops;
    - the full-buffer fallback in `apply_remote`;
    - `Document:rejoin`'s `set_lines`;
    - the file-restore `set_lines`;
    - the history's own undo and redo.
- **D8:** as recommended: groups follow Neovim's undo steps (`seq_cur` read when
  `reconcile` runs). Macros and mappings within one tick merge into one group.
  An insert interrupted by a remote op becomes two groups, so a group never
  straddles a remote op.

Corrections from that review:
- Transform the stacks by `ops_to_apply` (the op applied to `doc.content`,
  `document.lua` ~261), not by `update.op`.
- Undo and redo must not go through `reconcile`, which would record the inverse
  as a new group and clear redo. Instead:
  1. reconcile synchronously;
  2. apply the inverse to `doc.content` and to the buffer under
     `applying_remote` and `undolevels=-1`;
  3. `submit_op(inverse)`.
- `invert` of a multi-component op reverses the component order.
- Neither `apply_ops` nor `ot.apply` checks deleted text today, so add that
  check rather than copy an assertion style.
- This depends on the OT fixes F1, F2 and F4 in `docs/bug-hunt-2026-10-12.md`.
  `transform_ops` is currently wrong for multi-component ops, and the undo stack
  would hit that constantly.
- Tracked changes: Overleaf's RangesTracker most likely treats deleting your own
  tracked insertion as retracting it. A plain op with `meta.tc` is probably
  enough, but check it live.

## Execution notes

This is subtle OT and concurrency work. Have a strong model plan or review it,
and run an adversarial review before merge. It is independent of
`docs/mirror-agent-safety-spec.md`. Phase 2 of that spec reuses the same
`ot.transform_ops` machinery, so do this first or alongside it.
