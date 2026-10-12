-- Two clients against an in-memory server that follows the live protocol:
--   P1 catch-up updates carry meta.source;
--   P2 the emit callback fires on enqueueing, the op-less ACK carries the applied-at v;
--   P3 dupIfSource drops a resend whose earlier copy was applied, and ACKs it;
--   P4 the hash is checked only on untransformed updates;
--   P5 a rejected op errors every client in the project and disconnects them all;
--   P6 astral characters are stored as U+FFFD (the client sanitizes first).
-- Modes: 'gated' answers joinDoc only once the server queue is empty; 'queued'
-- answers while ops are still queued, sometimes late, sometimes before the
-- events sent ahead of it. Faults: watchdog expiry, forced rejoins, socket
-- drops (new public id), callback timeouts, and injected rejections.
-- Every insert is a unique token, so duplicates and losses are both visible.
local Document = require('overleaf.document')
local bridge = require('overleaf.bridge')
local buffer = require('overleaf.buffer')
local config = require('overleaf.config')
local ot = require('overleaf.ot')
local overleaf = require('overleaf')

local SEEDS = tonumber(os.getenv('SIM_SEEDS') or '') or 200
local ONLY = tonumber(os.getenv('SIM_ONLY') or '')
local VERBOSE = os.getenv('SIM_LOG') ~= nil
local PREFIXES = { '', 'é', '日', '😀', '\n' }
-- Deletes remove base letters, which are unique, so the diff cannot shift a
-- delete across a token boundary (a shifted delete would swallow a concurrent
-- insert's bracket, an OT artefact rather than a protocol bug). The letters are
-- separate words: the text merge diffs by word, and a word it rewrites
-- overwrites a collaborator's concurrent edit inside it.
local BASE = 'a b c d e f g h i j k l m n o p q r s t u v w x y z'
-- w watchdog, r forced rejoin, d socket drop, t callback timeout, i injected
-- rejection, p poisoned op (always rejected), s server queue stalled long enough
-- for a give-up, after which the stalled op lands late, m forced text merge
local FAULTS = os.getenv('SIM_FAULTS') or 'wrdtips'

local function random(seed)
  return function(n)
    seed = (seed * 48271) % 2147483647
    return seed % n + 1
  end
end

local function text(doc) return table.concat(vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false), '\n') end

--- 0-based byte offset -> row, col.
local function pos(str, byte)
  local row, start = 0, 1
  while true do
    local nl = str:find('\n', start, true)
    if not nl or nl > byte then break end
    row, start = row + 1, nl + 1
  end
  return row, byte - (start - 1)
end

local function tokens_in(str)
  local out, init = {}, 1
  while true do
    local s, e = str:find('%[[^%[%]]*%]', init)
    if not s then break end
    out[#out + 1] = { s = s - 1, e = e, n = tonumber(str:sub(s, e):match('(%d+)%]$')) or -1 }
    init = e + 1
  end
  return out
end

--- Byte offsets outside every token.
local function spots(str)
  local out, depth = { 0 }, 0
  for i = 1, #str do
    local c = str:sub(i, i)
    if c == '[' then
      depth = depth + 1
    elseif c == ']' then
      depth = depth - 1
    end
    if depth == 0 then out[#out + 1] = i end
  end
  return out
end

-- The real otUpdateApplied/otUpdateError handlers from init.lua.
local handlers = {}
do
  local on_event, registered, event_handlers = bridge.on_event, overleaf._registered_handlers, bridge._event_handlers
  bridge.on_event = function(name, handler) handlers[name] = handler end
  bridge._event_handlers = {}
  overleaf._registered_handlers = nil
  overleaf._setup_event_handlers()
  bridge.on_event, overleaf._registered_handlers, bridge._event_handlers = on_event, registered, event_handlers
end

local function run_seed(seed, mode, stats, logs, fault_set)
  local rand = random(seed * 7919 + (mode == 'queued' and 1 or 2))
  local server = { content = BASE, version = 0, history = {}, incoming = {}, poison = {}, stall = 0 }
  local deferred, clients, active = {}, {}, nil
  local inserted, deleted, next_token = {}, {}, 0
  local giveups, fallbacks = 0, 0

  local function with(id, fn)
    local prev_state, prev_active = overleaf._state, active
    overleaf._state, active = clients[id].state, id
    local ok, err = pcall(fn)
    overleaf._state, active = prev_state, prev_active
    if not ok then error(err, 0) end
  end
  local function later(id, fn) deferred[#deferred + 1] = { id = id, fn = fn } end
  vim.defer_fn = function(fn) later(active, fn) end

  local function deliver(id, event)
    local c = clients[id]
    if c.alive and (c.joined or event.error) then c.events[#c.events + 1] = event end
  end

  local schedule_reconnect
  local function deliver_one(id)
    local c = clients[id]
    local ev = table.remove(c.events, 1)
    with(id, function()
      if ev.update then
        logs[#logs + 1] = ('DELIVER %d %s'):format(id, vim.inspect(ev.update, { newline = '', indent = '' }))
        handlers.otUpdateApplied(ev.update)
      elseif ev.error then
        handlers.otUpdateError(ev.error)
      elseif ev.disconnect then
        c.state.connected = false
        schedule_reconnect(id)
      end
    end)
  end
  local function flush_events(id)
    while #clients[id].events > 0 do
      deliver_one(id)
    end
  end

  schedule_reconnect = function(id)
    local c = clients[id]
    local wait = rand(4)
    local function attempt()
      if wait > 0 then
        wait = wait - 1
        return later(id, attempt)
      end
      c.sockets = c.sockets + 1
      c.socket, c.alive, c.joined, c.events = c.sockets, true, false, {}
      local public_id = ('c%ds%d'):format(id, c.socket)
      c.state.public_id = public_id
      c.state.public_ids[public_id] = true
      c.state.connected = true
      stats.reconnects = stats.reconnects + 1
      later(id, function() overleaf._rejoin_documents() end)
    end
    later(id, attempt)
  end

  local function drop_socket(id)
    local c = clients[id]
    c.alive, c.events = false, {}
    stats.drops = stats.drops + 1
    with(id, function()
      c.state.connected = false
      schedule_reconnect(id)
    end)
  end

  -- A document that drops an unacknowledged op replaces the socket.
  overleaf._force_reconnect = function()
    local c = clients[active]
    stats.cycles = stats.cycles + 1
    if c.alive and c.state.connected then drop_socket(active) end
  end

  local function boot_all(message)
    stats.boots = stats.boots + 1
    for id = 1, #clients do
      local c = clients[id]
      if c.alive then
        deliver(id, { error = { message = message, doc_id = 'sim' } })
        c.events[#c.events + 1] = { disconnect = true }
        c.alive = false
      end
    end
  end

  bridge.request = function(method, params, cb)
    local id = active
    local c = clients[id]
    local function timeout()
      later(id, function() cb({ code = 'TIMEOUT', message = method .. ' timeout (10s)' }) end)
    end
    if method == 'joinDoc' then
      if not c.alive then return timeout() end
      local socket = c.socket
      local function answer()
        if c.socket ~= socket or not c.alive then return cb({ code = 'TIMEOUT', message = 'joinDoc timeout (10s)' }) end
        if mode == 'gated' and #server.incoming > 0 then return later(id, answer) end
        c.joined = true
        if mode == 'gated' or rand(2) == 1 then flush_events(id) end
        local updates = {}
        if (params.fromVersion or -1) >= 0 then
          for k = params.fromVersion + 1, #server.history do
            updates[#updates + 1] = vim.deepcopy(server.history[k])
          end
        end
        logs[#logs + 1] = ('JOINDOC %d from=%s -> v%d'):format(id, tostring(params.fromVersion), server.version)
        cb(nil, {
          lines = vim.split(server.content, '\n', { plain = true }),
          version = server.version,
          updates = updates,
          ranges = {},
        })
      end
      if mode == 'queued' and rand(3) == 1 then return later(id, answer) end
      answer()
    elseif method == 'applyOtUpdate' then
      if not c.alive then return timeout() end
      server.incoming[#server.incoming + 1] = {
        client = id,
        socket = c.socket,
        source = c.state.public_id,
        op = vim.deepcopy(params.op),
        v = params.v,
        content = params.content,
        dup = params.dupIfSource and vim.deepcopy(params.dupIfSource),
      }
      logs[#logs + 1] = ('SEND %d v=%d dup=%s op=%s'):format(
        id,
        params.v,
        vim.inspect(params.dupIfSource, { newline = '', indent = '' }),
        vim.inspect(params.op, { newline = '', indent = '' })
      )
      if params.dupIfSource then stats.resends = stats.resends + 1 end
      if rand(25) == 1 and fault_set:find('t') then return timeout() end
      cb(nil, {})
    elseif cb then
      cb(nil, {})
    end
  end

  local function process(faults)
    local req = table.remove(server.incoming, 1)
    if req.dup then
      for k = req.v + 1, #server.history do
        if vim.tbl_contains(req.dup, server.history[k].meta.source) then
          stats.dup_dropped = stats.dup_dropped + 1
          if clients[req.client].socket == req.socket then
            deliver(req.client, { update = { doc = 'sim', v = k - 1 } })
          end
          return
        end
      end
    end
    local ok, result = pcall(function()
      assert(req.v <= server.version, 'future version')
      local ops = req.op
      for k = req.v + 1, #server.history do
        ops = ot.transform_ops(ops, server.history[k].op, 'left')
      end
      local new = ot.apply(server.content, ops)
      if req.v == server.version and req.content and ot.apply(req.content, req.op) ~= new then error('Invalid hash') end
      return { ops = ops, content = new }
    end)
    if not ok then
      stats.rejected = stats.rejected + 1
      logs[#logs + 1] = 'REJECT ' .. tostring(result)
      return boot_all(tostring(result))
    end
    for _, c in ipairs(req.op) do
      if c.i and server.poison[c.i] then
        stats.injected = stats.injected + 1
        logs[#logs + 1] = 'POISONED REJECT'
        return boot_all('Delete component does not match')
      end
    end
    if faults and rand(150) == 1 and fault_set:find('p') and req.op[1] and req.op[1].i then
      -- This op is rejected every time it arrives.
      server.poison[req.op[1].i] = true
      stats.poisoned = stats.poisoned + 1
      logs[#logs + 1] = 'POISON ' .. req.op[1].i
      return boot_all('Delete component does not match')
    end
    if faults and rand(40) == 1 and fault_set:find('i') then
      stats.injected = stats.injected + 1
      logs[#logs + 1] = 'INJECTED REJECT'
      return boot_all('Delete component does not match')
    end
    local v = server.version
    server.content, server.version = result.content, v + 1
    server.history[#server.history + 1] = { v = v, op = result.ops, meta = { source = req.source } }
    logs[#logs + 1] = ('APPLY from %s at v%d -> %s'):format(req.source, v, server.content)
    for id = 1, #clients do
      if id == req.client and clients[id].socket == req.socket then
        deliver(id, { update = { doc = 'sim', v = v } })
      else
        deliver(id, { update = { doc = 'sim', v = v, op = vim.deepcopy(result.ops), meta = { source = req.source } } })
      end
    end
  end

  for id = 1, 2 do
    local doc = Document.new('sim', '/sim.tex')
    doc.joined, doc.version, doc.content, doc.server_content = true, 0, BASE, BASE
    doc.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, { BASE })
    buffer.attach(doc.bufnr, doc)
    local give_up, fallback = doc._give_up, doc._fallback
    doc._give_up = function(...)
      giveups = giveups + 1
      if server.stall > 0 then stats.stall_giveups = stats.stall_giveups + 1 end
      return give_up(...)
    end
    doc._fallback = function(...)
      fallbacks = fallbacks + 1
      return fallback(...)
    end
    local public_id = ('c%ds1'):format(id)
    clients[id] = {
      doc = doc,
      state = {
        connected = true,
        public_id = public_id,
        public_ids = { [public_id] = true },
        documents = { sim = doc },
      },
      socket = 1,
      sockets = 1,
      alive = true,
      joined = true,
      events = {},
    }
  end

  local function edit(id)
    local doc = clients[id].doc
    local cur = text(doc)
    if rand(4) == 1 then
      local letters, depth = {}, 0
      for i = 1, #cur do
        local c = cur:sub(i, i)
        if c == '[' then
          depth = depth + 1
        elseif c == ']' then
          depth = depth - 1
        elseif depth == 0 and c:match('%l') then
          letters[#letters + 1] = i - 1
        end
      end
      if #letters > 0 then
        local at = letters[rand(#letters)]
        local row, col = pos(cur, at)
        deleted[cur:sub(at + 1, at + 1)] = true
        vim.api.nvim_buf_set_text(doc.bufnr, row, col, row, col + 1, { '' })
        return
      end
    end
    local candidates = spots(cur)
    local at = candidates[rand(#candidates)]
    next_token = next_token + 1
    inserted[next_token] = true
    local row, col = pos(cur, at)
    local token = '[' .. PREFIXES[rand(#PREFIXES)] .. next_token .. ']'
    vim.api.nvim_buf_set_text(doc.bufnr, row, col, row, col, vim.split(token, '\n', { plain = true }))
  end

  local function step(faults)
    if server.stall > 0 then
      -- Stalled: nothing is ordered, so the watchdogs fire and catch up again and again.
      server.stall = server.stall - 1
      for id = 1, 2 do
        local doc = clients[id].doc
        if doc.inflight_op and not doc._rejoining and rand(3) == 1 then
          with(id, function() doc:_on_ack_timeout() end)
        end
      end
      -- The users keep typing, so new ops follow an op that was given up.
      if rand(4) == 1 then
        local id = rand(2)
        edit(id)
        with(id, function() buffer.reconcile(clients[id].doc) end)
      end
    elseif #server.incoming > 0 and (not faults or rand(2) == 1) then
      process(faults)
    end
    for id = 1, 2 do
      if #clients[id].events > 0 and (not faults or rand(3) ~= 1) then deliver_one(id) end
    end
    if #deferred > 0 and (not faults or rand(2) == 1) then
      local entry = table.remove(deferred, 1)
      with(entry.id, entry.fn)
    end
    if faults then
      local id = rand(2)
      local c = clients[id]
      local r = rand(40)
      if r == 1 and c.doc.inflight_op and fault_set:find('w') then
        stats.watchdogs = stats.watchdogs + 1
        with(id, function() c.doc:_on_ack_timeout() end)
      elseif r == 2 and fault_set:find('r') then
        stats.forced = stats.forced + 1
        with(id, function() c.doc:rejoin() end)
      elseif r == 3 and c.alive and c.state.connected and fault_set:find('d') then
        drop_socket(id)
      elseif r == 4 and fault_set:find('m') then
        stats.merges = stats.merges + 1
        with(id, function() c.doc:rejoin('merge') end)
      end
      if server.stall == 0 and #server.incoming > 0 and rand(150) == 1 and fault_set:find('s') then
        server.stall = 60 + rand(60)
        stats.stalls = stats.stalls + 1
      end
    end
    for id = 1, 2 do
      with(id, function()
        buffer.reconcile(clients[id].doc)
        clients[id].doc:flush()
      end)
    end
  end

  for _ = 1, 24 do
    -- Each edit is reconciled on its own: a diff over several edits may delete
    -- and reinsert the text between them, and two clients doing that at once
    -- duplicate it (an artefact of diffing, not of the protocol). The edits
    -- still pile up in pending.
    for _ = 1, rand(3) do
      local id = rand(2)
      edit(id)
      with(id, function() buffer.reconcile(clients[id].doc) end)
    end
    for _ = 1, rand(3) do
      step(true)
    end
  end
  local settled = false
  for _ = 1, 3000 do
    step(false)
    local quiet = #server.incoming == 0 and #deferred == 0
    for id = 1, 2 do
      local c = clients[id]
      quiet = quiet
        and #c.events == 0
        and c.alive
        and c.state.connected
        and not c.doc.inflight_op
        and not c.doc.pending_ops
        and not c.doc._rejoining
        and not c.doc._stopped
    end
    if quiet then
      settled = true
      break
    end
  end

  local problems = {}
  if not settled then problems[#problems + 1] = 'stuck' end
  for id = 1, 2 do
    local doc = clients[id].doc
    if doc.content ~= server.content or text(doc) ~= server.content or doc.version ~= server.version then
      problems[#problems + 1] = ('diverged %d: %q'):format(id, text(doc))
    end
  end
  local counts = {}
  for _, t in ipairs(tokens_in(server.content)) do
    counts[t.n] = (counts[t.n] or 0) + 1
  end
  local residue = server.content:gsub('%[[^%[%]]*%]', '')
  local want = BASE:gsub('%l', function(c) return deleted[c] and '' or c end)
  local dup, lost = false, {}
  for n, c in pairs(counts) do
    if c > 1 or not inserted[n] then dup = true end
  end
  for n in pairs(inserted) do
    if not counts[n] then lost[#lost + 1] = n end
  end
  if residue ~= want then
    -- A letter twice or a stray character is a duplicate; a deleted letter
    -- still there, or a kept one gone, is a lost edit.
    local seen = {}
    for c in residue:gmatch('.') do
      if c ~= ' ' and (seen[c] or not c:match('%l')) then dup = true end
      seen[c] = true
    end
    if not dup then lost[#lost + 1] = ('letters %q, want %q'):format(residue, want) end
  end
  if dup then problems[#problems + 1] = 'dup' end
  if #lost > 0 then
    -- Only a give-up or a merge conflict may lose edits, and either keeps them
    -- in a recovery file.
    local saved = {}
    for _, file in ipairs(vim.fn.glob(vim.fn.stdpath('state') .. '/overleaf/recovery/*', false, true)) do
      saved[#saved + 1] = table.concat(vim.fn.readfile(file), '\n')
    end
    saved = table.concat(saved, '\n')
    local unexplained = saved == ''
    for _, n in ipairs(lost) do
      if type(n) == 'number' and not saved:find('%[%D*' .. n .. '%]') then unexplained = true end
    end
    if unexplained then
      problems[#problems + 1] = 'lost ' .. table.concat(lost, ',')
    else
      stats.lost_recovered = stats.lost_recovered + 1
    end
  end
  stats.giveups = stats.giveups + giveups
  stats.fallbacks = stats.fallbacks + fallbacks
  for id = 1, 2 do
    local doc = clients[id].doc
    if doc._ack_timer then vim.fn.timer_stop(doc._ack_timer) end
    if doc._flush_timer then vim.fn.timer_stop(doc._flush_timer) end
    vim.api.nvim_buf_delete(doc.bufnr, { force = true })
  end
  return problems, server.content
end

local function simulate(mode, fault_set)
  local old_request, old_defer, old_state, old_log, old_stdpath, old_force =
    bridge.request, vim.defer_fn, overleaf._state, config.log, vim.fn.stdpath, overleaf._force_reconnect
  local state_dir = vim.fn.tempname()
  local stats = {
    seeds = 0,
    ok = 0,
    dup = 0,
    lost = 0,
    diverged = 0,
    stuck = 0,
    lost_recovered = 0,
    stalls = 0,
    stall_giveups = 0,
    cycles = 0,
    merges = 0,
    rejected = 0,
    injected = 0,
    poisoned = 0,
    boots = 0,
    drops = 0,
    reconnects = 0,
    resends = 0,
    dup_dropped = 0,
    giveups = 0,
    fallbacks = 0,
    watchdogs = 0,
    forced = 0,
  }
  local failures = {}
  local ok, err = pcall(function()
    vim.fn.stdpath = function(what)
      if what == 'state' then return state_dir end
      return old_stdpath(what)
    end
    for seed = ONLY or 1, ONLY or SEEDS do
      local logs = {}
      config.log = function(level, fmt, ...)
        if VERBOSE then logs[#logs + 1] = ('[%s] ' .. fmt):format(level, ...) end
      end
      stats.seeds = stats.seeds + 1
      local problems, final = run_seed(seed, mode, stats, logs, fault_set)
      for _, p in ipairs(problems) do
        local kind = p:match('^%a+')
        stats[kind] = stats[kind] + 1
      end
      if #problems == 0 then
        stats.ok = stats.ok + 1
      elseif #failures < 5 then
        failures[#failures + 1] = ('seed %d: %s; server=%q'):format(seed, table.concat(problems, '; '), final)
      end
      if VERBOSE then print(table.concat(logs, '\n')) end
      vim.fn.delete(state_dir, 'rf')
    end
  end)
  bridge.request, vim.defer_fn, overleaf._state, config.log, vim.fn.stdpath, overleaf._force_reconnect =
    old_request, old_defer, old_state, old_log, old_stdpath, old_force
  vim.fn.delete(state_dir, 'rf')
  if not ok then error(err, 0) end
  print(('SIM %s %s %s'):format(mode, fault_set, vim.inspect(stats, { newline = ' ', indent = '' })))
  return stats, failures
end

describe('two-client OT simulation', function()
  for _, mode in ipairs({ 'gated', 'queued' }) do
    it(('%s joinDoc: no duplicates, losses or divergence across %d seeds'):format(mode, SEEDS), function()
      local stats, failures = simulate(mode, FAULTS)
      local detail = table.concat(failures, '\n')
      assert.are.equal(0, stats.dup, detail)
      assert.are.equal(0, stats.lost, detail)
      assert.are.equal(0, stats.diverged, detail)
      assert.are.equal(0, stats.stuck, detail)
      assert.are.equal(0, stats.rejected, 'the server rejected a client op\n' .. detail)
      assert.are.equal(0, stats.fallbacks, 'a catch-up fell back to the text merge\n' .. detail)
      assert.is_true(stats.resends > 0 and stats.boots > 0 and stats.giveups > 0, 'faults were not exercised')
      -- Only a queued joinDoc lets a resend race its original, or catches up
      -- while the queue is stalled.
      if mode == 'queued' then
        assert.is_true(stats.dup_dropped > 0, 'no resend was dropped as a duplicate')
        assert.is_true(stats.stall_giveups > 0, 'no op was given up while stalled')
      end
    end)

    -- The text merge cannot tell whether a still-queued in-flight op will land,
    -- so it may duplicate one (a documented limitation); it must never lose text
    -- other than into a recovery file.
    it(('%s joinDoc with forced text merges: no losses or divergence'):format(mode), function()
      local stats, failures = simulate(mode, FAULTS .. 'm')
      local detail = table.concat(failures, '\n')
      assert.are.equal(0, stats.lost, detail)
      assert.are.equal(0, stats.diverged, detail)
      assert.are.equal(0, stats.stuck, detail)
      assert.are.equal(0, stats.rejected, 'the server rejected a client op\n' .. detail)
      assert.is_true(stats.fallbacks > 0, 'no fallback ran')
    end)
  end
end)
