local config = require('overleaf.config')
local sync = require('overleaf.sync')
local buffer = require('overleaf.buffer')
local mode = require('overleaf.mode')

local function read_file(path)
  local f = assert(io.open(path, 'rb'))
  local data = f:read('*a')
  f:close()
  return data
end

local function write_file(path, content)
  local f = assert(io.open(path, 'wb'))
  f:write(content)
  f:close()
end

local function replace_file(path, content)
  local tmp = path .. '.new'
  write_file(tmp, content)
  assert.is_true(os.rename(tmp, path))
end

describe('document disk watcher', function()
  local tmpdir, path, doc
  local original_changed, original_closed, original_replace, original_log, original_mode

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    sync._sync_dir = tmpdir
    path = tmpdir .. '/main.tex'
    doc = { doc_id = 'doc_main', path = 'main.tex', content = 'original' }
    original_changed = sync._on_file_changed
    original_closed = sync._sync_closed_doc
    original_replace = buffer.replace_content
    original_log = config.log
    original_mode = mode._mode
  end)

  after_each(function()
    sync.stop()
    sync._on_file_changed = original_changed
    sync._sync_closed_doc = original_closed
    buffer.replace_content = original_replace
    config.log = original_log
    mode._mode = original_mode
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.api.nvim_buf_delete(doc.bufnr, { force = true }) end
    vim.fn.delete(tmpdir, 'rf')
  end)

  it('sees two rename-replaces followed by an in-place write', function()
    local changed = {}
    sync._sync_closed_doc = function(closed_doc, content) closed_doc.content = content end
    sync._on_file_changed = function(changed_path, changed_doc)
      table.insert(changed, read_file(changed_path))
      original_changed(changed_path, changed_doc)
    end
    sync.write_doc(doc)
    sync.watch(doc)

    replace_file(path, 'first')
    assert.is_true(vim.wait(5000, function() return #changed == 1 end))
    replace_file(path, 'second')
    assert.is_true(vim.wait(5000, function() return #changed == 2 end))
    write_file(path, 'third')
    assert.is_true(vim.wait(5000, function() return #changed == 3 end))
    assert.are.same({ 'first', 'second', 'third' }, changed)
  end)

  it('keeps a second external write that arrives before the debounced write', function()
    doc = require('overleaf.document').new('doc_main', 'main.tex')
    doc.joined, doc.version, doc.content, doc.server_content = true, 0, 'original', 'original'
    doc._schedule_flush = function() end
    doc.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, { doc.content })
    sync.write_doc(doc)
    sync.watch(doc)

    write_file(path, 'first')
    assert.is_true(vim.wait(5000, function() return doc.content == 'first' end))
    -- Simulate an fs_event lost while the first change's write is pending.
    sync.unwatch(doc)
    write_file(path, 'second')
    assert.is_true(vim.wait(5000, function() return doc.content == 'second' end))
    assert.are.same({ 'second' }, vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false))
    assert.are.equal('second', read_file(path))
    assert.is_true(vim.wait(5000, function() return sync._write_timers[doc.doc_id] == nil end))
    assert.are.equal('second', read_file(path))
  end)

  it('warns once and stops watching after deletion', function()
    local warnings = {}
    config.log = function(level, message, ...)
      if level == 'warn' then table.insert(warnings, string.format(message, ...)) end
    end
    sync.write_doc(doc)
    sync.watch(doc)

    assert.is_true(os.remove(path))
    assert.is_true(vim.wait(5000, function() return #warnings == 1 end))
    assert.are.equal('main.tex was deleted on disk; it is not deleted on Overleaf', warnings[1])
    assert.is_nil(sync._watchers[path])
    vim.wait(350, function() return false end)
    assert.are.equal(1, #warnings)
  end)

  it('writes on the first write even if a file already exists', function()
    write_file(path, 'external')
    assert.is_nil(sync._last_written[path])
    sync.write_doc(doc)
    assert.are.equal('original', read_file(path))
    assert.are.equal('original', sync._last_written[path])
  end)

  it('holds an unprocessed disk edit in viewing mode', function()
    sync.write_doc(doc)
    write_file(path, 'external')
    mode._mode = mode.VIEWING
    sync.write_doc(doc)
    assert.are.equal('external', read_file(path))
    assert.is_true(sync._held[path])
  end)
end)
