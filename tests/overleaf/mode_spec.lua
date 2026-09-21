-- Editing / suggesting / viewing. The rules that matter: a mode the server would
-- reject is never offered, an edit goes out under the mode it was typed in, and
-- viewing sends nothing -- not from the buffer and not from the disk mirror.
local config = require('overleaf.config')
local mode = require('overleaf.mode')
local bridge = require('overleaf.bridge')
local sync = require('overleaf.sync')
local project = require('overleaf.project')
local buffer = require('overleaf.buffer')
local Document = require('overleaf.document')
local overleaf = require('overleaf')

local function write_file(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

local function calls_of(calls, method)
  local out = {}
  for _, c in ipairs(calls) do
    if c.method == method then table.insert(out, c) end
  end
  return out
end

describe('mode policy', function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config._config)
    config.setup({ log_level = 'error', mode = 'auto' })
    mode.reset()
  end)

  after_each(function()
    mode.reset()
    mode._listeners = {}
    config._config = original_config
    -- Listeners registered by init.lua at load time were just cleared.
    mode.on_change(function() overleaf._apply_mode_to_buffers() end)
  end)

  describe('what each access level may do', function()
    it('lets an owner use every mode and starts in editing', function()
      mode.init('owner', {}, 'u1')
      assert.are.equal('editing', mode.get())
      assert.are.same({ 'editing', 'suggesting', 'viewing' }, mode.allowed())
    end)

    it('lets a read/write collaborator use every mode', function()
      mode.init('readAndWrite', false, 'u1')
      assert.are.equal('editing', mode.get())
      assert.is_true(mode.is_allowed('suggesting'))
    end)

    it('starts a reviewer in suggesting, since the server rejects their plain edits', function()
      mode.init('review', false, 'u1')
      assert.are.equal('suggesting', mode.get())
      assert.is_false(mode.is_allowed('editing'))
      local ok, err = mode.set('editing')
      assert.is_false(ok)
      assert.is_truthy(err:find('review', 1, true))
    end)

    it('starts a read-only collaborator in viewing and offers nothing else', function()
      mode.init('readOnly', false, 'u1')
      assert.are.equal('viewing', mode.get())
      assert.are.same({ 'viewing' }, mode.allowed())
      assert.is_false((mode.set('suggesting')))
    end)

    it('treats an unknown access level as unrestricted rather than locking the user out', function()
      mode.init('somethingNew', false, 'u1')
      assert.are.equal('editing', mode.get())
    end)
  end)

  describe('when the project forces tracking on', function()
    it('binds a collaborator to suggesting', function()
      mode.init('readAndWrite', { u1 = true }, 'u1')
      assert.are.equal('suggesting', mode.get())
      local ok, err = mode.set('editing')
      assert.is_false(ok)
      assert.is_truthy(err:find('Track changes', 1, true))
      assert.is_true((mode.set('viewing')))
    end)

    it('binds everyone when the state is a plain boolean', function()
      mode.init('readAndWrite', true, 'u1')
      assert.are.equal('suggesting', mode.get())
      assert.is_false(mode.is_allowed('editing'))
    end)

    it('ignores tracking that is on for somebody else', function()
      mode.init('readAndWrite', { other = true }, 'u1')
      assert.are.equal('editing', mode.get())
    end)

    it('starts an owner in suggesting but does not bind them', function()
      mode.init('owner', { u1 = true }, 'u1')
      assert.are.equal('suggesting', mode.get())
      assert.is_true((mode.set('editing')))
    end)
  end)

  describe('the configured mode', function()
    it('is used when it is allowed', function()
      config.setup({ mode = 'suggesting' })
      mode.init('owner', {}, 'u1')
      assert.are.equal('suggesting', mode.get())
    end)

    it('falls back to the nearest allowed mode when it is not', function()
      config.setup({ mode = 'editing' })
      mode.init('review', false, 'u1')
      assert.are.equal('suggesting', mode.get())
    end)
  end)

  describe('switching', function()
    before_each(function() mode.init('owner', {}, 'u1') end)

    it('rejects a mode that does not exist', function()
      local ok, err = mode.set('proofreading')
      assert.is_false(ok)
      assert.is_truthy(err:find('Unknown mode', 1, true))
      assert.are.equal('editing', mode.get())
    end)

    it('tells listeners the new and the old mode, and only on a real change', function()
      local seen = {}
      mode.on_change(function(new, old) table.insert(seen, { new, old }) end)

      mode.set('suggesting')
      mode.set('suggesting')
      mode.set('viewing')

      assert.are.same({ { 'suggesting', 'editing' }, { 'viewing', 'suggesting' } }, seen)
    end)

    it('returns to editing on reset', function()
      mode.set('viewing')
      mode.reset()
      assert.are.equal('editing', mode.get())
    end)
  end)

  describe('what each mode permits', function()
    before_each(function() mode.init('owner', {}, 'u1') end)

    it('editing writes everything outright', function()
      assert.is_false(mode.tracked())
      assert.is_true(mode.writable())
      assert.is_true(mode.can_replace_files())
    end)

    it('suggesting tracks text but cannot replace a whole file', function()
      mode.set('suggesting')
      assert.is_true(mode.tracked())
      assert.is_true(mode.writable())
      assert.is_false(mode.can_replace_files())
    end)

    it('viewing writes nothing', function()
      mode.set('viewing')
      assert.is_false(mode.tracked())
      assert.is_false(mode.writable())
      assert.is_false(mode.can_replace_files())
    end)
  end)
end)

describe('mode in use', function()
  local original_config, original_request, original_state
  local tmpdir, calls

  --- A bridge that answers joins and acknowledges every update, recording all calls.
  local function install_bridge(doc_text)
    calls = {}
    local content = doc_text or ''
    bridge.request = function(method, params, callback)
      table.insert(calls, { method = method, params = params })
      if method == 'joinDoc' then
        return callback(nil, { lines = vim.split(content, '\n', { plain = true }), version = 3, ranges = {} })
      elseif method == 'applyOtUpdate' or method == 'leaveDoc' then
        return callback(nil, {})
      elseif method == 'uploadFile' then
        return callback(nil, { success = true, entity_id = 'new_id', entity_type = 'file' })
      end
      return callback(nil, {})
    end
  end

  before_each(function()
    original_config = vim.deepcopy(config._config)
    original_request = bridge.request
    original_state = overleaf._state
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    config.setup({ sync_dir = tmpdir, log_level = 'error', mode = 'auto' })
    project.parse_project_tree({
      rootFolder = {
        {
          _id = 'root',
          name = 'rootFolder',
          docs = { { _id = 'doc_main', name = 'main.tex' } },
          fileRefs = { { _id = 'file_top', name = 'top.asm' } },
          folders = {},
        },
      },
    })
    overleaf._state = { connected = true, project_id = 'proj', csrf_token = 'csrf', documents = {} }
    mode.reset()
    mode.init('owner', {}, 'u1')
    sync.start('Test Project')
  end)

  after_each(function()
    sync.stop()
    mode.reset()
    bridge.request = original_request
    overleaf._state = original_state
    config._config = original_config
    vim.fn.delete(tmpdir, 'rf')
  end)

  describe('the update sent to Overleaf', function()
    --- A joined document with one op queued, ready to flush.
    local function queued_doc()
      local doc = Document.new('doc_main', 'main.tex')
      doc.joined = true
      doc.version = 3
      doc.content = ''
      doc.server_content = ''
      doc.pending_ops = { { p = 0, i = 'hello' } }
      doc.check_content = function() return true end
      return doc
    end

    it('is a plain edit in editing mode', function()
      install_bridge()
      queued_doc():flush()
      assert.are.equal(false, calls_of(calls, 'applyOtUpdate')[1].params.tracked)
    end)

    it('is a suggestion in suggesting mode', function()
      install_bridge()
      mode.set('suggesting')
      queued_doc():flush()
      assert.are.equal(true, calls_of(calls, 'applyOtUpdate')[1].params.tracked)
    end)

    it('goes out under the mode it was typed in when the mode changes right after', function()
      install_bridge()
      local doc = queued_doc()
      overleaf._state.documents = { doc_main = doc }

      assert.is_true(overleaf.set_mode('suggesting'))

      local updates = calls_of(calls, 'applyOtUpdate')
      assert.are.equal(1, #updates)
      assert.are.equal(false, updates[1].params.tracked, 'typed while editing, so not a suggestion')
      assert.are.equal('suggesting', mode.get())
      assert.is_nil(doc.pending_ops)
    end)
  end)

  describe('a disk edit to a document that is not open', function()
    local doc, path

    before_each(function()
      install_bridge('old text')
      doc = Document.new('doc_main', 'main.tex')
      doc.content = 'old text'
      doc.server_content = 'old text'
      doc.version = 3
      sync.write_doc(doc)
      sync.watch(doc)
      path = tmpdir .. '/Test Project/main.tex'
    end)

    it('is sent as a suggestion in suggesting mode', function()
      mode.set('suggesting')
      write_file(path, 'new text')
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'applyOtUpdate') > 0 end))
      assert.are.equal(true, calls_of(calls, 'applyOtUpdate')[1].params.tracked)
    end)

    it('is not sent in viewing mode, and is left on disk untouched', function()
      mode.set('viewing')
      write_file(path, 'new text')
      vim.wait(1500, function() return #calls_of(calls, 'applyOtUpdate') > 0 end)

      assert.are.equal(0, #calls_of(calls, 'applyOtUpdate'))
      assert.are.equal('new text', io.open(path, 'rb'):read('*a'))
      assert.are.equal(1, sync.held_count())
    end)

    it('is sent by :Overleaf sync import once viewing is over', function()
      mode.set('viewing')
      write_file(path, 'new text')
      vim.wait(1000, function() return sync.held_count() > 0 end)
      assert.are.equal(0, #calls_of(calls, 'applyOtUpdate'))

      mode.set('editing')
      sync.import_all({ documents = { doc_main = doc } })
      assert.is_true(vim.wait(5000, function() return #calls_of(calls, 'applyOtUpdate') > 0 end))
    end)

    it('is refused by import in viewing mode', function()
      mode.set('viewing')
      write_file(path, 'new text')
      sync.import_all({ documents = { doc_main = doc } })
      vim.wait(300)
      assert.are.equal(0, #calls_of(calls, 'applyOtUpdate'))
    end)
  end)

  describe('replacing a whole file on Overleaf', function()
    local entry

    before_each(function()
      install_bridge()
      entry = project.get_doc_by_path('top.asm')
      write_file(tmpdir .. '/top.asm', 'mov eax, 1\n')
    end)

    it('goes through in editing mode', function()
      local err
      sync.upload_file(entry, tmpdir .. '/top.asm', nil, function(e) err = e end)
      assert.is_nil(err)
      assert.are.equal(1, #calls_of(calls, 'uploadFile'))
    end)

    it('is refused in suggesting mode, because it cannot be a suggestion', function()
      mode.set('suggesting')
      local err
      sync.upload_file(entry, tmpdir .. '/top.asm', nil, function(e) err = e end)
      assert.are.equal('MODE', err.code)
      assert.are.equal(0, #calls_of(calls, 'uploadFile'))
    end)

    it('is refused in viewing mode', function()
      mode.set('viewing')
      local err
      sync.upload_file(entry, tmpdir .. '/top.asm', nil, function(e) err = e end)
      assert.are.equal('MODE', err.code)
      assert.are.equal(0, #calls_of(calls, 'uploadFile'))
    end)
  end)

  describe('the buffer', function()
    local doc, bufnr

    before_each(function()
      install_bridge()
      doc = Document.new('doc_main', 'main.tex')
      doc.joined = true
      doc.content = 'one\ntwo'
      doc.server_content = 'one\ntwo'
      doc.version = 1
      bufnr = buffer.create(doc, { 'one', 'two' })
      doc.bufnr = bufnr
      overleaf._state.documents = { doc_main = doc }
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end)

    it('is read-only in viewing mode and writable again after', function()
      assert.is_true(vim.bo[bufnr].modifiable)

      assert.is_true(overleaf.set_mode('viewing'))
      assert.is_false(vim.bo[bufnr].modifiable)
      assert.is_false(pcall(vim.api.nvim_buf_set_lines, bufnr, 0, 1, false, { 'typed' }))

      assert.is_true(overleaf.set_mode('editing'))
      assert.is_true(vim.bo[bufnr].modifiable)
    end)

    it('still takes edits from other collaborators while read-only', function()
      overleaf.set_mode('viewing')

      buffer.apply_remote(doc, { { p = 3, i = ' and more' } })
      vim.wait(200, function() return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= 'one' end)

      assert.are.equal('one and more', vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
      assert.is_false(vim.bo[bufnr].modifiable, 'must be locked again after the remote edit')
    end)

    it('unlocked() restores the previous state even when the write fails', function()
      vim.bo[bufnr].modifiable = false
      local ok = pcall(buffer.unlocked, bufnr, function() error('boom') end)
      assert.is_false(ok)
      assert.is_false(vim.bo[bufnr].modifiable)
    end)
  end)

  describe('changes to the project structure', function()
    it('are refused in viewing mode', function()
      install_bridge()
      overleaf.set_mode('viewing')

      overleaf.create_doc('new.tex')
      overleaf.create_folder('figs')
      overleaf.delete_entity()
      overleaf.rename_entity()

      assert.are.equal(0, #calls_of(calls, 'createDoc'))
      assert.are.equal(0, #calls_of(calls, 'createFolder'))
      assert.are.equal(0, #calls_of(calls, 'deleteEntity'))
      assert.are.equal(0, #calls_of(calls, 'renameEntity'))
    end)
  end)

  describe('switching', function()
    it('needs a connection', function()
      overleaf._state.connected = false
      assert.is_false(overleaf.set_mode('viewing'))
      assert.are.equal('editing', mode.get())
    end)

    it('refuses a mode the access level does not allow', function()
      mode.reset()
      mode.init('review', false, 'u1')
      assert.is_false(overleaf.set_mode('editing'))
      assert.are.equal('suggesting', mode.get())
    end)

    it('shows the mode in the statusline, unless it is the default', function()
      overleaf._state.project_name = 'Thesis'
      assert.are.equal('OL: Thesis', overleaf.statusline())

      mode.set('suggesting')
      assert.are.equal('OL: Thesis [suggesting]', overleaf.statusline())

      mode.set('viewing')
      assert.are.equal('OL: Thesis [viewing]', overleaf.statusline())

      overleaf._state.connected = false
      assert.are.equal('', overleaf.statusline())
    end)
  end)
end)
