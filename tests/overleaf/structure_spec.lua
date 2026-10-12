local ol = require('overleaf')
local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local project = require('overleaf.project')
local sync = require('overleaf.sync')
local Document = require('overleaf.document')
local tree = require('overleaf.tree')
local comments = require('overleaf.comments')

local function project_data(name)
  return {
    rootFolder = {
      {
        _id = 'root',
        name = name,
        docs = { { _id = 'top', name = 'main.tex' } },
        folders = {
          {
            _id = 'folder',
            name = 'chapters',
            docs = { { _id = 'nested', name = 'one.tex' } },
            fileRefs = { { _id = 'asset', name = 'asset.png' } },
            folders = {
              { _id = 'deep', name = 'deep', docs = { { _id = 'deepdoc', name = 'two.tex' } } },
            },
          },
          { _id = 'target', name = 'target', docs = {} },
        },
      },
    },
  }
end

local function read(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  return content
end

describe('project structure events', function()
  local saved = {}
  local tmp
  local calls

  before_each(function()
    saved.request = bridge.request
    saved.on_event = bridge.on_event
    saved.handlers = bridge._event_handlers
    saved.config = vim.deepcopy(config._config)
    saved.state = ol._state
    saved.tree_toggle = tree.toggle
    saved.tree_refresh = tree.refresh
    saved.load_threads = comments.load_threads
    saved.sync_all = sync.sync_all
    saved.bridge_exit = bridge._on_unexpected_exit
    saved.defer_fn = vim.defer_fn
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    config.setup({ sync_dir = tmp, log_level = 'error' })
    calls = {}
    bridge._event_handlers = {}
    bridge.on_event = function(name, handler)
      bridge._event_handlers[name] = bridge._event_handlers[name] or {}
      table.insert(bridge._event_handlers[name], handler)
    end
    bridge.request = function(method, params, callback)
      table.insert(calls, { method = method, params = params })
      if method == 'connect' then
        callback(nil, { project = project_data(params.projectId), permissionsLevel = 'readAndWrite' })
      elseif method == 'joinDoc' then
        callback(nil, { lines = { 'server content' }, version = 2, ranges = {} })
      elseif callback then
        callback(nil, {})
      end
    end
    tree.toggle = function() end
    tree.refresh = function() end
    comments.load_threads = function() end
    sync.sync_all = function() end
    ol._state = { connected = false, documents = {}, pdf_opened = {}, user_id = 'user' }
    ol._registered_handlers = nil
    vim.defer_fn = saved.defer_fn
    project.parse_project_tree(project_data('initial'))
    ol._setup_event_handlers()
    sync.start('initial')
  end)

  after_each(function()
    sync.stop()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].overleaf_file then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(tmp, 'rf')
    bridge.request = saved.request
    bridge.on_event = saved.on_event
    bridge._event_handlers = saved.handlers
    bridge._on_unexpected_exit = saved.bridge_exit
    config._config = saved.config
    ol._state = saved.state
    tree.toggle = saved.tree_toggle
    tree.refresh = saved.tree_refresh
    comments.load_threads = saved.load_threads
    sync.sync_all = saved.sync_all
    ol._registered_handlers = nil
  end)

  -- Handlers defer UI work with vim.schedule; run it inline so an error in a
  -- deferred callback fails the test instead of only printing.
  local function dispatch(name, data)
    local schedule = vim.schedule
    vim.schedule = function(fn) fn() end
    local ok, err = pcall(function()
      for _, handler in ipairs(bridge._event_handlers[name] or {}) do
        handler(data)
      end
    end)
    vim.schedule = schedule
    if not ok then error(err, 0) end
  end

  local function open_doc(id)
    local entry = project.get_doc_by_id(id)
    local doc = Document.new(id, entry.path)
    doc.joined = true
    doc.content = id .. ' content'
    doc.bufnr = vim.api.nvim_create_buf(true, false)
    vim.bo[doc.bufnr].swapfile = false
    vim.api.nvim_buf_set_name(doc.bufnr, sync.buf_name(doc.path))
    vim.b[doc.bufnr].overleaf_file = doc.path
    ol._state.documents[id] = doc
    sync.write_doc(doc)
    sync.watch(doc)
    return doc
  end

  it('tears down each project on switching and keeps one handler per event', function()
    ol._connect_project('cookie', 'first', 'first')
    local doc = open_doc('nested')
    local file_buf = vim.api.nvim_create_buf(false, true)
    vim.b[file_buf].overleaf_file = 'asset.txt'
    local tree_buf = vim.api.nvim_create_buf(false, true)
    tree._bufnr = tree_buf
    ol._connect_project('cookie', 'second', 'second')
    assert.is_true(vim.wait(1000, function() return ol._state.project_id == 'second' end))
    assert.is_false(vim.api.nvim_buf_is_valid(doc.bufnr or -1))
    assert.is_false(vim.api.nvim_buf_is_valid(file_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(tree_buf))
    assert.is_nil(next(ol._state.documents))
    assert.is_nil(next(sync._watchers))
    ol._connect_project('cookie', 'third', 'third')
    assert.is_true(vim.wait(1000, function() return ol._state.project_id == 'third' end))
    for name, handlers in pairs(bridge._event_handlers) do
      assert.are.equal(1, #handlers, name)
    end
  end)

  it('removes a folder subtree and its open documents on a remote deletion', function()
    local doc = open_doc('deepdoc')
    local mirror = sync.file_path(doc.path)
    local file_buf = vim.api.nvim_create_buf(false, true)
    vim.b[file_buf].overleaf_file = 'chapters/asset.png'
    dispatch('removeEntity', { entityId = 'folder' })
    assert.is_nil(project.get_doc_by_id('folder'))
    assert.is_nil(project.get_doc_by_id('nested'))
    assert.is_nil(project.get_doc_by_id('deepdoc'))
    assert.is_nil(ol._state.documents.deepdoc)
    assert.is_false(vim.api.nvim_buf_is_valid(file_buf))
    assert.is_nil(next(sync._watchers))
    assert.is_nil(doc.bufnr)
    assert.are.equal('deepdoc content', read(mirror))
  end)

  it('cleans an open document on remote removal', function()
    local doc = open_doc('top')
    dispatch('removeEntity', { entityId = 'top' })
    assert.is_nil(ol._state.documents.top)
    assert.is_nil(doc.bufnr)
    assert.is_nil(next(sync._watchers))
  end)

  it('renames a remote folder, its open buffers, and its mirror files', function()
    local doc = open_doc('deepdoc')
    local old_mirror = sync.file_path(doc.path)
    dispatch('reciveEntityRename', { entityId = 'folder', newName = 'renamed' })
    local new_path = 'renamed/deep/two.tex'
    assert.are.equal(new_path, project.get_doc_by_id('deepdoc').path)
    assert.are.equal(new_path, doc.path)
    assert.are.equal(sync.buf_name(new_path), vim.api.nvim_buf_get_name(doc.bufnr))
    assert.are.equal(new_path, vim.b[doc.bufnr].overleaf_file)
    assert.is_nil(read(old_mirror))
    assert.are.equal('deepdoc content', read(sync.file_path(new_path)))
    assert.is_nil(sync._watchers[old_mirror])
    assert.is_not_nil(sync._watchers[sync.file_path(new_path)])
    assert.is_nil(sync._last_written[old_mirror])
    -- No placeholder buffer under the old name, no emptied directories left behind.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      assert.are_not.equal(sync.buf_name('chapters/deep/two.tex'), vim.api.nvim_buf_get_name(b))
    end
    assert.is_nil(vim.uv.fs_stat(vim.fn.fnamemodify(old_mirror, ':h')))
  end)

  it('moves a closed document mirror on a local folder rename', function()
    local old_path = sync.file_path('chapters/one.tex')
    sync.write_doc({ doc_id = 'nested', path = 'chapters/one.tex', content = 'closed content' })
    ol._rename_entry('folder', 'drafts')
    assert.is_nil(read(old_path))
    assert.are.equal('closed content', read(sync.file_path('drafts/one.tex')))
    assert.is_nil(sync._last_written[old_path])
    assert.are.equal('closed content', sync._last_written[sync.file_path('drafts/one.tex')])
  end)

  it('uses the same subtree cleanup for local deletion', function()
    local doc = open_doc('nested')
    ol._remove_entity('folder')
    assert.is_nil(project.get_doc_by_id('nested'))
    assert.is_nil(ol._state.documents.nested)
    assert.is_nil(doc.bufnr)
  end)

  it('moves a folder and updates descendant paths and depths', function()
    dispatch('reciveEntityMove', { entityId = 'folder', parentFolderId = 'target' })
    assert.are.equal('target/chapters/', project.get_doc_by_id('folder').path)
    assert.are.equal(1, project.get_doc_by_id('folder').depth)
    assert.are.equal(2, project.get_doc_by_id('deep').depth)
    assert.are.equal(3, project.get_doc_by_id('deepdoc').depth)
    assert.are.equal('target/chapters/deep/two.tex', project.get_doc_by_id('deepdoc').path)
  end)

  it('adds an unseen restored document once', function()
    local data = {
      parentFolderId = 'folder',
      doc = { _id = 'restored', name = 'restored.tex' },
      meta = { kind = 'file-restore', path = '/chapters/restored.tex' },
    }
    dispatch('reciveNewDoc', data)
    dispatch('reciveNewDoc', data)
    assert.are.equal('chapters/restored.tex', project.get_doc_by_id('restored').path)
    local count = 0
    for _, entry in ipairs(project._project_tree) do
      if entry.id == 'restored' then count = count + 1 end
    end
    assert.are.equal(1, count)
  end)

  it('adds a new folder once at the parent depth', function()
    local data = { parentFolderId = 'folder', folder = { _id = 'newfolder', name = 'new' } }
    dispatch('reciveNewFolder', data)
    dispatch('reciveNewFolder', data)
    assert.are.equal('chapters/new/', project.get_doc_by_id('newfolder').path)
    assert.are.equal(1, project.get_doc_by_id('newfolder').depth)
  end)

  it('schedules a mirror write after rejoin', function()
    ol._state.connected = true
    local doc = Document.new('nested', 'chapters/one.tex')
    vim.defer_fn = function(callback) callback() end
    doc:rejoin()
    assert.are.equal('server content', doc.content)
    assert.is_not_nil(sync._write_timers.nested)
  end)
end)
