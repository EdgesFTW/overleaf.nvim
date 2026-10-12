-- Reading strings back out of gdbus's text output, which prints GVariant
-- values in their text format rather than as raw bytes.
--
-- A string is single-quoted unless it contains a single quote and no double
-- quote, in which case it is double-quoted instead -- so a path like
-- `chapters/author's note.tex` arrives as "...", not '...'. Inside either form,
-- the quote character, backslashes and non-printable characters are
-- backslash-escaped.
local M = {}

local SIMPLE_ESCAPES = { a = '\a', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', v = '\v' }

--- Decode the string literal that opens at `init` in `text`.
---@param text string
---@param init number index of the opening quote
---@return string|nil value, number|nil index just past the closing quote
function M.read_string(text, init)
  local quote = text:sub(init, init)
  if quote ~= "'" and quote ~= '"' then return nil end

  local out = {}
  local i = init + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == quote then return table.concat(out), i + 1 end
    if c == '\\' then
      local e = text:sub(i + 1, i + 1)
      if e == 'u' or e == 'U' then
        local width = e == 'u' and 4 or 8
        local code = tonumber(text:sub(i + 2, i + 1 + width), 16)
        if not code then return nil end
        table.insert(out, vim.fn.nr2char(code, 1))
        i = i + 2 + width
      else
        table.insert(out, SIMPLE_ESCAPES[e] or e)
        i = i + 2
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return nil -- unterminated
end

--- Find `prefix` in `text` and decode the string literal right after it.
---@param text string
---@param prefix string plain text, e.g. 'Edit ('
---@return string|nil value, number|nil index just past the closing quote
function M.string_after(text, prefix)
  local _, last = text:find(prefix, 1, true)
  if not last then return nil end
  return M.read_string(text, last + 1)
end

return M
