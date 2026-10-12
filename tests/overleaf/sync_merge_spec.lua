-- Mirror Phase 2: every mirrored document stays joined, and a disk edit is
-- merged three-way from the bytes the plugin last wrote.
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

describe('mirror merge (Phase 2)', function()
  local tmp, dir, calls, server, logs, saved, fail_join, hold_joins, on_create
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
    }
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
    ol._state = { connected = true, public_id = 'mine', public_ids = { mine = true }, documents = {} }
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
  end)

  local function dispatch(name, data)
    for _, handler in ipairs(bridge._event_handlers[name] or {}) do
      handler(data)
    end
  end

  local function synced()
    local done = false
    sync.sync_all(ol._state, project._project_tree, function() done = true end)
    assert.is_true(vim.wait(2000, function() return done end))
  end

  local function settle(doc_id, path)
    assert.is_true(vim.wait(3000, function()
      local doc = ol._state.documents[doc_id]
      return doc.inflight_op == nil
        and doc.pending_ops == nil
        and sync._write_timers[doc_id] == nil
        and read(path) == server[doc_id].text
    end))
  end

  it('keeps every mirrored document joined after the initial sync', function()
    synced()
    for id, entry in pairs(server) do
      local doc = ol._state.documents[id]
      assert.is_true(doc.joined)
      assert.are.equal(entry.text, read(dir .. '/' .. doc.path))
    end
    assert.are.equal(2, count('joinDoc'))
    assert.are.equal(0, count('leaveDoc'))
  end)

  it('writes a remote edit to a document without a buffer to its file', function()
    synced()
    collaborate('main', BASE:gsub('First', 'Opening'))
    assert.is_true(vim.wait(2000, function() return read(dir .. '/main.tex') == server.main.text end))
  end)

  it('keeps both edits when a collaborator edits between the read and the write of a closed document', function()
    synced()
    local path = dir .. '/main.tex'
    local read_by_agent = read(path)
    -- Lands before the debounced mirror write: the agent never saw it.
    collaborate('main', BASE:gsub('First', 'Opening'))
    replace(path, (read_by_agent:gsub('Third', 'Final')))
    local expected = 'Opening line here.\nSecond line here.\nFinal line here.'
    assert.is_true(vim.wait(3000, function() return server.main.text == expected end))
    settle('main', path)
    assert.are.equal(expected, read(path))
    assert.are.equal(1, count('applyOtUpdate', 'main'))
  end)

  it('sends a deliberate revert to an older text instead of taking it as a stale read', function()
    synced()
    local path = dir .. '/main.tex'
    local original = read(path)
    replace(path, (original:gsub('Third', 'Final')))
    assert.is_true(vim.wait(3000, function() return server.main.text:find('Final') ~= nil end))
    settle('main', path)
    replace(path, original)
    assert.is_true(vim.wait(3000, function() return server.main.text == original end))
  end)

  it('reuses the joined Document when a document is opened, with exactly one joinDoc', function()
    synced()
    local doc = ol._state.documents.main
    ol.open_document('main', 'main.tex')
    assert.are.equal(doc, ol._state.documents.main)
    assert.are.equal(1, count('joinDoc', 'main'))
    assert.is_truthy(doc.bufnr)
    assert.are.equal(BASE, buffer_text(doc.bufnr))
  end)

  it('waits for a join already under way instead of sending a second one', function()
    hold_joins = {}
    sync.sync_all(ol._state, project._project_tree)
    ol.open_document('main', 'main.tex')
    for _, respond in ipairs(hold_joins) do
      respond()
    end
    local doc = ol._state.documents.main
    assert.are.equal(1, count('joinDoc', 'main'))
    assert.is_truthy(doc.bufnr)
    assert.are.equal(BASE, buffer_text(doc.bufnr))
  end)

  it('merges a disk edit into an open document with unsent typing in it', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    local read_by_agent = read(path)
    vim.api.nvim_buf_set_lines(doc.bufnr, 1, 2, false, { 'Second line typed.' })
    replace(path, (read_by_agent:gsub('Third', 'Final')))
    local expected = 'First line here.\nSecond line typed.\nFinal line here.'
    assert.is_true(vim.wait(3000, function() return server.main.text == expected end))
    settle('main', path)
    assert.are.equal(expected, buffer_text(doc.bufnr))
    assert.are.equal(expected, read(path))
  end)

  it('saves an overlapping edit to a uniquely named conflict copy and sends nothing', function()
    synced()
    local path = dir .. '/main.tex'
    local agent = BASE:gsub('Second', 'Middle')
    collaborate('main', BASE:gsub('Second', '2nd'))
    local theirs = server.main.text
    replace(path, agent)
    assert.is_true(vim.wait(3000, function() return read(path .. '.overleaf-conflict.1') == agent end))
    assert.are.equal(theirs, read(path))
    assert.are.equal(theirs, sync._last_written[path])
    assert.are.equal(0, count('applyOtUpdate'))
    assert.is_truthy(logged('warn', path .. '.overleaf-conflict.1'))

    -- A second conflict gets its own copy.
    collaborate('main', theirs:gsub('First', 'Opening'))
    local second = theirs:gsub('First', 'Start')
    replace(path, second)
    assert.is_true(vim.wait(3000, function() return read(path .. '.overleaf-conflict.2') == second end))
    assert.are.equal(agent, read(path .. '.overleaf-conflict.1'))
    assert.are.equal(server.main.text, read(path))
    assert.are.equal(0, count('applyOtUpdate'))
  end)

  it('sends a disk edit two-way, with a warning, when there is no base', function()
    synced()
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    sync._last_written[path] = nil
    write(path, 'Replaced entirely.')
    sync._on_file_changed(path, doc)
    assert.is_truthy(logged('warn', 'without a merge'))
    assert.is_true(vim.wait(3000, function() return server.main.text == 'Replaced entirely.' end))
  end)

  it('merges non-ASCII text and stores astral characters as Overleaf does', function()
    server.main.text = 'Ünïcode café line.\n日本語 second line.\nthird line.'
    synced()
    local path = dir .. '/main.tex'
    local read_by_agent = read(path)
    collaborate('main', server.main.text:gsub('third', 'THIRD'))
    replace(path, (read_by_agent:gsub('café', 'caffè 🎉')))
    local expected = 'Ünïcode caffè \239\191\189\239\191\189 line.\n日本語 second line.\nTHIRD line.'
    assert.is_true(vim.wait(3000, function() return server.main.text == expected end))
    settle('main', path)
    assert.are.equal(expected, read(path))
  end)

  it('rejoins documents without a buffer after a reconnect', function()
    synced()
    vim.defer_fn = function(fn) fn() end
    ol._rejoin_documents()
    local caught_up = {}
    for _, call in ipairs(calls) do
      if call.method == 'joinDoc' and call.params.fromVersion then caught_up[call.params.docId] = true end
    end
    assert.are.same({ main = true, other = true }, caught_up)
    assert.is_true(ol._state.documents.main.joined)
    assert.is_false(ol._state.documents.main._rejoining)
  end)

  it('holds a disk edit in viewing mode', function()
    synced()
    local path = dir .. '/main.tex'
    mode._mode = mode.VIEWING
    replace(path, 'Agent text.')
    assert.is_true(vim.wait(3000, function() return sync._held[path] == true end))
    assert.are.equal('Agent text.', read(path))
    assert.are.equal(0, count('applyOtUpdate'))
  end)

  it('sends every one of a burst of rename-replace saves', function()
    synced()
    local path = dir .. '/main.tex'
    for i = 1, 5 do
      local text = read(path) .. '\nline ' .. i
      replace(path, text)
      assert.is_true(vim.wait(3000, function() return server.main.text == text end), 'save ' .. i)
    end
    settle('main', path)
  end)

  it('keeps the document joined when its buffer is closed, and reopens it without a join', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local bufnr = doc.bufnr
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'Typed just before closing.' })
    vim.cmd('bdelete! ' .. bufnr)
    assert.is_nil(doc.bufnr)
    assert.is_true(doc.joined)
    assert.are.equal(0, count('leaveDoc'))
    assert.is_true(vim.wait(3000, function() return server.main.text:find('Typed just before closing.', 1, true) end))
    assert.is_true(vim.wait(1000, function() return not vim.api.nvim_buf_is_valid(bufnr) end))

    collaborate('main', server.main.text .. '\nMore.')
    ol.open_document('main', 'main.tex')
    assert.are.equal(1, count('joinDoc', 'main'))
    assert.are.equal(server.main.text, buffer_text(doc.bufnr))
  end)

  it('falls back to a snapshot when a document cannot be joined, and still merges its disk edits', function()
    fail_join.main = 1
    synced()
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    assert.is_truthy(logged('warn', 'Could not keep main.tex joined'))
    assert.is_false(doc.joined)
    assert.are.equal(1, count('leaveDoc', 'main'))
    assert.are.equal(BASE, read(path))

    -- The snapshot does not follow the server; the merge uses a fresh join.
    local entry = server.main
    entry.text = entry.text:gsub('First', 'Opening')
    entry.version = entry.version + 1
    replace(path, (BASE:gsub('Third', 'Final')))
    local expected = 'Opening line here.\nSecond line here.\nFinal line here.'
    assert.is_true(vim.wait(3000, function() return entry.text == expected end))
    assert.is_true(vim.wait(3000, function() return read(path) == expected end))
    assert.are.equal(2, count('leaveDoc', 'main'))
  end)
  it('searches without leaving documents the mirror keeps joined, sharing a join under way', function()
    hold_joins = {}
    sync.sync_all(ol._state, project._project_tree)
    vim.fn.setqflist({}, 'r')
    require('overleaf.search').grep('Second', ol._state)
    for _, respond in ipairs(hold_joins) do
      respond()
    end
    assert.is_true(vim.wait(2000, function() return #vim.fn.getqflist() == 1 end))
    vim.cmd('cclose')
    assert.are.equal(1, count('joinDoc', 'main'))
    assert.are.equal(0, count('leaveDoc'))
    assert.is_true(ol._state.documents.main.joined)
  end)

  it('joins an untracked document through a Document when searching with a mirror', function()
    vim.fn.setqflist({}, 'r')
    require('overleaf.search').grep('Other', ol._state)
    assert.is_true(vim.wait(2000, function() return #vim.fn.getqflist() == 1 end))
    vim.cmd('cclose')
    assert.are.equal(0, count('leaveDoc'))
    assert.is_true(ol._state.documents.other.joined)
    assert.are.equal('Other text.', read(dir .. '/other.tex'))
  end)

  it('joins and mirrors a document created on Overleaf', function()
    synced()
    server.remote = { text = 'Remote doc.', version = 0 }
    dispatch('reciveNewDoc', { parentFolderId = 'root', doc = { _id = 'remote', name = 'remote.tex' } })
    local doc = ol._state.documents.remote
    assert.is_true(doc.joined)
    assert.are.equal('Remote doc.', read(dir .. '/remote.tex'))
    collaborate('remote', 'Remote doc, edited.')
    assert.is_true(vim.wait(2000, function() return read(dir .. '/remote.tex') == 'Remote doc, edited.' end))
    dispatch('reciveNewDoc', { parentFolderId = 'root', doc = { _id = 'remote', name = 'remote.tex' } })
    assert.are.equal(1, count('joinDoc', 'remote'))
  end)

  it('keeps a disk-only file when a document of the same name is created on Overleaf', function()
    synced()
    write(dir .. '/remote.tex', 'agent draft')
    server.remote = { text = 'Remote doc.', version = 0 }
    dispatch('reciveNewDoc', { parentFolderId = 'root', doc = { _id = 'remote', name = 'remote.tex' } })
    assert.is_true(ol._state.documents.remote.joined)
    assert.are.equal('agent draft', read(dir .. '/remote.tex.overleaf-conflict.1'))
    assert.are.equal('Remote doc.', read(dir .. '/remote.tex'))
    assert.is_truthy(logged('warn', 'remote.tex.overleaf-conflict.1'))
  end)

  it('does not join a second time a document this client creates from a disk file', function()
    config.setup({ sync_new_files = true })
    ol._state.project_id = 'project'
    synced()
    -- Overleaf broadcasts the new document before it answers createDoc.
    on_create = function(params, callback)
      server.created = { text = '', version = 0 }
      dispatch('reciveNewDoc', { parentFolderId = 'root', doc = { _id = 'created', name = params.name } })
      callback(nil, { _id = 'created' })
      dispatch('reciveNewDoc', { parentFolderId = 'root', doc = { _id = 'created', name = params.name } })
    end
    write(dir .. '/new.tex', 'Agent wrote this.')
    assert.is_true(vim.wait(4000, function() return server.created and server.created.text == 'Agent wrote this.' end))
    assert.are.equal(1, count('joinDoc', 'created'))
    assert.are.equal('Agent wrote this.', read(dir .. '/new.tex'))
  end)

  it('rejoins a restored document without a buffer through its Document and rewrites its mirror', function()
    synced()
    local doc = ol._state.documents.main
    server.restored = { text = 'Restored text.', version = 0 }
    ol._pending_restore = { ['/main.tex'] = 'main' }
    dispatch('reciveNewDoc', {
      parentFolderId = 'root',
      doc = { _id = 'restored', name = 'main.tex' },
      meta = { kind = 'file-restore', path = '/main.tex' },
    })
    assert.are.equal(doc, ol._state.documents.restored)
    assert.is_true(doc.joined)
    assert.are.equal('restored', doc.doc_id)
    assert.are.equal('Restored text.', doc.content)
    assert.is_true(vim.wait(2000, function() return read(dir .. '/main.tex') == 'Restored text.' end))
    collaborate('restored', 'Restored text, edited.')
    assert.is_true(vim.wait(2000, function() return read(dir .. '/main.tex') == 'Restored text, edited.' end))
  end)
  -- Writers that read the file just before writing, as Claude Code does: the
  -- base is the text the plugin last wrote, so what they remove stays removed.
  it('keeps a writer removing its own earlier insertion while editing elsewhere', function()
    synced()
    local path = dir .. '/main.tex'
    local m1 = BASE .. '\nAdded paragraph line.'
    replace(path, m1)
    assert.is_true(vim.wait(3000, function() return server.main.text == m1 end))
    settle('main', path)
    local m2 = (BASE:gsub('Third', 'Final'))
    replace(path, m2)
    assert.is_true(vim.wait(3000, function() return server.main.text == m2 end))
    settle('main', path)
  end)

  it('keeps a fresh-read writer deleting a collaborator line while editing elsewhere', function()
    synced()
    local path = dir .. '/main.tex'
    collaborate('main', BASE .. '\nTODO from collaborator.')
    assert.is_true(vim.wait(2000, function() return read(path) == server.main.text end))
    local m = (BASE:gsub('First', 'Opening'))
    replace(path, m)
    assert.is_true(vim.wait(3000, function() return server.main.text == m end))
    settle('main', path)
  end)

  it('keeps an agent removing a typed line that reached the disk while editing elsewhere', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    vim.api.nvim_buf_set_lines(doc.bufnr, 3, 3, false, { '% user note' })
    assert.is_true(vim.wait(3000, function() return read(path) == BASE .. '\n% user note' end))
    settle('main', path)
    local m = (BASE:gsub('Second', 'Middle'))
    replace(path, m)
    assert.is_true(vim.wait(3000, function() return server.main.text == m end))
    settle('main', path)
    assert.are.equal(m, buffer_text(doc.bufnr))
  end)

  it('keeps a writer rewriting the paragraph it just added, with no conflict copy', function()
    synced()
    local path = dir .. '/main.tex'
    local m1 = BASE .. '\nA long paragraph the agent wrote first, with many words in it.'
    replace(path, m1)
    assert.is_true(vim.wait(3000, function() return server.main.text == m1 end))
    settle('main', path)
    local m2 = BASE .. '\nShort rewrite.'
    replace(path, m2)
    assert.is_true(vim.wait(3000, function() return server.main.text == m2 end))
    settle('main', path)
    assert.is_nil(read(path .. '.overleaf-conflict.1'))
  end)

  it('keeps a writer deleting its own insertion after a collaborator edit it has read', function()
    synced()
    local path = dir .. '/main.tex'
    local added = '\nA paragraph the agent added earlier.'
    local m1 = BASE .. added
    replace(path, m1)
    assert.is_true(vim.wait(3000, function() return server.main.text == m1 end))
    settle('main', path)
    collaborate('main', (m1:gsub('First', 'Fist')))
    assert.is_true(vim.wait(2000, function() return read(path) == server.main.text end))
    local fresh = read(path)
    local m2 = fresh:sub(1, #fresh - #added)
    replace(path, m2)
    assert.is_true(vim.wait(3000, function() return server.main.text == m2 end))
    settle('main', path)
  end)

  it('merges a disk edit made while an open document is joining once the join answers', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    -- As the file-restore remap does: not joined, then joined again.
    hold_joins = {}
    doc.joined = false
    doc:join(function() end)
    local m = (BASE:gsub('Third', 'Final'))
    replace(path, m)
    vim.wait(700, function() return false end)
    assert.are.equal(0, count('applyOtUpdate'))
    assert.are.equal(BASE, doc.content)
    for _, respond in ipairs(hold_joins) do
      respond()
    end
    assert.is_true(vim.wait(3000, function() return server.main.text == m end))
    settle('main', path)
    assert.are.equal(m, buffer_text(doc.bufnr))
  end)

  it('holds a disk edit to a stopped document and changes nothing', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    doc.joined, doc._stopped = false, true
    local m = (BASE:gsub('Third', 'Final'))
    replace(path, m)
    assert.is_true(vim.wait(3000, function() return sync._held[path] == true end))
    assert.is_truthy(logged('warn', 'not syncing with Overleaf'))
    assert.are.equal(BASE, doc.content)
    assert.are.equal(BASE, buffer_text(doc.bufnr))
    assert.are.equal(m, read(path))
    assert.are.equal(0, count('applyOtUpdate'))
  end)

  it('does not leave a document a Document joined while a snapshot edit was joining', function()
    fail_join.main = 1
    synced()
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    assert.is_false(doc.joined)
    assert.are.equal(1, count('leaveDoc', 'main'))
    hold_joins = {}
    local m = (BASE:gsub('Third', 'Final'))
    replace(path, m)
    assert.is_true(vim.wait(2000, function() return #hold_joins == 1 end))
    ol.open_document('main', 'main.tex')
    assert.are.equal(2, #hold_joins)
    for _, respond in ipairs(hold_joins) do
      respond()
    end
    assert.is_true(vim.wait(3000, function() return server.main.text == m end))
    settle('main', path)
    assert.are.equal(1, count('leaveDoc', 'main'))
    assert.is_true(subscribed.main)
    assert.is_true(doc.joined)
    assert.are.equal(m, buffer_text(doc.bufnr))
  end)

  it('keeps the base and holds the edit when the conflict copy cannot be written', function()
    synced()
    local path = dir .. '/main.tex'
    collaborate('main', BASE:gsub('Second', '2nd'))
    local agent = BASE:gsub('Second', 'Middle')
    replace(path, agent)
    vim.uv.fs_chmod(dir, tonumber('500', 8))
    local held = vim.wait(3000, function() return sync._held[path] == true end)
    vim.uv.fs_chmod(dir, tonumber('700', 8))
    assert.is_true(held)
    assert.are.equal(BASE, sync._last_written[path])
    assert.are.equal(agent, read(path))
    assert.are.equal(0, count('applyOtUpdate'))
    -- A later mirror write must not write over the writer's only copy.
    sync.write_doc(ol._state.documents.main)
    assert.are.equal(agent, read(path .. '.overleaf-conflict.1'))
    assert.are.equal(server.main.text, read(path))
  end)

  it('keeps the base and holds the edit when the snapshot path cannot join', function()
    fail_join.main = 1
    synced()
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    fail_join.main = 1
    local m = (BASE:gsub('Third', 'Final'))
    replace(path, m)
    assert.is_true(vim.wait(3000, function() return sync._held[path] == true end))
    assert.are.equal(BASE, sync._last_written[path])
    assert.are.equal(m, read(path))
    -- The next mirror write sends it instead of writing over it.
    sync.write_doc(doc)
    assert.is_true(vim.wait(3000, function() return server.main.text == m end))
    assert.are.equal(m, read(path))
  end)

  it('leaves, without mirroring, a document deleted while its join was under way', function()
    hold_joins = {}
    local done = false
    sync.sync_all(ol._state, project._project_tree, function() done = true end)
    ol._remove_entity('other')
    for _, respond in ipairs(hold_joins) do
      respond()
    end
    assert.is_true(vim.wait(2000, function() return done end))
    assert.is_nil(ol._state.documents.other)
    assert.is_nil(subscribed.other)
    assert.is_nil(read(dir .. '/other.tex'))
    assert.is_true(subscribed.main)
  end)

  it('leaves a document whose join answers after it was left, without waiting for it', function()
    hold_joins = {}
    local doc = require('overleaf.document').new('main', 'main.tex')
    doc:join()
    local left = false
    doc:leave(function() left = true end)
    assert.is_true(left)
    for _, respond in ipairs(hold_joins) do
      respond()
    end
    assert.is_true(vim.wait(1000, function() return not doc.joined end))
    assert.is_nil(subscribed.main)
  end)

  it('does not run a scheduled rejoin for a document that was left', function()
    synced()
    local doc = ol._state.documents.main
    local deferred = {}
    vim.defer_fn = function(fn) table.insert(deferred, fn) end
    doc:rejoin()
    doc:leave()
    for _, fn in ipairs(deferred) do
      fn()
    end
    for _, call in ipairs(calls) do
      assert.is_nil(call.params and call.params.fromVersion)
    end
    assert.is_false(doc._rejoining)
    assert.is_false(doc.joined)
  end)
  it('detaches an unloaded buffer, sending its last typing, and reopens it for typing', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local bufnr = doc.bufnr
    -- Let the buffer's scheduled setup (treesitter, which loads it) run first.
    vim.wait(50, function() return false end)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'Typed before unloading.' })
    vim.cmd('enew')
    vim.cmd('bunload! ' .. bufnr)
    assert.is_true(vim.wait(1000, function() return doc.bufnr == nil and not vim.api.nvim_buf_is_valid(bufnr) end))
    assert.is_true(doc.joined)
    local typed = (BASE:gsub('First line here.', 'Typed before unloading.'))
    assert.is_true(vim.wait(3000, function() return server.main.text == typed end))

    ol.open_document('main', 'main.tex')
    assert.are.equal(1, count('joinDoc', 'main'))
    assert.are.equal(typed, buffer_text(doc.bufnr))
    vim.api.nvim_buf_set_lines(doc.bufnr, -1, -1, false, { 'Typed after reopening.' })
    local expected = typed .. '\nTyped after reopening.'
    assert.is_true(vim.wait(3000, function() return server.main.text == expected end))
    settle('main', dir .. '/main.tex')
  end)

  it('keeps syncing a buffer reloaded with :edit!, without losing or repeating edits', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local bufnr = doc.bufnr
    local path = dir .. '/main.tex'
    -- A remote edit not yet on disk, and typing not yet sent.
    collaborate('main', BASE .. '\nRemote.')
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'First typed.' })
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd('edit!')
    local typed = 'First typed.\nSecond line here.\nThird line here.\nRemote.'
    assert.is_true(vim.wait(1000, function() return buffer_text(bufnr) == typed end))
    assert.are.equal(bufnr, doc.bufnr)
    assert.is_false(vim.bo[bufnr].modified)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { 'After reload.' })
    local expected = typed .. '\nAfter reload.'
    assert.is_true(vim.wait(3000, function() return server.main.text == expected end))
    settle('main', path)
    assert.are.equal(expected, buffer_text(bufnr))
    assert.are.equal(expected, read(path))
  end)
  it('keeps a disk edit made while an open document is being restored', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local path = dir .. '/main.tex'
    settle('main', path)
    server.restored = { text = BASE, version = 0 }
    ol._pending_restore = { ['/main.tex'] = 'main' }
    hold_joins = {}
    dispatch('reciveNewDoc', {
      parentFolderId = 'root',
      doc = { _id = 'restored', name = 'main.tex' },
      meta = { kind = 'file-restore', path = '/main.tex' },
    })
    local m = (BASE:gsub('Third', 'Final'))
    replace(path, m)
    vim.wait(700, function() return false end)
    local pending = hold_joins
    hold_joins = nil
    for _, respond in ipairs(pending) do
      respond()
    end
    assert.is_true(vim.wait(3000, function() return server.restored.text == m end))
    settle('restored', path)
    assert.are.equal(m, doc.content)
    assert.are.equal(m, buffer_text(doc.bufnr))
    assert.are.equal(m, read(path))
    assert.is_nil(logged('debug', 'divergence'))
  end)

  it('lets a disk edit reach a reloaded buffer only through the merge, not :checktime', function()
    synced()
    ol.open_document('main', 'main.tex')
    local doc = ol._state.documents.main
    local bufnr = doc.bufnr
    local path = dir .. '/main.tex'
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd('edit!')
    assert.is_true(vim.wait(1000, function() return vim.bo[bufnr].autoread == false end))
    vim.o.autoread = true
    local m = (BASE:gsub('Third', 'Final'))
    replace(path, m)
    vim.cmd('checktime')
    vim.o.autoread = false
    assert.is_true(vim.wait(3000, function() return server.main.text == m end))
    settle('main', path)
    assert.are.equal(m, buffer_text(bufnr))
    assert.are.equal(1, count('applyOtUpdate', 'main'))
  end)
end)
