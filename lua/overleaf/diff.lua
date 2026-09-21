-- Text difference -> OT ops, as small as the change really is.
--
-- Overleaf anchors comments and tracked changes to ranges of text. An op that
-- deletes and re-inserts text that did not change removes what was anchored to
-- it: a comment collapses to an empty range, a suggested insertion vanishes, a
-- suggested deletion is displaced. So the ops sent for a bulk change -- an
-- external tool rewriting the mirror file, a formatter run over the buffer --
-- must touch only the words that differ.
--
-- The ops come back in DESCENDING position order with non-overlapping hunks.
-- That makes each one valid against the original text however many there are
-- (a later position never shifts an earlier one), and it is what lets
-- ot.transform_ops, which transforms components independently, stay correct
-- for a list of them.
local ot = require('overleaf.ot')

local M = {}

-- Times the token diff produced ops that did not reproduce the new text and the
-- coarse fallback was used instead. Should stay 0; the tests assert it.
M._fallbacks = 0

-- Past this many tokens on either side the token diff is skipped and the change
-- is sent as one hunk. Correct, just coarser; only a wholesale rewrite gets here.
local MAX_TOKENS = 200000

local diff_fn = (vim.text and vim.text.diff) or vim.diff

-- A minimal edit script is often not unique, and among the tied ones the diff
-- will happily delete a word and put it back elsewhere -- which is exactly what
-- drops a comment anchored to it. Counting a word as several lines makes
-- touching one cost more than any amount of shuffled whitespace, so a reflow
-- moves the blanks and leaves the words where they are.
local WORD_WEIGHT = 4

--- Split into words, runs of blanks, newlines and single punctuation bytes.
--- Bytes >= 0x80 count as word characters, so a multibyte character is never
--- split. Returns the tokens and each token's 0-based byte offset.
---@param s string
---@return string[] tokens, integer[] starts
local function tokenize(s)
  local tokens, starts = {}, {}
  local pos, n = 1, #s
  while pos <= n do
    local _, e = s:find('^[A-Za-z0-9_\128-\255]+', pos)
    if not e then
      _, e = s:find('^[ \t\r]+', pos)
    end
    if not e then e = pos end
    tokens[#tokens + 1] = s:sub(pos, e)
    starts[#starts + 1] = pos - 1
    pos = e + 1
  end
  return tokens, starts
end

--- Word characters, as the tokenizer counts them: bytes >= 0x80 are all part of
--- a multibyte letter.
local function is_word_byte(b)
  return b ~= nil and (b >= 48 and b <= 57 or b >= 65 and b <= 90 or b >= 97 and b <= 122 or b == 95 or b >= 128)
end

--- Walk back to a UTF-8 character boundary.
local function floor_char_boundary(str, n)
  while n > 0 and n < #str and bit.band(str:byte(n + 1), 0xC0) == 0x80 do
    n = n - 1
  end
  return n
end

local function common_prefix_len(a, b)
  local max = math.min(#a, #b)
  local i = 0
  while i < max and a:byte(i + 1) == b:byte(i + 1) do
    i = i + 1
  end
  return floor_char_boundary(a, i)
end

--- Common suffix, on a character boundary and clear of the prefix already claimed.
local function common_suffix_len(a, b, prefix_len)
  local max = math.min(#a, #b) - prefix_len
  local i = 0
  while i < max and a:byte(#a - i) == b:byte(#b - i) do
    i = i + 1
  end
  while i > 0 and bit.band(a:byte(#a - i + 1), 0xC0) == 0x80 do
    i = i - 1
  end
  return i
end

--- One delete-and-insert pair covering the whole differing middle.
local function single_hunk(a, b, base_char)
  local ops = {}
  if #a > 0 then ops[#ops + 1] = { p = base_char, d = a } end
  if #b > 0 then ops[#ops + 1] = { p = base_char, i = b } end
  return ops
end

--- Ops relative to the start of `old`.
---@param old string
---@param new string
---@param words boolean whole-word replacements instead of the smallest edit
---@return table[]
local function build(old, new, words)
  if old == new then return {} end

  -- Typing, a paste, a single replaced word: one hunk, found in O(n).
  local prefix = common_prefix_len(old, new)
  local suffix = common_suffix_len(old, new, prefix)
  local a = old:sub(prefix + 1, #old - suffix)
  local b = new:sub(prefix + 1, #new - suffix)

  -- Replacing one word with another that shares letters ("lazy" -> "sleepy",
  -- sharing the y) trims down to "laz" -> "sleep". As an edit that is fine; as a
  -- suggestion a reviewer wants to read "lazy" struck out and "sleepy" added.
  -- Only replacements are widened: a character typed or deleted inside a word
  -- stays a one-character op.
  if words and a ~= '' and b ~= '' then
    if is_word_byte(a:byte(1)) or is_word_byte(b:byte(1)) then
      while prefix > 0 and is_word_byte(old:byte(prefix)) do
        prefix = prefix - 1
      end
    end
    if is_word_byte(a:byte(#a)) or is_word_byte(b:byte(#b)) then
      while suffix > 0 and is_word_byte(old:byte(#old - suffix + 1)) do
        suffix = suffix - 1
      end
    end
    a = old:sub(prefix + 1, #old - suffix)
    b = new:sub(prefix + 1, #new - suffix)
  end

  local origin = ot.byte_to_char(old, prefix)

  if a == '' or b == '' then return single_hunk(a, b, origin) end

  -- Several separate changes in one go: diff the middle by token, so the text
  -- between them is left alone.
  local ta, sa = tokenize(a)
  local tb, sb = tokenize(b)
  if #ta > MAX_TOKENS or #tb > MAX_TOKENS then return single_hunk(a, b, origin) end

  -- The diff works on lines, so give every distinct token a number and diff the
  -- numbers, one per line -- a word repeated WORD_WEIGHT times (see above).
  -- `first` and `owner` translate between token and line indices.
  local ids, next_id = {}, 0
  local function expand(tokens)
    local lines, first, owner = {}, {}, {}
    for i, tok in ipairs(tokens) do
      local id = ids[tok]
      if not id then
        next_id = next_id + 1
        id = next_id
        ids[tok] = id
      end
      local weight = tok:find('^[A-Za-z0-9_\128-\255]') and WORD_WEIGHT or 1
      first[i - 1] = #lines
      for _ = 1, weight do
        lines[#lines + 1] = id
        owner[#lines - 1] = i - 1
      end
    end
    return table.concat(lines, '\n') .. '\n', first, owner, #lines
  end

  local text_a, first_a, owner_a, lines_a = expand(ta)
  local text_b, first_b, owner_b, lines_b = expand(tb)

  local ok, hunks = pcall(diff_fn, text_a, text_b, { result_type = 'indices' })
  if not ok or type(hunks) ~= 'table' or #hunks == 0 then return single_hunk(a, b, origin) end

  local function byte_of(starts, len, idx) return idx < #starts and starts[idx + 1] or len end

  -- Token a hunk boundary at line `e` falls in. A boundary inside a word's
  -- repeated lines is pushed out to the word's edge; if that leaves the hunk
  -- inconsistent the check at the end falls back to one coarse hunk.
  local function token_start(owner, total, count, e) return e >= total and count or owner[e] end
  local function token_end(owner, first, total, count, e)
    if e >= total then return count end
    local tok = owner[e]
    return first[tok] == e and tok or tok + 1
  end

  -- Hunks arrive ascending. Character offsets are counted forward across them so
  -- the text is scanned once, then the ops are emitted from the last hunk back.
  local located = {}
  local cur_byte, cur_char = 0, origin
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    -- A side with nothing in the hunk reports the line BEFORE it.
    local ea = count_a > 0 and start_a - 1 or start_a
    local eb = count_b > 0 and start_b - 1 or start_b

    local ia = token_start(owner_a, lines_a, #ta, ea)
    local ib = token_start(owner_b, lines_b, #tb, eb)
    local ja = count_a > 0 and token_end(owner_a, first_a, lines_a, #ta, ea + count_a) or ia
    local jb = count_b > 0 and token_end(owner_b, first_b, lines_b, #tb, eb + count_b) or ib

    local from_a = byte_of(sa, #a, ia)
    local to_a = byte_of(sa, #a, ja)
    local from_b = byte_of(sb, #b, ib)
    local to_b = byte_of(sb, #b, jb)

    cur_char = cur_char + ot.utf8_len(a:sub(cur_byte + 1, from_a))
    cur_byte = from_a

    located[#located + 1] = {
      p = cur_char,
      deleted = a:sub(from_a + 1, to_a),
      inserted = b:sub(from_b + 1, to_b),
    }
  end

  local ops = {}
  for i = #located, 1, -1 do
    local h = located[i]
    if h.deleted ~= '' then ops[#ops + 1] = { p = h.p, d = h.deleted } end
    if h.inserted ~= '' then ops[#ops + 1] = { p = h.p, i = h.inserted } end
  end

  -- Belt and braces: a diff that does not reproduce `new` is worse than a coarse
  -- one, since the mirror and the server would silently disagree.
  local applied_ok, result = pcall(ot.apply, old, ops)
  if not applied_ok or result ~= new then
    M._fallbacks = M._fallbacks + 1
    return single_hunk(a, b, origin)
  end

  return ops
end

--- Ops turning `old` into `new`.
---@param old string
---@param new string
---@param base_char integer|nil character offset of `old` within the document (default 0)
---@param opts { words: boolean|nil }|nil `words` replaces whole words rather than the smallest
---  possible edit; wanted for suggestions, where the replacement is read by a person
---@return table[] ops descending by position, ready for ot.apply / applyOtUpdate
function M.ops(old, new, base_char, opts)
  local ops = build(old, new, opts ~= nil and opts.words == true)
  if base_char and base_char ~= 0 then
    for _, op in ipairs(ops) do
      op.p = op.p + base_char
    end
  end
  return ops
end

return M
