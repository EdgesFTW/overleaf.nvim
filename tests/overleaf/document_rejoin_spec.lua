-- Regressions for the B2b review: duplicate resends, bounded retries, wedged
-- rejoins, stale events, and the fallback merge.
local calls = {}
local logs = {}
package.loaded['overleaf.bridge'] = {
  request = function(method, params, cb) calls[#calls + 1] = { method = method, params = params, cb = cb } end,
}
package.loaded['overleaf.config'] = {
  log = function(level, fmt, ...) logs[#logs + 1] = { level = level, msg = string.format(fmt, ...) } end,
}
local state = { connected = true, public_id = 'mine', public_ids = { mine = true } }
local reconnects = {}
package.loaded['overleaf'] = {
  _state = state,
  _force_reconnect = function(reason) reconnects[#reconnects + 1] = reason end,
}
package.loaded['overleaf.sync'] = { schedule_write = function() end }
local Document = require('overleaf.document')
local buffer = require('overleaf.buffer')
local merge = require('overleaf.merge')
local ot = require('overleaf.ot')

local active = {}
local scheduled = {}
local defer = vim.defer_fn
local stdpath = vim.fn.stdpath
local state_dir = vim.fn.tempname()

local function doc(base)
  local d = Document.new('rejoin', '/rejoin.tex')
  d.joined, d.version, d.server_content, d.content = true, 0, base, base
  d._schedule_flush = function() end
  active[#active + 1] = d
  return d
end

local function with_buffer(d, text)
  d.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(d.bufnr, 0, -1, false, vim.split(text, '\n', { plain = true }))
  buffer.attach(d.bufnr, d)
  return d
end

local function text(d) return table.concat(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false), '\n') end

local function run_scheduled()
  local fn = table.remove(scheduled, 1)
  assert.is_not_nil(fn, 'nothing scheduled')
  fn()
end

local function last(method)
  for i = #calls, 1, -1 do
    if calls[i].method == method then return calls[i] end
  end
end

local function count(method)
  local n = 0
  for _, call in ipairs(calls) do
    if call.method == method then n = n + 1 end
  end
  return n
end

local function logged(level, pattern)
  for _, entry in ipairs(logs) do
    if entry.level == level and entry.msg:find(pattern) then return entry.msg end
  end
end

describe('document rejoin regressions', function()
  before_each(function()
    calls, logs, scheduled, reconnects = {}, {}, {}, {}
    state.connected, state.public_id, state.public_ids = true, 'mine', { mine = true }
    vim.defer_fn = function(fn) scheduled[#scheduled + 1] = fn end
    vim.fn.stdpath = function(what)
      if what == 'state' then return state_dir end
      return stdpath(what)
    end
  end)
  after_each(function()
    vim.defer_fn = defer
    vim.fn.stdpath = stdpath
    for _, d in ipairs(active) do
      if d._flush_timer then vim.fn.timer_stop(d._flush_timer) end
      if d._ack_timer then vim.fn.timer_stop(d._ack_timer) end
      if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then vim.api.nvim_buf_delete(d.bufnr, { force = true }) end
    end
    active = {}
    vim.fn.delete(state_dir, 'rf')
  end)

  it('resends a still-queued in-flight op with dupIfSource and applies it once', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    calls[1].cb(nil, {})
    d:_on_ack_timeout()
    run_scheduled()
    assert.are.equal('joinDoc', calls[2].method)
    assert.are.equal(0, calls[2].params.fromVersion)
    -- The server has not ordered the op yet: the catch-up is empty.
    calls[2].cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
    assert.is_false(d._rejoining)
    assert.is_nil(d.pending_ops)
    assert.are.same({ { p = 1, i = 'b' } }, d.inflight_op)
    d:flush()
    local resend = calls[3]
    assert.are.equal('applyOtUpdate', resend.method)
    assert.are.equal(0, resend.params.v)
    assert.are.same({ 'mine' }, resend.params.dupIfSource)
    -- The original is applied at v0; the resend is a duplicate (P3).
    d:receive({ v = 0 })
    assert.are.equal(1, d.version)
    assert.is_nil(d.inflight_op)
    assert.are.equal('ab', d.server_content)
    d:receive({ v = 0 })
    assert.are.equal(1, d.version)
    assert.is_falsy(d._rejoining)
    assert.are.equal('ab', d.content)
  end)

  it('keeps edits typed during the resend pending until the in-flight op is acked', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    d:rejoin()
    d:submit_op({ { p = 2, i = 'c' } })
    d.content = 'abc'
    run_scheduled()
    calls[2].cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
    d:flush()
    assert.are.same({ { p = 1, i = 'b' } }, calls[3].params.op)
    assert.are.same({ { p = 2, i = 'c' } }, d.pending_ops)
    d:flush()
    assert.are.equal(3, #calls)
    d:receive({ v = 0 })
    d:flush()
    assert.are.same({ { p = 2, i = 'c' } }, calls[4].params.op)
    assert.are.equal(1, calls[4].params.v)
    assert.is_nil(calls[4].params.dupIfSource)
  end)

  it('treats a broadcast of our op from an earlier socket as its ACK', function()
    local d = doc('a')
    state.public_id = 's1'
    state.public_ids = { s1 = true }
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    -- Reconnect under a new public id before the op is ordered.
    state.public_id = 's2'
    state.public_ids.s2 = true
    d:rejoin()
    run_scheduled()
    calls[2].cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
    d:flush()
    local resend = calls[3]
    table.sort(resend.params.dupIfSource)
    assert.are.same({ 's1', 's2' }, resend.params.dupIfSource)
    -- The new socket receives the original as somebody else's op.
    d:receive({ v = 0, op = { { p = 1, i = 'b' } }, meta = { source = 's1' } })
    assert.are.equal('ab', d.content)
    assert.are.equal('ab', d.server_content)
    assert.are.equal(1, d.version)
    assert.is_nil(d.inflight_op)
    d:receive({ v = 0 })
    assert.are.equal(1, d.version)
    assert.is_falsy(d._rejoining)
  end)

  it('acks through a catch-up update sent from an earlier socket', function()
    local d = doc('a')
    state.public_id = 's1'
    state.public_ids = { s1 = true }
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    state.public_id = 's2'
    state.public_ids.s2 = true
    d:rejoin()
    run_scheduled()
    calls[2].cb(nil, {
      lines = { 'Xab' },
      version = 2,
      updates = {
        { v = 0, op = { { p = 0, i = 'X' } }, meta = { source = 'other' } },
        { v = 1, op = { { p = 2, i = 'b' } }, meta = { source = 's1' } },
      },
      ranges = {},
    })
    assert.is_nil(d.inflight_op)
    assert.are.equal('Xab', d.content)
    assert.are.equal(2, d.version)
    d:flush()
    assert.are.equal(2, #calls)
  end)

  it('gives up after three rejoins with the same op unacked: recovery file, server text, ERROR', function()
    local d = with_buffer(doc('a'), 'a')
    vim.api.nvim_buf_set_text(d.bufnr, 0, 1, 0, 1, { 'b' })
    buffer.reconcile(d)
    d:flush()
    local pattern = vim.fn.stdpath('state') .. '/overleaf/recovery/rejoin-*'
    local before = #vim.fn.glob(pattern, false, true)
    for round = 1, 3 do
      d:rejoin()
      run_scheduled()
      last('joinDoc').cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
      assert.is_false(d._rejoining)
      if round < 3 then
        d:flush()
        assert.are.equal('applyOtUpdate', calls[#calls].method)
      end
    end
    local after = vim.fn.glob(pattern, false, true)
    assert.are.equal(before + 1, #after)
    assert.are.equal('ab', table.concat(vim.fn.readfile(after[#after]), '\n'))
    vim.fn.delete(after[#after])
    assert.is_nil(d.inflight_op)
    assert.is_nil(d.pending_ops)
    assert.are.equal('a', d.content)
    assert.are.equal('a', text(d))
    assert.is_truthy(logged('error', vim.pesc(after[#after])))
    local sends = count('applyOtUpdate')
    d:flush()
    assert.are.equal(sends, count('applyOtUpdate'))
  end)

  it('a failing recovery write keeps the local text and stops sending', function()
    local d = with_buffer(doc('base'), 'mine')
    d.content = 'mine'
    d.pending_ops = { { p = 0, d = 'base' }, { p = 0, i = 'mine' } }
    local fs_open = vim.loop.fs_open
    vim.loop.fs_open = function() return nil, 'EROFS: read-only file system' end
    local ok, err = pcall(function()
      d:rejoin('merge')
      run_scheduled()
      calls[1].cb(nil, { lines = { 'theirs' }, version = 1, ranges = {} })
    end)
    vim.loop.fs_open = fs_open
    assert.is_true(ok, tostring(err))
    assert.is_false(d._rejoining)
    assert.is_true(d._stopped)
    assert.are.equal('mine', text(d))
    assert.is_truthy(logged('warn', 'EROFS'))
    assert.is_truthy(logged('error', 'only in the buffer'))
    d:flush()
    d:receive({ v = 1, op = { { p = 0, i = 'X' } } })
    assert.are.equal(0, count('applyOtUpdate'))
    assert.are.equal('mine', text(d))
    -- A later rejoin merges again; this time the file can be written.
    d:rejoin()
    run_scheduled()
    last('joinDoc').cb(nil, { lines = { 'theirs' }, version = 1, ranges = {} })
    assert.are.equal(-1, last('joinDoc').params.fromVersion)
    assert.is_true(d.joined)
    assert.is_false(d._stopped)
    assert.are.equal('theirs', text(d))
  end)

  it('a give-up whose recovery write fails keeps the local text', function()
    local d = with_buffer(doc('a'), 'a')
    vim.api.nvim_buf_set_text(d.bufnr, 0, 1, 0, 1, { 'b' })
    buffer.reconcile(d)
    d:flush()
    local fs_open = vim.loop.fs_open
    vim.loop.fs_open = function() return nil, 'EROFS: read-only file system' end
    for _ = 1, 3 do
      d:rejoin()
      run_scheduled()
      last('joinDoc').cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
      d:flush()
    end
    vim.loop.fs_open = fs_open
    assert.are.equal('ab', text(d))
    assert.is_true(d._stopped)
    assert.is_truthy(logged('error', 'only in the buffer'))
  end)

  it('after giving up, sends nothing on that socket and applies the late original as a remote op', function()
    -- D is sent at v0 and stalls at the server; three catch-ups miss it.
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    for _ = 1, 3 do
      d:_on_ack_timeout()
      run_scheduled()
      last('joinDoc').cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
      d:flush()
    end
    assert.is_nil(d.inflight_op)
    assert.are.equal('a', d.content)
    assert.are.equal(1, #reconnects)
    local sends = count('applyOtUpdate')
    -- The user types; nothing may go out on the socket D was sent from, where
    -- D's op-less ACK would pass for the ACK of this edit.
    d:submit_op({ { p = 1, i = 'c' } })
    d.content = 'ac'
    d:flush()
    assert.are.equal(sends, count('applyOtUpdate'))
    -- New socket. D finally lands; the catch-up shows it from the old source.
    state.public_id = 's2'
    state.public_ids.s2 = true
    d:rejoin()
    run_scheduled()
    last('joinDoc').cb(nil, {
      lines = { 'ab' },
      version = 1,
      updates = { { v = 0, op = { { p = 1, i = 'b' } }, meta = { source = 'mine' } } },
      ranges = {},
    })
    assert.are.equal('ab', d.server_content)
    assert.are.equal(1, d.version)
    assert.are.equal(ot.apply('ab', d.pending_ops), d.content)
    d:flush()
    local send = last('applyOtUpdate')
    assert.are.equal(sends + 1, count('applyOtUpdate'))
    assert.are.equal(1, send.params.v)
    assert.is_nil(send.params.dupIfSource)
    -- Its ACK, and D's duplicate resends ACKed at v0, change nothing else.
    d:receive({ v = 0 })
    d:receive({ v = 1 })
    assert.are.equal(2, d.version)
    assert.are.equal(d.content, d.server_content)
    assert.is_nil(d.inflight_op)
    -- A later resend of the new op names only the new socket.
    d:submit_op({ { p = 0, i = 'Z' } })
    d.content = 'Z' .. d.content
    d:flush()
    d:rejoin()
    run_scheduled()
    last('joinDoc').cb(nil, { lines = { d.server_content }, version = 2, updates = {}, ranges = {} })
    d:flush()
    assert.are.same({ 's2' }, last('applyOtUpdate').params.dupIfSource)
  end)

  it('gives up after two unacked catch-ups once Overleaf has rejected the op', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    d._inflight_rejected = true
    for round = 1, 2 do
      d:rejoin()
      run_scheduled()
      last('joinDoc').cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
      if round == 1 then
        assert.is_not_nil(d.inflight_op)
        d:flush()
      end
    end
    assert.is_nil(d.inflight_op)
    assert.are.equal('a', d.content)
    assert.is_truthy(logged('error', 'after 2 attempts'))
  end)

  it('on the last attempt, same version but different text shows the server text', function()
    local d = with_buffer(doc('base'), 'base mine')
    d.content = 'base mine'
    d.pending_ops = { { p = 4, i = ' mine' } }
    d.version = 4
    d:rejoin('merge')
    for attempt = 1, 5 do
      run_scheduled()
      last('joinDoc').cb(nil, { lines = { 'other' }, version = 4, ranges = {} })
      if attempt < 5 then
        assert.is_true(d._rejoining)
        assert.are.equal('base mine', text(d))
      end
    end
    assert.is_false(d._rejoining)
    assert.is_falsy(d._stopped)
    assert.are.equal('other', text(d))
    assert.are.equal('other', d.content)
    assert.are.equal('other', d.server_content)
    assert.is_nil(d.pending_ops)
    local saved = logged('error', 'Local text saved to')
    assert.is_truthy(saved)
    assert.are.equal('base mine', table.concat(vim.fn.readfile(saved:match('saved to (.*)$')), '\n'))
  end)

  it('an exception inside the rejoin chain clears _rejoining and retries with backoff', function()
    local d = doc('one two three')
    d.content = 'ONE two three'
    local three_way = merge.three_way
    merge.three_way = function() error('boom') end
    local ok = pcall(function()
      d:rejoin('merge')
      run_scheduled()
      calls[1].cb(nil, { lines = { 'one two THREE' }, version = 1, ranges = {} })
    end)
    merge.three_way = three_way
    assert.is_true(ok)
    assert.is_truthy(logged('debug', 'boom') or logged('warn', 'boom') or logged('error', 'boom'))
    assert.are.equal(1, #scheduled)
    run_scheduled()
    last('joinDoc').cb(nil, { lines = { 'one two THREE' }, version = 1, ranges = {} })
    assert.is_false(d._rejoining)
    assert.are.equal('ONE two THREE', d.content)
  end)

  it('drops stale broadcasts and stale ACKs without rejoining', function()
    local d = doc('a')
    d.version = 5
    d:receive({ v = 3, op = { { p = 0, i = 'X' } } })
    d:receive({ v = 4 })
    assert.are.equal(5, d.version)
    assert.are.equal('a', d.content)
    assert.is_falsy(d._rejoining)
    assert.are.equal(0, #scheduled)
  end)

  it('an op-less event at the current version with nothing in flight rejoins', function()
    local d = doc('a')
    d:receive({ v = 0 })
    assert.is_true(d._rejoining)
  end)

  it('processes an ACK queued during the rejoin after the catch-up', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    d:rejoin()
    d:receive({ v = 0 })
    run_scheduled()
    calls[2].cb(nil, { lines = { 'a' }, version = 0, updates = {}, ranges = {} })
    assert.is_nil(d.inflight_op)
    assert.are.equal(1, d.version)
    assert.are.equal('ab', d.server_content)
    d:flush()
    assert.are.equal(2, #calls)
  end)

  it('sanitizes the fallback pending ops and shows the replacement', function()
    local d = with_buffer(doc('q 😀abc'), 'Q 😀abd')
    d.version = 3
    d.content = 'Q 😀abd'
    d.pending_ops = { { p = 0, d = 'q' }, { p = 0, i = 'Q' } }
    d:rejoin('merge')
    run_scheduled()
    calls[1].cb(nil, { lines = { 'q 😀abc' }, version = 3, ranges = {} })
    local _, changed = ot.sanitize_inserts(d.pending_ops or {})
    assert.is_false(changed)
    assert.are.equal(ot.apply(d.server_content, d.pending_ops), d.content)
    assert.are.equal(d.content, text(d))
  end)

  it('retries the catch-up when joinDoc fails and merges only after repeated failure', function()
    local d = doc('red blue green')
    d.content = 'RED blue green'
    d:rejoin()
    run_scheduled()
    calls[1].cb({ code = 'EMIT_ERROR', message = 'history unavailable' })
    run_scheduled()
    assert.are.equal(0, calls[2].params.fromVersion)
    calls[2].cb({ code = 'TIMEOUT', message = 'joinDoc timeout (10s)' })
    run_scheduled()
    assert.are.equal(0, calls[3].params.fromVersion)
    calls[3].cb({ code = 'EMIT_ERROR', message = 'history unavailable' })
    run_scheduled()
    assert.are.equal(0, calls[4].params.fromVersion)
    calls[4].cb({ code = 'EMIT_ERROR', message = 'history unavailable' })
    -- Third real failure: fall back to the text merge.
    if calls[5] == nil then run_scheduled() end
    assert.are.equal(-1, calls[5].params.fromVersion)
    calls[5].cb(nil, { lines = { 'red blue GREEN' }, version = 3, ranges = {} })
    assert.are.equal('RED blue GREEN', d.content)
    assert.is_false(d._rejoining)
  end)

  it('fallback with the same version but different text applies nothing and retries', function()
    local d = with_buffer(doc('base'), 'base')
    d.version = 4
    d:rejoin('merge')
    run_scheduled()
    calls[1].cb(nil, { lines = { '' }, version = 4, ranges = {} })
    assert.is_true(d._rejoining)
    assert.are.equal(1, #scheduled)
    assert.are.equal('base', d.content)
    assert.are.equal('base', d.server_content)
    assert.are.equal('base', text(d))
  end)

  it('a failed buffer apply is repaired synchronously', function()
    local d = with_buffer(doc('abc'), 'abc')
    d.content = 'abcX'
    buffer.apply_remote(d, { { p = 0, d = 'zz' } })
    assert.is_false(d.applying_remote)
    assert.are.equal('abcX', text(d))
  end)

  it('ignores an error callback from an earlier send', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    d:receive({ v = 0 })
    d.pending_ops, d.content = { { p = 2, i = 'c' } }, 'abc'
    d:flush()
    calls[1].cb({ code = 'TIMEOUT', message = 'applyOtUpdate timeout (10s)' })
    assert.is_falsy(d._rejoining)
    calls[2].cb({ code = 'TIMEOUT', message = 'applyOtUpdate timeout (10s)' })
    assert.is_true(d._rejoining)
    assert.is_not_nil(d.inflight_op)
  end)

  it('_show_replacements falls back to set_lines under applying_remote without throwing', function()
    local d = with_buffer(doc('a'), 'a😀')
    d.content = 'a\239\191\189\239\191\189'
    local apply_ops = buffer.apply_ops
    buffer.apply_ops = function() return false, 'stub' end
    local seen
    vim.api.nvim_buf_attach(d.bufnr, false, {
      on_lines = function() seen = d.applying_remote end,
    })
    local ok = pcall(buffer._show_replacements, d)
    buffer.apply_ops = apply_ops
    assert.is_true(ok)
    assert.is_true(seen)
    assert.is_false(d.applying_remote)
    assert.is_nil(d._dirty)
    assert.are.equal(d.content, text(d))
    d.applying_remote = true
    vim.api.nvim_buf_set_lines(d.bufnr, 0, -1, false, { 'zz' })
    d.applying_remote = false
    vim.bo[d.bufnr].modifiable = false
    buffer.apply_ops = function() return false, 'stub' end
    ok = pcall(buffer._show_replacements, d)
    buffer.apply_ops = apply_ops
    assert.is_true(ok)
    assert.is_false(d.applying_remote)
  end)
end)
