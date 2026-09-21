local M = {}

M._config = {
  env_file = '.env',
  cookie = nil,
  node_path = 'node',
  base_url = 'https://www.overleaf.com', -- Overleaf instance URL (for self-hosted)
  pdf_viewer = nil, -- PDF viewer command (nil = auto-detect: 'open' on macOS, 'xdg-open' on Linux)
  pdf_dir = nil, -- PDF output directory (nil = a private per-user dir under the system temp dir)
  -- When a compile should hand the PDF to the viewer. Every compile rewrites
  -- the same path atomically, so a viewer that reloads on change stays current
  -- without being launched again -- and without stealing focus from Neovim.
  --   'once'   - launch the viewer for the first compile of a session only
  --   'always' - launch it after every compile (the old behaviour)
  --   false    - never; ':Overleaf pdf' opens it on demand
  pdf_auto_open = 'once',
  -- Ctrl+click in the PDF jumps the buffer to the line that produced it. Needs
  -- zathura: it resolves the click against the SyncTeX database the plugin
  -- downloads next to the PDF, then announces the result on the session bus.
  inverse_search = true,
  sync_dir = nil, -- Local file sync directory (nil = disabled; enables external tool integration)
  -- Files Overleaf stores as binary "fileRefs" (anything whose extension is
  -- not on its text whitelist, e.g. .asm or .c) have no real-time document
  -- behind them, so they can only be edited by re-uploading the whole file.
  --   'auto'  - open any fileRef whose content is text (UTF-8, no NUL bytes)
  --   { 'asm', 'c' } - only fileRefs with these extensions (content still checked)
  --   false   - never; fileRefs are download-only, as before
  editable_files = 'auto',
  -- How this client changes the project, as in Overleaf's editor:
  --   'auto'       - editing where the project allows it, else the nearest mode
  --   'editing'    - edits are applied as typed
  --   'suggesting' - edits are sent as tracked changes (suggestions)
  --   'viewing'    - read-only; nothing is sent, the disk mirror is not pushed
  -- Switch at any time with :Overleaf mode.
  mode = 'auto',
  -- Every default keymap hangs off this prefix, so the whole set can be moved
  -- aside when another plugin already claims '<leader>o' (obsidian.nvim, say).
  keymap_prefix = '<leader>o',
  keymaps = true, -- false leaves every key free; the :Overleaf commands still work
  log_level = 'info', -- 'debug', 'info', 'warn', 'error'
}

function M.setup(opts)
  if opts then
    for k, v in pairs(opts) do
      M._config[k] = v
    end
  end
end

function M.get() return M._config end

local function cookie_preview(cookie)
  if not cookie or cookie == '' then return '<empty>' end

  local key, value = cookie:match('^([^=]+)=(.+)$')
  if key and value then
    if #value <= 12 then return key .. '=' .. value end
    return string.format('%s=%s...%s...', key, value:sub(1, 4), value:sub(5, 12))
  end

  if #cookie <= 16 then return cookie end
  return cookie:sub(1, 16) .. '...'
end

local function resolve_cookie_paths(env_file)
  -- io.open() takes the path literally, so '~/x' would be read as a directory
  -- named '~'. Normalize first, which expands both '~' and '$VAR'.
  -- vim.fs.normalize is used rather than vim.fn.expand because it does not
  -- glob -- a path containing '*' stays literal.
  env_file = vim.fs.normalize(env_file)

  if env_file:sub(1, 1) == '/' then
    -- Absolute path: use directly
    return { env_file }
  end

  -- Relative path: try cwd, then plugin root
  return {
    vim.fn.getcwd() .. '/' .. env_file,
    M.plugin_root() .. '/' .. env_file,
  }
end

function M.load_cookie(opts)
  opts = opts or {}
  local checks = {}

  local function finish(cookie, source, path)
    local meta = {
      source = source,
      path = path,
      checks = checks,
    }
    if opts.return_metadata then return cookie, meta end
    return cookie
  end

  if M._config.cookie then return finish(M._config.cookie, 'config', nil) end

  local env_file = M._config.env_file
  local paths = resolve_cookie_paths(env_file)

  for _, path in ipairs(paths) do
    local found = false
    local cookie = nil
    local f = io.open(path, 'r')
    if f then
      for line in f:lines() do
        local key, value = line:match('^([^=]+)=(.+)$')
        if key == 'OVERLEAF_COOKIE' then
          cookie = value
          found = true
          break
        end
      end
      f:close()
    end

    table.insert(checks, { path = path, found = found })

    if found then
      M._config.cookie = cookie
      M.log('debug', 'Loaded cookie from %s: %s', path, cookie_preview(cookie))
      return finish(cookie, 'env-file', path)
    end
  end

  return finish(nil, nil, nil)
end

function M.plugin_root()
  -- Resolve plugin root from this file's location
  local source = debug.getinfo(1, 'S').source:sub(2)
  -- source = /path/to/overleaf-neovim/lua/overleaf/config.lua
  return vim.fn.fnamemodify(source, ':h:h:h')
end

function M.bridge_script() return M.plugin_root() .. '/node/bridge.js' end

function M.log(level, msg, ...)
  local levels = { debug = 0, info = 1, warn = 2, error = 3 }
  local current = levels[M._config.log_level] or 1
  local target = levels[level] or 1

  if target >= current then
    local vim_level = ({
      debug = vim.log.levels.DEBUG,
      info = vim.log.levels.INFO,
      warn = vim.log.levels.WARN,
      error = vim.log.levels.ERROR,
    })[level] or vim.log.levels.INFO

    local formatted = string.format(msg, ...)
    vim.notify('[overleaf] ' .. formatted, vim_level)
  end
end

return M
