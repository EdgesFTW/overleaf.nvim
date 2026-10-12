local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local mode = require('overleaf.mode')
local project = require('overleaf.project')
local sync = require('overleaf.sync')

local function write(path, content)
  local file = assert(io.open(path, 'wb'))
  file:write(content)
  file:close()
end

local function calls_of(calls, method)
  local found = {}
  for _, call in ipairs(calls) do
    if call.method == method then table.insert(found, call) end
  end
  return found
end

describe('new files in the disk mirror', function()
  local tmp, state, calls, saved

  before_each(function()
    saved = {
      request = bridge.request,
      config = vim.deepcopy(config._config),
      mode = mode._mode,
      tree = project._project_tree,
      root = project._root_folder_id,
    }
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    config.setup({ sync_dir = tmp, sync_new_files = false, log_level = 'error' })
    mode._mode = mode.EDITING
    project.parse_project_tree({ rootFolder = { _id = 'root', name = 'mirror', docs = {}, folders = {} } })
    state = { connected = true, project_id = 'project', csrf_token = 'csrf', documents = {} }
    calls = {}
    local next_id = 0
    bridge.request = function(method, params, callback)
      table.insert(calls, { method = method, params = params })
      if method == 'createFolder' or method == 'createDoc' then
        next_id = next_id + 1
        callback(nil, { _id = method .. next_id })
      elseif method == 'joinDoc' then
        callback(nil, { lines = { '' }, version = 0 })
      elseif method == 'uploadFile' then
        next_id = next_id + 1
        callback(nil, { entity_id = 'file' .. next_id })
      elseif callback then
        callback(nil, {})
      end
    end
    sync.start('mirror')
  end)

  after_each(function()
    sync.stop()
    vim.fn.delete(tmp, 'rf')
    bridge.request = saved.request
    config._config = saved.config
    mode._mode = saved.mode
    project._project_tree = saved.tree
    project._root_folder_id = saved.root
  end)

  local function start_watching(setting)
    config.setup({ sync_new_files = setting })
    sync.sync_all(state, project._project_tree)
  end

  it('leaves new files alone by default but reports them in sync status', function()
    start_watching(false)
    write(sync.file_path('draft.tex'), 'draft')
    vim.wait(650, function() return false end)
    assert.are.equal(0, #calls)
    project.add_entry({ id = 'missing', name = 'missing.tex', path = 'missing.tex', type = 'doc', depth = 0 })
    local status = sync.status(project._project_tree)
    assert.are.same({ 'draft.tex' }, status.disk_only)
    assert.are.same({ 'missing.tex' }, status.missing_on_disk)
  end)

  it('imports a disk-only text file on an explicit sync import while automatic import is off', function()
    start_watching(false)
    write(sync.file_path('manual.tex'), 'manual content')
    sync.import_all(state)
    assert.is_true(vim.wait(4000, function() return #calls_of(calls, 'applyOtUpdate') == 1 end))
    assert.is_not_nil(project.get_doc_by_path('manual.tex'))
  end)

  it('creates a nested folder and document, then sends its content through OT', function()
    start_watching(true)
    local dir = sync.file_path('chapters')
    vim.fn.mkdir(dir, 'p')
    write(dir .. '/intro.tex', 'Hello from disk')
    assert.is_true(vim.wait(4000, function() return #calls_of(calls, 'applyOtUpdate') == 1 end))
    assert.are.equal('chapters', calls_of(calls, 'createFolder')[1].params.name)
    assert.are.equal('root', calls_of(calls, 'createFolder')[1].params.parentFolderId)
    assert.are.equal('intro.tex', calls_of(calls, 'createDoc')[1].params.name)
    local op = calls_of(calls, 'applyOtUpdate')[1].params
    assert.are.equal('', op.content)
    assert.is_false(op.tracked)
    assert.are.equal('Hello from disk', state.documents[project.get_doc_by_path('chapters/intro.tex').id].content)
    assert.are.equal(0, #calls_of(calls, 'leaveDoc'))
    assert.is_not_nil(sync._dir_watchers[dir])
    assert.is_not_nil(sync._watchers[dir .. '/intro.tex'])
  end)

  it('ignores build products, editor temps, dotfiles and conflict copies', function()
    start_watching(true)
    for _, name in ipairs({
      '.private.tex',
      '4913',
      'main.tex~',
      'main.tex.swp',
      'main.tex.tmp.1234',
      'main.tex.tmp.session',
      'main.tex.new',
      'main.tex.overleaf-conflict.1',
      'main.aux',
      'main.log',
      'main.out',
      'main.synctex.gz',
      'main.fdb_latexmk',
      'main.fls',
      'main.bbl',
      'main.blg',
      'main.pdf',
    }) do
      write(sync.file_path(name), 'ignored')
    end
    vim.fn.mkdir(sync.file_path('build'), 'p')
    write(sync.file_path('build/generated.tex'), 'ignored')
    vim.wait(900, function() return false end)
    assert.are.equal(0, #calls_of(calls, 'createDoc'))
    assert.are.equal(0, #calls_of(calls, 'uploadFile'))
  end)

  it('uploads binaries only when their extension is explicit', function()
    start_watching(true)
    write(sync.file_path('plot.png'), '\137PNG')
    vim.wait(700, function() return false end)
    assert.are.equal(0, #calls_of(calls, 'uploadFile'))
    config.setup({ sync_new_files = { binary = { 'png' } } })
    write(sync.file_path('second.png'), '\137PNG')
    assert.is_true(vim.wait(4000, function()
      for _, call in ipairs(calls_of(calls, 'uploadFile')) do
        if call.params.fileName == 'second.png' then return true end
      end
      return false
    end))
  end)

  it('holds new files in viewing mode', function()
    mode._mode = mode.VIEWING
    start_watching(true)
    local path = sync.file_path('readonly.tex')
    write(path, 'hold this')
    assert.is_true(vim.wait(4000, function() return sync._held[path] == true end))
    assert.are.equal(0, #calls_of(calls, 'createDoc'))
    assert.are.same({ 'readonly.tex' }, sync.status(project._project_tree).held)
  end)

  it('holds a new document when createDoc is refused', function()
    local original_request = bridge.request
    bridge.request = function(method, params, callback)
      if method == 'createDoc' then
        table.insert(calls, { method = method, params = params })
        callback({ code = 'CREATE_FAILED', message = 'review collaborator cannot create' })
      else
        original_request(method, params, callback)
      end
    end
    start_watching(true)
    local path = sync.file_path('refused.tex')
    write(path, 'review text')
    assert.is_true(vim.wait(4000, function() return sync._held[path] == true end))
    assert.are.equal(1, #calls_of(calls, 'createDoc'))
    assert.are.equal(0, #calls_of(calls, 'applyOtUpdate'))
  end)

  it('holds a configured binary in suggesting mode', function()
    mode._mode = mode.SUGGESTING
    start_watching({ binary = { 'png' } })
    local path = sync.file_path('figure.png')
    write(path, '\137PNG')
    assert.is_true(vim.wait(4000, function() return sync._held[path] == true end))
    assert.are.equal(0, #calls_of(calls, 'uploadFile'))
  end)

  it('sends a tracked insertion in suggesting mode', function()
    mode._mode = mode.SUGGESTING
    start_watching(true)
    write(sync.file_path('suggest.tex'), 'suggested content')
    assert.is_true(vim.wait(4000, function() return #calls_of(calls, 'applyOtUpdate') == 1 end))
    assert.is_true(calls_of(calls, 'applyOtUpdate')[1].params.tracked)
  end)

  it('does not recreate a remotely added document mirrored to disk', function()
    start_watching(true)
    project.add_entry({ id = 'remote', name = 'remote.tex', path = 'remote.tex', type = 'doc', depth = 0 })
    local doc = { doc_id = 'remote', path = 'remote.tex', content = 'remote content' }
    sync.write_doc(doc)
    vim.wait(800, function() return false end)
    assert.are.equal(0, #calls_of(calls, 'createDoc'))
    assert.are.equal('remote content', sync._last_written[sync.file_path('remote.tex')])
    assert.are.same({}, sync.status(project._project_tree).disk_only)
  end)

  it('waits until a growing file has the same size twice', function()
    start_watching(true)
    local path = sync.file_path('growing.tex')
    write(path, 'a')
    vim.wait(300, function() return false end)
    write(path, 'a longer document')
    vim.wait(350, function() return false end)
    assert.are.equal(0, #calls_of(calls, 'createDoc'))
    assert.is_true(vim.wait(4000, function() return #calls_of(calls, 'createDoc') == 1 end))
    assert.are.equal('a longer document', state.documents[project.get_doc_by_path('growing.tex').id].content)
  end)
end)
