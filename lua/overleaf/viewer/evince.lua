-- Evince resolves source locations with SyncView and reports inverse clicks as
-- SyncSource signals on D-Bus. Papers does not expose this interface.

local gvariant = require('overleaf.viewer.gvariant')

local DAEMON_NAME = 'org.gnome.evince.Daemon'
local DAEMON_PATH = '/org/gnome/evince/Daemon'
local WINDOW_PATH = '/org/gnome/evince/Window/0'
local INTERFACE = 'org.gnome.evince.Window'

local M = {}

local function run(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  return result.code == 0, (result.stdout or '') .. (result.stderr or '')
end

--- The URI Evince filed `pdf_path` under. The daemon compares URI strings, so
--- use GLib's filename URI spelling, including its exact set of safe bytes.
---@param pdf_path string
---@return string
function M._document_uri(pdf_path)
  local safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!$&'()*+,-./:=@_~"
  local encoded = {}
  for i = 1, #pdf_path do
    local byte = pdf_path:sub(i, i)
    encoded[i] = safe:find(byte, 1, true) and byte or string.format('%%%02X', pdf_path:byte(i))
  end
  return 'file://' .. table.concat(encoded)
end

--- Each open document gets its own private bus name, handed out by a shared
--- daemon that is itself D-Bus-activated, so there is nothing to launch by
--- hand. `spawn=false` means this only reports a window that already has the
--- file open; it never opens one.
---@param pdf_path string
---@param _pid number|nil unused: Evince's directory is keyed by path, not pid
---@return string|nil bus name (a private name like ':1.234', not a well-known one)
function M.find(pdf_path, _pid)
  if vim.fn.executable('gdbus') == 0 then return nil end
  local ok, out = run({
    'gdbus',
    'call',
    '--session',
    '--dest',
    DAEMON_NAME,
    '--object-path',
    DAEMON_PATH,
    '--method',
    DAEMON_NAME .. '.FindDocument',
    M._document_uri(pdf_path),
    'false',
  })
  if not ok then return nil end

  local owner = out:match("^%('(.-)',%)")
  if not owner or owner == '' then return nil end
  return owner
end

--- Move an already-open Evince window to an absolute source location.
---@param pdf_path string
---@param file string path recorded by the local SyncTeX database
---@param line number 1-based
---@param column number 1-based
---@return boolean, string|nil
function M.forward(pdf_path, file, line, column)
  if vim.fn.executable('gdbus') == 0 then return false, 'gdbus is needed for Evince forward search' end
  local bus_name = M.find(pdf_path)
  if not bus_name then return false, 'No Evince window is showing ' .. pdf_path end
  local ok, out = run({
    'gdbus',
    'call',
    '--session',
    '--dest',
    bus_name,
    '--object-path',
    WINDOW_PATH,
    '--method',
    INTERFACE .. '.SyncView',
    file,
    string.format('(%d, %d)', line, math.max(column - 1, 0)),
    '0',
  })
  if not ok then return false, 'Evince rejected the jump: ' .. vim.trim(out) end
  return true
end

--- The command whose output is watched for SyncSource signals.
---@param bus_name string
---@return table argv
function M.monitor_command(bus_name) return { 'gdbus', 'monitor', '--session', '--dest', bus_name } end

--- Pick a SyncSource signal out of a line of `gdbus monitor` output.
---
---   /org/gnome/evince/Window/0: org.gnome.evince.Window.SyncSource ('file:///compile/main.tex', (71, -1), uint32 123)
---@param line string
---@return string|nil file (a file:// URI; init.lua's _synctex_source_path decodes it), number|nil line, number|nil column
function M.parse_edit(line)
  local file, rest = gvariant.string_after(line, 'org.gnome.evince.Window.SyncSource (')
  if not file then return nil end
  local ln, col = line:match('^, %((%-?%d+), (%-?%d+)%)', rest)
  if not ln then return nil end

  -- Signed, unlike zathura's: "no column" arrives as a plain -1.
  local column = tonumber(col)
  if not column or column < 0 then column = 0 end
  return file, tonumber(ln), column
end

return M
