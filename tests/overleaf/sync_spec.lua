-- Disk mirror sync: text detection, and the two paths an on-disk edit takes
-- back to Overleaf (OT for docs, whole-file re-upload for fileRefs).
local config = require('overleaf.config')
local sync = require('overleaf.sync')
local project = require('overleaf.project')
local bridge = require('overleaf.bridge')
local Document = require('overleaf.document')

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

local function write_file(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

--- Replace bridge.request with a fake that serves downloads from `store`
--- (fileId -> bytes) and records every call in `calls`.
local function fake_bridge(store, calls, opts)
  opts = opts or {}
  return function(method, params, callback)
    table.insert(calls, { method = method, params = params })
    if method == 'downloadFile' then
      local data = store[params.fileId]
      if not data then return callback({ code = 'DOWNLOAD_FAILED', message = 'no such file' }) end
      local tmp = vim.fn.tempname()
      write_file(tmp, data)
      return callback(nil, { path = tmp })
    elseif method == 'uploadFile' then
      local sent = read_file(params.filePath)
      table.insert(calls, { method = 'uploaded-bytes', data = sent })
      local new_id = 'file_' .. tostring(#calls)
      store[new_id] = sent
      local function respond() callback(nil, { success = true, entity_id = new_id, entity_type = 'file' }) end
      if opts.hold_uploads then
        opts.held = opts.held or {}
        table.insert(opts.held, respond)
        return
      end
      return respond()
    elseif method == 'joinDoc' then
      opts.doc_content = opts.doc_content or table.concat(opts.doc_lines or { '' }, '\n')
      opts.doc_version = opts.doc_version or 0
      return callback(
        nil,
        { lines = vim.split(opts.doc_content, '\n', { plain = true }), version = opts.doc_version, ranges = {} }
      )
    elseif method == 'applyOtUpdate' then
      -- Keep a real server-side view so a later join reflects earlier ops
      local content = opts.doc_content
      for _, op in ipairs(params.op) do
        if op.d then content = content:sub(1, op.p) .. content:sub(op.p + #op.d + 1) end
        if op.i then content = content:sub(1, op.p) .. op.i .. content:sub(op.p + 1) end
      end
      opts.doc_content = content
      opts.doc_version = opts.doc_version + 1
      return callback(nil, {})
    elseif method == 'leaveDoc' then
      return callback(nil, {})
    end
    error('unexpected bridge call: ' .. method)
  end
end

local function calls_of(calls, method)
  local out = {}
  for _, c in ipairs(calls) do
    if c.method == method then table.insert(out, c) end
  end
  return out
end

describe('sync', function()
  local original_config, original_request, original_state
  local tmpdir

  before_each(function()
    original_config = vim.deepcopy(config._config)
    original_request = bridge.request
    original_state = require('overleaf')._state
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    config.setup({ sync_dir = tmpdir, log_level = 'error' })
    project.parse_project_tree({
      rootFolder = {
        {
          _id = 'root',
          name = 'rootFolder',
          docs = { { _id = 'doc_main', name = 'main.tex' } },
          fileRefs = {
            { _id = 'file_top', name = 'top.asm' },
            { _id = 'file_png', name = 'logo.png' },
            { _id = 'file_dat', name = 'blob.dat' },
          },
          folders = {
            {
              _id = 'sub',
              name = 'src',
              docs = {},
              folders = {},
              fileRefs = { { _id = 'file_asm', name = 'main.asm' } },
            },
          },
        },
      },
    })
    require('overleaf')._state = { connected = true, project_id = 'proj', csrf_token = 'csrf', documents = {} }
    sync.start('Test Project')
  end)

  after_each(function()
    sync.stop()
    bridge.request = original_request
    require('overleaf')._state = original_state
    config._config = original_config
    vim.fn.delete(tmpdir, 'rf')
  end)

  describe('is_text', function()
    it('accepts ASCII', function() assert.is_true(sync.is_text('mov eax, 1\n')) end)
    it('accepts an empty file', function() assert.is_true(sync.is_text('')) end)
    it('accepts multibyte UTF-8', function() assert.is_true(sync.is_text('日本語 café 🎉')) end)
    it('rejects a NUL byte', function() assert.is_false(sync.is_text('abc\0def')) end)
    it('rejects invalid UTF-8', function() assert.is_false(sync.is_text('abc\255def')) end)
    it('rejects a truncated sequence', function() assert.is_false(sync.is_text('abc\226\130')) end)
    it('rejects overlong encodings', function() assert.is_false(sync.is_text('\192\128')) end)
    it('rejects UTF-16 surrogates', function() assert.is_false(sync.is_text('\237\160\128')) end)
    it('rejects non-strings', function() assert.is_false(sync.is_text(nil)) end)
  end)

  describe('file_policy', function()
    it('sniffs unknown extensions in auto mode', function()
      config.setup({ editable_files = 'auto' })
      assert.is_nil(sync.file_policy({ name = 'main.asm' }))
    end)

    it('never sniffs known binary extensions', function()
      config.setup({ editable_files = 'auto' })
      assert.is_false(sync.file_policy({ name = 'figure.PNG' }))
      assert.is_false(sync.file_policy({ name = 'paper.pdf' }))
    end)

    it('is off when editable_files is false', function()
      config.setup({ editable_files = false })
      assert.is_false(sync.file_policy({ name = 'main.asm' }))
    end)

    it('restricts to a listed extension', function()
      config.setup({ editable_files = { 'asm', '.S' } })
      assert.is_nil(sync.file_policy({ name = 'main.asm' }))
      assert.is_nil(sync.file_policy({ name = 'boot.s' }))
      assert.is_false(sync.file_policy({ name = 'main.c' }))
    end)
  end)

  describe('project.get_parent_folder_id', function()
    it(
      'returns the root folder for top-level entries',
      function() assert.are.equal('root', project.get_parent_folder_id(project.get_doc_by_path('top.asm'))) end
    )

    it(
      'returns the containing folder for nested entries',
      function() assert.are.equal('sub', project.get_parent_folder_id(project.get_doc_by_path('src/main.asm'))) end
    )
  end)

  describe('fetch_file', function()
    it('mirrors a text fileRef, marks it text, and watches it', function()
      local calls = {}
      bridge.request = fake_bridge({ file_asm = 'mov eax, 1\n' }, calls)
      local entry = project.get_doc_by_path('src/main.asm')

      local done, got_path
      sync.fetch_file(entry, 'proj', function(err, path)
        assert.is_nil(err)
        done, got_path = true, path
      end)
      assert.is_true(vim.wait(2000, function() return done end))

      assert.is_true(entry.text)
      assert.are.equal(tmpdir .. '/Test Project/src/main.asm', got_path)
      assert.are.equal('mov eax, 1\n', read_file(got_path))
      assert.is_not_nil(sync._file_watchers[got_path])
      assert.are.equal('mov eax, 1\n', sync._files['src/main.asm'].content)
    end)

    it('marks a fileRef with binary content as not text and does not watch it', function()
      local calls = {}
      bridge.request = fake_bridge({ file_dat = 'ab\0cd' }, calls)
      local entry = project.get_doc_by_path('blob.dat')
      local done
      sync.fetch_file(entry, 'proj', function() done = true end)
      assert.is_true(vim.wait(2000, function() return done end))
      assert.is_false(entry.text)
      assert.is_nil(sync._file_watchers[tmpdir .. '/Test Project/blob.dat'])
      assert.are.equal('ab\0cd', read_file(tmpdir .. '/Test Project/blob.dat'))
    end)

    it('does not re-download a known binary already on disk', function()
      local calls = {}
      bridge.request = fake_bridge({ file_png = 'PNG' }, calls)
      local entry = project.get_doc_by_path('logo.png')
      local done
      sync.fetch_file(entry, 'proj', function() done = true end)
      assert.is_true(vim.wait(2000, function() return done end))
      assert.are.equal(1, #calls_of(calls, 'downloadFile'))

      done = false
      sync.fetch_file(entry, 'proj', function() done = true end)
      assert.is_true(vim.wait(2000, function() return done end))
      assert.are.equal(1, #calls_of(calls, 'downloadFile'))
      assert.is_false(entry.text)
    end)

    it('re-fetches text fileRefs so the mirror follows the server', function()
      local calls = {}
      local store = { file_top = 'v1\n' }
      bridge.request = fake_bridge(store, calls)
      local entry = project.get_doc_by_path('top.asm')
      local done
      sync.fetch_file(entry, 'proj', function() done = true end)
      assert.is_true(vim.wait(2000, function() return done end))

      store.file_top = 'v2\n'
      done = false
      sync.fetch_file(entry, 'proj', function() done = true end)
      assert.is_true(vim.wait(2000, function() return done end))
      assert.are.equal('v2\n', read_file(tmpdir .. '/Test Project/top.asm'))
      assert.are.equal(2, #calls_of(calls, 'downloadFile'))
    end)

    it('respects editable_files = false', function()
      config.setup({ editable_files = false })
      local calls = {}
      bridge.request = fake_bridge({ file_asm = 'mov eax, 1\n' }, calls)
      local entry = project.get_doc_by_path('src/main.asm')
      local done
      sync.fetch_file(entry, 'proj', function() done = true end)
      assert.is_true(vim.wait(2000, function() return done end))
      assert.is_false(entry.text)
      assert.is_nil(sync._file_watchers[tmpdir .. '/Test Project/src/main.asm'])
    end)
  end)

  describe('disk edit of a text fileRef', function()
    local calls, entry, path

    before_each(function()
      calls = {}
      bridge.request = fake_bridge({ file_asm = 'mov eax, 1\n' }, calls)
      entry = project.get_doc_by_path('src/main.asm')
      local done
      sync.fetch_file(entry, 'proj', function(_, p)
        path = p
        done = true
      end)
      assert.is_true(vim.wait(2000, function() return done end))
    end)

    it('re-uploads the file into its folder and adopts the new id', function()
      write_file(path, 'mov eax, 2\n')
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'uploadFile') > 0 end))

      local up = calls_of(calls, 'uploadFile')[1].params
      assert.are.equal('main.asm', up.fileName)
      assert.are.equal('sub', up.parentFolderId)
      assert.are.equal('proj', up.projectId)
      assert.are.equal('csrf', up.csrfToken)
      assert.are.equal(path, up.filePath)
      assert.are.equal('mov eax, 2\n', calls_of(calls, 'uploaded-bytes')[1].data)

      assert.is_true(vim.wait(2000, function() return entry.id ~= 'file_asm' end))
      assert.are.equal(entry.id, project.get_doc_by_path('src/main.asm').id)
      assert.are.equal('mov eax, 2\n', sync._files['src/main.asm'].content)
    end)

    it('uploads a revert to the originally mirrored bytes', function()
      write_file(path, 'mov eax, 2\n')
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'uploadFile') > 0 end))
      write_file(path, 'mov eax, 1\n') -- back to what fetch_file wrote: still a real change
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'uploadFile') > 1 end))
      assert.are.equal('mov eax, 1\n', calls_of(calls, 'uploaded-bytes')[2].data)
    end)

    it('does not resend bytes a direct upload already has in flight (a :w in Neovim)', function()
      local held = { hold_uploads = true }
      bridge.request = fake_bridge({ file_asm = 'mov eax, 1\n' }, calls, held)
      write_file(path, 'mov eax, 7\n') -- what BufWritePost sees on disk
      local finished
      sync.upload_file(entry, path, nil, function(err)
        assert.is_nil(err)
        finished = true
      end)
      -- the watcher fires for the same write while the upload is still pending
      vim.wait(1500, function() return false end)
      assert.are.equal(1, #calls_of(calls, 'uploadFile'))
      held.held[1]()
      assert.is_true(vim.wait(1000, function() return finished end))
      vim.wait(800, function() return false end)
      assert.are.equal(1, #calls_of(calls, 'uploadFile'))
      assert.are.equal('mov eax, 7\n', sync._files['src/main.asm'].content)
    end)

    it('does not upload our own mirror write or unchanged content', function()
      write_file(path, 'mov eax, 1\n') -- same bytes: touch only
      vim.wait(1500, function() return false end)
      assert.are.equal(0, #calls_of(calls, 'uploadFile'))
    end)

    it('ignores a truncated (empty) read', function()
      write_file(path, '')
      vim.wait(1500, function() return false end)
      assert.are.equal(0, #calls_of(calls, 'uploadFile'))
    end)

    it('keeps working after the file is replaced by rename', function()
      -- Many editors and tools save via temp file + rename, which swaps the inode
      local tmp = path .. '.new'
      write_file(tmp, 'mov eax, 3\n')
      assert.is_true(os.rename(tmp, path))
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'uploadFile') > 0 end))
      assert.are.equal('mov eax, 3\n', calls_of(calls, 'uploaded-bytes')[1].data)

      -- and again, proving the watcher was re-armed on the new inode
      local tmp2 = path .. '.new'
      write_file(tmp2, 'mov eax, 4\n')
      assert.is_true(os.rename(tmp2, path))
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'uploadFile') > 1 end))
      assert.are.equal('mov eax, 4\n', calls_of(calls, 'uploaded-bytes')[2].data)
    end)

    it('stops after forget_file', function()
      sync.forget_file(entry)
      write_file(path, 'mov eax, 9\n')
      vim.wait(1500, function() return false end)
      assert.are.equal(0, #calls_of(calls, 'uploadFile'))
    end)

    it('follows a rename', function()
      local updated = project.rename_entry(entry.id, 'boot.asm')
      sync.rename_file('src/main.asm', updated)
      local new_path = tmpdir .. '/Test Project/src/boot.asm'
      assert.are.equal('mov eax, 1\n', read_file(new_path))
      assert.is_nil(sync._files['src/main.asm'])

      write_file(new_path, 'mov eax, 5\n')
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'uploadFile') > 0 end))
      assert.are.equal('boot.asm', calls_of(calls, 'uploadFile')[1].params.fileName)
    end)

    it('import_all uploads a fileRef whose disk copy changed', function()
      sync._stop_file_watcher(path) -- pretend the watcher missed it
      write_file(path, 'mov eax, 6\n')
      sync.import_all(require('overleaf')._state)
      assert.is_true(vim.wait(2000, function() return #calls_of(calls, 'uploadFile') > 0 end))
      assert.are.equal('mov eax, 6\n', calls_of(calls, 'uploaded-bytes')[1].data)
    end)

    it('export_all restores the last known content to disk', function()
      sync._stop_file_watcher(path)
      write_file(path, 'scribbles')
      sync.export_all(require('overleaf')._state)
      assert.are.equal('mov eax, 1\n', read_file(path))
    end)
  end)

  describe('disk edit of a closed doc', function()
    it('is sent to Overleaf as a delete-all/insert-all OT op', function()
      local calls = {}
      bridge.request = fake_bridge({}, calls, { doc_lines = { 'old' }, doc_version = 7 })
      local doc = Document.new('doc_main', 'main.tex')
      doc.content = 'old'
      doc.server_content = 'old'
      doc.version = 7
      sync.write_doc(doc)
      sync.watch(doc)
      local path = tmpdir .. '/Test Project/main.tex'
      assert.are.equal('old', read_file(path))

      write_file(path, 'new text')
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'applyOtUpdate') > 0 end))

      local update = calls_of(calls, 'applyOtUpdate')[1].params
      assert.are.equal('doc_main', update.docId)
      assert.are.equal(7, update.v)
      assert.are.same({ { p = 0, d = 'old' }, { p = 0, i = 'new text' } }, update.op)
      assert.are.equal('new text', doc.content)
      assert.are.equal(1, #calls_of(calls, 'leaveDoc'))
    end)

    it('sends a revert to the originally written bytes', function()
      local calls = {}
      bridge.request = fake_bridge({}, calls, { doc_lines = { 'old' }, doc_version = 7 })
      local doc = Document.new('doc_main', 'main.tex')
      doc.content = 'old'
      doc.server_content = 'old'
      doc.version = 7
      sync.write_doc(doc)
      sync.watch(doc)
      local path = tmpdir .. '/Test Project/main.tex'

      write_file(path, 'new text')
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'applyOtUpdate') > 0 end))

      write_file(path, 'old') -- the bytes write_doc originally wrote: a real change now
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'applyOtUpdate') > 1 end))
      assert.are.same(
        { { p = 0, d = 'new text' }, { p = 0, i = 'old' } },
        calls_of(calls, 'applyOtUpdate')[2].params.op
      )
    end)
  end)
end)
