local ot = require('overleaf.ot')

local M = {}

function M.new() return { undo = {}, redo = {}, seq = nil } end

function M.clear(history)
  history.undo = {}
  history.redo = {}
  history.seq = nil
end

function M.close(history) history.seq = nil end

local function rebase(stack, active, other)
  local kept = {}
  -- Each older step is based on the text after its own edit. Carry the external
  -- op backwards through newer steps so it reaches that older coordinate space.
  for i = #stack, 1, -1 do
    local group = stack[i]
    local ok, carried, rebased = pcall(ot.transform_x, other, group[active])
    -- Without the carried op the older steps cannot be placed: drop them too.
    if not ok then break end
    other = carried
    if #rebased > 0 then
      group[active] = rebased
      kept[#kept + 1] = group
    end
  end
  for i = 1, math.floor(#kept / 2) do
    kept[i], kept[#kept - i + 1] = kept[#kept - i + 1], kept[i]
  end
  return kept
end

-- The diff sent for several changes at once (a :s///g, a macro) replaces
-- whole tokens. Stored as is, a step would own letters it never changed, and
-- undoing it could restore letters a collaborator has since deleted. Trim
-- each replacement to what actually changed (whole characters, UTF-16 offsets).
local function minimal(ops)
  local out, k = {}, 1
  while k <= #ops do
    local d, i = ops[k], ops[k + 1]
    if d.d and not d.i and i and i.i and not i.d and i.p == d.p then
      local a, b = d.d, i.i
      local pre = 0
      while pre < #a and pre < #b and a:byte(pre + 1) == b:byte(pre + 1) do
        pre = pre + 1
      end
      while pre > 0 and (a:byte(pre + 1) or 0) >= 0x80 and (a:byte(pre + 1) or 0) < 0xC0 do
        pre = pre - 1
      end
      local suf = 0
      while suf < #a - pre and suf < #b - pre and a:byte(#a - suf) == b:byte(#b - suf) do
        suf = suf + 1
      end
      while suf > 0 and a:byte(#a - suf + 1) >= 0x80 and a:byte(#a - suf + 1) < 0xC0 do
        suf = suf - 1
      end
      local p = d.p + ot.u16_len(a:sub(1, pre))
      local nd, ni = a:sub(pre + 1, #a - suf), b:sub(pre + 1, #b - suf)
      if nd ~= '' then out[#out + 1] = { p = p, d = nd } end
      if ni ~= '' then out[#out + 1] = { p = p, i = ni } end
      k = k + 2
    else
      out[#out + 1] = d
      k = k + 1
    end
  end
  return out
end

--- Record a local edit. `exact` keeps the ops as sent (suggestions: Overleaf
--- cancels a tracked change only when the undo matches it).
function M.record(history, ops, content_before, seq, exact)
  if not exact then ops = minimal(ops) end
  local inverse = ot.invert(ops, content_before)
  if #inverse == 0 then return end
  local group = history.undo[#history.undo]
  if history.seq == nil or history.seq ~= seq or not group then
    group = { ops = ops, inverse = inverse }
    history.undo[#history.undo + 1] = group
  else
    group.ops = ot.compose(group.ops, ops)
    group.inverse = ot.compose(inverse, group.inverse)
  end
  history.seq = seq
  history.redo = {}
end

--- Move stored edits through a change made outside this buffer's typing.
function M.transform(history, other)
  M.close(history)
  history.undo = rebase(history.undo, 'inverse', other)
  history.redo = rebase(history.redo, 'ops', other)
end

local function apply(doc, ops)
  -- Overleaf marks undo inserts with `u`: one that restores text a tracked
  -- deletion removed cancels that suggestion instead of suggesting the text
  -- again (RangesTracker.applyInsertToChanges).
  for _, c in ipairs(ops) do
    if c.i then c.u = true end
  end
  local buffer = require('overleaf.buffer')
  local before = doc.content
  local updated = ot.apply(before, ops)
  local bufnr = doc.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local actual = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    if actual ~= before then error('History buffer differs from document text') end
    doc.applying_remote = true
    local ok, err = pcall(function()
      buffer.without_undo(bufnr, function()
        local applied, apply_err = buffer.apply_ops(bufnr, ops)
        if not applied then error(apply_err) end
      end)
    end)
    if not ok then
      local restored = pcall(function()
        buffer.unlocked(bufnr, function() buffer.replace_content(bufnr, before) end)
      end)
      doc.applying_remote = false
      if not restored then doc:rejoin('merge') end
      error(err)
    end
    doc.applying_remote = false
  end
  doc.content = updated
  doc:submit_op(ops)
  require('overleaf.sync').schedule_write(doc)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr and ops[1] then
    local byte = ot.u16_to_byte_floor(updated, ops[1].p)
    local row, col = ot.byte_offset_to_pos(updated, byte)
    pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col })
  end
end

local function step(doc, from, to, field)
  local history = doc.history
  local group = history[from][#history[from]]
  if not group then return false end
  local ops = group[field]
  local before = doc.content
  local reverse = ot.invert(ops, before)
  apply(doc, ops)
  table.remove(history[from])
  if field == 'inverse' then
    group.ops = reverse
  else
    group.inverse = reverse
  end
  history[to][#history[to] + 1] = group
  M.close(history)
  return true
end

local function run(doc, count, from, to, field)
  if not doc or not doc.history then return end
  local bufnr = doc.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modifiable then
    vim.api.nvim_echo({ { "E21: Cannot make changes, 'modifiable' is off", 'ErrorMsg' } }, true, {})
    return
  end
  require('overleaf.buffer').reconcile(doc)
  for _ = 1, count or 1 do
    local ok, result = pcall(step, doc, from, to, field)
    if not ok then
      require('overleaf.config').log(
        'warn',
        'Could not %s %s: %s',
        from == 'undo' and 'undo' or 'redo',
        doc.path,
        result
      )
      break
    end
    if not result then break end
  end
end

function M.undo(doc, count) run(doc, count, 'undo', 'redo', 'inverse') end
function M.redo(doc, count) run(doc, count, 'redo', 'undo', 'ops') end

return M
