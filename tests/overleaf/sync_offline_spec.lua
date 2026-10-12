-- Mirror Phase 4 (decision D5): a mirror file edited while the plugin was not
-- connected is told apart from a server change by a manifest of hashes.
local ol = require('overleaf')
local bridge = require('overleaf.bridge')
local buffer = require('overleaf.buffer')
local config = require('overleaf.config')
local diff = require('overleaf.diff')
local mode = require('overleaf.mode')
local ot = require('overleaf.ot')
local project = require('overleaf.project')
local sync = require('overleaf.sync')
local tree = require('overleaf.tree')

local BASE = 'First line here.\nSecond line here.\nThird line here.'

local function read(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local data = file:read('*a')
  file:close()
  return data
end

local function write(path, content)
  local file = assert(io.open(path, 'wb'))
  file:write(content)
  file:close()
end

-- How Claude Code saves: a temp file renamed over the original.
local function replace(path, content)
  write(path .. '.agent', content)
  assert(os.rename(path .. '.agent', path))
end

local function buffer_text(bufnr) return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') end

describe('mirror offline edits (Phase 4)', function()
  local tmp, state_dir, dir, calls, server, logs, saved, fail_join, hold_joins, on_create
  -- doc id -> true while this client's socket is joined to it on the server
  local subscribed

  local function count(method, doc_id)
    local n = 0
    for _, call in ipairs(calls) do
      if call.method == method and (not doc_id or call.params.docId == doc_id) then n = n + 1 end
    end
    return n
  end

  local function logged(level, pattern)
    for _, entry in ipairs(logs) do
      if entry.level == level and entry.msg:find(pattern, 1, true) then return entry.msg end
    end
  end

  --- A collaborator's edit: applied on the server and broadcast to the doc.
  local function collaborate(doc_id, new_text)
    local entry = server[doc_id]
    local op = diff.ops(entry.text, new_text)
    local v = entry.version
    entry.text = ot.apply(entry.text, op)
    entry.version = v + 1
    local doc = ol._state.documents[doc_id]
    -- Broadcast only to a client joined to the document.
    if doc and subscribed[doc_id] then doc:receive({ doc = doc_id, op = op, v = v, meta = { source = 'other' } }) end
  end

  local function respond_join(params, callback)
    local entry = server[params.docId]
    local result = {
      lines = vim.split(entry.text, '\n', { plain = true }),
      version = entry.version,
      ranges = {},
    }
    if params.fromVersion then result.updates = {} end
    subscribed[params.docId] = true
    callback(nil, result)
  end

  before_each(function()
    saved = {
      request = bridge.request,
      log = config.log,
      config = vim.deepcopy(config._config),
      mode = mode._mode,
      state = ol._state,
      tree = project._project_tree,
      root = project._root_folder_id,
      attach_lsp = buffer._attach_lsp,
      chktex = buffer._run_chktex,
      defer_fn = vim.defer_fn,
      on_event = bridge.on_event,
      handlers = bridge._event_handlers,
      registered = ol._registered_handlers,
      tree_refresh = tree.refresh,
      pending_restore = ol._pending_restore,
      manifest_dir = sync._manifest_dir,
    }
    state_dir = vim.fn.tempname()
    sync._manifest_dir = function() return state_dir end
    tree.refresh = function() end
    bridge._event_handlers = {}
    bridge.on_event = function(name, handler)
      bridge._event_handlers[name] = bridge._event_handlers[name] or {}
      table.insert(bridge._event_handlers[name], handler)
    end
    ol._registered_handlers = nil
    ol._setup_event_handlers()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    config.setup({ sync_dir = tmp, log_level = 'error' })
    logs = {}
    config.log = function(level, fmt, ...) table.insert(logs, { level = level, msg = string.format(fmt, ...) }) end
    mode._mode = mode.EDITING
    buffer._attach_lsp = function() end
    buffer._run_chktex = function() end
    ol._state =
      { connected = true, project_id = 'proj1', public_id = 'mine', public_ids = { mine = true }, documents = {} }
    project.parse_project_tree({
      rootFolder = {
        {
          _id = 'root',
          name = 'mirror',
          docs = { { _id = 'main', name = 'main.tex' }, { _id = 'other', name = 'other.tex' } },
          folders = {},
        },
      },
    })
    server = {
      main = { text = BASE, version = 3 },
      other = { text = 'Other text.', version = 1 },
    }
    calls, fail_join, hold_joins, on_create, subscribed = {}, {}, nil, nil, {}
    bridge.request = function(method, params, callback)
      table.insert(calls, { method = method, params = params })
      if method == 'joinDoc' then
        if (fail_join[params.docId] or 0) > 0 then
          fail_join[params.docId] = fail_join[params.docId] - 1
          callback({ message = 'refused' })
        elseif hold_joins then
          table.insert(hold_joins, function() respond_join(params, callback) end)
        else
          respond_join(params, callback)
        end
      elseif method == 'createDoc' and on_create then
        on_create(params, callback)
      elseif method == 'applyOtUpdate' then
        local entry = server[params.docId]
        if not subscribed[params.docId] then
          callback({ message = 'not joined' })
          return
        end
        if params.v ~= entry.version then
          callback({ message = 'version mismatch' })
          return
        end
        entry.text = ot.apply(entry.text, params.op)
        entry.version = entry.version + 1
        callback(nil)
        -- Only to the client that sent it: never to the next test's documents.
        local sender = ol._state
        vim.schedule(function()
          local doc = ol._state == sender and sender.documents[params.docId]
          if doc then doc:receive({ doc = params.docId, v = params.v }) end
        end)
      elseif method == 'leaveDoc' then
        subscribed[params.docId] = nil
        if callback then callback(nil, {}) end
      elseif callback then
        callback(nil, {})
      end
    end
    sync.start('mirror')
    dir = sync._sync_dir
  end)

  after_each(function()
    sync.stop()
    for _, doc in pairs(ol._state.documents) do
      for _, name in ipairs({ '_flush_timer', '_ack_timer' }) do
        if doc[name] then vim.fn.timer_stop(doc[name]) end
      end
      if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
        vim.api.nvim_buf_delete(doc.bufnr, { force = true })
      end
    end
    vim.fn.delete(tmp, 'rf')
    bridge.request = saved.request
    config.log = saved.log
    config._config = saved.config
    mode._mode = saved.mode
    ol._state = saved.state
    project._project_tree = saved.tree
    project._root_folder_id = saved.root
    buffer._attach_lsp = saved.attach_lsp
    buffer._run_chktex = saved.chktex
    vim.defer_fn = saved.defer_fn
    bridge.on_event = saved.on_event
    bridge._event_handlers = saved.handlers
    ol._registered_handlers = saved.registered
    tree.refresh = saved.tree_refresh
    ol._pending_restore = saved.pending_restore
    sync._manifest_dir = saved.manifest_dir
    vim.fn.delete(state_dir, 'rf')
  end)

  local function manifest_name() return 'proj1-' .. vim.fn.sha256(sync._sync_dir):sub(1, 12) .. '.json' end
  local function manifest_path() return state_dir .. '/' .. manifest_name() end

  local function manifest_on_disk()
    local data = read(manifest_path())
    return data and vim.json.decode(data)
  end

  local function sha(text) return vim.fn.sha256(text) end

  local function conflicts(name) return vim.fn.glob(dir .. '/' .. name .. '.overleaf-conflict.*', false, true) end

  local function synced()
    local done = false
    sync.sync_all(ol._state, project._project_tree, function() done = true end)
    assert.is_true(vim.wait(2000, function() return done end))
  end

  --- The plugin goes away (its manifest is flushed) and comes back later.
  local function restart()
    sync.stop()
    for _, doc in pairs(ol._state.documents) do
      for _, name in ipairs({ '_flush_timer', '_ack_timer' }) do
        if doc[name] then vim.fn.timer_stop(doc[name]) end
      end
    end
    ol._state.documents = {}
    subscribed, calls = {}, {}
    sync.start('mirror')
  end

  --- Connect, then disconnect with the mirror in sync.
  local function first_session()
    synced()
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    restart()
  end

  local function sent_ops()
    local sent = {}
    for _, call in ipairs(calls) do
      if call.method == 'applyOtUpdate' then table.insert(sent, call.params) end
    end
    return sent
  end

  it('does nothing when the disk equals the server (case 1)', function()
    first_session()
    synced()
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    assert.are.equal(0, count('applyOtUpdate'))
    assert.are.same({}, conflicts('main.tex'))
  end)

  it('overwrites with the server text when only the server changed (case 2)', function()
    first_session()
    server.main.text = 'Changed on Overleaf.'
    server.main.version = 4
    synced()
    assert.are.equal('Changed on Overleaf.', read(dir .. '/main.tex'))
    assert.are.same({}, conflicts('main.tex'))
    assert.are.equal(0, count('applyOtUpdate'))
    assert.is_nil(logged('warn', 'main.tex'))
  end)

  it('sends the disk text as an edit when only the disk changed (case 3)', function()
    first_session()
    local edited = 'First line here.\nSecond line, edited offline.\nThird line here.'
    write(dir .. '/main.tex', edited)
    synced()
    assert.is_true(vim.wait(3000, function() return server.main.text == edited end))
    assert.are.equal(edited, read(dir .. '/main.tex'))
    assert.are.same({}, conflicts('main.tex'))
    assert.is_truthy(logged('info', 'main.tex was edited while Overleaf was not connected'))
    assert.is_nil(logged('warn', 'main.tex'))
    local sent = sent_ops()
    assert.are.equal(1, #sent)
    assert.is_false(sent[1].tracked)
    -- Only the words that differ, not the whole document.
    for _, component in ipairs(sent[1].op) do
      assert.is_true(#(component.i or component.d) < 15)
    end
  end)

  it('keeps a conflict copy of the disk version when both sides changed (case 4)', function()
    first_session()
    write(dir .. '/main.tex', 'Disk offline edit.')
    server.main.text = 'Server offline edit.'
    server.main.version = 4
    synced()
    local copies = conflicts('main.tex')
    assert.are.equal(1, #copies)
    assert.are.equal('Disk offline edit.', read(copies[1]))
    assert.are.equal('Server offline edit.', read(dir .. '/main.tex'))
    assert.are.equal(0, count('applyOtUpdate'))
    local msg = logged('warn', 'main.tex differs from Overleaf')
    assert.is_truthy(msg)
    assert.is_truthy(msg:find('main.tex.overleaf-conflict.1', 1, true))
  end)

  it('overwrites differing files as before when there is no manifest yet', function()
    first_session()
    os.remove(manifest_path())
    write(dir .. '/main.tex', 'Stale text from before the manifest.')
    synced()
    assert.are.equal(0, #conflicts('main.tex'))
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    assert.are.equal(0, count('applyOtUpdate'))
    -- The record starts now: the next offline edit is told apart.
    sync.flush_manifest()
    assert.are.equal(sha(BASE), manifest_on_disk().docs['main.tex'])
  end)

  it('treats a differing file with no manifest entry as a conflict (case 4)', function()
    first_session()
    local data = manifest_on_disk()
    data.docs['main.tex'] = nil
    write(manifest_path(), vim.json.encode(data))
    write(dir .. '/main.tex', 'Disk text nobody recorded.')
    synced()
    local copies = conflicts('main.tex')
    assert.are.equal(1, #copies)
    assert.are.equal('Disk text nobody recorded.', read(copies[1]))
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    assert.are.equal(0, count('applyOtUpdate'))
  end)

  it('leaves other documents alone when one has an offline edit', function()
    first_session()
    write(dir .. '/main.tex', 'Disk offline edit.')
    synced()
    assert.is_true(vim.wait(3000, function() return server.main.text == 'Disk offline edit.' end))
    assert.are.equal('Other text.', read(dir .. '/other.tex'))
    assert.are.equal('Other text.', server.other.text)
  end)

  it('writes the manifest atomically, privately and debounced, outside the mirror', function()
    local flushes = 0
    local flush = sync.flush_manifest
    sync.flush_manifest = function(...)
      if sync._manifest_dirty then flushes = flushes + 1 end
      return flush(...)
    end
    local ok, err = pcall(function()
      synced()
      -- A new record is saved once, complete, when the first sync ends.
      assert.is_not_nil(read(manifest_path()))
      for i = 1, 5 do
        collaborate('main', BASE .. ' ' .. i)
        sync.write_doc(ol._state.documents.main)
      end
      assert.is_true(vim.wait(3000, function() return manifest_on_disk().docs['main.tex'] == sha(BASE .. ' 5') end))
    end)
    sync.flush_manifest = flush
    assert(ok, err)
    -- One write for the initial sync, one for the burst.
    assert.are.equal(2, flushes)
    local stat = vim.uv.fs_stat(manifest_path())
    assert.are.equal(tonumber('600', 8), bit.band(stat.mode, tonumber('777', 8)))
    assert.are.equal(tonumber('700', 8), bit.band(vim.uv.fs_stat(state_dir).mode, tonumber('777', 8)))
    assert.are.same({ manifest_name() }, vim.fn.readdir(state_dir))
    assert.is_false(vim.startswith(manifest_path(), dir))
    assert.are.equal('', vim.fn.glob(dir .. '/**/*overleaf-sync*'))
    local data = manifest_on_disk()
    assert.are.equal('proj1', data.project_id)
    assert.are.equal(sha('Other text.'), data.docs['other.tex'])
  end)

  it('flushes the pending manifest when the sync stops', function()
    synced()
    local file = manifest_path()
    collaborate('main', BASE .. ' more')
    sync.write_doc(ol._state.documents.main)
    -- Within the debounce: not on disk yet.
    assert.are.equal(sha(BASE), vim.json.decode(read(file)).docs['main.tex'])
    sync.stop()
    assert.are.equal(sha(BASE .. ' more'), vim.json.decode(read(file)).docs['main.tex'])
    sync.start('mirror')
  end)

  it('does not save a new manifest before the first sync is complete', function()
    hold_joins = {}
    sync.sync_all(ol._state, project._project_tree, function() end)
    vim.wait(200)
    sync.stop()
    assert.is_nil(read(manifest_path()))
    sync.start('mirror')
  end)

  it('restores a file emptied while offline, with a warning', function()
    first_session()
    write(dir .. '/main.tex', '')
    synced()
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    assert.are.equal(0, #conflicts('main.tex'))
    assert.are.equal(0, count('applyOtUpdate'))
    assert.is_truthy(logged('warn', 'emptied while Overleaf was not connected'))
  end)

  it('treats a manifest it cannot read as empty, keeping both versions', function()
    first_session()
    local file = manifest_path()
    write(dir .. '/main.tex', 'Offline text.')
    vim.uv.fs_chmod(file, 0)
    synced()
    vim.uv.fs_chmod(file, tonumber('600', 8))
    assert.are.equal(1, #conflicts('main.tex'))
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    assert.is_truthy(logged('warn', 'unreadable'))
  end)

  it('reads the manifest again in a new session', function()
    first_session()
    assert.is_nil(sync._manifest)
    synced()
    assert.are.equal(sha(BASE), sync._manifest['main.tex'])
    assert.are.equal(sha('Other text.'), sync._manifest['other.tex'])
  end)

  it('moves the manifest entry when a document is renamed', function()
    synced()
    local doc = ol._state.documents.main
    local old = doc.path
    doc.path = 'renamed.tex'
    sync.move_doc(old, doc)
    sync.flush_manifest()
    local docs = manifest_on_disk().docs
    assert.is_nil(docs['main.tex'])
    assert.are.equal(sha(BASE), docs['renamed.tex'])
    assert.are.equal(BASE, read(dir .. '/renamed.tex'))
  end)

  it('drops the manifest entry when a document is deleted', function()
    synced()
    sync.unwatch(ol._state.documents.main, true)
    sync.flush_manifest()
    local docs = manifest_on_disk().docs
    assert.is_nil(docs['main.tex'])
    assert.is_not_nil(docs['other.tex'])
  end)

  it('treats a corrupt manifest as empty and warns once', function()
    first_session()
    write(manifest_path(), '{ not json')
    write(dir .. '/main.tex', 'Disk offline edit.')
    synced()
    local warned = 0
    for _, entry in ipairs(logs) do
      if entry.level == 'warn' and entry.msg:find('unreadable', 1, true) then warned = warned + 1 end
    end
    assert.are.equal(1, warned)
    -- No record, so the differing file is kept as a conflict copy.
    assert.are.equal(1, #conflicts('main.tex'))
    assert.are.equal(BASE, read(dir .. '/main.tex'))
    -- The next flush replaces it.
    sync.flush_manifest()
    assert.are.equal(sha(BASE), manifest_on_disk().docs['main.tex'])
  end)

  it('holds an offline edit in viewing mode and leaves the file alone (case 3)', function()
    first_session()
    mode._mode = mode.VIEWING
    local path = dir .. '/main.tex'
    write(path, 'Disk offline edit.')
    synced()
    assert.is_true(sync._held[path])
    assert.are.equal('Disk offline edit.', read(path))
    assert.are.equal(BASE, server.main.text)
    assert.are.equal(0, count('applyOtUpdate'))
    assert.are.same({}, conflicts('main.tex'))
  end)

  it('sends an offline edit as a tracked change in suggesting mode (case 3)', function()
    first_session()
    mode._mode = mode.SUGGESTING
    local edited = 'First line here.\nSecond line, suggested.\nThird line here.'
    write(dir .. '/main.tex', edited)
    synced()
    assert.is_true(vim.wait(3000, function() return server.main.text == edited end))
    local sent = sent_ops()
    assert.are.equal(1, #sent)
    assert.is_true(sent[1].tracked)
  end)

  it('stores astral characters in an offline edit as Overleaf does', function()
    first_session()
    write(dir .. '/main.tex', 'First line here.\nSecond line \240\159\152\128 here.\nThird line here.')
    synced()
    -- One replacement per UTF-16 unit, as Overleaf counts them.
    local stored = 'First line here.\nSecond line \239\191\189\239\191\189 here.\nThird line here.'
    assert.is_true(vim.wait(3000, function() return server.main.text == stored end))
    assert.is_true(vim.wait(3000, function() return read(dir .. '/main.tex') == stored end))
    assert.are.same({}, conflicts('main.tex'))
  end)
end)
