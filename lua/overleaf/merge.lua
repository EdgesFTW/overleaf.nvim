local diff = require('overleaf.diff')
local ot = require('overleaf.ot')

local M = {}

local function word_byte(byte)
  return byte ~= nil
    and (
      byte >= 48 and byte <= 57
      or byte >= 65 and byte <= 90
      or byte >= 97 and byte <= 122
      or byte == 95
      or byte >= 128
    )
end

local function hunks(base, changed)
  local result = {}
  for _, op in ipairs(diff.ops(base, changed, nil, { words = true })) do
    local h = result[#result]
    if not h or h.start ~= op.p then
      h = { start = op.p, stop = op.p, inserted = '' }
      result[#result + 1] = h
    end
    if op.d then h.stop = h.start + ot.u16_len(op.d) end
    if op.i then h.inserted = op.i end
  end
  for _, h in ipairs(result) do
    local first = ot.u16_to_byte(base, h.start)
    local last = ot.u16_to_byte(base, h.stop)
    local expanded_first, expanded_last = first, last
    while expanded_first > 0 and word_byte(base:byte(expanded_first)) do
      expanded_first = expanded_first - 1
    end
    while expanded_last < #base and word_byte(base:byte(expanded_last + 1)) do
      expanded_last = expanded_last + 1
    end
    h.inserted = base:sub(expanded_first + 1, first) .. h.inserted .. base:sub(last + 1, expanded_last)
    h.start = ot.byte_to_u16(base, expanded_first)
    h.stop = ot.byte_to_u16(base, expanded_last)
  end
  for i = 2, #result do
    if result[i].stop >= result[i - 1].start then
      return { { start = 0, stop = ot.u16_len(base), inserted = changed } }
    end
  end
  return result
end

--- Merge disjoint edits against a common base; touching spans conflict.
function M.three_way(base, mine, theirs)
  if mine == theirs then return mine end
  if mine == base then return theirs end
  if theirs == base then return mine end

  local all = hunks(base, mine)
  for _, incoming in ipairs(hunks(base, theirs)) do
    local duplicate = false
    for _, existing in ipairs(all) do
      if
        existing.start == incoming.start
        and existing.stop == incoming.stop
        and existing.inserted == incoming.inserted
      then
        duplicate = true
        break
      end
      if incoming.start <= existing.stop and existing.start <= incoming.stop then return nil end
    end
    if not duplicate then all[#all + 1] = incoming end
  end
  table.sort(all, function(a, b) return a.start > b.start end)
  local merged = base
  for _, h in ipairs(all) do
    local first = ot.u16_to_byte(merged, h.start)
    local last = ot.u16_to_byte(merged, h.stop)
    merged = merged:sub(1, first) .. h.inserted .. merged:sub(last + 1)
  end
  return merged
end

return M
