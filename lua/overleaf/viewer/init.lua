-- Resolve PDF viewer profiles and manage their shared D-Bus inverse listener.
-- Command profiles only describe argv; the listener drivers parse each bus's
-- signal and identify the window showing our PDF.
local config = require('overleaf.config')
local profiles = require('overleaf.viewer.profiles')

local M = {}
local monitor_job
local monitor_bus
local monitor_driver
local monitor_path

local function argv_ok(argv)
  if type(argv) ~= 'table' or type(argv[1]) ~= 'string' or argv[1] == '' then return false end
  for _, value in ipairs(argv) do
    if type(value) ~= 'string' or value == '' then return false end
  end
  return #argv > 0
end

--- Resolve nil, executable names or user tables into a viewer profile.
---@return table|nil profile, string|nil error
function M.profile()
  local setting = config.get().pdf_viewer
  if setting == nil then return { name = 'default', forward = profiles.zathura.forward, listen = 'zathura' } end
  if type(setting) == 'string' then
    if setting == '' then return nil, 'pdf_viewer must not be empty' end
    local name = vim.fn.fnamemodify(setting, ':t')
    local built_in = profiles[name]
    if not built_in then return { name = name, open = { setting, '@pdf' }, listen = 'zathura' } end
    local resolved = vim.deepcopy(built_in)
    resolved.open[1] = setting
    if type(resolved.forward) == 'table' then resolved.forward[1] = setting end
    return resolved
  end
  if type(setting) ~= 'table' then return nil, 'pdf_viewer must be nil, a command, or a profile table' end
  local p = setting
  if p.name ~= nil and type(p.name) ~= 'string' then return nil, 'pdf_viewer.name must be a string' end
  if not argv_ok(p.open) then return nil, 'pdf_viewer.open must be a nonempty argv list' end
  if p.forward ~= nil and p.forward ~= 'evince' and not argv_ok(p.forward) then
    return nil, 'pdf_viewer.forward must be an argv list or "evince"'
  end
  if p.inverse ~= nil and (type(p.inverse) ~= 'table' or #p.inverse == 0) then
    return nil, 'pdf_viewer.inverse must be an argv list'
  end
  if p.inverse then
    for _, arg in ipairs(p.inverse) do
      if type(arg) ~= 'string' or arg == '' then return nil, 'pdf_viewer.inverse must be an argv list' end
    end
  end
  if p.listen ~= nil and p.listen ~= 'zathura' and p.listen ~= 'evince' then
    return nil, 'pdf_viewer.listen must be "zathura" or "evince"'
  end
  if p.unique_bus ~= nil and (type(p.unique_bus) ~= 'string' or p.unique_bus == '') then
    return nil, 'pdf_viewer.unique_bus must be a nonempty D-Bus name'
  end
  return p
end

--- Whether a profile's single-instance viewer already owns its session bus name.
--- Only such profiles need this lookup; other viewers never require gdbus here.
---@param profile table
---@return boolean
function M.unique_running(profile)
  if not profile.unique_bus or vim.fn.executable('gdbus') == 0 then return false end
  local ok, result = pcall(vim.system, {
    'gdbus',
    'call',
    '--session',
    '--dest',
    'org.freedesktop.DBus',
    '--object-path',
    '/org/freedesktop/DBus',
    '--method',
    'org.freedesktop.DBus.NameHasOwner',
    profile.unique_bus,
  }, { text = true })
  if not ok then return false end
  local answer = result:wait()
  return answer.code == 0 and (answer.stdout or ''):match('^%(%s*true,?%s*%)') ~= nil
end

--- Expand known placeholders once, preserving viewer syntax and path bytes.
---@param argv string[]
---@param values table<string, string|number>
---@param inverse boolean
---@return string[]
function M.expand(argv, values, inverse)
  local expanded = {}
  for i, arg in ipairs(argv) do
    if not (arg:find('@callback', 1, true) and not inverse) then
      local value = arg:gsub('@(%a+)', function(key)
        if values[key] == nil then return '@' .. key end
        return tostring(values[key])
      end)
      expanded[i] = value
    end
  end
  local compact = {}
  for i = 1, #argv do
    if expanded[i] then compact[#compact + 1] = expanded[i] end
  end
  return compact
end

--- Build an argv for launching (`open`) or moving (`forward`) the viewer.
---
--- The profile's optional `inverse` arguments go right after the executable,
--- and only on `open`: Okular, the one built-in that uses them, refuses to
--- take an editor command from a second `--unique` invocation (it exits 1 with
--- "You cannot set the editor command in an already running okular instance"),
--- so a forward search must not repeat them.
---@param profile table
---@param kind string 'open' or 'forward'
---@param values table<string, string|number>
---@param inverse boolean
---@return string[]|nil
function M.command(profile, kind, values, inverse)
  local source = profile[kind]
  if type(source) ~= 'table' then return nil end
  local argv = { source[1] }
  if kind == 'open' and inverse and values.callback and profile.inverse then vim.list_extend(argv, profile.inverse) end
  for i = 2, #source do
    argv[#argv + 1] = source[i]
  end
  return M.expand(argv, values, inverse and values.callback ~= nil)
end

--- Launch an argv without a shell and report failures after the process exits.
---@param argv string[]
---@param on_exit fun(code: number, stderr: string)|nil
---@return number job id
function M._start_job(argv, on_exit)
  local stderr = {}
  local job = vim.fn.jobstart(argv, {
    detach = true,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line ~= '' then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if on_exit then on_exit(code, table.concat(stderr, '\n')) end
    end,
  })
  return job
end

--- Move the viewer using its command or Evince's SyncView method.
---@param profile table
---@param values table<string, string|number>
---@param inverse boolean
---@return boolean, string|nil
function M.forward(profile, values, inverse)
  if not profile.forward then
    return false, 'Forward search supports zathura, okular, evince, or a pdf_viewer profile table with forward'
  end
  if profile.forward == 'evince' then
    return require('overleaf.viewer.evince').forward(values.pdf, values.file, values.line, values.column)
  end
  -- With the system opener, a new zathura window could open beside a different
  -- viewer. An explicit zathura profile may launch at the requested location.
  if config.get().pdf_viewer == nil then
    if vim.fn.executable('gdbus') == 0 or vim.fn.executable('busctl') == 0 then
      return false, 'gdbus and busctl are needed for zathura forward search'
    end
    if not require('overleaf.viewer.zathura').find(values.pdf, values.pid) then
      return false, 'No zathura is showing ' .. values.pdf .. '; set pdf_viewer for forward search with another viewer'
    end
  end
  local argv = M.command(profile, 'forward', values, inverse)
  local job = M._start_job(argv, function(code, stderr)
    if code ~= 0 then config.log('warn', 'Viewer forward search exited %d: %s', code, stderr) end
  end)
  if job <= 0 then return false, 'Could not start viewer forward search: ' .. argv[1] end
  return true
end

--- Listen to Edit or SyncSource through the driver's parser. One monitor serves
--- either driver; changing the PDF or viewer stops the old monitor first.
---@param profile table
---@param pdf_path string
---@param pid number|nil
---@param on_edit fun(file: string, line: number, column: number)
---@return boolean, string|nil
function M.watch_edits(profile, pdf_path, pid, on_edit)
  if not profile.listen then return true end
  local driver = require('overleaf.viewer.' .. profile.listen)
  local bus_name
  if M.watching() then
    if monitor_driver == driver and monitor_path == pdf_path then
      bus_name = driver.find(pdf_path, pid)
      if bus_name == monitor_bus then return true end
    end
    M.stop_watching()
  end
  if vim.fn.executable('gdbus') == 0 then return false, 'gdbus is needed to watch the viewer' end
  bus_name = bus_name or driver.find(pdf_path, pid)
  if not bus_name then return false, 'No ' .. profile.listen .. ' is showing ' .. pdf_path end
  local pending = ''
  local function deliver(line)
    local file, ln, col = driver.parse_edit(line)
    if file then on_edit(file, ln, col) end
  end
  local job = M._start_monitor(driver.monitor_command(bus_name), {
    on_stdout = function(_, lines)
      for i = 1, #lines - 1 do
        deliver((i == 1 and pending or '') .. lines[i])
      end
      if #lines > 0 then pending = (#lines == 1 and pending or '') .. lines[#lines] end
    end,
    on_exit = function(id)
      if monitor_job == id then
        if pending ~= '' then deliver(pending) end
        monitor_job = nil
        monitor_bus = nil
        monitor_driver = nil
        monitor_path = nil
      end
    end,
  })
  if job <= 0 then return false, 'Could not start gdbus monitor' end
  monitor_job = job
  monitor_bus = bus_name
  monitor_driver = driver
  monitor_path = pdf_path
  config.log('debug', 'Watching %s for SyncTeX clicks', monitor_bus)
  return true
end

--- Job-start seam for deterministic tests of split monitor output.
---@param argv string[]
---@param options table
---@return number
function M._start_monitor(argv, options) return vim.fn.jobstart(argv, options) end

---@return boolean
function M.watching() return monitor_job ~= nil end

--- Stop the current monitor on disconnect or a viewer change.
function M.stop_watching()
  if monitor_job then
    pcall(vim.fn.jobstop, monitor_job)
    monitor_job = nil
    monitor_bus = nil
    monitor_driver = nil
    monitor_path = nil
  end
end

return M
