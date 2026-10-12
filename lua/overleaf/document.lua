local bridge = require('overleaf.bridge')
local ot = require('overleaf.ot')
local diff = require('overleaf.diff')
local merge = require('overleaf.merge')
local config = require('overleaf.config')

local Document = {}
Document.__index = Document

-- The in-flight op follows ShareJS: it is never merged into pending. A rejoin
-- either finds it in the catch-up (by the public ids it was sent under) or
-- resends it at the new version with `dupIfSource`, so a copy the server still
-- had queued is not applied twice.
local MAX_UNACKED_REJOINS = 3 -- catch-ups that may find the in-flight op missing
-- ... once Overleaf has rejected it. Every rejection disconnects every
-- collaborator, so give up after one resend.
local MAX_UNACKED_REJECTED = 2
local MAX_CATCHUP_FAILURES = 3 -- failed catch-ups before the text merge
local MAX_REJOIN_ATTEMPTS = 5
local BACKOFF = { 200, 8000, 15000, 25000, 40000 }

local function state() return require('overleaf')._state or {} end

--- The public id of the current socket: the server stamps it as `meta.source`
--- on every op this client sends.
local function current_public_id()
  local s = state()
  return s.public_id or (s.public_ids and (next(s.public_ids)))
end

local function buffer_text(self)
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    return table.concat(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false), '\n')
  end
  return self.content
end

local function stop_timer(self, name)
  if self[name] then
    vim.fn.timer_stop(self[name])
    self[name] = nil
  end
end

local function clear_inflight(self)
  self.inflight_op = nil
  self._inflight_sources = nil
  self._resend = false
  self._unacked_rejoins = 0
  self._inflight_rejected = false
  stop_timer(self, '_ack_timer')
end

--- Drop the in-flight op without its ACK. The server may still have a copy
--- queued that lands later. If that copy was sent from the current socket, its
--- op-less ACK would arrive here looking exactly like the ACK of our next op (an
--- ACK carries only `v`). So nothing more is sent on this document until the
--- socket has been replaced: on a new socket the late copy arrives as a full op
--- from a source the next op was never sent under, and is applied as a remote
--- edit.
local function abandon_inflight(self)
  local current = current_public_id()
  if self.inflight_op and current and vim.tbl_contains(self._inflight_sources or {}, current) then
    self._unsafe_public_id = current
    local overleaf = require('overleaf')
    if overleaf._force_reconnect then overleaf._force_reconnect('dropped an unacknowledged edit to ' .. self.path) end
  end
  clear_inflight(self)
end

function Document.new(doc_id, path)
  local self = setmetatable({}, Document)
  self.doc_id = doc_id
  self.path = path
  self.bufnr = nil
  self.version = nil
  self.content = nil
  self.server_content = nil
  self.joined = false
  self.inflight_op = nil
  self.pending_ops = nil
  self.applying_remote = false
  self._queued = {}
  self._inflight_sources = nil
  self._resend = false
  self._send_seq = 0
  self._unacked_rejoins = 0
  self._catchup_failures = 0
  return self
end

function Document:join(callback)
  self._joining = true
  bridge.request('joinDoc', { docId = self.doc_id }, function(err, result)
    if err then
      self._joining = false
      config.log('error', 'Failed to join doc %s: %s', self.path, err.message)
      if callback then callback(err) end
      return
    end
    local content = table.concat(result.lines, '\n')
    self.version = result.version
    self.content = content
    self.server_content = content
    self.joined = true
    self.ranges = result.ranges
    self._joining = false
    config.log('debug', 'Joined doc: %s (v%d)', self.path, self.version)
    if callback then callback(nil, result.lines, result.ranges) end
    self:_replay_queued()
  end)
end

function Document:leave(callback)
  if not self.joined then
    if callback then callback(nil) end
    return
  end
  stop_timer(self, '_flush_timer')
  stop_timer(self, '_ack_timer')
  bridge.request('leaveDoc', { docId = self.doc_id }, function(err)
    self.joined = false
    clear_inflight(self)
    self.pending_ops = nil
    if callback then callback(err) end
  end)
end

function Document:submit_op(ops)
  if self.content == nil or (not self.joined and not self._rejoining) then return end
  if self.pending_ops then
    self.pending_ops = ot.compose(self.pending_ops, ops)
  else
    self.pending_ops = ops
  end
  if not self._rejoining then self:_schedule_flush() end
end

function Document:_schedule_flush()
  if (not self.pending_ops and not self._resend) or self._rejoining or self._stopped then return end
  stop_timer(self, '_flush_timer')
  self._flush_timer = vim.fn.timer_start(100, function()
    self._flush_timer = nil
    self:flush()
  end)
end

--- Send the pending ops, or resend the in-flight op after a rejoin. Pending ops
--- wait until the in-flight op is acknowledged.
function Document:flush()
  if not self.joined or self._rejoining or self._joining or self._stopped then return end
  if self._unsafe_public_id then
    if self._unsafe_public_id == current_public_id() then return end
    self._unsafe_public_id = nil
  end
  if self.inflight_op then
    if self._resend then self:_send() end
    return
  end
  if not self.pending_ops then return end
  if not self:check_content() then return end
  self.inflight_op = self.pending_ops
  self.pending_ops = nil
  self._inflight_sources = {}
  self._unacked_rejoins = 0
  self:_send()
end

function Document:_send()
  local resend = self._resend
  self._resend = false
  local sources = self._inflight_sources
  local source = current_public_id()
  if source and not vim.tbl_contains(sources, source) then sources[#sources + 1] = source end
  self._send_seq = self._send_seq + 1
  local seq = self._send_seq
  stop_timer(self, '_ack_timer')
  self._ack_timer = vim.fn.timer_start(10000, function()
    self._ack_timer = nil
    self:_on_ack_timeout()
  end)
  bridge.request('applyOtUpdate', {
    docId = self.doc_id,
    op = self.inflight_op,
    v = self.version,
    content = self.server_content,
    tracked = require('overleaf.mode').tracked(),
    -- The server drops the resend if a copy sent under any of these ids was
    -- applied since `v`, and acks it instead.
    dupIfSource = resend and #sources > 0 and vim.deepcopy(sources) or nil,
  }, function(err)
    if not err then return end
    config.log('debug', 'OT update callback error for %s: %s', self.path, err.message or vim.inspect(err))
    -- The callback only reports enqueueing. An error or a timeout does not mean
    -- the op was not applied; the catch-up finds out.
    if self._send_seq ~= seq or not self.inflight_op or self._rejoining then return end
    self:rejoin()
  end)
end

function Document:_on_ack_timeout()
  if self.inflight_op and not self._rejoining then
    config.log('debug', 'ACK timeout for %s', self.path)
    self:rejoin()
  end
end

function Document:_is_inflight_source(update)
  local source = update.meta and update.meta.source
  return self.inflight_op ~= nil
    and source ~= nil
    and self._inflight_sources ~= nil
    and vim.tbl_contains(self._inflight_sources, source)
end

--- The server applied our in-flight op at `update.v`: an op-less event on the
--- sending socket, or the op itself when it was sent from an earlier socket.
function Document:_on_ack(update)
  if not self.inflight_op then
    -- An op of ours we no longer track (given up, or merged away) was applied.
    config.log('debug', 'ACK at v%s for %s with nothing in flight; catching up', tostring(update.v), self.path)
    self:rejoin()
    return false
  end
  if update.v ~= self.version then
    config.log('debug', 'ACK version mismatch for %s: local v%s, ACK v%s', self.path, self.version, update.v)
    self:rejoin()
    return false
  end
  local ok, content = pcall(ot.apply, self.server_content, self.inflight_op)
  if not ok then
    config.log('debug', 'ACK apply failed for %s: %s', self.path, content)
    self:rejoin('merge')
    return false
  end
  self.server_content = content
  self.version = self.version + 1
  clear_inflight(self)
  config.log('debug', 'ACK for %s applied at v%s, now v%d', self.path, tostring(update.v), self.version)
  if not self._rejoining then self:_schedule_flush() end
  return true
end

function Document:receive(update)
  if self._rejoining or self._joining then
    self._queued[#self._queued + 1] = update
    return
  end
  if not self.joined then return end
  -- Already part of our state: a broadcast the catch-up or the snapshot
  -- included, or the server's ACK of a resend it dropped as a duplicate.
  if type(update.v) == 'number' and self.version and update.v < self.version then
    config.log(
      'debug',
      'Dropping stale %s v%d for %s (at v%d)',
      update.op and 'op' or 'ACK',
      update.v,
      self.path,
      self.version
    )
    return
  end
  if self.bufnr then require('overleaf.buffer').reconcile(self) end
  if self._rejoining then
    self._queued[#self._queued + 1] = update
    return
  end
  if update.op == nil or self:_is_inflight_source(update) then
    self:_on_ack(update)
  else
    self:on_remote_op(update, function(ops) require('overleaf.buffer').apply_remote(self, ops) end)
    require('overleaf.sync').schedule_write(self)
  end
end

function Document:_replay_queued()
  local queued = self._queued
  self._queued = {}
  -- `receive` drops what is stale and queues again once a rejoin starts.
  for _, update in ipairs(queued) do
    self:receive(update)
  end
end

--- Save `text` where the user can recover it. Never throws.
---@return string|nil path
local function save_recovery(self, text)
  local ok, result = pcall(function()
    local dir = vim.fn.stdpath('state') .. '/overleaf/recovery'
    vim.fn.mkdir(dir, 'p')
    local name = self.doc_id:gsub('[^%w_-]', '_')
      .. '-'
      .. os.date('%Y%m%d-%H%M%S')
      .. '-'
      .. tostring(vim.loop.hrtime())
      .. '.tex'
    local path = dir .. '/' .. name
    local fd = assert(vim.loop.fs_open(path, 'w', 384))
    local wrote, write_err = vim.loop.fs_write(fd, text or '', 0)
    vim.loop.fs_close(fd)
    assert(wrote, write_err)
    return path
  end)
  if not ok then
    config.log('warn', 'Could not save the local text of %s for recovery: %s', self.path, tostring(result))
    return nil
  end
  return result
end

function Document:_replace_buffer(content)
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  self.applying_remote = true
  local ok, err = pcall(function()
    require('overleaf.buffer').unlocked(
      self.bufnr,
      function() require('overleaf.buffer').replace_content(self.bufnr, content) end
    )
  end)
  self.applying_remote = false
  if not ok then error(err) end
end

--- Run one step of the rejoin chain. An exception must not leave the document
--- rejoining forever: clear the flag, log, and retry with the backoff.
function Document:_guard(attempt, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then return end
  config.log('warn', 'Rejoin of %s failed: %s', self.path, tostring(err):match('^[^\n]*'))
  config.log('debug', '%s', err)
  self._rejoining = false
  self:_retry_rejoin(attempt, err)
end

function Document:_finish_rejoin()
  self.joined = true
  self._rejoining = false
  self._force_merge = false
  self._catchup_failures = 0
  self:_replay_queued()
  if self._rejoining then return end
  self:_schedule_flush()
  require('overleaf.sync').schedule_write(self)
end

--- The local text could not be saved, so it must not be overwritten: keep the
--- buffer as it is and send nothing more for this document. The next rejoin
--- (a reconnect) merges again.
function Document:_keep_local_text(why)
  self.joined = false
  self._stopped = true
  self._rejoining = false
  self._force_merge = true
  stop_timer(self, '_flush_timer')
  stop_timer(self, '_ack_timer')
  config.log(
    'error',
    '%s for %s, and the local text could not be saved: it is only in the buffer. '
      .. 'Nothing more is sent for this document until it rejoins; save the buffer elsewhere',
    why,
    self.path
  )
end

--- Show the server's text and drop our unsent edits, keeping the local text in
--- a recovery file. Returns false, keeping the local text, if that file cannot
--- be written.
function Document:_accept_server(theirs, version, ranges, why)
  local path = save_recovery(self, buffer_text(self) or '')
  if not path then
    self:_keep_local_text(why)
    return false
  end
  self:_replace_buffer(theirs)
  self.server_content = theirs
  self.content = theirs
  self.version = version or self.version
  self.ranges = ranges or self.ranges
  self.pending_ops = nil
  abandon_inflight(self)
  config.log('error', '%s for %s; showing the server text. Local text saved to %s', why, self.path, path)
  return true
end

--- The server kept not applying the in-flight op. The catch-up has just
--- confirmed that `server_content` is the server's text.
function Document:_give_up()
  local why = ('Overleaf did not apply an edit after %d attempts'):format(self._unacked_rejoins)
  return self:_accept_server(self.server_content, nil, nil, why)
end

function Document:_fallback(attempt)
  -- Retries after this point stay on the merge path.
  self._force_merge = true
  bridge.request('joinDoc', { docId = self.doc_id, fromVersion = -1 }, function(err, result)
    self:_guard(attempt, function()
      if err or not result or not result.lines then return self:_retry_rejoin(attempt, err) end
      local theirs = table.concat(result.lines, '\n')
      local base = self.server_content
      -- The same version must be the same text. Anything else is inconsistent:
      -- apply nothing and ask again.
      if base ~= nil and result.version == self.version and theirs ~= base then
        if attempt < MAX_REJOIN_ATTEMPTS then return self:_retry_rejoin(attempt, 'same version, different text') end
        -- Still inconsistent on the last attempt: the server is authoritative.
        if self:_accept_server(theirs, result.version, result.ranges, 'The server text disagrees with ours') then
          self:_finish_rejoin()
        end
        return
      end
      local mine = buffer_text(self) or ''
      local merged = merge.three_way(base or '', mine, theirs)
      if not merged then
        local path = save_recovery(self, mine)
        if not path then return self:_keep_local_text('Merge conflict') end
        config.log('warn', 'Merge conflict for %s; local text saved to %s', self.path, path)
        merged = theirs
      end
      -- Overleaf stores astral characters as U+FFFD; send and show what it keeps.
      local ops, replaced = ot.sanitize_inserts(diff.ops(theirs, merged))
      if replaced then merged = ot.apply(theirs, ops) end
      self:_replace_buffer(merged)
      self.server_content = theirs
      self.content = merged
      self.version = result.version
      self.ranges = result.ranges
      abandon_inflight(self)
      self.pending_ops = #ops > 0 and ops or nil
      if replaced and self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        require('overleaf.buffer')._show_replacements(self)
      end
      self:_finish_rejoin()
    end)
  end)
end

function Document:_retry_rejoin(attempt, err)
  config.log('debug', 'Rejoin attempt %d failed for %s: %s', attempt, self.path, vim.inspect(err))
  if attempt >= MAX_REJOIN_ATTEMPTS then
    local path = save_recovery(self, buffer_text(self) or '')
    config.log('error', 'Could not rejoin %s; local text: %s', self.path, path or '(could not be saved)')
    self._rejoining = false
    self._stopped = true
    return
  end
  self:rejoin(self._force_merge and 'merge' or nil, attempt + 1)
end

--- A catch-up failed or was inconsistent. Retry it; merge text only after
--- repeated failure. Emit timeouts say nothing about the history, so they do
--- not count towards that.
function Document:_catch_up_failed(attempt, err)
  if not (type(err) == 'table' and err.code == 'TIMEOUT') then
    self._catchup_failures = (self._catchup_failures or 0) + 1
  end
  config.log(
    'debug',
    'Catch-up of %s failed (%d/%d): %s',
    self.path,
    self._catchup_failures,
    MAX_CATCHUP_FAILURES,
    vim.inspect(err)
  )
  if self._catchup_failures >= MAX_CATCHUP_FAILURES then return self:_fallback(attempt) end
  self:_retry_rejoin(attempt, err)
end

function Document:_catch_up(result, attempt)
  local current = table.concat(result.lines, '\n')
  local buffer = require('overleaf.buffer')
  buffer.reconcile(self)
  if self._force_merge then return self:_fallback(attempt) end
  for _, update in ipairs(result.updates) do
    if update.v ~= self.version then
      if update.v > self.version then
        return self:_catch_up_failed(attempt, ('gap: at v%d, update v%d'):format(self.version, update.v))
      end
    elseif self:_is_inflight_source(update) then
      if not self:_on_ack(update) then return self:_fallback(attempt) end
    else
      self:on_remote_op(update, function(ops) buffer.apply_remote(self, ops) end)
      if self._force_merge then return self:_fallback(attempt) end
    end
  end
  if self.version ~= result.version or self.server_content ~= current then
    return self:_catch_up_failed(
      attempt,
      ('inconsistent: v%d, server v%d, text %s'):format(
        self.version,
        result.version,
        self.server_content == current and 'equal' or 'differs'
      )
    )
  end
  self.ranges = result.ranges
  stop_timer(self, '_ack_timer')
  if self.inflight_op then
    self._unacked_rejoins = (self._unacked_rejoins or 0) + 1
    local limit = self._inflight_rejected and MAX_UNACKED_REJECTED or MAX_UNACKED_REJOINS
    if self._unacked_rejoins >= limit then
      if not self:_give_up() then return end
    else
      config.log('debug', 'In-flight op of %s not applied yet; resending at v%d', self.path, self.version)
      self._resend = true
    end
  end
  self:_finish_rejoin()
end

--- Catch up from the last known version before falling back to a text merge.
--- The in-flight and pending ops are kept throughout.
function Document:rejoin(reason, attempt)
  if type(reason) == 'number' then
    attempt, reason = reason, nil
  end
  attempt = attempt or 1
  if attempt == 1 then self._stopped = false end
  if self._rejoining and attempt == 1 then
    if reason == 'merge' then self._force_merge = true end
    return
  end
  self._rejoining = true
  self._force_merge = self._force_merge or reason == 'merge'
  stop_timer(self, '_flush_timer')
  stop_timer(self, '_ack_timer')
  local delay = BACKOFF[attempt] or BACKOFF[#BACKOFF]
  vim.defer_fn(function()
    self:_guard(attempt, function()
      if not state().connected then
        -- The reconnect rejoins again.
        self._rejoining = false
        return
      end
      if self._force_merge or self.version == nil then return self:_fallback(attempt) end
      bridge.request('joinDoc', { docId = self.doc_id, fromVersion = self.version }, function(err, result)
        self:_guard(attempt, function()
          if err or not result or not result.lines or not result.updates then
            return self:_catch_up_failed(attempt, err or 'no catch-up updates')
          end
          self:_catch_up(result, attempt)
        end)
      end)
    end)
  end, delay)
end

function Document:check_content()
  if not self.joined or self._rejoining then return true end
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return true end
  if self.applying_remote or require('overleaf.buffer').has_pending(self) then return true end
  local current = buffer_text(self)
  if current ~= self.content then
    config.log('debug', 'Content divergence detected for %s; merging', self.path)
    self:rejoin('merge')
    return false
  end
  return true
end

function Document:on_remote_op(update, apply_to_buffer)
  if not self.joined then return end
  if update.v ~= self.version then
    config.log('debug', 'Version mismatch: expected %s, got %s for %s', self.version, update.v, self.path)
    if require('overleaf')._state.connected then self:rejoin() end
    return
  end
  local remote_ops = update.op or {}
  local previous = {
    server_content = self.server_content,
    content = self.content,
    inflight_op = self.inflight_op,
    pending_ops = self.pending_ops,
    version = self.version,
  }
  local ok, err = pcall(function()
    local server = ot.apply(self.server_content, remote_ops)
    local ops_to_apply = remote_ops
    local inflight, pending = self.inflight_op, self.pending_ops
    if inflight then
      inflight, ops_to_apply = ot.transform_x(inflight, ops_to_apply)
    end
    if pending then
      pending, ops_to_apply = ot.transform_x(pending, ops_to_apply)
    end
    local content = ot.apply(self.content, ops_to_apply)
    self.server_content = server
    self.inflight_op = inflight
    self.pending_ops = pending
    self.version = self.version + 1
    self.content = content
    if apply_to_buffer then apply_to_buffer(ops_to_apply) end
  end)
  if not ok then
    self.server_content = previous.server_content
    self.content = previous.content
    self.inflight_op = previous.inflight_op
    self.pending_ops = previous.pending_ops
    self.version = previous.version
    config.log('debug', 'Remote op failed for %s: %s; rejoining', self.path, err)
    self:rejoin('merge')
  end
end

return Document
