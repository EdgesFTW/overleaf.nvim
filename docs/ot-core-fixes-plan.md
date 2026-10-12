# Plan: OT core fixes (batch B2)

## Status

Planned 2026-10-12 by an Opus advisor review at commit ed299f9, for findings F1–F6
in `docs/bug-hunt-2026-10-12.md`, plus two findings added during planning (F7,
F8). Split into **B2a** (pure functions, no protocol change) and **B2b**
(concurrency and protocol), to be reviewed separately. Out of scope: the undo
spec, mirror Phase 2 (it will reuse `merge.lua` from B2b), and the file-restore
path (`init.lua` ~362-427).

Three protocol behaviours here are recalled from Overleaf's server code, not
verified. The live stress run must confirm each one:

- the `applyOtUpdate` callback fires when the update is *queued*, not when it is
  applied;
- the ack's `v` is the version the op was applied at;
- ops returned by `joinDoc` carry `meta.source`.

**Observed live 2026-10-12** (two-client stress run on the B2a code, with emoji):
- The emit callback fires before the server has ordered our op. When a
  collaborator's op is ordered first, the client logs "ACK received, now v26",
  then gets the collaborator's op stamped v25 ("Version mismatch: expected 26,
  got 25").
- The op-less `otUpdateApplied` for our op then arrives with `v=26`. So **the
  ack's `v` is the applied-at version (confirmed)**, and the callback is not an
  ack (F7 confirmed).
- The client then sends an op based on the wrong state. The server answers
  `otUpdateError "Delete component does not match"` and **boots the socket**
  (`disconnect reason=booted`).
- The reconnect's rejoin drops unacked edits (F5). Runs end around 60–150 bytes
  after 60 edits.
- So B2a alone does not make live editing converge; B2b is required.

---

## B2a: pure functions

**Done 2026-10-12 (ec8d415).** An adversarial Opus review fuzzed 10,000 more cases against text0
and 3,000 simulated documents through `Document:on_remote_op`, with no mismatches. Its one
regression (cursor and comment rendering raising on a stale offset inside a surrogate pair) is fixed
by `ot.u16_to_byte_floor`. Open items carried to B2b:
- `on_remote_op` returns on an empty op without bumping the version. Overleaf broadcasts ops that
  transform to `[]`, for example two users deleting the same text, so each one forces a rejoin.
- `_on_ack` calls strict `ot.apply` without a pcall.
- `ipairs(nil)` crashes when a rejoin clears `inflight_op` before the ack arrives.
- Comment components inside remote ops are not position-transformed, so a highlight can be off
  while an op is in flight.
- `transform_x` recurses once per split. About 8,000 local inserts inside one remote delete
  overflow the stack; the pcall catches it and the document rejoins. text0 has the same property.

### F1/F2: transform (`ot.lua`)

Rewrite `transform_component` (~110-199) and `transform_ops` (~206-225) as a
straight port of ShareJS text0, which Overleaf's `text` type matches for insert
and delete. The reference is `ot-json0/lib/text0.js`, which is a test
dependency in `tests/node/package.json`.

Helpers. All positions and lengths are UTF-16 units (see F3).

- `append(dest, c)` must copy `c` and merge exactly as text0 does, so client and
  server normalise identically:
  1. drop `c` if its `i` or `d` is `''`;
  2. if both `last` and `c` are inserts and
     `last.p <= c.p <= last.p + len(last.i)`, replace `last` with
     `{p=last.p, i=inject(last.i, c.p-last.p, c.i)}`;
  3. if both are deletes and `c.p <= last.p <= c.p + len(c.d)`, replace `last`
     with `{p=c.p, d=inject(c.d, last.p-c.p, last.d)}`;
  4. otherwise push.
- `tpos(pos, c, insert_after)`:
  - `c` is an insert: return `pos + len(c.i)` if `c.p < pos` or
    (`c.p == pos` and `insert_after`); otherwise `pos`.
  - `c` is a delete: return `pos` if `pos <= c.p`; `c.p` if
    `pos <= c.p + len(c.d)`; otherwise `pos - len(c.d)`.
  - `c` is anything else (a comment): return `pos`.

`tc(dest, c, o, side)`, one component against another:

- **`c` is an insert:** `append(dest, {p=tpos(c.p, o, side=='right'), i=c.i})`.
- **`c` is a delete and `o` is an insert:**
  1. `s = c.d`.
  2. If `c.p < o.p`, append `{p=c.p, d=sub(s,0,o.p-c.p)}` and set
     `s = sub(s,o.p-c.p)`.
  3. If `s ~= ''`, append `{p=c.p+len(o.i), d=s}`. This is the F1 fix: today's
     code also adds `len(before)` to the position.
- **`c` is a delete and `o` is a delete:**
  - if `c.p >= o.p+len(o.d)`, append `{p=c.p-len(o.d), d=c.d}`;
  - else if `c.p+len(c.d) <= o.p`, append `c`;
  - otherwise they overlap. Build `nd`: `c.d`'s prefix before `o.p` plus its
    suffix after `o.p+len(o.d)`. Assert that the overlapping text is equal in
    both, or `error()`. If `nd ~= ''`, append `{p=tpos(c.p,o), d=nd}`.
- **A comment component** (`c` field) on either side: append `c` unchanged.
  `apply` ignores comments.

`transform_x(left, right)`, list against list, a port of ShareJS
`bootstrapTransform`:

```
new_right = {}
for each rc in right:
  r = rc; new_left = {}; k = 1
  while k <= #left:
    nr = {}
    tc(new_left, left[k], r, 'left'); tc(nr, r, left[k], 'right'); k = k + 1
    if #nr == 1 then r = nr[1]
    elseif #nr == 0 then append rest of left[k..] to new_left; r = nil; break
    else l2, r2 = transform_x(slice(left,k), nr); append l2 to new_left
         append r2 to new_right; r = nil; break end
  if r then append(new_right, r) end
  left = new_left
return left, new_right
```

- `transform_ops(ops, other, side)`:
  - if `other` is empty, return a copy;
  - `'left'` returns `transform_x(ops, other)` (its first result);
  - `'right'` returns the second result of `transform_x(other, ops)`.
- Keep `transform_component` as a wrapper around `tc`. Leave `compose` as
  concatenation.
- `document.lua` ~249-258 calls `transform_x` directly, so each pair is
  consistent:
  - `inflight, r = transform_x(inflight, remote)`
  - `pending, r = transform_x(pending, r)`
  - `ops_to_apply = r`
- **Strict `apply`** (`ot.lua` ~84-101): `error()` when the deleted text does not
  match. Every caller already uses `pcall`.
- **Strict `buffer.apply_ops`** (~310-331): compare the buffer slice with `op.d`
  before deleting, and fail on a mismatch so the full-replace fallback runs.

Test changes: `ot_spec.lua` ~192 expects 7 (not 9). New regressions:

- F1: `ABCDEF`, delete `BCDE`@1 against insert `X`@3 converges to `AXF`;
- F2: `[X@0, Y@1]` against `Z@0`;
- inserts at exactly the start and the end of a delete;
- overlapping deletes whose text differs raise an error.

Property tests (`tests/overleaf/ot_property_spec.lua`, seeded, about 2000 cases):

- **Inputs:** the alphabet is `a b ␠ \n é 日 😀 𝔸`. Ops have 1–4 sequential
  components, built against a running copy of the text. Positions are picked
  as character indices and converted to UTF-16, so a surrogate pair is never
  split.
- **Properties:**
  1. convergence: `apply(apply(s,a), r) == apply(apply(s,b), l)`, with strict
     apply;
  2. `transform_ops` agrees with `transform_x`;
  3. transforming against an empty op is the identity.
- **Reference fixtures:** `tests/node/gen-ot-fixtures.js` uses a seeded
  generator and `ot-json0/lib/text0` to write `tests/fixtures/ot_text0.json`
  (about 1000 cases of `{s, a, b, left, right}`), which is committed. The Lua
  spec deep-compares its results with the fixtures, so the Lua tests need no
  Node at runtime.

### F3: UTF-16 positions throughout Lua; no conversion in Node

Every op position and length in Lua becomes a UTF-16 code unit, as in ShareJS,
the hash, and the comment offsets the server sends.

- Node is not used for this: it holds no document state, so it could not
  convert remote ops.
- Mixing code points and UTF-16 would mean two coordinate systems in one module.

Changes:

- **`ot.lua`:** replace `utf8_len`, `byte_to_char` and `char_to_byte` with
  `u16_len`, `byte_to_u16` and `u16_to_byte`. Remove the old names so any missed
  call site fails loudly.
  - A 4-byte UTF-8 sequence counts as 2 units; anything else counts as 1.
  - `u16_to_byte` raises an error if the position falls between the two halves
    of a surrogate pair.
  - Use these in `apply`, `tc`, `sub`, `inject` and `append`.
- **`buffer.lua`:** `reconcile` (~250) uses `byte_to_u16`; `apply_ops`
  (~316, ~323) uses `u16_to_byte`.
- **`diff.lua`:** ~135 uses `byte_to_u16`; ~206 uses `u16_len`. The tokenizer
  already keeps multibyte characters whole.
- **`comments.lua`:** ~70 and ~78 use `u16_len(op.c)`; ~89 `u16_to_byte`; ~109
  `byte_to_u16`.
- **`cursors.lua`** ~103-104: `collab.col` is a UTF-16 column. Convert it with
  `u16_to_byte(line, col)`, clamped to the line.
- **`node/socket.js`:** unchanged. The hash becomes correct once positions are
  UTF-16.

Test changes:

- `buffer_spec.lua` ~317: `p` 2 → 3 (`A😀B`).
- Rename the conversion tests in `ot_spec.lua` and add astral-plane cases.
- `diff_spec`: add a case with `𝔸`.

### F8: decode encoded range strings (`node/socket.js` ~252-261)

With `encodeRanges: true`, Overleaf Latin-1-encodes the strings
`comment.op.c`, `change.op.i` and `change.op.d`. Today they are decoded only
when `ranges` is a string, so comments with non-ASCII text come out garbled.
Decode those fields the same way the lines are decoded (~248-250). Add a Node
test with an encoded fixture, and confirm live with a comment on `é` or `😀`.

---

## B2b: concurrency and protocol

### F4: reconcile, transform and buffer apply in one tick

`bridge.lua` ~166-175 already delivers events in order from a scheduled
callback. Add `Document:receive(update)`; the `init.lua` handler (~316-328)
becomes `if doc then doc:receive(data) end`. `receive` runs these steps:

1. If `_rejoining` or `_joining`, add the update to `self._queued` and return.
2. If the document is not joined, return.
3. Reconcile synchronously first, when the document has a buffer.
4. If the update has no `op`, it is our ack (F7): call `_on_ack(update)`.
5. Otherwise call `on_remote_op(update, function(ops) buffer.apply_remote(self, ops) end)`,
   then `sync.schedule_write(self)`.

`buffer.apply_remote` (~349-380) becomes synchronous:

- remove its `vim.schedule`;
- remove its `M.reconcile(doc)`, which caused F4, and replace it with
  `assert(doc._dirty == nil)`;
- keep `applying_remote` set for the whole apply (on_lines returns early, so
  nothing re-enters);
- wrap the apply in `pcall`; on a textlock or E11 error, retry a full replace
  from `doc.content` on the next tick.

Keep `on_remote_op`'s signature.

### F7: ack on the server's op-less event, not on the emit callback

Today `document.lua` ~102-111 treats the `applyOtUpdate` callback as the ack,
and `init.lua` ~317-319 drops op-less `otUpdateApplied` events. When the server
orders a collaborator's op before ours, the versions mismatch and the document
rejoins.

- The callback handles errors only.
- `_on_ack` runs from an op-less event while `inflight_op ~= nil`, and is
  ignored with a debug log otherwise. Log the ack's `v` so the live run settles
  the convention.
- Add a 10 s watchdog that calls `rejoin()` if no ack arrives.

**Hash risk:** if the server checks the hash after transforming our op, every
concurrent edit will error "Invalid hash". The stress harness must count hash
errors. If there are any, stop sending the hash; it is optional in the
protocol.

### F5/F6: rejoin without losing anything

**New `lua/overleaf/merge.lua`.** `three_way(base, mine, theirs) -> merged | nil`
follows the D1 rule:

- word-level hunks, treated as closed intervals in base coordinates;
- overlapping or touching hunks are a conflict, except identical hunks, which
  are taken once;
- otherwise apply all the disjoint hunks to `base` in descending position order.

Mirror Phase 2 reuses it.

**`Document:rejoin()` rewrite** (~128-195):

1. **Keep the state.**
   - Set `_rejoining`. Do NOT clear `inflight_op`, `pending_ops`, `content` or
     `server_content`. Stop the flush timer.
   - The first attempt runs after about 200 ms; later attempts keep the existing
     backoff.
2. **Keep recording typing during the rejoin.**
   - `buffer.lua` ~276: `if not doc.joined then return` becomes
     `if doc.content == nil then return end`.
   - `buffer.lua` ~204-207: drop dirty only if `content == nil`.
   - `submit_op` composes into pending while joined or rejoining.
   - `flush` refuses while rejoining.
3. **Catch-up join.** Call `joinDoc` with `fromVersion = self.version`.
   `socket.js` ~241-245 takes `fromVersion` (default -1) and returns the
   updates; `bridge.js` ~168-173 passes it through. If the server refuses
   (range unavailable), go to step 5.
4. **Process the catch-up.** Reconcile synchronously, then for each update in
   order:
   - `u.v ~= version` → step 5;
   - `u.meta.source` is one of our public ids → it is the ack of the in-flight
     op (with no in-flight op → step 5);
   - anything else → `on_remote_op` with the synchronous buffer apply.

   Our public ids live in `state.public_ids`, starting from `result.publicId`
   (`init.lua` ~287) and appended on every reconnect (~639).

   Afterwards:
   - require `version == result.version` and `server_content == joined text`,
     or go to step 5;
   - set `pending = compose(inflight or {}, pending or {})` and `inflight = nil`;
   - replay `_queued`: skip `v < version`, apply `v == version`, rejoin again on
     `v > version`, and drop op-less events;
   - set `joined = true` and `_rejoining = false`, then call `_schedule_flush()`
     and `sync.schedule_write(self)`. The last call also fixes M1.
5. **Fallback text merge.** Also used directly after a `check_content`
   divergence.
   1. Rejoin with `fromVersion = -1`.
   2. Take base = the old `server_content`, mine = the buffer text (or
      `content`), theirs = the joined text.
   3. Merge: `merged = merge.three_way(base, mine, theirs)`. Identical hunks
      cover the case where our op was applied but its ack was lost.
   4. On conflict: `merged = theirs`, save mine to
      `stdpath('state')/overleaf/recovery/<doc>-<timestamp>.tex`, and WARN naming
      the file.
   5. Bring the buffer to `merged` under `applying_remote`.
   6. Set `server_content = theirs`, the version from the join,
      `content = merged`, `inflight = nil`, and `pending = diff.ops(theirs, merged)`
      if that is non-empty.
6. **F6, the empty document.** Delete the guard at ~163-174.
   - `server_content` is set only ever from the server's lines.
   - Same version but different text from base: inconsistent, so retry and
     apply nothing.
7. **Bounded retries.**
   - `flush`'s error path keeps `inflight_op` and calls `rejoin()`.
   - The same resent op erroring twice → step 5. If that also fails, save a
     recovery file and stop with an ERROR.
8. **Reconnect.** `_rejoin_documents` (`init.lua` ~650-665) stops clearing ops
   and just calls `rejoin()`.
9. **Initial join.** `Document:join` uses the same `_joining` queue and drops
   events with `v < version`.

Test changes:

- `document_spec.lua` ~179-187: while rejoining, ops go into pending and are not
  flushed.
- `buffer_spec.lua` ~250: "ignores changes when not joined" now applies only
  when `content == nil`. Add a case where a rejoining document records a change.

### Tests (offline, runnable without network)

- **F4:** in the same tick, a dirty buffer receives a remote op. The
  collaborator's text survives, and buffer == `doc.content` immediately. No ops
  are produced by on_lines re-entry.
- **F7:**
  - the callback alone does not ack, and an op-less event does;
  - a remote op that arrives between our send and our ack is transformed with no
    rejoin;
  - the watchdog fires.
- **F5/F6 with a stub bridge:**
  - catch-up where our op appears as our own, and where it is absent (resend);
  - catch-up unavailable → merge;
  - typing during the rejoin is kept;
  - an empty-document conflict writes a recovery file and leaves
    `server_content == ''`;
  - same version but different text → retry;
  - a reconnect keeps pending ops.
- **`merge.lua`:** disjoint, overlapping, touching and identical hunks, plus
  astral characters.
- **Simulation (`tests/overleaf/ot_sim_spec.lua`):**
  - an in-memory server transforms incoming ops `'left'` against its history
    since `v`, sends the callback immediately, and sends the ack and broadcasts
    with random delays;
  - two `Document`s with scratch buffers make random edits through
    `nvim_buf_set_text`, sometimes several per tick, with forced rejoins mixed
    in;
  - 200 seeds must all converge.
- **Mock server** (`tests/node/mock-server.js` ~209-300):
  - transforms against its history with text0, and calls back before applying;
  - acks with `v` = the applied-at version and sets `meta.source`;
  - `joinDoc` honours `fromVersion`;
  - optional message delays;
  - a hash-policy flag.

### Live two-client stress test (the lead runs it in the LaTeX sandbox)

Two headless clients on one throwaway document make random concurrent
`nvim_buf_set_text` edits (ASCII, `é`, `日本`, `😀`, `𝔸`; multi-line; bursts;
optional forced rejoins; editing and suggesting modes).

They pass only if all of these hold:

- in each client, buffer == `doc.content`, and A == B;
- a fresh `joinDoc` returns the same text;
- the logs show no divergence, no "OT update failed" and no hash `otUpdateError`;
- no recovery files are written;
- rejoins happen only when forced.

Record the observed protocol facts: the ack `v` convention, whether catch-up
updates carry `meta.source`, and whether a hash error appears under concurrency.
