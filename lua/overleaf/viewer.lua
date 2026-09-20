-- Driving the PDF viewer over D-Bus, so a forward search can move the page
-- without the plugin having to own the window.
--
-- Only zathura is supported: it is the one common Linux viewer that exposes
-- GotoPage and HighlightRects on the session bus. Everything here degrades to a
-- warning when it is not the viewer in use.
local config = require('overleaf.config')

local M = {}

local OBJECT = '/org/pwmt/zathura'
local INTERFACE = 'org.pwmt.zathura'

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
  return out:match("<'(.-)'>") or out:match('<"(.-)">')
end

--- Find the zathura showing `pdf_path`. A pid we launched ourselves is checked
--- first; otherwise every instance on the bus is asked what it has open, which
--- also picks up a viewer left over from an earlier session.
---@param pdf_path string
---@param pid number|nil pid of a viewer this plugin started
---@return string|nil bus name
function M.find(pdf_path, pid)
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

--- Show `page` of `pdf_path` and highlight `rects` on it.
---@param pdf_path string
---@param page number 1-based, as SyncTeX counts pages
---@param rects table list of { x1, y1, x2, y2 } in PDF points from the page's top-left
---@param pid number|nil pid of a viewer this plugin started
---@return boolean, string|nil
function M.show(pdf_path, page, rects, pid)
  if type(pdf_path) ~= 'string' or pdf_path == '' then return false, 'No PDF to move' end
  if vim.fn.executable('gdbus') == 0 or vim.fn.executable('busctl') == 0 then
    return false, 'gdbus and busctl are needed to drive the viewer'
  end

  local bus_name = M.find(pdf_path, pid)
  if not bus_name then
    return false, 'No zathura is showing ' .. pdf_path .. ' (set pdf_viewer = "zathura" and run :Overleaf pdf)'
  end

  local parts = {}
  for _, r in ipairs(rects) do
    table.insert(parts, string.format('(%f, %f, %f, %f)', r[1], r[2], r[3], r[4]))
  end

  -- zathura counts pages from zero; SyncTeX counts from one.
  local ok, out = run({
    'gdbus',
    'call',
    '--session',
    '--dest',
    bus_name,
    '--object-path',
    OBJECT,
    '--method',
    INTERFACE .. '.HighlightRects',
    tostring(math.max(page - 1, 0)),
    '[' .. table.concat(parts, ', ') .. ']',
    '[]',
  })
  if not ok then
    M._bus_name = nil
    return false, 'Viewer rejected the jump: ' .. vim.trim(out)
  end

  config.log('debug', 'Viewer moved to page %d via %s', page, bus_name)
  return true, nil
end

M._monitor_job = nil
M._monitor_bus = nil

--- The command whose output is watched for Edit signals. A seam for tests,
--- which have no zathura to click on.
---@param bus_name string
---@return table argv
function M._monitor_command(bus_name) return { 'gdbus', 'monitor', '--session', '--dest', bus_name } end

--- Pick an Edit signal out of a line of `gdbus monitor` output.
---
---   /org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/./main.tex', uint32 71, uint32 4294967295)
---@param line string
---@return string|nil file, number|nil line, number|nil column
function M._parse_edit(line)
  local file, ln, col = line:match("Edit %('(.-)', uint32 (%d+), uint32 (%d+)%)")
  if not file then return nil end

  -- SyncTeX reports "no column" as -1, which arrives unsigned.
  local column = tonumber(col)
  if column == nil or column >= 2 ^ 31 then column = 0 end
  return file, tonumber(ln), column
end

--- Watch a zathura for backward-search clicks.
---
--- zathura resolves a ctrl+click through the SyncTeX database sitting next to
--- the PDF and announces the result as an `Edit` signal, whether or not
--- `synctex-editor-command` is set. Listening for that is how the plugin learns
--- about a click at all: there is no signal for a raw one.
---@param pdf_path string
---@param pid number|nil
---@param on_edit fun(file: string, line: number, column: number)
---@return boolean, string|nil
function M.watch_edits(pdf_path, pid, on_edit)
  if M.watching() then return true, nil end
  if vim.fn.executable('gdbus') == 0 then return false, 'gdbus is needed to watch the viewer' end

  local bus_name = M.find(pdf_path, pid)
  if not bus_name then return false, 'No zathura is showing ' .. pdf_path end

  local job = vim.fn.jobstart(M._monitor_command(bus_name), {
    on_stdout = function(_, lines)
      for _, line in ipairs(lines) do
        local file, ln, col = M._parse_edit(line)
        if file then on_edit(file, ln, col) end
      end
    end,
    on_exit = function(id)
      if M._monitor_job == id then
        M._monitor_job = nil
        M._monitor_bus = nil
      end
    end,
  })

  if job <= 0 then return false, 'Could not start gdbus monitor' end

  M._monitor_job = job
  M._monitor_bus = bus_name
  config.log('debug', 'Watching %s for SyncTeX clicks', bus_name)
  return true, nil
end

---@return boolean
function M.watching() return M._monitor_job ~= nil end

function M.stop_watching()
  if M._monitor_job then
    pcall(vim.fn.jobstop, M._monitor_job)
    M._monitor_job = nil
    M._monitor_bus = nil
  end
end

return M
