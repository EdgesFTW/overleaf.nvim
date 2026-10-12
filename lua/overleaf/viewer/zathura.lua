-- Zathura announces inverse clicks as Edit signals on the session bus,
-- including for a viewer opened by hand. A click also runs -x when configured,
-- so the plugin uses only the signal to avoid two jumps from one click.

local gvariant = require('overleaf.viewer.gvariant')

local OBJECT = '/org/pwmt/zathura'
local INTERFACE = 'org.pwmt.zathura'

local M = {}

M._bus_name = nil -- the instance we last talked to, if it is still ours

local function run(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  return result.code == 0, (result.stdout or '') .. (result.stderr or '')
end

--- Every zathura on the session bus, newest first. The name carries the pid:
--- org.pwmt.zathura.PID-1234.
local function bus_names()
  local ok, out = run({ 'busctl', '--user', 'list', '--no-legend' })
  if not ok then return {} end

  local names = {}
  for line in out:gmatch('[^\n]+') do
    local name = line:match('^(org%.pwmt%.zathura%.[%w%-]+)')
    if name then table.insert(names, name) end
  end
  return names
end

--- The document a given instance has open, or nil if it will not say.
local function document_of(bus_name)
  local ok, out = run({
    'gdbus',
    'call',
    '--session',
    '--dest',
    bus_name,
    '--object-path',
    OBJECT,
    '--method',
    'org.freedesktop.DBus.Properties.Get',
    INTERFACE,
    'filename',
  })
  if not ok then return nil end
  return gvariant.string_after(out, '(<')
end

--- Find the zathura showing `pdf_path`. A pid we launched ourselves is checked
--- first; otherwise every instance on the bus is asked what it has open, which
--- also picks up a viewer left over from an earlier session.
---@param pdf_path string
---@param pid number|nil pid of a viewer this plugin started
---@return string|nil bus name
function M.find(pdf_path, pid)
  if vim.fn.executable('gdbus') == 0 or vim.fn.executable('busctl') == 0 then return nil end
  local wanted = vim.fs.normalize(pdf_path)

  local candidates = {}
  if pid then table.insert(candidates, 'org.pwmt.zathura.PID-' .. pid) end
  if M._bus_name then table.insert(candidates, M._bus_name) end
  vim.list_extend(candidates, bus_names())

  local seen = {}
  for _, name in ipairs(candidates) do
    if not seen[name] then
      seen[name] = true
      local doc = document_of(name)
      if doc and vim.fs.normalize(doc) == wanted then
        M._bus_name = name
        return name
      end
    end
  end

  M._bus_name = nil
  return nil
end

--- The command whose output is watched for Edit signals.
---@param bus_name string
---@return table argv
function M.monitor_command(bus_name) return { 'gdbus', 'monitor', '--session', '--dest', bus_name } end

--- Pick an Edit signal out of a line of `gdbus monitor` output.
---
---   /org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/./main.tex', uint32 71, uint32 4294967295)
---@param line string
---@return string|nil file, number|nil line, number|nil column
function M.parse_edit(line)
  local file, rest = gvariant.string_after(line, 'org.pwmt.zathura.Edit (')
  if not file then return nil end
  local ln, col = line:match('^, uint32 (%d+), uint32 (%d+)%)', rest)
  if not ln then return nil end

  -- SyncTeX reports "no column" as -1, which arrives unsigned.
  local column = tonumber(col)
  if column == nil or column >= 2 ^ 31 then column = 0 end
  return file, tonumber(ln), column
end

return M
