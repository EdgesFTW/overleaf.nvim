-- OT (Operational Transform) engine for Overleaf's text operations.
-- Positions and lengths use UTF-16 code units, matching ShareJS text0.

local M = {}

local function utf8_width(byte)
  if byte < 0x80 then return 1 end
  if byte < 0xE0 then return 2 end
  if byte < 0xF0 then return 3 end
  return 4
end

--- Count UTF-16 code units in UTF-8 text.
function M.u16_len(s)
  local units, i = 0, 1
  while i <= #s do
    local width = utf8_width(s:byte(i))
    units = units + (width == 4 and 2 or 1)
    i = i + width
  end
  return units
end

--- Convert a 0-based byte offset to a 0-based UTF-16 offset.
function M.byte_to_u16(s, byte_offset)
  local units, i = 0, 1
  while i <= byte_offset and i <= #s do
    local width = utf8_width(s:byte(i))
    units = units + (width == 4 and 2 or 1)
    i = i + width
  end
  return units
end

--- Convert a 0-based UTF-16 offset to a 0-based byte offset.
function M.u16_to_byte(s, u16_offset)
  if u16_offset <= 0 then return 0 end
  local units, i = 0, 1
  while i <= #s and units < u16_offset do
    local width = utf8_width(s:byte(i))
    local next_units = units + (width == 4 and 2 or 1)
    if u16_offset < next_units then error('UTF-16 position splits a surrogate pair') end
    units = next_units
    i = i + width
  end
  return i - 1
end

--- Like u16_to_byte, but a position inside a surrogate pair rounds down to the
--- character's start instead of raising. For display only (cursors, comment
--- highlights), where an offset can be stale against the local text.
function M.u16_to_byte_floor(s, u16_offset)
  if u16_offset <= 0 then return 0 end
  local units, i = 0, 1
  while i <= #s and units < u16_offset do
    local width = utf8_width(s:byte(i))
    units = units + (width == 4 and 2 or 1)
    if units > u16_offset then break end
    i = i + width
  end
  return i - 1
end

local function sub(s, first, last)
  local from = M.u16_to_byte(s, first)
  local to = last and M.u16_to_byte(s, last) or #s
  return s:sub(from + 1, to)
end

local function inject(s, pos, value)
  local byte = M.u16_to_byte(s, pos)
  return s:sub(1, byte) .. value .. s:sub(byte + 1)
end

--- Apply sequential operations; a mismatched deletion must trigger resync.
function M.apply(content, ops)
  for _, op in ipairs(ops) do
    if op.d then
      local byte_p = M.u16_to_byte(content, op.p)
      if content:sub(byte_p + 1, byte_p + #op.d) ~= op.d then error('Delete component does not match deleted text') end
      content = content:sub(1, byte_p) .. content:sub(byte_p + #op.d + 1)
    end
    if op.i then content = inject(content, op.p, op.i) end
  end
  return content
end

-- Overleaf's document-updater replaces every UTF-16 surrogate in inserted text
-- with U+FFFD (UpdateManager._sanitizeUpdate), so an emoji or a math letter such
-- as 𝔸 is stored as two U+FFFD. Sending the real character makes the hash we
-- attach disagree with what the server stores, and the server drops the op and
-- disconnects us. Inserts are rewritten the same way before sending; a 4-byte
-- character is two UTF-16 units and becomes two U+FFFD, so positions are kept.
local REPLACEMENT = '\239\191\189'

--- Rewrite inserts as Overleaf will store them.
---@return table[] ops, boolean changed
function M.sanitize_inserts(ops)
  local out, changed = {}, false
  for _, op in ipairs(ops) do
    if op.i and (op.i:find('[\240-\247]') or op.i:find('\237[\160-\191]')) then
      local i = op.i:gsub('[\240-\247][\128-\191][\128-\191][\128-\191]', REPLACEMENT .. REPLACEMENT)
      -- A lone surrogate encoded in UTF-8 (CESU-style) is one unit.
      i = i:gsub('\237[\160-\191][\128-\191]', REPLACEMENT)
      local c = {}
      for k, v in pairs(op) do
        c[k] = v
      end
      c.i = i
      out[#out + 1] = c
      changed = changed or i ~= op.i
    else
      out[#out + 1] = op
    end
  end
  return out, changed
end

local function copy(c)
  local result = {}
  for k, v in pairs(c) do
    result[k] = v
  end
  return result
end

-- text0's append normalizes adjacent inserts and deletes while building a transform.
local function append(dest, c)
  if c.i == '' or c.d == '' then return end
  local last = dest[#dest]
  if last and last.i and c.i and last.p <= c.p and c.p <= last.p + M.u16_len(last.i) then
    dest[#dest] = { p = last.p, i = inject(last.i, c.p - last.p, c.i) }
  elseif last and last.d and c.d and c.p <= last.p and last.p <= c.p + M.u16_len(c.d) then
    dest[#dest] = { p = c.p, d = inject(c.d, last.p - c.p, last.d) }
  else
    dest[#dest + 1] = copy(c)
  end
end

local function tpos(pos, c, insert_after)
  if c.i then
    if c.p < pos or (c.p == pos and insert_after) then return pos + M.u16_len(c.i) end
  elseif c.d then
    if pos <= c.p then return pos end
    if pos <= c.p + M.u16_len(c.d) then return c.p end
    return pos - M.u16_len(c.d)
  end
  return pos
end

-- Port of text0 transformComponent, with comment components passed through.
local function tc(dest, c, other, side)
  if c.c or (not c.i and not c.d) then
    append(dest, c)
  elseif c.i then
    append(dest, { p = tpos(c.p, other, side == 'right'), i = c.i })
  elseif other.i then
    local s = c.d
    if c.p < other.p then
      append(dest, { p = c.p, d = sub(s, 0, other.p - c.p) })
      s = sub(s, other.p - c.p)
    end
    if s ~= '' then append(dest, { p = c.p + M.u16_len(other.i), d = s }) end
  elseif other.d then
    local c_end, other_end = c.p + M.u16_len(c.d), other.p + M.u16_len(other.d)
    if c.p >= other_end then
      append(dest, { p = c.p - M.u16_len(other.d), d = c.d })
    elseif c_end <= other.p then
      append(dest, c)
    else
      local nd = ''
      if c.p < other.p then nd = sub(c.d, 0, other.p - c.p) end
      if c_end > other_end then nd = nd .. sub(c.d, other_end - c.p) end
      local overlap_start, overlap_end = math.max(c.p, other.p), math.min(c_end, other_end)
      if
        sub(c.d, overlap_start - c.p, overlap_end - c.p)
        ~= sub(other.d, overlap_start - other.p, overlap_end - other.p)
      then
        error('Delete ops delete different text in the same region of the document')
      end
      if nd ~= '' then append(dest, { p = tpos(c.p, other), d = nd }) end
    end
  else
    append(dest, c)
  end
  return dest
end

function M.transform_component(c, other, side) return tc({}, c, other, side) end

--- Transform both sequential lists together, as text0 bootstrapTransform does.
function M.transform_x(left, right)
  local new_right = {}
  for _, rc in ipairs(right) do
    local r, new_left, k = rc, {}, 1
    while k <= #left do
      local nr = {}
      tc(new_left, left[k], r, 'left')
      tc(nr, r, left[k], 'right')
      k = k + 1
      if #nr == 1 then
        r = nr[1]
      elseif #nr == 0 then
        for j = k, #left do
          append(new_left, left[j])
        end
        r = nil
        break
      else
        local rest = {}
        for j = k, #left do
          rest[#rest + 1] = left[j]
        end
        local l2, r2 = M.transform_x(rest, nr)
        for _, c in ipairs(l2) do
          append(new_left, c)
        end
        for _, c in ipairs(r2) do
          append(new_right, c)
        end
        r = nil
        break
      end
    end
    if r then append(new_right, r) end
    left = new_left
  end
  return left, new_right
end

function M.transform_ops(ops, other, side)
  if side ~= 'left' and side ~= 'right' then error("side must be 'left' or 'right'") end
  if #other == 0 then
    local result = {}
    for _, c in ipairs(ops) do
      result[#result + 1] = copy(c)
    end
    return result
  end
  if side == 'left' then return (M.transform_x(ops, other)) end
  local _, right = M.transform_x(other, ops)
  return right
end

--- Compose two operations into one (op2 applied after op1)
---@param ops1 table[] first operation
---@param ops2 table[] second operation (applied after ops1)
---@return table[] composed operation
function M.compose(ops1, ops2)
  -- Simple composition: just concatenate
  -- This works because ops are position-based and applied sequentially
  local result = {}
  for _, op in ipairs(ops1) do
    table.insert(result, op)
  end
  for _, op in ipairs(ops2) do
    table.insert(result, op)
  end
  return result
end

--- Convert byte offset to (0-indexed row, col) in content string
---@param content string
---@param byte_offset number 0-based byte offset
---@return number row (0-indexed)
---@return number col (0-indexed)
function M.byte_offset_to_pos(content, byte_offset)
  local row = 0
  local last_newline = 0 -- position after last newline (1-indexed in content)

  for i = 1, byte_offset do
    if content:byte(i) == 10 then -- '\n'
      row = row + 1
      last_newline = i
    end
  end

  local col = byte_offset - last_newline
  return row, col
end

--- Convert (0-indexed row, col) to byte offset in content string
---@param content string
---@param row number 0-indexed
---@param col number 0-indexed
---@return number byte offset (0-based)
function M.pos_to_byte_offset(content, row, col)
  local current_row = 0
  local offset = 0

  for i = 1, #content do
    if current_row == row then return offset + col end
    if content:byte(i) == 10 then current_row = current_row + 1 end
    offset = offset + 1
  end

  -- Past end of content, return at the requested position
  return offset + col
end

return M
