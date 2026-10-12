# Spec: Make the disk mirror safe for agents and other external writers

## Status

Draft (2026-10-12). Nothing implemented yet. Phase 1 is small and needs no product
decisions. Phases 2 and 3 need the decisions listed under "Open decisions" first.
A separate, independent item, file tree order, is planned near the end.

## Problem

`sync_dir` mirrors every document to disk so that tools such as Claude Code can
read and edit the project. The two-way path has four defects. Each one was
confirmed by reading `lua/overleaf/sync.lua`, and the watcher behaviour was also
confirmed by experiment:

1. **Only the first atomic save of a file is seen.** Claude Code's edit tool saves
   by writing a temp file and renaming it over the original; its inode changes on
   every edit (checked 2026-10-12). The plugin watches each file with a libuv
   `fs_event`, which is bound to the inode. After a rename-replace it fires once
   and then goes silent: in a test, neither a second rename nor an in-place write
   produced another event.
   - For a closed document (`_sync_closed_doc`), nothing re-arms the watcher. The
     agent's second and later edits stay on disk and never reach Overleaf. The next
     connect or `:Overleaf sync` then writes the server copy over them, so they are
     lost.
   - For an open document, the watcher is re-armed only when the plugin's
     debounced `write_doc` runs, about 500 ms later. An external edit inside that
     window is missed, and then that `write_doc` overwrites it with the buffer's
     content.
   - The fileRef watcher (`watch_file`) already re-arms itself on every event; the
     document watcher (`watch`) never got the same fix.
2. **External writes are merged two-way, so they can revert other people's edits.**
   `_sync_closed_doc` sends `diff(server_now, disk)`, and the open-document path
   replaces the buffer with the disk content. Neither uses the version the writer
   started from. Anything that changed on the server after the agent read the file
   is undone: a collaborator's edit, or your typing within the last 500 ms.
3. **Closed documents are stale snapshots.** The plugin leaves each document after
   writing it on connect, and Overleaf sends live updates only for joined
   documents. A collaborator's edit to a chapter you don't have open never reaches
   the disk, so an agent reads old text. Combined with (2), its write then reverts
   the collaborator.
4. **Files created, deleted or renamed on disk are ignored.** Nothing watches
   directories. A new `.tex` an agent creates is never uploaded. A deletion or
   rename is not sent, which is the safe default but is currently silent.

## Goals

- Every external save reaches Overleaf, however the writer saves (in place, or
  temp file plus rename) and however often.
- An external write never silently reverts changes the writer did not see.
- Agents read current text for every document, not only the open ones.
- Optionally, new files created in the mirror become project files.

## Non-Goals

- Sending deletions or renames to Overleaf automatically. They are destructive and
  hard to tell apart from save patterns.
- Real-time collaboration for fileRefs, which stay last-writer-wins.
- macOS/Windows-specific watcher behaviour beyond what libuv gives for free. Linux
  is the tested platform.

---

## Phase 1: never drop or overwrite an external save (small, no decisions needed)

**Done 2026-10-12.** Implemented as specified, plus two details: an empty disk file is rewritten
rather than treated as an external edit, and a file deleted on disk is watched again once the
plugin recreates it. Verified live in the sandbox: five rename-replace saves to a closed
document all reached Overleaf, against only the first one on the previous code.

**1a. Re-arm the document watcher on every event.** In `M.watch`, inside the
scheduled callback, re-create the watch before handling the change, exactly as
`watch_file` does:
`if M._watchers[path] and M._watchers[path].handle == handle then M.watch(doc) end`.
If `handle:start` fails (the file is briefly missing mid-rename), retry once after
200 ms, again as `watch_file` does. If the file is still missing, log once at
`warn`: "<path> was deleted on disk; it is not deleted on Overleaf". Then stop.

**1b. Don't let the debounced write clobber an unprocessed external edit.** In
`write_doc`, before writing, read the file. If its bytes differ from both
`M._last_written[path]` and `doc.content`, an external write landed that has not
been handled yet. Call `M._on_file_changed(path, doc)` instead of writing, and let
the resulting buffer change schedule the next write. A missing file is treated as
"no unprocessed edit".

**1c. Clean up the stale guard comment.** The comment in `write_doc` that says the
re-watch is needed because "rename() replaces the inode" stays true. Once 1a
lands, also say that external renames are handled in `watch`.

**Tests (plenary, real `fs_event` in a `vim.fn.tempname()` directory):**
- Two consecutive rename-replaces and then an in-place write of a watched closed
  document produce three `_on_file_changed` calls (stub `_sync_closed_doc`).
- For an open document: an external write lands, then a second external write
  lands before the debounced `write_doc` fires. The buffer ends with the second
  write's content and the disk is not reverted.
- Deleting the file logs the warning once and does not crash.

**Live check:** LaTeX sandbox only, never the user's real projects. The cookie in
`~/.overleaf.env` must be refreshed first. Use a headless session with
`sync_dir`, and a shell loop doing five `mv tmp file` saves to a closed document a
second apart. Confirm all five arrive (read back through `joinDoc`), then delete
the throwaway document.

## Phase 2: merge from the writer's starting version, and keep closed documents fresh

**2a. Three-way merge using the existing OT transform.** For every external change
there are three versions:

- `base`: what the writer read. For an open document this is
  `M._last_written[path]`. For a closed document it is `doc.content`, the snapshot
  taken when the plugin last wrote or synced it.
- `theirs`: the current truth. For an open document, the buffer content. For a
  closed document, the server content from `joinDoc`.
- `mine`: the new disk content.

Compute `a = diff.ops(base, mine)` and `b = diff.ops(base, theirs)`, then
`merged = ot.apply(theirs, ot.transform_ops(a, b, 'left'))`. Send
`diff.ops(theirs, merged)` as now. For an open document, apply
`replace_content(bufnr, merged)`. In both cases, write `merged` back to disk so
the writer sees the result. `ot.transform_ops` already exists and is covered by
`tests/overleaf/ot_spec.lua`, so this needs no diff3 implementation and does not
depend on Overleaf's server-side version window.

- **Overlapping edits** (both `a` and `b` touch the same character range): see
  decision D1. The recommendation is not to auto-merge. Send nothing, write the
  writer's version to `<file>.overleaf-conflict` next to the file, put the merged
  `theirs` in the file itself, and log a `warn` naming both files.
- **No base** (first sight of the file, or offline edits from before connect):
  keep the current two-way behaviour, but log `warn` that the change was not
  merged.
- Tracked-changes mode: diff with `{ words = mode.tracked() }` as now.

**2b. Keep closed documents joined so reads are fresh** (decision D2). After
`sync_all` writes a document, stay joined instead of calling `leaveDoc`. Route
`otUpdateApplied` for documents without a buffer through
`doc:on_remote_op`/`ot.apply` on `doc.content`, plus `schedule_write`. Check that
`Document:on_remote_op` works with no `bufnr`; `buffer.apply_remote` must be
skipped for those. This removes defect 3 and makes 2a's `theirs == base` the
common case. The cost is a live subscription for every document in the project.
If Overleaf caps joined documents per connection, find out, and fall back to the
current snapshot behaviour above that cap.

**Alternative considered for closed documents:** submit `diff(base, mine)` at
`v = doc.version` and let Overleaf transform it server-side. This was rejected as
the primary path. It depends on the server still holding the intervening ops, and
on the update hash: the bridge hashes the content it expects after the op
(`node/socket.js` `applyOtUpdate`), which would not match once the server
transforms it. Both would need checking against Overleaf's source, and the local
merge has neither dependency.

**Tests:**
- Unit: base/theirs/mine merges that don't overlap (both edits kept), that overlap
  (conflict file, nothing sent), that have no base (warning, two-way), and that
  contain non-ASCII text.
- Node mock server: a collaborator op arrives between snapshot and external write
  on a closed document; the sent op keeps the collaborator's text.
- Live: in the sandbox, a second client (another headless Neovim with the same
  cookie) edits paragraph A while a scripted writer edits paragraph B of the same
  closed document from an older read. Both edits survive.

## Phase 3: files created on disk (opt-in)

**Done 2026-10-12.** `sync_new_files = false` (default), `true` (Overleaf's text extensions), or
`{ binary = { 'png', … } }`; `:Overleaf sync status` lists disk-only files, files missing on disk
and held changes.
- A new text file is created with `createDoc` (and `createFolder` for missing parents). The
  Document then joins it and stays joined, and the content goes out through `submit_op`: tracked in
  suggesting mode (D4), sanitized like typed text.
- Disk edits to a joined, bufferless document go through `_sync_joined_doc` (`submit_op`). The old
  join-and-leave path is kept for documents that are not joined.

Verified live with two clients. A new folder and document written by an "agent" appeared for the
other client; `.aux` and dotfiles were ignored; an emoji was stored as U+FFFD and the disk copy
rewritten to match; a later rename-replace edit reached the server; a collaborator's edit reached
the agent's file on disk.

Behind decision D3; off by default.

- Watch every mirrored directory. On Linux `fs_event` is not recursive, so use one
  watcher per folder, added when folders are created.
- On a new file, after it has been stable for 500 ms (same size twice):
  - Ignore it unless it matches the allowlist: the configured extensions,
    defaulting to Overleaf's text whitelist (`tex bib sty cls txt md` …).
  - Always ignore dotfiles, `*~`, `*.swp`, `4913`, the plugin's own
    `*.tmp.<pid>`, editor and agent temp names, `.git/`, and LaTeX build output
    (`*.aux *.log *.out *.synctex.gz *.fdb_latexmk *.fls *.bbl *.blg`, `*.pdf`).
    An agent running `latexmk` in the mirror must not upload its build directory.
  - A whitelisted text file: `createDoc` in the matching parent folder (the bridge
    already has `createDoc`/`createFolder`), then send the content and start
    watching it as a document. Anything else: upload it as a file through the
    existing fileRef upload path.
- Deletions and renames are never sent. A rename shows up as a new file (uploaded
  if allowed) plus a missing old one (warned). `:Overleaf sync status` (new) lists
  disk-vs-project differences: files only on disk, files missing on disk, and held
  changes. The user can then act on them by hand or in the web UI.
- Mode: in viewing, hold. In suggesting, see D4. Creating a file is not a tracked
  change in Overleaf, so it would bypass review.

## Phase 4 (optional): offline edits

Persist `{ path -> sha1 of last content written }` to `<sync_dir>/<project>/.overleaf-sync.json`
(mode 0600) on every `write_doc`. On connect, before `sync_all` overwrites a file,
compare the disk sha with the manifest. If they differ, the file was edited while
disconnected: run it through the Phase 2 merge with base = server content at last
sync (store it, or skip the merge and save a conflict copy) instead of discarding
it. This replaces today's silent loss of offline mirror edits for documents. The
README already says this happens for fileRefs.

## Also planned: file tree order (independent of the phases above)

**Done 2026-10-12.** Overleaf's web tree (`file-tree-folder-list.tsx`, `util/file-collator.ts`) lists
subfolders first, then docs and files interleaved, sorted by
`Intl.Collator('en', {numeric: true, sensitivity: 'variant', caseFirst: 'upper'})`. The plugin
approximates that, with accented letters in byte order. The main document is marked `*`, and
`tree_sort = 'overleaf'` keeps storage order.

**Problem.** The tree panel (`lua/overleaf/tree.lua`) draws `project._project_tree`
exactly as stored, and nothing in the plugin sorts it:

- `project._walk_folder` emits, per folder, subfolders, then docs, then fileRefs.
  Each group is in Overleaf's storage order, which is roughly creation order, not
  name order. So `03-hpca27-rebuttal/` can sit above `01-…/`, and `fig10.png`
  above `fig2.png`.
- Docs and fileRefs are split. A `listing.c` or `table.csv` comes after every
  `.tex` in its folder, whatever its name.
- `project.add_entry` (a doc, file or folder created this session, from the tree
  or from a collaborator's `reciveNewDoc`/`reciveNewFile`) appends to the end of
  the flat list. The new entry renders at the bottom of the whole tree, indented
  as if it belonged to whatever folder happens to be last. `rename_entry` never
  re-sorts either.
- Tree actions find their entry by line number in that same flat list
  (`tree.lua` `_on_enter` and the rename/delete/create handlers around lines
  122–226), so any reordering must change rendering and lookup together.

**Plan.**
- Add `project.display_rows()`. It builds the folder hierarchy from entry paths
  rather than relying on list position, sorts each folder's children, and returns
  a depth-first list of rows `{ entry, depth }`. Sort folders first, then all
  files together (docs and fileRefs interleaved), each by case-insensitive
  *natural* order, so `fig2` < `fig10` and `01-intro` < `02-design` <
  `10-appendix`. This is how Overleaf's web editor appears to order its tree:
  check this against the web UI on the sandbox project before relying on it.
- `tree.refresh` renders `display_rows()` and stores the result as
  `tree._rows`. Every handler that maps a cursor line to an entry reads
  `tree._rows[line]` instead of indexing `project._project_tree`. Depth comes from
  the row, so a stale `entry.depth` can no longer misplace anything, and
  `add_entry`/`rename_entry`/`remove_entry` need no ordering logic.
- Keep the cursor on the same entry (not the same line number) across a refresh
  that reorders rows, e.g. after a rename or a collaborator adding a file.
- Config `tree_sort`: `'name'` (default, as above) or `'overleaf'` (storage
  order). Optionally accept a comparator `function(a, b)` for anything else.
  Decision D6.
- The document picker (`project.select_document`) uses the same order.

**Tests** (there is no tree spec yet; add `tests/overleaf/tree_spec.lua`):
- Natural sort, folders first, and docs/fileRefs interleaved.
- A nested folder's children stay under it.
- An `add_entry` for a file in a subfolder renders inside that folder, not at
  the bottom.
- After a rename that moves an entry, the row under the cursor still maps to the
  entry shown on that line (`<CR>` opens the right file).
- `tree_sort = 'overleaf'` reproduces today's order.

This is small and needs no live Overleaf, apart from optionally checking the web
UI's order. It can go before or alongside Phase 1.

## Open decisions (for the user, before Phases 2–3)

- **D1. Overlapping edits:** conflict file and send nothing (recommended), or let
  OT keep both edits (always merges, may garble the overlapping text)?
- **D2. Keep closed documents joined for fresh reads:** default on (recommended
  for agent use), opt-in, or only while a `sync_dir` is set?
- **D3. Upload files created on disk:** off by default with an allowlist
  (recommended), or on for `.tex`/`.bib` only?
- **D4. New files while suggesting:** hold them (recommended, since creation
  bypasses review) or create them anyway?
- **D5. Phase 4:** worth doing, or keep "offline edits are discarded" and document
  it for documents too?
- **D6. Tree order:** folders first and natural name order by default
  (recommended), with `tree_sort = 'overleaf'` for the old order? Should the main
  document be pinned to the top?

## Decisions taken (advisor, 2026-10-12)

The user delegated D1–D6 to an advisor (an Opus review of this spec against the
code). Choices and the corrections they imply:

- **D1. Overlapping edits:** all-or-nothing per external write.
  - If any hunk of `diff(base, mine)` overlaps or touches any hunk of
    `diff(base, theirs)` (closed intervals in base coordinates; identical hunks
    count once), send nothing.
  - Save the writer's version to a *uniquely named* conflict copy
    (`<file>.overleaf-conflict.<n>`), leave the file and `_last_written` at
    `theirs`, and `vim.notify` at WARN.
  - Without overlap, apply the union of the disjoint hunks to `base` in
    descending position order; `transform_ops` is not needed.
  - Judge overlap with word-level diffs (`words = true`); use
    `words = mode.tracked()` only for the final op that is sent.
- **D2. Keep documents joined:** always, whenever `sync_dir` is set, with no
  separate option.
  - Remote ops for bufferless documents already flow (`init.lua` ~316-328), so
    the change is to set `joined = true` and stop leaving (`sync.lua` ~764).
  - Warn and fall back to a snapshot if a join fails (today that is only
    logged at debug, `sync.lua` ~741).
  - Required follow-ons the spec missed:
    - `open_document` must attach the buffer to the existing `Document`
      instead of creating a second one (`init.lua` ~687-696);
    - `_rejoin_documents` must rejoin bufferless documents after a reconnect
      (`init.lua` ~650-665);
    - `Document:rejoin` must schedule a mirror write;
    - `_sync_closed_doc` becomes "update `doc.content` and `submit_op`", with no
      join or leave.
  - With D2, `doc.content` is live, so Phase 2a's base is
    `M._last_written[path]` for every document and theirs is `doc.content` (after
    a synchronous `reconcile` when there is a buffer). Open and closed documents
    then share one path.
- **D3. Upload files created on disk:** off by default.
  - When on, the allowlist is Overleaf's text-document extensions. Binary
    uploads happen only for extensions the user lists.
  - When off, `:Overleaf sync status`/`import` still list disk-only files.
  - The user's own config should probably turn it on.
- **D4. New files while suggesting:** create an empty document, then insert the
  content through OT, so it is sent as a tracked insertion (the web editor does
  the same).
  - Hold anything that would be a binary upload (`mode.can_replace_files()`).
  - A `review` collaborator's `createDoc` is refused by the server: catch that
    and hold.
- **D5. Offline edits:** do Phase 4, in reduced form.
  - Keep a manifest of the sha256 of the last content written per path, at
    `stdpath('state')/overleaf/<project_id>.json`, not inside the mirror.
  - On connect, before `sync_all` overwrites a file:
    1. disk equals server → nothing;
    2. disk sha equals the manifest → server changed, overwrite;
    3. server sha equals the manifest → only the disk changed, send it as an
       edit (mode-gated);
    4. otherwise → conflict copy of the disk version, write the server version,
       warn.
- **D6. Tree order:**
  - folders first, then documents and files interleaved, case-insensitive;
  - natural (`fig2` < `fig10`) only if Overleaf's web editor does that — check
    on the sandbox; it may be plain `localeCompare`;
  - keep `'overleaf'` storage order as an option, and drop the comparator
    function;
  - no main-document pin: mark it in the tree instead.
  - The line-to-entry lookup is also duplicated in `init.lua` ~1066 (the rename
    picker).

Other corrections from the same review:
- Phase 3's ignore list must include the conflict copies.
- `search.lua` searches the stale content of closed documents today; D2 fixes
  that.
- Phase 2's base is only right when the writer re-reads before writing.
  Claude Code does; document the limitation for other tools.

## Mitigation until this ships

- Open in Neovim the documents an agent will edit. Open documents get live
  updates, so reads are fresh, and their watcher re-arms on each plugin write. The
  remaining risk is two external saves less than 500 ms apart.
- After an agent session, `:Overleaf sync import` pushes every file that differs
  from what the plugin last knew. Because of defect 2, only do this when nobody
  else edited those documents since you connected.

## Execution notes

- Phase 1 is well specified: suitable for one implementation agent plus lead
  review. Run `make test`, then the sandbox live check.
- Phase 2 is subtle correctness work. Have it planned or reviewed by a strong
  model, and adversarially reviewed before merge.
- All live testing uses the "LaTeX sandbox" project with throwaway documents, never
  the user's papers.
