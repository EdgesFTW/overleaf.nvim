local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local project = require('overleaf.project')
local Document = require('overleaf.document')
local buffer = require('overleaf.buffer')
local sync = require('overleaf.sync')
local viewer = require('overleaf.viewer')
local mode = require('overleaf.mode')

local M = {}

--- Address of this Neovim's RPC server, or an empty string if none is running.
---@return string
function M._server_address() return vim.v.servername end

--- Stable, private state file name with no project text for viewer macros to expand.
---@param pdf_path string
---@return string
function M._server_state_path(pdf_path)
  return vim.fn.stdpath('run') .. '/overleaf-inverse-' .. vim.fn.sha256(pdf_path):sub(1, 16)
end

--- Build one POSIX-quoted callback command for viewers with editor hooks.
---@param pdf_path string
---@return string|nil
local function callback_command(pdf_path)
  if not config.get().inverse_search or M._server_address() == '' then return nil end
  local source = debug.getinfo(1, 'S').source:sub(2)
  local script = vim.fn.fnamemodify(source, ':p:h:h:h') .. '/scripts/overleaf-inverse.lua'
  local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
  return table.concat(
    { quote(vim.v.progpath), '--clean -l', quote(script), quote(M._server_state_path(pdf_path)) },
    ' '
  )
end

local function viewer_values(pdf_path, file, line, column)
  return { pdf = pdf_path, file = file, line = line, column = column, callback = callback_command(pdf_path) }
end

--- Write the current RPC address into the user's runtime directory (mode 0600).
---@param pdf_path string
local function write_server_state(pdf_path)
  if not pdf_path or M._server_address() == '' then return end
  local statefile = M._server_state_path(pdf_path)
  local fd, err = vim.uv.fs_open(statefile, 'w', tonumber('600', 8))
  if not fd then
    config.log('warn', 'Could not write inverse search state %s: %s', statefile, err)
    return
  end
  local secured, mode_err = vim.uv.fs_fchmod(fd, tonumber('600', 8))
  if not secured then
    vim.uv.fs_close(fd)
    os.remove(statefile)
    config.log('warn', 'Could not secure inverse search state %s: %s', statefile, mode_err)
    return
  end
  local written, write_err = vim.uv.fs_write(fd, M._server_address() .. '\n', 0)
  vim.uv.fs_close(fd)
  if not written then config.log('warn', 'Could not write inverse search state %s: %s', statefile, write_err) end
end

--- Remove the state only if it still belongs to this Neovim session.
---@param pdf_path string|nil
local function remove_server_state(pdf_path)
  if not pdf_path or M._server_address() == '' then return end
  local statefile = M._server_state_path(pdf_path)
  local handle = io.open(statefile, 'r')
  if not handle then return end
  local server = handle:read('*l')
  handle:close()
  if server == M._server_address() then os.remove(statefile) end
end

M._callback_command = callback_command
M._write_server_state = write_server_state
M._remove_server_state = remove_server_state

--- Open a file with the configured viewer or platform default.
---@param file_path string
---@return number|nil pid of the viewer, when it was started by us
local function open_file(file_path)
  write_server_state(file_path)
  local profile, err = viewer.profile()
  if not profile then
    config.log('error', '%s', err)
    return nil
  end
  if not profile.open then
    -- vim.ui.open() detaches the platform opener. With xdg-open its pipes are
    -- disabled and the viewer is reparented to init, so it outlives Neovim
    -- without leaving a zombie. vim.fn.system() would wait for the viewer and
    -- freeze the editor until that window closed.
    local _, open_err = vim.ui.open(file_path)
    if open_err then config.log('error', 'Could not open %s: %s', file_path, open_err) end
    return nil
  end
  -- Okular rejects a second --editor-cmd on an existing --unique instance.
  local with_inverse = config.get().inverse_search and not viewer.unique_running(profile)
  local argv = viewer.command(profile, 'open', viewer_values(file_path), with_inverse)
  local job = viewer._start_job(argv, function(code, stderr)
    if code ~= 0 then config.log('warn', 'PDF viewer exited %d: %s', code, stderr) end
  end)
  if job <= 0 then
    config.log('error', 'Could not start PDF viewer: %s', argv[1])
    return nil
  end
  local ok, pid = pcall(vim.fn.jobpid, job)
  if ok then return pid end
end

M._state = {
  connected = false,
  project_name = nil,
  project_id = nil,
  project_data = nil,
  csrf_token = nil,
  root_doc_id = nil, -- project's main document; Overleaf compiles this one
  documents = {}, -- doc_id -> Document
  public_ids = {}, -- socket ids retained across reconnects for catch-up ACKs
  public_id = nil, -- the current socket's id
  user_id = nil, -- the signed-in user's id, for per-user project settings
  pdf_path = nil, -- where the last compile's output.pdf landed
  pdf_opened = {}, -- path -> true once a viewer has been launched for it
  pdf_pid = nil, -- viewer process, when we started it (used to find it on D-Bus)
  build_id = nil, -- identifier of the last compile
  clsi_server_id = nil, -- CLSI node holding that build
  synctex_path = nil, -- SyncTeX database mirrored next to the PDF
  synctex_root = nil, -- source prefix recorded in the local database
}

-- Suffixes appended to config.keymap_prefix. Kept as data so the prefix is the
-- only thing that has to move when another plugin claims the same leader key.
local DEFAULT_KEYMAPS = {
  { 'c', 'Connect', function() M.connect() end },
  { 'd', 'Disconnect', function() M.disconnect() end },
  { 'b', 'Build (compile)', function() M.compile() end },
  { 't', 'Toggle tree', function() M.toggle_tree() end },
  { 'o', 'Open document', function() M.select_document() end },
  { 'p', 'Preview file', function() M.preview_file() end },
  { 'r', 'Read comment', function() M.show_comment() end },
  { 'R', 'Reply to comment', function() M.reply_comment() end },
  { 'x', 'Resolve/reopen comment', function() M.resolve_comment() end },
  { 'f', 'Find in project', function() M.search() end },
  { 'm', 'Set main document', function() M.set_main_file() end },
  { 'v', 'View PDF', function() M.open_pdf() end },
  { 's', 'Forward search (SyncTeX)', function() M.forward_search() end },
  { 'M', 'Switch mode (editing/suggesting/viewing)', function() M.select_mode() end },
}
local installed_keymaps = {}

function M.setup(opts)
  config.setup(opts)
  M._set_keymaps()
  local group = vim.api.nvim_create_augroup('OverleafViewerState', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      remove_server_state(M._state.pdf_path)
      sync.flush_manifest()
    end,
  })
end

function M._set_keymaps()
  local current = {}
  for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
    current[map.lhs] = map
  end
  for _, map in ipairs(installed_keymaps) do
    if current[map.lhs] and current[map.lhs].callback == map.callback then vim.keymap.del('n', map.lhs) end
  end
  installed_keymaps = {}

  local cfg = config.get()
  if cfg.keymaps == false then return end

  local prefix = cfg.keymap_prefix
  for _, km in ipairs(DEFAULT_KEYMAPS) do
    local suffix, desc, rhs = km[1], km[2], km[3]
    vim.keymap.set('n', prefix .. suffix, rhs, { desc = 'Overleaf: ' .. desc })
    for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
      if map.callback == rhs then
        table.insert(installed_keymaps, { lhs = map.lhs, callback = rhs })
        break
      end
    end
  end

  -- Label the prefix itself so which-key shows "Overleaf" instead of a bare
  -- key. Optional: the keymaps above work without it.
  local ok, wk = pcall(require, 'which-key')
  if ok and type(wk.add) == 'function' then wk.add({ { prefix, group = 'Overleaf' } }) end
end

function M.connect()
  config.log('info', 'Starting bridge...')

  -- Step 1: Start bridge process
  bridge.start(function(err)
    if err then
      config.log('error', 'Failed to start bridge: %s', err.message)
      return
    end

    -- Step 2: Get cookie (from config, .env, or Chrome)
    M._get_cookie(function(cookie, cookie_source)
      if not cookie then return end

      config.log('info', 'Authenticating...')

      -- Step 3: Authenticate and get project list
      bridge.request('auth', { cookie = cookie, cookieSource = cookie_source }, function(auth_err, result)
        if auth_err then
          config.log('error', 'Authentication failed: %s', auth_err.message)
          return
        end

        local normalized_cookie = result.normalizedCookie or cookie
        if result.cookieWasNormalized then
          config.log('warn', 'Cookie value missing "overleaf_session2=" prefix, auto-prepending')
        end
        if result.cookieSource then config.log('debug', 'Cookie source: %s', result.cookieSource) end
        config.get().cookie = normalized_cookie

        config.log('info', 'Authenticated as %s (%d projects)', result.userEmail or result.userId, #result.projects)
        M._state.csrf_token = result.csrfToken
        M._state.user_id = result.userId
        project.set_projects(result.projects)

        -- Step 4: Select project
        project.select_project(
          function(project_id, project_name) M._connect_project(normalized_cookie, project_id, project_name) end
        )
      end)
    end)
  end)
end

function M._get_cookie(callback)
  -- Explicit configuration wins. If the user set `cookie` or pointed `env_file`
  -- at a readable file, use it and skip browser detection entirely -- otherwise
  -- a machine with several Chrome/Chromium installs prompts with a profile
  -- picker on every connect even though the cookie was already configured.
  local configured = config.load_cookie()
  if configured then
    config.log('debug', 'Cookie source: config/env (skipping Chrome detection)')
    callback(configured, 'env')
    return
  end

  -- Otherwise search every profile of every detected browser. The bridge picks
  -- the most recently used Overleaf session, so no profile prompt is needed.
  config.log('info', 'Searching browser profiles for an Overleaf session...')
  bridge.request('getCookie', {}, function(cookie_err, cookie_result)
    if not cookie_err and cookie_result and cookie_result.cookie then
      config.log('info', 'Cookie extracted from browser')
      config.get().cookie = cookie_result.cookie
      callback(cookie_result.cookie, 'chrome')
      return
    end
    config.log('debug', 'Browser extraction failed: %s', cookie_err and cookie_err.message or 'unknown')
    M._get_cookie_fallback(callback)
  end)
end

function M._get_cookie_fallback(callback)
  local cookie, meta = config.load_cookie({ return_metadata = true })
  if meta and meta.checks then
    for _, check in ipairs(meta.checks) do
      config.log('debug', '.env path checked: %s (found: %s)', check.path, check.found and 'yes' or 'no')
    end
  end

  if cookie then
    local source = meta and meta.source or 'config'
    config.log('debug', 'Cookie source: %s', source)
    callback(cookie, source)
    return
  end
  config.log('error', 'No cookie found. Log in to overleaf.com in Chrome, or set OVERLEAF_COOKIE in .env')
  callback(nil, nil)
end

function M._connect_project(cookie, project_id, project_name)
  if M._state.project_id then
    M._teardown(false, function() M._connect_project(cookie, project_id, project_name) end)
    return
  end
  config.log('info', 'Connecting to project: %s', project_name)

  -- Register event handlers before connecting
  M._setup_event_handlers()

  -- Set up bridge auto-restart on unexpected exit
  bridge._on_unexpected_exit = function(code)
    config.log('warn', 'Bridge process died (code %d), attempting reconnect...', code)
    M._state.connected = false
    M._reconnect.attempt = 0
    M._attempt_reconnect()
  end

  bridge.request('connect', {
    cookie = cookie,
    projectId = project_id,
  }, function(err, result)
    if err then
      config.log('error', 'Failed to connect: %s', err.message)
      return
    end

    M._state.connected = true
    M._state.project_id = project_id
    M._state.project_name = project_name
    M._state.project_data = result.project
    if result.publicId then
      M._state.public_ids = M._state.public_ids or {}
      M._state.public_ids[result.publicId] = true
      M._state.public_id = result.publicId
    end
    M._state.root_doc_id = result.project and result.project.rootDoc_id or nil

    -- What this session may do depends on the access level the server granted
    -- and on whether the project forces tracking on for this user.
    mode.init(result.permissionsLevel, result.project and result.project.trackChangesState, M._state.user_id)
    if mode.get() ~= mode.EDITING then config.log('info', 'Mode: %s (%s)', mode.get(), M._mode_note(mode.get())) end

    -- Parse project tree
    project.parse_project_tree(result.project)

    config.log('info', 'Connected to: %s', project_name)

    -- Load comment threads
    require('overleaf.comments').load_threads(project_id)

    -- Start file sync (if sync_dir configured)
    sync.start(project_name)
    sync.sync_all(M._state, project._project_tree)

    -- Show tree immediately
    vim.schedule(function() require('overleaf.tree').toggle() end)
  end)
end

local function tree_paths()
  local paths = {}
  for _, entry in ipairs(project._project_tree) do
    paths[entry.id] = entry.path
  end
  return paths
end

-- Renaming a buffer works like :file, which leaves an unlisted placeholder
-- buffer under the old name; drop it so renames don't accumulate strays.
local function rename_buffer(bufnr, name)
  local old = vim.api.nvim_buf_get_name(bufnr)
  vim.api.nvim_buf_set_name(bufnr, name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= bufnr and not vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == old then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local function reconcile_paths(old_paths)
  for _, entry in ipairs(project._project_tree) do
    local old_path = old_paths[entry.id]
    if old_path and old_path ~= entry.path then
      if entry.type == 'doc' then
        local doc = M._state.documents[entry.id]
        if doc then
          doc.path = entry.path
          if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
            rename_buffer(doc.bufnr, sync.buf_name(entry.path))
            vim.b[doc.bufnr].overleaf_file = entry.path
          end
        end
        sync.move_doc(old_path, doc or { doc_id = entry.id, path = entry.path })
      elseif entry.type == 'file' then
        sync.rename_file(old_path, entry)
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].overleaf_file == old_path then
            rename_buffer(bufnr, sync.buf_name(entry.path))
            vim.b[bufnr].overleaf_file = entry.path
          end
        end
      end
    end
  end
end

function M._rename_entry(entity_id, new_name)
  local entry = project.get_doc_by_id(entity_id)
  if not entry or not new_name or new_name == entry.name then return entry end
  local old_paths = tree_paths()
  local updated = project.rename_entry(entity_id, new_name)
  if updated then reconcile_paths(old_paths) end
  return updated
end

function M._move_entry(entity_id, parent_folder_id)
  local entry = project.get_doc_by_id(entity_id)
  if not entry then return nil end
  local old_paths = tree_paths()
  local updated = project.move_entry(entity_id, parent_folder_id)
  if updated then reconcile_paths(old_paths) end
  return updated
end

function M._remove_entity(entity_id)
  local entry = project.get_doc_by_id(entity_id)
  if not entry then return end
  local prefix = entry.type == 'folder' and entry.path or nil
  for _, child in ipairs(project._project_tree) do
    if child == entry or (prefix and child.path:sub(1, #prefix) == prefix) then
      if child.type == 'doc' then
        local doc = M._state.documents[child.id]
        if doc then
          sync.unwatch(doc, true)
          M._state.documents[child.id] = nil
          doc:leave(function() buffer.cleanup(doc) end)
        end
      elseif child.type == 'file' then
        sync.forget_file(child)
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].overleaf_file == child.path then
            vim.api.nvim_buf_delete(bufnr, { force = true })
          end
        end
      end
    end
  end
  project.remove_entry(entity_id)
end

--- With a sync_dir, a document created on Overleaf is joined and mirrored
--- like every other: its file follows the server and disk edits are merged.
--- A document this client is creating from a disk file (Phase 3 import) is
--- joined by that import, so it is left alone here.
---@param doc_id string
---@param path string
function M._follow_new_doc(doc_id, path)
  if not sync.active() or not M._state.connected then return end
  if M._state.documents[doc_id] or sync._creating[path] then return end
  local doc = Document.new(doc_id, path)
  M._state.documents[doc_id] = doc
  doc:join(function(err)
    if M._state.documents[doc_id] ~= doc then
      -- Deleted (or the project closed) while the join was under way.
      if not err then doc:leave() end
      return
    end
    if err then
      if not doc.bufnr then M._state.documents[doc_id] = nil end
      config.log('warn', 'Could not join new document %s; it is mirrored on the next :Overleaf sync', path)
      return
    end
    sync.preserve_disk_only(doc)
    sync.write_doc(doc)
    sync.watch(doc)
  end)
end

function M._setup_event_handlers()
  M._registered_handlers = M._registered_handlers or {}
  local function on_event(name, handler)
    local registered = M._registered_handlers[name]
    if registered then
      local handlers = bridge._event_handlers and bridge._event_handlers[name]
      if not bridge._event_handlers then return end
      for _, existing in ipairs(handlers or {}) do
        if existing == registered then return end
      end
      bridge.on_event(name, registered)
    else
      M._registered_handlers[name] = handler
      bridge.on_event(name, handler)
    end
  end
  on_event('otUpdateApplied', function(data)
    local doc = M._state.documents[data.doc]
    if doc then doc:receive(data) end
  end)

  -- The server pushes this when the main document is changed from any client.
  on_event('rootDocUpdated', function(data)
    if data and data.docId then
      M._state.root_doc_id = data.docId
      local entry = project.get_doc_by_id(data.docId)
      config.log('info', 'Main document is now %s', entry and entry.path or data.docId)
    end
  end)

  -- Overleaf sends this to every client in the project and then disconnects
  -- them all. Only a document with an op in flight can have caused it; the
  -- rejoin's catch-up (or the reconnect's) finds out whether that op landed, and
  -- the document gives the op up if it keeps failing.
  on_event('otUpdateError', function(data)
    data = data or {}
    local doc_id = data.doc_id or data.doc
    local doc = doc_id and M._state.documents[doc_id]
    if not (doc and doc.inflight_op) then
      config.log('debug', 'OT error for doc %s: %s', doc_id or '?', data.message or '?')
      return
    end
    config.log('warn', 'Overleaf rejected an edit to %s: %s', doc.path or doc_id, data.message or '?')
    -- Each rejection disconnects every collaborator: give this op up sooner.
    doc._inflight_rejected = true
    if M._state.connected then doc:rejoin() end
  end)

  on_event('disconnect', function(data)
    if M._state.connected then config.log('warn', 'Disconnected: %s — reconnecting...', data.reason or 'unknown') end
    M._state.connected = false
    M._attempt_reconnect()
  end)

  -- File tree events
  on_event('reciveNewDoc', function(data)
    if not data or not data.doc then return end
    local doc_info = data.doc
    local meta = data.meta or {}
    local new_id = doc_info._id or doc_info.id

    -- File-restore: remap old doc to new ID and rejoin
    if meta.kind == 'file-restore' then
      local old_id = M._pending_restore and M._pending_restore[meta.path or '']
      if old_id then
        M._pending_restore[meta.path] = nil
        config.log('info', 'File restore: remapping %s -> %s (%s)', old_id, new_id, meta.path or '?')

        -- Update tree entry ID
        project.update_entry_id(old_id, new_id)

        -- Remap open document to new ID
        local old_doc = M._state.documents[old_id]
        if old_doc then
          M._state.documents[old_id] = nil
          M._state.documents[new_id] = old_doc
          old_doc.doc_id = new_id
          require('overleaf.history').clear(old_doc.history)
          old_doc.joined = false
          old_doc.inflight_op = nil
          old_doc.pending_ops = nil
          if old_doc._flush_timer then
            vim.fn.timer_stop(old_doc._flush_timer)
            old_doc._flush_timer = nil
          end

          -- Immediately join the new doc (server already has it ready),
          -- through the Document so that events queued meanwhile are replayed.
          old_doc._rejoining = false
          old_doc:join(function(err, _, ranges)
            if err then
              config.log('error', 'Failed to join restored doc %s: %s', meta.path or '?', err.message)
              return
            end
            config.log('info', 'Restored doc %s (v%d)', meta.path or '?', old_doc.version)
            sync.schedule_write(old_doc)

            -- Show the restored text now, before anything waiting for this
            -- join (a disk edit made meanwhile) changes the document further: a
            -- later replace would undo that change in the buffer only.
            if old_doc.bufnr and vim.api.nvim_buf_is_valid(old_doc.bufnr) then
              local ok, replace_err = pcall(old_doc._replace_buffer, old_doc, old_doc.content)
              if not ok then config.log('warn', 'Could not show restored %s: %s', meta.path or '?', replace_err) end
              vim.bo[old_doc.bufnr].modified = false

              -- Re-render comments if available
              if ranges then
                vim.schedule(function()
                  if not (old_doc.bufnr and vim.api.nvim_buf_is_valid(old_doc.bufnr)) then return end
                  local comments = require('overleaf.comments')
                  comments.parse_ranges(new_id, ranges)
                  comments.render(old_doc.bufnr, new_id, old_doc.content)
                end)
              end
            end
          end)
        end
      end

      if old_id then
        vim.schedule(function() require('overleaf.tree').refresh() end)
        return
      end
    end

    -- Normal new doc (not restore)
    local parent_path = project.get_folder_path(data.parentFolderId)
    local path = parent_path .. (doc_info.name or '')
    if not project.get_doc_by_id(new_id) and not project.path_exists(path) then
      local depth = 0
      if data.parentFolderId then
        for _, e in ipairs(project._project_tree) do
          if e.id == data.parentFolderId then
            depth = (e.depth or 0) + 1
            break
          end
        end
      end
      project.add_entry({
        id = new_id,
        name = doc_info.name,
        path = path,
        type = 'doc',
        depth = depth,
      })
    end
    local entry = project.get_doc_by_id(new_id)
    if entry and entry.type == 'doc' then M._follow_new_doc(new_id, entry.path) end
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  on_event('reciveNewFolder', function(data)
    if not data or not data.folder then return end
    local folder = data.folder
    local id = folder._id or folder.id
    if not id or project.get_doc_by_id(id) then return end
    local parent_path = project.get_folder_path(data.parentFolderId)
    local path = parent_path .. (folder.name or '') .. '/'
    if project.path_exists(path) then return end
    local parent = project.get_doc_by_id(data.parentFolderId)
    project.add_entry({
      id = id,
      name = folder.name,
      path = path,
      type = 'folder',
      depth = parent and parent.depth + 1 or 0,
    })
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  on_event('reciveEntityRename', function(data)
    if not data then return end
    local id = data.entityId or data.id or (type(data.entity) == 'table' and (data.entity._id or data.entity.id))
    local name = data.newName or data.name
    if type(name) == 'table' then name = name.newName or name.name end
    if type(name) ~= 'string' then return end
    if id and name and M._rename_entry(id, name) then
      vim.schedule(function() require('overleaf.tree').refresh() end)
    end
  end)

  on_event('reciveEntityMove', function(data)
    if not data then return end
    local id = data.entityId or data.id or (type(data.entity) == 'table' and (data.entity._id or data.entity.id))
    local parent_id = data.newParentFolderId or data.parentFolderId or data.folderId
    if type(data.meta) == 'table' then
      parent_id = data.meta.newParentFolderId or data.meta.parentFolderId or parent_id
    end
    if id and parent_id and M._move_entry(id, parent_id) then
      vim.schedule(function() require('overleaf.tree').refresh() end)
    end
  end)

  on_event('reciveNewFile', function(data)
    if not data or not data.file then return end
    local file = data.file
    local new_id = file._id or file.id
    local parent_path = project.get_folder_path(data.parentFolderId)
    local path = parent_path .. (file.name or '')
    local existing = project.get_doc_by_path(path)
    local entry

    if existing and existing.type == 'file' then
      -- Same path, new id: an upload over an existing name replaces the
      -- fileRef. Keep the entry (and its text flag) and take on the new id,
      -- unless it already carries it because the upload was ours.
      if existing.id == new_id then return end
      config.log('debug', 'File replaced on Overleaf: %s (%s -> %s)', path, existing.id, new_id)
      existing.id = new_id
      entry = existing
    elseif existing then
      config.log('warn', 'Ignoring file %s: a document already has that path', path)
      return
    else
      local depth = 0
      if data.parentFolderId then
        for _, e in ipairs(project._project_tree) do
          if e.id == data.parentFolderId then
            depth = (e.depth or 0) + 1
            break
          end
        end
      end
      entry = { id = new_id, name = file.name, path = path, type = 'file', depth = depth }
      project.add_entry(entry)
    end

    -- Refresh the mirror so a replacement made elsewhere shows up on disk
    if sync.active() and M._state.project_id then sync.fetch_file(entry, M._state.project_id) end
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  on_event('removeEntity', function(data)
    if not data or not data.entityId then return end
    local meta = data.meta or {}

    -- For file-restore, don't remove the entry — reciveNewDoc will remap it
    if meta.kind == 'file-restore' then
      config.log('debug', 'File restore: old doc %s will be replaced', data.entityId)
      M._pending_restore = M._pending_restore or {}
      M._pending_restore[meta.path or ''] = data.entityId
      return
    end

    -- A fileRef replaced by an upload (ours or anyone's) arrives as
    -- removeEntity(old id, 'upload') followed by reciveNewFile(new id): the
    -- entry is dropped here and re-added, re-fetched and re-watched there.
    M._remove_entity(data.entityId)
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  -- Comment events
  local function rerender_comments()
    local comments = require('overleaf.comments')
    for doc_id, doc in pairs(M._state.documents) do
      if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and doc.content then
        comments.render(doc.bufnr, doc_id, doc.content)
      end
    end
  end

  on_event('newComment', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_new_comment(data)
      rerender_comments()
    end)
  end)

  on_event('resolveThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_resolve_thread(data)
      rerender_comments()
    end)
  end)

  on_event('reopenThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_reopen_thread(data)
      rerender_comments()
    end)
  end)

  on_event('deleteThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_delete_thread(data)
      rerender_comments()
    end)
  end)

  -- Collaborator cursor tracking
  on_event('clientUpdated', function(data)
    vim.schedule(function() require('overleaf.cursors').on_client_updated(data) end)
  end)

  on_event('clientDisconnected', function(data)
    vim.schedule(function() require('overleaf.cursors').on_client_disconnected(data) end)
  end)
end

-- Auto-reconnect state
M._reconnect = {
  attempt = 0,
  max_attempts = 5,
  timer = nil,
  in_progress = false,
}

--- Replace the socket now. A document that dropped an unacknowledged op calls
--- this: on a new socket a late copy of that op arrives as a full op from an old
--- public id, not as an op-less ACK that would pass for the ACK of the next op.
---@param reason string
function M._force_reconnect(reason)
  if not M._state.connected then return end -- a reconnect is already coming
  config.log('debug', 'Reconnecting: %s', reason)
  M._state.connected = false
  M._reconnect.attempt = 0
  M._attempt_reconnect()
  bridge.request('disconnect', {}, function() end)
end

function M._attempt_reconnect()
  if M._reconnect.in_progress then return end
  if M._state.connected then return end
  if not M._state.project_id then return end -- never connected

  M._reconnect.attempt = M._reconnect.attempt + 1
  if M._reconnect.attempt > M._reconnect.max_attempts then
    config.log('error', 'Reconnect failed after %d attempts', M._reconnect.max_attempts)
    M._reconnect.attempt = 0
    return
  end

  -- Exponential backoff: 2s, 4s, 8s, 16s, 30s
  local delay = math.min(2000 * (2 ^ (M._reconnect.attempt - 1)), 30000)
  config.log(
    'debug',
    'Reconnecting in %ds (attempt %d/%d)...',
    delay / 1000,
    M._reconnect.attempt,
    M._reconnect.max_attempts
  )

  M._reconnect.in_progress = true

  if M._reconnect.timer then vim.fn.timer_stop(M._reconnect.timer) end

  M._reconnect.timer = vim.fn.timer_start(delay, function()
    M._reconnect.timer = nil
    M._do_reconnect()
  end)
end

function M._do_reconnect()
  local cookie = config.get().cookie
  if not cookie then
    config.log('error', 'No cookie available for reconnect')
    M._reconnect.in_progress = false
    return
  end

  -- Ensure bridge is running
  if not bridge.is_running() then
    bridge.start(function(err)
      if err then
        config.log('error', 'Failed to restart bridge: %s', err.message)
        M._reconnect.in_progress = false
        M._attempt_reconnect()
        return
      end
      M._setup_event_handlers()
      M._reconnect_to_project(cookie)
    end)
  else
    M._reconnect_to_project(cookie)
  end
end

function M._reconnect_to_project(cookie)
  bridge.request('connect', {
    cookie = cookie,
    projectId = M._state.project_id,
  }, function(err, result)
    M._reconnect.in_progress = false

    if err then
      config.log('debug', 'Reconnect failed: %s', err.message)
      M._attempt_reconnect()
      return
    end

    M._state.connected = true
    M._state.project_data = result.project
    if result.publicId then
      M._state.public_ids = M._state.public_ids or {}
      M._state.public_ids[result.publicId] = true
      M._state.public_id = result.publicId
    end
    M._reconnect.attempt = 0

    config.log('info', 'Reconnected to: %s', M._state.project_name or '?')

    -- Re-join all open documents (wait for server to settle after restore)
    vim.defer_fn(function() M._rejoin_documents() end, 3000)
  end)
end

function M._rejoin_documents()
  -- Joined documents without a buffer too: with a sync_dir every mirrored
  -- document stays joined, and its file must keep following the server.
  for _, doc in pairs(M._state.documents) do
    if doc.joined or (doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr)) then doc:rejoin() end
  end
end

function M.open_document(doc_id_or_path, doc_path)
  local doc_id = doc_id_or_path
  local path = doc_path

  if not path then
    -- Assume it's a path, look up ID
    local info = project.get_doc_by_path(doc_id_or_path)
    if info and info.type == 'file' then
      M.open_file_entry(info)
      return
    elseif info then
      doc_id = info.id
      path = info.path
    else
      config.log('error', 'Document not found: %s', doc_id_or_path)
      return
    end
  end

  local doc = M._state.documents[doc_id]
  if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
    vim.api.nvim_set_current_buf(doc.bufnr)
    return
  end

  -- With a sync_dir the document is usually joined already, without a buffer.
  -- The buffer attaches to that Document: a second Document, or a second
  -- joinDoc, would split the document's version and in-flight state in two.
  local created = doc == nil
  if created then
    doc = Document.new(doc_id, path)
    M._state.documents[doc_id] = doc
  end

  local function attach(ranges)
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      vim.api.nvim_set_current_buf(doc.bufnr)
      return
    end
    local bufnr = buffer.create(doc, vim.split(doc.content, '\n', { plain = true }))
    if not mode.writable() then vim.bo[bufnr].modifiable = false end
    M._detach_on_close(doc, bufnr)

    -- Write to sync dir and start watching for external changes
    sync.write_doc(doc)
    sync.watch(doc)

    -- Parse and render comments if ranges contain comments
    if ranges then
      local comments = require('overleaf.comments')
      comments.parse_ranges(doc_id, ranges)
      vim.schedule(function()
        if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then comments.render(doc.bufnr, doc_id, doc.content) end
      end)
    end
  end

  if doc.content ~= nil and (doc.joined or doc._rejoining) then
    attach(doc.ranges)
    return
  end

  doc:join(function(err, _, ranges)
    if err then
      if created and M._state.documents[doc_id] == doc then M._state.documents[doc_id] = nil end
      return
    end
    attach(ranges)
  end)
end

--- Closing a document's buffer keeps the document joined: with a sync_dir its
--- file keeps following the server and disk edits are still merged, and
--- opening it again needs no new join. The buffer's last typing is sent first.
--- `:bdelete` and `:bunload` leave an unloaded buffer under the document's
--- name; it is wiped so that opening the document again can create a fresh
--- one. `:edit` reloads the buffer from the mirror file instead; it is then
--- attached again and shown the document's text.
---@param doc table Document instance
---@param bufnr number
function M._detach_on_close(doc, bufnr)
  -- Neovim detaches the change listener before any of these events, which
  -- drops the record of unsent lines; compare the whole buffer instead. The
  -- text is still there until the events return.
  local function send_last_typing()
    if doc.content ~= nil and vim.api.nvim_buf_is_loaded(bufnr) then
      doc._dirty = { first = 0, from_end = 0 }
      pcall(buffer.reconcile, doc)
    end
  end
  local function detach()
    doc.bufnr = nil
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
    end)
  end

  vim.api.nvim_create_autocmd('BufUnload', {
    buffer = bufnr,
    callback = function()
      if doc.bufnr ~= bufnr then return true end
      send_last_typing()
      -- `:edit` reloads within the same command; anything else leaves the
      -- buffer unloaded.
      vim.schedule(function()
        if doc.bufnr ~= bufnr then return end
        if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
          detach()
          return
        end
        -- Reloaded from the mirror file, which may lag the document or hold
        -- a disk edit not processed yet. Show the document's text; the watcher
        -- (or the mirror write's check) merges any disk edit as usual.
        buffer.attach(bufnr, doc)
        local ok, err = pcall(doc._replace_buffer, doc, doc.content, false)
        if not ok then config.log('warn', 'Could not restore %s after a reload: %s', doc.path, err) end
        vim.bo[bufnr].modified = false
        if not mode.writable() then vim.bo[bufnr].modifiable = false end
        -- Disk changes reach the buffer only through the merge. (Neovim does
        -- not check an acwrite buffer's file on :checktime anyway.)
        vim.bo[bufnr].autoread = false
        sync.schedule_write(doc)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    buffer = bufnr,
    callback = function()
      if doc.bufnr ~= bufnr then return true end
      send_last_typing()
      detach()
      return true
    end,
  })
end

--- Open a fileRef (a file Overleaf stores as binary) for editing.
--- Text fileRefs have no OT document, so the buffer is a plain file. As with
--- docs, :w sends the change to Overleaf (here: a whole-file re-upload) and
--- then compiles. With a sync directory the mirror's watcher also covers
--- edits made by external tools.
---@param entry table tree entry {id, name, path, type='file'}
---@param opts table|nil { prepare_window = function } called before the buffer is shown
function M.open_file_entry(entry, opts)
  opts = opts or {}
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local function refuse() config.log('info', 'Binary file, cannot be edited: %s (use :Overleaf preview)', entry.name) end
  if entry.text == false then
    refuse()
    return
  end

  sync.fetch_file(entry, M._state.project_id, function(err, local_path)
    if err then
      config.log('error', 'Download failed for %s: %s', entry.path, err.message)
      return
    end
    if not entry.text then
      refuse()
      return
    end

    vim.schedule(function()
      if opts.prepare_window then opts.prepare_window() end
      vim.cmd('edit ' .. vim.fn.fnameescape(local_path))
      local bufnr = vim.api.nvim_get_current_buf()
      vim.b[bufnr].overleaf_file = entry.path
      if not mode.writable() then vim.bo[bufnr].modifiable = false end

      -- :w uploads directly (the watcher skips bytes already in flight) so the
      -- compile can follow the upload, as it follows the OT flush for docs.
      vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = bufnr,
        callback = function()
          -- Replacing a file wholesale cannot be a suggestion.
          if not mode.can_replace_files() then
            config.log(
              'warn',
              '%s is stored as a file on Overleaf, so saving replaces it outright and cannot be a suggestion; not sent in %s mode',
              entry.name,
              mode.get()
            )
            return
          end
          sync.upload_file(entry, local_path, nil, function(upload_err)
            if not upload_err then M.compile() end
          end)
        end,
      })

      config.log(
        'info',
        '%s is stored as a file on Overleaf: each save replaces it whole (no live collaboration)',
        entry.name
      )
    end)
  end)
end

function M.select_project()
  if #project._projects == 0 then
    config.log('warn', 'Not authenticated. Run :OverleafConnect first.')
    return
  end

  project.select_project(function(project_id, project_name)
    local cookie = config.get().cookie
    M._connect_project(cookie, project_id, project_name)
  end)
end

function M.select_document()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :OverleafConnect first.')
    return
  end

  project.select_document(function(doc_id, doc_path) M.open_document(doc_id, doc_path) end)
end

function M.toggle_tree()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :OverleafConnect first.')
    return
  end
  require('overleaf.tree').toggle()
end

function M.preview_file()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end

  -- Get file entries from project tree
  local files = {}
  for _, entry in ipairs(project._project_tree) do
    if entry.type == 'file' then table.insert(files, entry) end
  end

  if #files == 0 then
    config.log('info', 'No binary files in project')
    return
  end

  vim.ui.select(files, {
    prompt = 'Preview file:',
    format_item = function(item) return item.path end,
  }, function(choice)
    if not choice then return end

    config.log('info', 'Downloading %s...', choice.name)
    bridge.request('downloadFile', {
      cookie = config.get().cookie,
      projectId = M._state.project_id,
      fileId = choice.id,
      fileName = choice.name,
      outputDir = config.get().pdf_dir,
    }, function(err, result)
      if err then
        config.log('error', 'Download failed: %s', err.message)
        return
      end
      config.log('info', 'Opening %s', result.path)
      vim.schedule(function() open_file(result.path) end)
    end)
  end)
end

function M.create_doc(name, parent_folder_id)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  if not mode.require_write('creating a document') then return end

  local prefix = project.get_folder_path(parent_folder_id)

  local function do_create(doc_name)
    if not doc_name or doc_name == '' then return end

    local full_path = prefix .. doc_name
    if project.path_exists(full_path) then
      config.log('error', 'File already exists: %s', full_path)
      return
    end

    bridge.request('createDoc', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      name = doc_name,
      parentFolderId = parent_folder_id,
    }, function(err, result)
      if err then
        local msg = err.message or ''
        if msg:match('already exists') or msg:match('400') then
          config.log('error', 'File already exists: %s', doc_name)
        else
          config.log('error', 'Failed to create doc: %s', msg)
        end
        return
      end

      config.log('info', 'Created: %s', full_path)
      vim.schedule(function()
        -- Add to tree from API response
        local depth = 0
        if parent_folder_id then
          for _, e in ipairs(project._project_tree) do
            if e.id == parent_folder_id then
              depth = (e.depth or 0) + 1
              break
            end
          end
        end
        project.add_entry({
          id = result._id or result.id,
          name = doc_name,
          path = full_path,
          type = 'doc',
          depth = depth,
        })
        require('overleaf.tree').refresh()
      end)
    end)
  end

  if name then
    do_create(name)
  else
    vim.ui.input({ prompt = 'New document name: ' }, do_create)
  end
end

function M.create_folder(name, parent_folder_id)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  if not mode.require_write('creating a folder') then return end

  local prefix = project.get_folder_path(parent_folder_id)

  local function do_create(folder_name)
    if not folder_name or folder_name == '' then return end

    local full_path = prefix .. folder_name .. '/'
    if project.path_exists(full_path) then
      config.log('error', 'Folder already exists: %s', full_path)
      return
    end

    bridge.request('createFolder', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      name = folder_name,
      parentFolderId = parent_folder_id,
    }, function(err, result)
      if err then
        local msg = err.message or ''
        if msg:match('already exists') or msg:match('400') then
          config.log('error', 'Folder already exists: %s', folder_name)
        else
          config.log('error', 'Failed to create folder: %s', msg)
        end
        return
      end

      config.log('info', 'Created folder: %s', full_path)
      vim.schedule(function()
        local depth = 0
        if parent_folder_id then
          for _, e in ipairs(project._project_tree) do
            if e.id == parent_folder_id then
              depth = (e.depth or 0) + 1
              break
            end
          end
        end
        project.add_entry({
          id = result._id or result.id,
          name = folder_name,
          path = full_path,
          type = 'folder',
          depth = depth,
        })
        require('overleaf.tree').refresh()
      end)
    end)
  end

  if name then
    do_create(name)
  else
    vim.ui.input({ prompt = 'New folder name: ' }, do_create)
  end
end

function M.search(pattern)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local function do_search(pat)
    if not pat or pat == '' then return end
    require('overleaf.search').grep(pat, M._state)
  end

  if pattern then
    do_search(pattern)
  else
    vim.ui.input({ prompt = 'Search pattern: ' }, do_search)
  end
end

function M.upload_file(file_path, parent_folder_id)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  if not mode.require_write('uploading a file') then return end

  local function do_upload(path)
    if not path or path == '' then return end

    -- Expand ~ and resolve
    path = vim.fn.expand(path)
    if vim.fn.filereadable(path) ~= 1 then
      config.log('error', 'File not found: %s', path)
      return
    end

    local file_name = vim.fn.fnamemodify(path, ':t')
    config.log('info', 'Uploading %s...', file_name)

    parent_folder_id = parent_folder_id or project._root_folder_id
    bridge.request('uploadFile', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      filePath = path,
      fileName = file_name,
      parentFolderId = parent_folder_id,
    }, function(err, result)
      if err then
        config.log('error', 'Upload failed: %s', err.message)
        return
      end
      config.log('info', 'Uploaded: %s', file_name)
      -- Tree update happens via the reciveNewFile socket event. Uploading over
      -- an existing name replaces that fileRef under a new id; record it now
      -- in case the event already came and went.
      local existing = project.get_doc_by_path(project.get_folder_path(parent_folder_id) .. file_name)
      if existing and existing.type == 'file' and result and result.entity_id then existing.id = result.entity_id end
    end)
  end

  if file_path then
    do_upload(file_path)
  else
    vim.ui.input({ prompt = 'Local file path: ', completion = 'file' }, do_upload)
  end
end

function M.rename_entity()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  if not mode.require_write('renaming') then return end

  -- Show entries to rename
  local entries = {}
  for _, row in ipairs(project.display_rows()) do
    table.insert(entries, row.entry)
  end

  vim.ui.select(entries, {
    prompt = 'Rename:',
    format_item = function(item) return item.path end,
  }, function(choice)
    if not choice then return end

    vim.ui.input({ prompt = 'New name for "' .. choice.name .. '": ', default = choice.name }, function(new_name)
      if not new_name or new_name == '' or new_name == choice.name then return end

      bridge.request('renameEntity', {
        cookie = config.get().cookie,
        csrfToken = M._state.csrf_token,
        projectId = M._state.project_id,
        entityId = choice.id,
        entityType = choice.type,
        newName = new_name,
      }, function(err, _)
        if err then
          config.log('error', 'Rename failed: %s', err.message)
          return
        end
        vim.schedule(function()
          local updated = M._rename_entry(choice.id, new_name)
          if updated then config.log('info', 'Renamed to: %s', updated.path) end
          require('overleaf.tree').refresh()
        end)
      end)
    end)
  end)
end

function M.delete_entity()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  if not mode.require_write('deleting') then return end

  -- Show deletable entries
  local entries = {}
  for _, entry in ipairs(project._project_tree) do
    table.insert(entries, entry)
  end

  vim.ui.select(entries, {
    prompt = 'Delete:',
    format_item = function(item)
      local icon = item.type == 'folder' and '[dir] ' or ''
      return icon .. item.path
    end,
  }, function(choice)
    if not choice then return end

    -- Confirm
    vim.ui.input({ prompt = 'Delete "' .. choice.path .. '"? (y/N): ' }, function(answer)
      if answer ~= 'y' and answer ~= 'Y' then return end

      bridge.request('deleteEntity', {
        cookie = config.get().cookie,
        csrfToken = M._state.csrf_token,
        projectId = M._state.project_id,
        entityId = choice.id,
        entityType = choice.type,
      }, function(err, _)
        if err then
          config.log('error', 'Delete failed: %s', err.message)
          return
        end
        config.log('info', 'Deleted: %s', choice.path)
        vim.schedule(function()
          M._remove_entity(choice.id)
          require('overleaf.tree').refresh()
        end)
      end)
    end)
  end)
end

function M.history()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  config.log('info', 'Fetching history...')
  bridge.request('getHistory', {
    cookie = config.get().cookie,
    projectId = M._state.project_id,
  }, function(err, result)
    if err then
      config.log('error', 'History failed: %s', err.message)
      return
    end

    local updates = result.updates or {}
    if #updates == 0 then
      config.log('info', 'No history entries')
      return
    end

    vim.schedule(function() M._show_history(updates) end)
  end)
end

function M._show_history(updates)
  -- Format history entries for display
  local items = {}
  for _, update in ipairs(updates) do
    local users = {}
    for _, u in ipairs(update.meta and update.meta.users or {}) do
      table.insert(users, u.first_name or u.email or '?')
    end

    local ts = update.meta and update.meta.end_ts or 0
    local date = os.date('%Y-%m-%d %H:%M', ts / 1000)

    local files = {}
    for _, p in ipairs(update.pathnames or {}) do
      table.insert(files, p)
    end

    table.insert(items, {
      label = date .. ' | ' .. table.concat(users, ', '),
      detail = table.concat(files, ', '),
      fromV = update.fromV,
      toV = update.toV,
    })
  end

  vim.ui.select(items, {
    prompt = 'Project History:',
    format_item = function(item)
      local detail = item.detail ~= '' and (' (' .. item.detail .. ')') or ''
      return item.label .. detail
    end,
  }, function(choice)
    if not choice then return end
    config.log('info', 'Version range: v%d -> v%d', choice.fromV, choice.toV)
  end)
end

function M.compile()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end

  config.log('info', 'Compiling...')

  bridge.request('compile', {
    cookie = config.get().cookie,
    csrfToken = M._state.csrf_token,
    projectId = M._state.project_id,
  }, function(err, result)
    if err then
      config.log('error', 'Compile failed: %s', err.message)
      return
    end

    -- Kept even on a failed compile: the ids address the build, and a stale
    -- build still answers SyncTeX until the server evicts it.
    M._state.build_id = result.buildId
    M._state.clsi_server_id = result.clsiServerId

    if result.status == 'success' then
      config.log('info', 'Compile succeeded')
      -- Auto-download and open PDF
      M._open_pdf(result.outputFiles or {}, result.clsiServerId)
    else
      config.log('warn', 'Compile status: %s', result.status)
    end

    vim.schedule(function() M._parse_compile_log(result.log or '') end)
  end)
end

--- Set the project's main document (what :Overleaf compile builds).
--- `name` optionally pre-selects by path; with no argument a picker is shown.
function M.set_main_file(name)
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end
  if not mode.require_write('changing the main document') then return end

  local candidates = {}
  for _, e in ipairs(project._project_tree) do
    if e.type == 'doc' and e.path:match('%.tex$') then table.insert(candidates, e) end
  end
  if #candidates == 0 then
    config.log('warn', 'No .tex documents in this project')
    return
  end

  local function apply(entry)
    if entry.id == M._state.root_doc_id then
      config.log('info', '%s is already the main document', entry.path)
      return
    end
    bridge.request('setRootDoc', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      rootDocId = entry.id,
    }, function(err)
      if err then
        config.log('error', 'Failed to set main document: %s', err.message)
        return
      end
      M._state.root_doc_id = entry.id
      config.log('info', 'Main document set to %s', entry.path)
      vim.schedule(function() require('overleaf.tree').refresh() end)
    end)
  end

  if name and name ~= '' then
    local match = project.get_doc_by_path(name)
    if not match then
      config.log('error', 'No such document: %s', name)
      return
    end
    apply(match)
    return
  end

  vim.ui.select(candidates, {
    prompt = 'Set main document (compiled by :Overleaf compile):',
    format_item = function(item) return (item.id == M._state.root_doc_id and '* ' or '  ') .. item.path end,
  }, function(choice)
    if choice then apply(choice) end
  end)
end

--- Fetch the build's SyncTeX database and park it beside the PDF.
---
--- zathura finds it by name: for `x.pdf` it reads `x.synctex.gz` from the same
--- directory. Without it a ctrl+click resolves to nothing and no signal is sent.
local function fetch_synctex_db(output_files, clsi_server_id, callback)
  local db = nil
  for _, f in ipairs(output_files) do
    if f.path == 'output.synctex.gz' then
      db = f
      break
    end
  end
  if not db or not db.url then
    callback('this build produced no SyncTeX database')
    return
  end

  local url = config.get().base_url .. db.url
  if clsi_server_id then url = url .. '?clsiserverid=' .. clsi_server_id end

  -- Use the same absolute spelling for the database rewrite, forward search,
  -- and inverse path mapping. The mirror itself may be configured relatively.
  local synctex_root = sync.active() and vim.fs.normalize(vim.fn.fnamemodify(sync._sync_dir, ':p')):gsub('/+$', '')
    or nil
  bridge.request('downloadUrl', {
    cookie = config.get().cookie,
    url = url,
    -- Same stem as the PDF, which is what the viewer will look for.
    fileName = (M._state.project_name or 'output') .. '.synctex.gz',
    outputDir = config.get().pdf_dir,
    synctexRoot = synctex_root,
  }, function(err, result)
    if err then
      callback(err.message)
      return
    end
    M._state.synctex_path = result.path
    M._state.synctex_root = synctex_root or '/compile'
    callback(nil)
  end)
end

function M._open_pdf(output_files, clsi_server_id)
  local pdf_file = nil
  for _, f in ipairs(output_files) do
    if f.path == 'output.pdf' then
      pdf_file = f
      break
    end
  end
  if not pdf_file or not pdf_file.url then
    config.log('error', 'Compile succeeded but no output.pdf was returned')
    return
  end

  -- Build output lives on the CLSI node that produced it; without clsiserverid
  -- the request is routed elsewhere and 404s.
  local url = config.get().base_url .. pdf_file.url
  if clsi_server_id then url = url .. '?clsiserverid=' .. clsi_server_id end

  bridge.request('downloadUrl', {
    cookie = config.get().cookie,
    url = url,
    fileName = (M._state.project_name or 'output') .. '.pdf',
    outputDir = config.get().pdf_dir,
  }, function(err, result)
    if err then
      config.log('error', 'PDF download failed: %s', err.message)
      return
    end
    if M._state.pdf_path and M._state.pdf_path ~= result.path then remove_server_state(M._state.pdf_path) end
    M._state.pdf_path = result.path
    write_server_state(result.path)
    M._state.synctex_path = nil
    M._state.synctex_root = nil

    fetch_synctex_db(output_files, clsi_server_id, function(db_err)
      if db_err then
        config.log('warn', 'No SyncTeX database this build: %s', db_err)
        return
      end
      -- A viewer already running can start answering clicks right away.
      vim.schedule(function() M._start_inverse_search(true) end)
    end)

    -- The file was replaced in place, so a viewer already showing it has the
    -- new build. Launching it again would only pull focus away from the
    -- buffer, which makes compiling on every :w unusable.
    local mode = config.get().pdf_auto_open
    local launch = mode == 'always' or (mode == 'once' and not M._state.pdf_opened[result.path])
    if not launch then
      config.log('info', 'PDF updated: %s', result.path)
      return
    end

    M._state.pdf_opened[result.path] = true
    config.log('info', 'Opening %s', result.path)
    vim.schedule(function()
      M._state.pdf_pid = open_file(result.path)
      -- The viewer needs a moment to claim its name on the bus.
      vim.defer_fn(function() M._start_inverse_search() end, 1500)
    end)
  end)
end

--- Open the last compiled PDF in the viewer, focus and all. This is the way
--- back when the viewer has been closed and `pdf_auto_open` will not relaunch
--- it by itself.
function M.open_pdf()
  local path = M._state.pdf_path
  if not path or vim.fn.filereadable(path) == 0 then
    config.log('warn', 'No compiled PDF yet. Run :Overleaf compile first.')
    return
  end
  M._state.pdf_opened[path] = true
  config.log('info', 'Opening %s', path)
  M._state.pdf_pid = open_file(path)
  vim.defer_fn(function() M._start_inverse_search(true) end, 1500)
end

-- Everything the build compiled lives under this directory inside Overleaf's
-- container, so the SyncTeX database records project files as
-- '/compile/./main.tex'. Anything outside it is a TeX Live package.
local COMPILE_ROOT = '/compile/'

--- Turn a path out of the SyncTeX database into a project path.
---@param input string
---@return string|nil nil when it is not a file of this project
function M._synctex_source_path(input)
  if type(input) ~= 'string' then return nil end
  if input:sub(1, 7) == 'file://' then
    local ok, decoded = pcall(vim.uri_to_fname, input)
    if not ok then return nil end
    input = decoded
  end
  local rel
  local mirror = M._state.synctex_root
  if mirror and mirror ~= '/compile' and input:sub(1, #mirror + 1) == mirror .. '/' then
    rel = input:sub(#mirror + 2)
  elseif input:sub(1, #COMPILE_ROOT) == COMPILE_ROOT then
    rel = input:sub(#COMPILE_ROOT + 1)
  else
    return nil
  end
  local previous
  repeat
    previous = rel
    rel = rel:gsub('^%./', ''):gsub('/%./', '/')
  until rel == previous
  if rel == '' or rel == '..' or rel:find('../', 1, true) then return nil end
  return rel
end

--- Put the cursor on `line` of the project file at `path`, opening it first.
local function jump_to_source(path, line, column)
  local function place(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return false end
    local win = vim.fn.bufwinid(bufnr)
    if win == -1 then
      vim.api.nvim_set_current_buf(bufnr)
      win = vim.api.nvim_get_current_win()
    else
      vim.api.nvim_set_current_win(win)
    end
    local target = math.min(math.max(line, 1), vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_set_cursor(win, { target, math.max(column - 1, 0) })
    vim.cmd('normal! zz')
    return true
  end

  local function buffer_for()
    for _, doc in pairs(M._state.documents) do
      if doc.path == path then return doc.bufnr end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].overleaf_file == path then return buf end
    end
    return nil
  end

  if place(buffer_for()) then return end

  M.open_document(path)

  -- open_document has no completion hook, so wait for the buffer to appear.
  local attempts = 0
  local function retry()
    attempts = attempts + 1
    if place(buffer_for()) or attempts > 30 then
      if attempts > 30 then config.log('warn', 'Could not open %s for inverse search', path) end
      return
    end
    vim.defer_fn(retry, 100)
  end
  vim.defer_fn(retry, 100)
end

--- A ctrl+click in the viewer landed on `file`:`line`.
function M._on_viewer_edit(file, line, column)
  local path = M._synctex_source_path(file)
  if not path then
    config.log('info', 'That part of the PDF comes from %s, which is not in this project', file)
    return
  end
  config.log('info', 'Inverse search: %s:%d', path, line)
  vim.schedule(function() jump_to_source(path, tonumber(line) or 1, math.max(tonumber(column) or 0, 0)) end)
end

--- Start listening for clicks in the viewer, if inverse search is on and there
--- is a viewer to listen to. Safe to call repeatedly.
---@param quiet boolean|nil do not warn when there is no viewer yet
function M._start_inverse_search(quiet)
  if not config.get().inverse_search then return end
  local profile, profile_err = viewer.profile()
  if not profile then
    config.log('error', '%s', profile_err)
    return
  end
  if not profile.listen then
    viewer.stop_watching()
    return
  end
  if not (M._state.pdf_path and M._state.synctex_path) then return end

  -- Called again after every forward search, which may have launched a viewer;
  -- only announce a listener that this call actually started.
  local already = viewer.watching()
  local ok, err = viewer.watch_edits(profile, M._state.pdf_path, M._state.pdf_pid, M._on_viewer_edit)
  if ok and not (already and viewer.watching()) then
    config.log('info', 'Inverse search ready in %s', profile.listen)
  elseif not quiet then
    config.log('debug', 'Inverse search not started: %s', err)
  end
end

--- The project path of what a buffer is showing: a live document, or a file
--- opened from the mirror. nil for anything else.
---@param bufnr number
---@return string|nil
function M._source_path(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr == bufnr then return doc.path end
  end
  return vim.b[bufnr].overleaf_file
end

--- Move the PDF viewer to whatever the cursor is sitting on.
function M.forward_search()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end
  local path = M._source_path(vim.api.nvim_get_current_buf())
  if not path then
    config.log('warn', 'This buffer is not part of the Overleaf project')
    return
  end
  if not (M._state.pdf_path and M._state.synctex_path) then
    config.log('warn', 'No compiled PDF and SyncTeX database yet. Run :Overleaf compile first.')
    return
  end
  local profile, profile_err = viewer.profile()
  if not profile then
    config.log('error', '%s', profile_err)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local root = M._state.synctex_root or '/compile'
  local values = viewer_values(M._state.pdf_path, root .. '/' .. path, cursor[1], cursor[2] + 1)
  values.pid = M._state.pdf_pid
  local ok, err = viewer.forward(profile, values, config.get().inverse_search)
  if not ok then
    config.log('warn', '%s', err)
    return
  end
  vim.defer_fn(function() M._start_inverse_search(true) end, 1500)
end

function M._parse_compile_log(log_text)
  local ns = vim.api.nvim_create_namespace('overleaf_compile')

  -- Clear all previous diagnostics
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.diagnostic.set(ns, doc.bufnr, {}) end
  end

  if #log_text == 0 then return end

  -- Build path -> doc lookup
  local path_to_doc = {}
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      path_to_doc[doc.path] = doc
      -- Also index without leading path components for relative matches
      local basename = doc.path:match('[^/]+$')
      if basename then path_to_doc[basename] = doc end
    end
  end

  local diagnostics = {} -- bufnr -> list of diagnostics

  -- Track current file via LaTeX log parenthesis-based file tracking
  local file_stack = {}
  local current_file = nil

  local lines = vim.split(log_text, '\n', { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]

    -- Track file opens/closes via parentheses
    for char in line:gmatch('[%(%)][^%(%)]*') do
      if char:sub(1, 1) == '(' then
        local fname = char:sub(2):match('^%s*([^%s%)]+)')
        if fname and fname:match('%.[a-zA-Z]+$') then
          table.insert(file_stack, current_file)
          current_file = fname
        end
      elseif char:sub(1, 1) == ')' then
        current_file = table.remove(file_stack)
      end
    end

    -- Match LaTeX errors: lines starting with "!"
    if line:match('^!') then
      local msg = line:sub(3) -- strip "! "
      local lnum = 0

      -- Look ahead for "l.<number>" line number
      for j = i + 1, math.min(i + 5, #lines) do
        local ln = lines[j]:match('^l%.(%d+)')
        if ln then
          lnum = tonumber(ln) - 1 -- 0-indexed
          break
        end
      end

      local doc = current_file and (path_to_doc[current_file] or path_to_doc[current_file:match('[^/]+$') or ''])
      if doc then
        diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
        table.insert(diagnostics[doc.bufnr], {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.ERROR,
          message = msg,
          source = 'latex',
        })
      end
    end

    -- Match LaTeX warnings
    local warn_msg = line:match('LaTeX Warning:%s*(.*)')
    if warn_msg then
      local lnum = 0
      local ln = warn_msg:match('on input line (%d+)')
      if ln then lnum = tonumber(ln) - 1 end

      local doc = current_file and (path_to_doc[current_file] or path_to_doc[current_file:match('[^/]+$') or ''])
      if doc then
        diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
        table.insert(diagnostics[doc.bufnr], {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = warn_msg,
          source = 'latex',
        })
      end
    end

    -- Match Overfull/Underfull hbox warnings
    local box_msg = line:match('(O[vn][edr][rf][fu][ul]l \\[hv]box.*)')
    if box_msg then
      local lnum = 0
      local ln = line:match('at lines? (%d+)')
      if ln then lnum = tonumber(ln) - 1 end

      local doc = current_file and (path_to_doc[current_file] or path_to_doc[current_file:match('[^/]+$') or ''])
      if doc then
        diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
        table.insert(diagnostics[doc.bufnr], {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.HINT,
          message = box_msg,
          source = 'latex',
        })
      end
    end

    i = i + 1
  end

  -- Set diagnostics for each buffer
  for bufnr, diags in pairs(diagnostics) do
    vim.diagnostic.set(ns, bufnr, diags)
  end

  -- Count by severity
  local error_count, warn_count, hint_count = 0, 0, 0
  for _, diags in pairs(diagnostics) do
    for _, d in ipairs(diags) do
      if d.severity == vim.diagnostic.severity.ERROR then
        error_count = error_count + 1
      elseif d.severity == vim.diagnostic.severity.WARN then
        warn_count = warn_count + 1
      else
        hint_count = hint_count + 1
      end
    end
  end

  if error_count > 0 or warn_count > 0 then
    config.log('info', 'Diagnostics: %d error(s), %d warning(s), %d hint(s)', error_count, warn_count, hint_count)
  end
end

function M.refresh_comments()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local comments = require('overleaf.comments')

  -- Reload threads from API
  comments.load_threads(M._state.project_id, function(err)
    if err then return end

    -- Re-join each open doc to get fresh ranges
    for doc_id, doc in pairs(M._state.documents) do
      if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and doc.joined then
        bridge.request('joinDoc', { docId = doc_id }, function(join_err, result)
          if join_err then return end
          if result.ranges then comments.parse_ranges(doc_id, result.ranges) end
          vim.schedule(function()
            if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
              comments.render(doc.bufnr, doc_id, doc.content)
            end
          end)
        end)
      end
    end
  end)
end

function M.show_comment()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  -- Find current doc
  local bufnr = vim.api.nvim_get_current_buf()
  local doc_id = nil
  local doc = nil
  for id, d in pairs(M._state.documents) do
    if d.bufnr == bufnr then
      doc_id = id
      doc = d
      break
    end
  end

  if not doc_id then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local comments = require('overleaf.comments')
  local doc_comments = comments._doc_comments[doc_id]
  local thread_count = vim.tbl_count(comments._threads)
  config.log(
    'debug',
    'show_comment: doc=%s, threads=%d, doc_comments=%d',
    doc_id,
    thread_count,
    doc_comments and #doc_comments or 0
  )

  local thread, _ = comments.get_thread_at_cursor(doc_id, doc.content)
  if thread then
    comments.show_thread(thread)
  else
    config.log(
      'info',
      'No comment at cursor (threads=%d, doc_comments=%d)',
      thread_count,
      doc_comments and #doc_comments or 0
    )
  end
end

function M.list_comments()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  require('overleaf.comments').list_all(M._state.project_id)
end

function M.reply_comment()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local doc_id = nil
  local doc = nil
  for id, d in pairs(M._state.documents) do
    if d.bufnr == bufnr then
      doc_id = id
      doc = d
      break
    end
  end

  if not doc_id then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local comments = require('overleaf.comments')
  local thread = comments.get_thread_at_cursor(doc_id, doc.content)
  if not thread then
    config.log('info', 'No comment at cursor')
    return
  end

  vim.ui.input({ prompt = 'Reply: ' }, function(content)
    if not content or content == '' then return end

    bridge.request('addComment', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      threadId = thread.id,
      content = content,
    }, function(err, _)
      if err then
        config.log('error', 'Reply failed: %s', err.message)
        return
      end
      config.log('info', 'Reply added')
    end)
  end)
end

function M.resolve_comment()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local doc_id = nil
  local doc = nil
  for id, d in pairs(M._state.documents) do
    if d.bufnr == bufnr then
      doc_id = id
      doc = d
      break
    end
  end

  if not doc_id then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local comments = require('overleaf.comments')
  local thread = comments.get_thread_at_cursor(doc_id, doc.content)
  if not thread then
    config.log('info', 'No comment at cursor')
    return
  end

  config.log('debug', 'resolve_comment: threadId=%s resolved=%s', thread.id, tostring(thread.resolved))

  if thread.resolved then
    bridge.request('reopenThread', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      docId = doc_id,
      threadId = thread.id,
    }, function(err, _)
      if err then
        config.log('error', 'Reopen failed: %s', err.message)
        return
      end
      thread.resolved = false
      config.log('info', 'Thread reopened')
      vim.schedule(function() comments.render(bufnr, doc_id, doc.content) end)
    end)
  else
    bridge.request('resolveThread', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      docId = doc_id,
      threadId = thread.id,
    }, function(err, _)
      if err then
        config.log('error', 'Resolve failed: %s', err.message)
        return
      end
      thread.resolved = true
      config.log('info', 'Thread resolved')
      vim.schedule(function() comments.render(bufnr, doc_id, doc.content) end)
    end)
  end
end

function M.sync_all()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  sync.sync_all(M._state, project._project_tree)
end

function M.sync_import()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  sync.import_all(M._state)
end

function M.sync_export()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  sync.export_all(M._state)
end

function M.sync_status() sync.status(project._project_tree) end

local function history_command(action, count)
  local bufnr = vim.api.nvim_get_current_buf()
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr == bufnr then
      require('overleaf.history')[action](doc, count)
      return
    end
  end
  config.log('warn', 'Not an Overleaf document')
end

function M.undo(count) history_command('undo', count or 1) end
function M.redo(count) history_command('redo', count or 1) end

function M._teardown(stop_bridge, callback)
  -- Stop auto-reconnect
  M._reconnect.attempt = 0
  M._reconnect.in_progress = false
  if M._reconnect.timer then
    vim.fn.timer_stop(M._reconnect.timer)
    M._reconnect.timer = nil
  end
  bridge._on_unexpected_exit = nil

  -- Prevent a deliberate socket disconnect from starting auto-reconnect.
  M._state.connected = false
  M._state.project_id = nil

  -- Stop file sync watchers
  remove_server_state(M._state.pdf_path)
  sync.stop()

  -- Clear collaborator cursors and comments
  pcall(function() require('overleaf.cursors').clear_all() end)
  pcall(function() require('overleaf.comments').clear_all() end)

  local tree = require('overleaf.tree')
  if tree._bufnr and vim.api.nvim_buf_is_valid(tree._bufnr) then
    vim.api.nvim_buf_delete(tree._bufnr, { force = true })
  end
  tree._bufnr = nil
  tree._tree_winnr = nil
  tree._editor_winnr = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].overleaf_file then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  -- Leave all documents before changing the socket's project.
  local documents = M._state.documents
  M._state.documents = {}
  local remaining = 0
  local finished = false
  for _ in pairs(documents) do
    remaining = remaining + 1
  end
  local function finish()
    if finished then return end
    finished = true
    if stop_bridge then
      bridge.stop()
    else
      bridge.request('disconnect', {}, function()
        if callback then vim.schedule(callback) end
      end)
    end
  end
  for _, doc in pairs(documents) do
    doc:leave(function()
      buffer.cleanup(doc)
      remaining = remaining - 1
      if remaining == 0 then finish() end
    end)
  end
  if remaining == 0 then finish() end

  M._state.project_name = nil
  M._state.project_data = nil
  M._state.public_ids = {}
  M._state.public_id = nil
  M._state.root_doc_id = nil
  M._state.pdf_path = nil
  M._state.pdf_opened = {}
  M._state.pdf_pid = nil
  M._state.build_id = nil
  M._state.clsi_server_id = nil
  M._state.synctex_path = nil
  M._state.synctex_root = nil
  viewer.stop_watching()
  mode.reset()
  project._project_tree = {}
  project._root_folder_id = nil
  M._pending_restore = nil

  if stop_bridge then
    M._state.csrf_token = nil
    M._state.user_id = nil
  end

  config.log('info', 'Disconnected')
end

function M.disconnect() M._teardown(true) end

local MODE_NOTES = {
  editing = 'edits are applied as typed',
  suggesting = 'edits are sent as suggestions',
  viewing = 'read-only, nothing is sent',
}

---@param name string
---@return string
function M._mode_note(name) return MODE_NOTES[name] or '' end

--- Lock or unlock every buffer the plugin shows for the current mode.
function M._apply_mode_to_buffers()
  local writable = mode.writable()
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.bo[doc.bufnr].modifiable = writable end
  end
  -- Files opened out of the mirror (text stored as binary on Overleaf).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].overleaf_file then vim.bo[buf].modifiable = writable end
  end
end

mode.on_change(function() M._apply_mode_to_buffers() end)

--- Send everything typed so far, so it goes out under the mode it was typed in.
--- A suggestion is decided per update; edits still queued when the mode flips
--- would otherwise be sent under the new one.
---@param timeout_ms number
---@return boolean drained
function M._drain_edits(timeout_ms)
  local docs = vim.tbl_values(M._state.documents)
  for _, doc in ipairs(docs) do
    buffer.reconcile(doc)
    doc:flush()
  end

  local function idle()
    for _, doc in ipairs(docs) do
      if doc.inflight_op or doc.pending_ops or buffer.has_pending(doc) then return false end
    end
    return true
  end
  return vim.wait(timeout_ms, idle, 20)
end

--- Switch between editing, suggesting and viewing.
---@param name string
---@return boolean ok
function M.set_mode(name)
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return false
  end

  local refusal = mode.refusal(name)
  if refusal then
    config.log('warn', '%s', refusal)
    return false
  end
  if name == mode.get() then
    config.log('info', 'Already in %s mode', name)
    return true
  end

  if not M._drain_edits(3000) then
    config.log('warn', 'Still sending edits; try again in a moment')
    return false
  end

  local was_viewing = mode.get() == mode.VIEWING
  mode.set(name)
  config.log('info', 'Mode: %s (%s)', name, M._mode_note(name))

  -- Disk edits made while viewing were held back, not lost.
  local held = sync.held_count()
  if was_viewing and held > 0 then
    config.log(
      'warn',
      '%d mirror file(s) changed while viewing and were not sent. :Overleaf sync import sends them.',
      held
    )
  end
  return true
end

--- Pick a mode from a list of the ones this session may use.
function M.select_mode()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end

  vim.ui.select(mode.allowed(), {
    prompt = 'Overleaf mode:',
    format_item = function(m) return string.format('%s %-10s %s', m == mode.get() and '*' or ' ', m, M._mode_note(m)) end,
  }, function(choice)
    if choice then M.set_mode(choice) end
  end)
end

function M.status()
  if not M._state.connected then
    config.log('info', 'Not connected')
    return
  end

  local doc_count = 0
  for _ in pairs(M._state.documents) do
    doc_count = doc_count + 1
  end

  config.log(
    'info',
    'Project: %s | Documents: %d | Connected: %s',
    M._state.project_name or '?',
    doc_count,
    M._state.connected and 'yes' or 'no'
  )

  for _, doc in pairs(M._state.documents) do
    config.log('info', '  - %s (v%d)', doc.path, doc.version or 0)
  end
end

--- Statusline component for lualine or custom statusline
--- Usage with lualine: sections = { lualine_x = { require('overleaf').statusline } }
function M.statusline()
  if not M._state.connected then return '' end

  local proj = M._state.project_name or '?'

  -- Editing is the default and says nothing; the other two are worth a glance,
  -- since they change what a keystroke does.
  local suffix = mode.get() == mode.EDITING and '' or (' [' .. mode.get() .. ']')

  -- Show current doc name if in an overleaf buffer
  local bufname = vim.api.nvim_buf_get_name(0)
  local doc_path = sync.parse_buf_name(bufname)
  if doc_path then return 'OL: ' .. proj .. ' / ' .. doc_path .. suffix end

  return 'OL: ' .. proj .. suffix
end

return M
