local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local project = require('overleaf.project')
local Document = require('overleaf.document')
local buffer = require('overleaf.buffer')
local sync = require('overleaf.sync')
local viewer = require('overleaf.viewer')

local M = {}

--- Open a file with the configured viewer or platform default
---@param file_path string
---@return number|nil pid of the viewer, when it was started by us
local function open_file(file_path)
  local viewer_cmd = config.get().pdf_viewer
  if viewer_cmd then
    -- User-configured viewer: run as background job to avoid disrupting cursor/window layout
    local job = vim.fn.jobstart({ viewer_cmd, file_path }, { detach = true })
    if job > 0 then
      local ok, pid = pcall(vim.fn.jobpid, job)
      if ok then return pid end
    end
    return nil
  else
    -- vim.ui.open() spawns with detach=true and, for xdg-open, with the stdout
    -- and stderr pipes disabled: the viewer is reparented to init (so it leaves
    -- no zombie and outlives nvim) and no output is buffered for its lifetime.
    -- It returns the process handle without waiting.
    --
    -- This previously used vim.fn.system(), which is synchronous and froze nvim
    -- until the viewer exited. vim.ui.open also covers more platforms than the
    -- mac/wsl/else detection it replaces.
    local _, err = vim.ui.open(file_path)
    if err then config.log('error', 'Could not open %s: %s', file_path, err) end
    return nil
  end
end

M._state = {
  connected = false,
  project_name = nil,
  project_id = nil,
  project_data = nil,
  csrf_token = nil,
  root_doc_id = nil, -- project's main document; Overleaf compiles this one
  documents = {}, -- doc_id -> Document
  pdf_path = nil, -- where the last compile's output.pdf landed
  pdf_opened = {}, -- path -> true once a viewer has been launched for it
  pdf_pid = nil, -- viewer process, when we started it (used to find it on D-Bus)
  build_id = nil, -- the build SyncTeX lookups address
  clsi_server_id = nil, -- CLSI node holding that build
  synctex_path = nil, -- SyncTeX database mirrored next to the PDF
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
}

function M.setup(opts)
  config.setup(opts)
  M._set_keymaps()
end

function M._set_keymaps()
  local cfg = config.get()
  if cfg.keymaps == false then return end

  local prefix = cfg.keymap_prefix
  for _, km in ipairs(DEFAULT_KEYMAPS) do
    local suffix, desc, rhs = km[1], km[2], km[3]
    vim.keymap.set('n', prefix .. suffix, rhs, { desc = 'Overleaf: ' .. desc })
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
    M._state.root_doc_id = result.project and result.project.rootDoc_id or nil

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

function M._setup_event_handlers()
  bridge.on_event('otUpdateApplied', function(data)
    -- Skip own-ACK events (no op field = acknowledgment for our own op)
    -- Our ACK is already handled by the applyOtUpdate callback → _on_ack()
    if not data.op then return end

    local doc = M._state.documents[data.doc]
    if doc then
      doc:on_remote_op(data, function(transformed_ops)
        buffer.apply_remote(doc, transformed_ops)
        sync.schedule_write(doc)
      end)
    end
  end)

  -- The server pushes this when the main document is changed from any client.
  bridge.on_event('rootDocUpdated', function(data)
    if data and data.docId then
      M._state.root_doc_id = data.docId
      local entry = project.get_doc_by_id(data.docId)
      config.log('info', 'Main document is now %s', entry and entry.path or data.docId)
    end
  end)

  bridge.on_event('otUpdateError', function(data)
    config.log('debug', 'OT Error for doc %s: %s', data.doc or '?', data.message or '?')
    -- Only rejoin if connected (disconnect handler handles reconnect separately)
    if M._state.connected then
      local doc = M._state.documents[data.doc]
      if doc and not doc._rejoining then doc:rejoin() end
    end
  end)

  bridge.on_event('disconnect', function(data)
    if M._state.connected then config.log('warn', 'Disconnected: %s — reconnecting...', data.reason or 'unknown') end
    M._state.connected = false
    M._attempt_reconnect()
  end)

  -- File tree events
  bridge.on_event('reciveNewDoc', function(data)
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
          old_doc.joined = false
          old_doc.inflight_op = nil
          old_doc.pending_ops = nil
          if old_doc._flush_timer then
            vim.fn.timer_stop(old_doc._flush_timer)
            old_doc._flush_timer = nil
          end

          -- Immediately join the new doc (server already has it ready)
          bridge.request('joinDoc', { docId = new_id }, function(err, result)
            if err then
              config.log('error', 'Failed to join restored doc %s: %s', meta.path or '?', err.message)
              return
            end

            local content = table.concat(result.lines, '\n')
            old_doc.version = result.version
            old_doc.content = content
            old_doc.server_content = content
            old_doc.joined = true
            old_doc._rejoining = false
            old_doc.ranges = result.ranges

            config.log('info', 'Restored doc %s (v%d)', meta.path or '?', result.version)

            -- Update buffer with new content
            if old_doc.bufnr and vim.api.nvim_buf_is_valid(old_doc.bufnr) then
              vim.schedule(function()
                old_doc.applying_remote = true
                vim.api.nvim_buf_set_lines(old_doc.bufnr, 0, -1, false, result.lines)
                vim.bo[old_doc.bufnr].modified = false
                old_doc.applying_remote = false

                -- Re-render comments if available
                if result.ranges then
                  local comments = require('overleaf.comments')
                  comments.parse_ranges(new_id, result.ranges)
                  comments.render(old_doc.bufnr, new_id, old_doc.content)
                end
              end)
            end
          end)
        end
      end

      vim.schedule(function() require('overleaf.tree').refresh() end)
      return
    end

    -- Normal new doc (not restore)
    local parent_path = project.get_folder_path(data.parentFolderId)
    local path = parent_path .. (doc_info.name or '')
    if not project.path_exists(path) then
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
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  bridge.on_event('reciveNewFile', function(data)
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

  bridge.on_event('removeEntity', function(data)
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
    local entry = project.get_doc_by_id(data.entityId)
    if entry and entry.type == 'file' then sync.forget_file(entry) end
    project.remove_entry(data.entityId)
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

  bridge.on_event('newComment', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_new_comment(data)
      rerender_comments()
    end)
  end)

  bridge.on_event('resolveThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_resolve_thread(data)
      rerender_comments()
    end)
  end)

  bridge.on_event('reopenThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_reopen_thread(data)
      rerender_comments()
    end)
  end)

  bridge.on_event('deleteThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_delete_thread(data)
      rerender_comments()
    end)
  end)

  -- Collaborator cursor tracking
  bridge.on_event('clientUpdated', function(data)
    vim.schedule(function() require('overleaf.cursors').on_client_updated(data) end)
  end)

  bridge.on_event('clientDisconnected', function(data)
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
    M._reconnect.attempt = 0

    config.log('info', 'Reconnected to: %s', M._state.project_name or '?')

    -- Re-join all open documents (wait for server to settle after restore)
    vim.defer_fn(function() M._rejoin_documents() end, 3000)
  end)
end

function M._rejoin_documents()
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      -- Reset all state for clean rejoin
      doc._rejoining = false
      doc.joined = false
      doc.inflight_op = nil
      doc.pending_ops = nil
      if doc._flush_timer then
        vim.fn.timer_stop(doc._flush_timer)
        doc._flush_timer = nil
      end
      doc:rejoin()
    end
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

  -- Check if already open
  if M._state.documents[doc_id] then
    local existing = M._state.documents[doc_id]
    if existing.bufnr and vim.api.nvim_buf_is_valid(existing.bufnr) then
      vim.api.nvim_set_current_buf(existing.bufnr)
      return
    end
  end

  local doc = Document.new(doc_id, path)
  M._state.documents[doc_id] = doc

  doc:join(function(err, lines, ranges)
    if err then
      M._state.documents[doc_id] = nil
      return
    end

    buffer.create(doc, lines)

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
  end)
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

      -- :w uploads directly (the watcher skips bytes already in flight) so the
      -- compile can follow the upload, as it follows the OT flush for docs.
      vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = bufnr,
        callback = function()
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

  -- Show entries to rename
  local entries = {}
  for _, entry in ipairs(project._project_tree) do
    table.insert(entries, entry)
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
          local updated = project.rename_entry(choice.id, new_name)
          if updated and choice.type == 'doc' then
            local doc = M._state.documents[choice.id]
            if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
              doc.path = updated.path
              vim.api.nvim_buf_set_name(doc.bufnr, sync.buf_name(updated.path))
            end
          end
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
          project.remove_entry(choice.id)
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

  bridge.request('downloadUrl', {
    cookie = config.get().cookie,
    url = url,
    -- Same stem as the PDF, which is what the viewer will look for.
    fileName = (M._state.project_name or 'output') .. '.synctex.gz',
    outputDir = config.get().pdf_dir,
  }, function(err, result)
    if err then
      callback(err.message)
      return
    end
    M._state.synctex_path = result.path
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
    M._state.pdf_path = result.path

    if config.get().inverse_search then
      fetch_synctex_db(output_files, clsi_server_id, function(db_err)
        if db_err then
          config.log('debug', 'No inverse search this build: %s', db_err)
          return
        end
        -- A viewer already running can start answering clicks right away.
        vim.schedule(function() M._start_inverse_search(true) end)
      end)
    end

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
end

-- Everything the build compiled lives under this directory inside Overleaf's
-- container, so the SyncTeX database records project files as
-- '/compile/./main.tex'. Anything outside it is a TeX Live package.
local COMPILE_ROOT = '/compile/'

--- Turn a path out of the SyncTeX database into a project path.
---@param input string
---@return string|nil nil when it is not a file of this project
function M._synctex_source_path(input)
  if type(input) ~= 'string' or input:sub(1, #COMPILE_ROOT) ~= COMPILE_ROOT then return nil end

  local rel = input:sub(#COMPILE_ROOT + 1)
  rel = rel:gsub('^%./', '')
  rel = rel:gsub('/%./', '/')
  if rel == '' then return nil end
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
  vim.schedule(function() jump_to_source(path, line, column or 0) end)
end

--- Start listening for clicks in the viewer, if inverse search is on and there
--- is a viewer to listen to. Safe to call repeatedly.
---@param quiet boolean|nil do not warn when there is no viewer yet
function M._start_inverse_search(quiet)
  if not config.get().inverse_search then return end
  if viewer.watching() then return end
  if not (M._state.pdf_path and M._state.synctex_path) then return end

  local ok, err = viewer.watch_edits(M._state.pdf_path, M._state.pdf_pid, M._on_viewer_edit)
  if ok then
    config.log('info', 'Inverse search ready: ctrl+click in the viewer')
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

  local bufnr = vim.api.nvim_get_current_buf()
  local path = M._source_path(bufnr)
  if not path then
    config.log('warn', 'This buffer is not part of the Overleaf project')
    return
  end
  if not M._state.build_id then
    config.log('warn', 'Nothing compiled yet. Run :Overleaf compile first.')
    return
  end
  if not M._state.pdf_path then
    config.log('warn', 'No PDF to move. Run :Overleaf compile first.')
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  -- Read once, up front: a disconnect between the request and its answer would
  -- otherwise leave the callback with no PDF to move.
  local pdf_path, pdf_pid = M._state.pdf_path, M._state.pdf_pid

  bridge.request('syncCode', {
    cookie = config.get().cookie,
    projectId = M._state.project_id,
    file = path,
    line = cursor[1],
    column = cursor[2] + 1,
    buildId = M._state.build_id,
    clsiServerId = M._state.clsi_server_id,
  }, function(err, result)
    if err then
      config.log('error', 'Forward search failed: %s', err.message)
      return
    end

    local hits = result and result.pdf or {}
    if #hits == 0 then
      -- Overleaf answers 200 with an empty list for a line that produced no
      -- output at all, and for a file the build never read.
      config.log('info', 'No PDF position for %s:%d', path, cursor[1])
      return
    end

    -- Everything SyncTeX returns for one place is on one page in practice, but
    -- only boxes on the page we jump to can be highlighted.
    local page = hits[1].page
    local rects = {}
    for _, hit in ipairs(hits) do
      if hit.page == page then
        -- SyncTeX gives the baseline; the box grows upwards from it.
        table.insert(rects, { hit.h, hit.v - hit.height, hit.h + hit.width, hit.v })
      end
    end

    vim.schedule(function()
      local ok, view_err = viewer.show(pdf_path, page, rects, pdf_pid)
      if ok then
        config.log('info', 'Forward search: %s:%d -> page %d', path, cursor[1], page)
      else
        config.log('warn', '%s', view_err)
      end
    end)
  end)
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

function M.disconnect()
  -- Stop auto-reconnect
  M._reconnect.attempt = 0
  M._reconnect.in_progress = false
  if M._reconnect.timer then
    vim.fn.timer_stop(M._reconnect.timer)
    M._reconnect.timer = nil
  end
  bridge._on_unexpected_exit = nil

  -- Stop file sync watchers
  sync.stop()

  -- Clear collaborator cursors and comments
  pcall(function() require('overleaf.cursors').clear_all() end)
  pcall(function() require('overleaf.comments').clear_all() end)

  -- Leave all documents
  for _, doc in pairs(M._state.documents) do
    doc:leave(function() buffer.cleanup(doc) end)
  end
  M._state.documents = {}

  -- Disconnect bridge
  bridge.stop()

  M._state.connected = false
  M._state.project_name = nil
  M._state.project_id = nil
  M._state.project_data = nil
  M._state.csrf_token = nil
  M._state.pdf_path = nil
  M._state.pdf_opened = {}
  M._state.pdf_pid = nil
  M._state.build_id = nil
  M._state.clsi_server_id = nil
  M._state.synctex_path = nil
  viewer.stop_watching()

  config.log('info', 'Disconnected')
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

  -- Show current doc name if in an overleaf buffer
  local bufname = vim.api.nvim_buf_get_name(0)
  local doc_path = sync.parse_buf_name(bufname)
  if doc_path then return 'OL: ' .. proj .. ' / ' .. doc_path end

  return 'OL: ' .. proj
end

return M
