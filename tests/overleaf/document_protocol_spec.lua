local calls = {}
package.loaded['overleaf.bridge'] = {
  request = function(method, params, cb) calls[#calls + 1] = { method = method, params = params, cb = cb } end,
}
package.loaded['overleaf.config'] = { log = function() end }
package.loaded['overleaf'] = { _state = { connected = true, public_ids = { mine = true } } }
package.loaded['overleaf.sync'] = { schedule_write = function() end }
local Document = require('overleaf.document')
local buffer = require('overleaf.buffer')
local active = {}

local function doc(base)
  local d = Document.new('protocol', '/protocol.tex')
  d.joined, d.version, d.server_content, d.content = true, 0, base, base
  d._schedule_flush = function() end
  active[#active + 1] = d
  return d
end

local function wait_rejoin(d)
  assert.is_true(vim.wait(350, function()
    for _, call in ipairs(calls) do
      if call.method == 'joinDoc' then return true end
    end
    return false
  end, 5))
  assert.are.equal('joinDoc', calls[#calls].method)
end

describe('document protocol', function()
  before_each(function() calls = {} end)
  after_each(function()
    for _, d in ipairs(active) do
      if d._flush_timer then vim.fn.timer_stop(d._flush_timer) end
      if d._ack_timer then vim.fn.timer_stop(d._ack_timer) end
    end
    active = {}
  end)

  it('the emit callback does not ACK; an op-less event does', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    assert.are.equal('applyOtUpdate', calls[1].method)
    assert.are.equal(1, #vim.fn.timer_info(d._ack_timer))
    calls[1].cb(nil, {})
    assert.are.equal(0, d.version)
    assert.is_not_nil(d.inflight_op)
    d:receive({ v = 0 })
    assert.are.equal(1, d.version)
    assert.are.equal('ab', d.server_content)
    assert.is_nil(d.inflight_op)
  end)

  it('reconciles a dirty buffer before transforming and applying remote text', function()
    local d = doc('a')
    d.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(d.bufnr, 0, -1, false, { 'a' })
    buffer.attach(d.bufnr, d)
    vim.api.nvim_buf_set_text(d.bufnr, 0, 1, 0, 1, { 'b' })
    d:receive({ v = 0, op = { { p = 0, i = 'X' } } })
    assert.are.equal('Xab', d.content)
    assert.are.equal('Xab', table.concat(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false), '\n'))
    assert.are.same({ { p = 2, i = 'b' } }, d.pending_ops)
    assert.is_nil(d._dirty)
    vim.api.nvim_buf_delete(d.bufnr, { force = true })
  end)

  it('rejoins when the ACK watchdog expires', function()
    local d = doc('a')
    d.inflight_op = { { p = 1, i = 'b' } }
    local defer = vim.defer_fn
    vim.defer_fn = function() end
    d:_on_ack_timeout()
    vim.defer_fn = defer
    assert.is_true(d._rejoining)
    assert.is_not_nil(d.inflight_op)
  end)

  it('treats op={} as a broadcast and transforms a remote op before ACK', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    d:receive({ v = 0, op = {} })
    assert.are.equal(1, d.version)
    assert.is_not_nil(d.inflight_op)
    d:receive({ v = 1, op = { { p = 0, i = 'X' } } })
    assert.are.equal('Xab', d.content)
    d:receive({ v = 2 })
    assert.are.equal('Xab', d.server_content)
    assert.are.equal(3, d.version)
    assert.is_nil(d.inflight_op)
  end)

  it('a stale ACK with no inflight op is dropped; a current one catches up', function()
    local d = doc('a')
    d.version = 1
    local defer = vim.defer_fn
    vim.defer_fn = function() end
    d:receive({ v = 0 })
    assert.are.equal(1, d.version)
    assert.is_falsy(d._rejoining)
    d:receive({ v = 1 })
    vim.defer_fn = defer
    assert.are.equal(1, d.version)
    assert.is_true(d._rejoining)
  end)

  it('strict ACK apply failure enters merge rejoin', function()
    local d = doc('a')
    d.inflight_op = { { p = 0, d = 'wrong' } }
    local defer = vim.defer_fn
    vim.defer_fn = function() end
    d:receive({ v = 0 })
    vim.defer_fn = defer
    assert.is_true(d._rejoining)
    assert.is_not_nil(d.inflight_op)
  end)

  it('catches up an own operation using the public ID', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    calls = {}
    d:rejoin()
    wait_rejoin(d)
    assert.are.equal(0, calls[1].params.fromVersion)
    calls[1].cb(nil, {
      lines = { 'ab' },
      version = 1,
      updates = { { v = 0, op = { { p = 1, i = 'b' } }, meta = { source = 'mine' } } },
    })
    assert.are.equal('ab', d.server_content)
    assert.is_nil(d.inflight_op)
    assert.is_false(d._rejoining)
  end)

  it('keeps an absent in-flight op in flight and resends it', function()
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:flush()
    calls = {}
    d:rejoin()
    wait_rejoin(d)
    calls[1].cb(nil, { lines = { 'a' }, version = 0, updates = {} })
    assert.are.same({ { p = 1, i = 'b' } }, d.inflight_op)
    assert.is_nil(d.pending_ops)
    assert.is_false(d._rejoining)
    d:flush()
    assert.are.equal('applyOtUpdate', calls[2].method)
    assert.are.same({ 'mine' }, calls[2].params.dupIfSource)
  end)

  it('merges disjoint text in the fallback', function()
    local d = doc('red blue green')
    d.content = 'RED blue green'
    d:rejoin('merge')
    wait_rejoin(d)
    assert.are.equal(-1, calls[1].params.fromVersion)
    calls[1].cb(nil, { lines = { 'red blue GREEN' }, version = 3, ranges = {} })
    assert.are.equal('RED blue GREEN', d.content)
    assert.are.equal('red blue GREEN', d.server_content)
    assert.is_not_nil(d.pending_ops)
  end)

  it('recovers a conflict when the server document becomes empty', function()
    local d = doc('base')
    d.content = 'mine'
    d:rejoin('merge')
    wait_rejoin(d)
    assert.are.equal(-1, calls[1].params.fromVersion)
    local pattern = vim.fn.stdpath('state') .. '/overleaf/recovery/protocol-*'
    local before = vim.fn.glob(pattern, false, true)
    calls[1].cb(nil, { lines = { '' }, version = 1, ranges = {} })
    local after = vim.fn.glob(pattern, false, true)
    assert.are.equal(#before + 1, #after)
    assert.are.equal('', d.content)
    assert.are.equal('', d.server_content)
    local file = after[#after]
    assert.are.equal('mine', table.concat(vim.fn.readfile(file), '\n'))
    assert.are.equal(384, bit.band(vim.loop.fs_stat(file).mode, 511))
    vim.fn.delete(file)
  end)

  it('records typing during a rejoin', function()
    local d = doc('a')
    d.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(d.bufnr, 0, -1, false, { 'a' })
    buffer.attach(d.bufnr, d)
    d:rejoin()
    vim.api.nvim_buf_set_text(d.bufnr, 0, 1, 0, 1, { 'b' })
    buffer.reconcile(d)
    assert.are.equal('ab', d.content)
    assert.are.same({ { p = 1, i = 'b' } }, d.pending_ops)
    vim.api.nvim_buf_delete(d.bufnr, { force = true })
  end)

  it('retries when a join has the same version but different text', function()
    local scheduled, defer = {}, vim.defer_fn
    vim.defer_fn = function(fn) scheduled[#scheduled + 1] = fn end
    local d = doc('a')
    d:rejoin()
    scheduled[1]()
    calls[1].cb(nil, { lines = { 'x' }, version = 0, updates = {} })
    vim.defer_fn = defer
    assert.are.equal(2, #scheduled)
    assert.is_true(d._rejoining)
    assert.are.equal('a', d.server_content)
    assert.are.equal('a', d.content)
  end)

  it('keeps pending edits when rejoin starts', function()
    local scheduled, defer = {}, vim.defer_fn
    vim.defer_fn = function(fn) scheduled[#scheduled + 1] = fn end
    local d = doc('a')
    d.pending_ops, d.content = { { p = 1, i = 'b' } }, 'ab'
    d:rejoin()
    vim.defer_fn = defer
    assert.are.same({ { p = 1, i = 'b' } }, d.pending_ops)
    assert.are.equal('ab', d.content)
    assert.are.equal('a', d.server_content)
  end)

  it('queues initial-join events and drops versions already in the snapshot', function()
    local d = Document.new('protocol', '/protocol.tex')
    d:join()
    d:receive({ v = 2, op = { { p = 0, i = 'old' } } })
    d:receive({ v = 3, op = { { p = 0, i = 'X' } } })
    calls[1].cb(nil, { lines = { 'a' }, version = 3, ranges = {} })
    assert.are.equal('Xa', d.content)
    assert.are.equal(4, d.version)
  end)
end)
