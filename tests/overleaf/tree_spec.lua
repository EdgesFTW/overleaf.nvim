local config = require('overleaf.config')
local project = require('overleaf.project')
local tree = require('overleaf.tree')
local ol = require('overleaf')

local function entry(id, name, path, kind) return { id = id, name = name, path = path, type = kind, depth = 99 } end

local function paths(rows)
  local result = {}
  for _, row in ipairs(rows) do
    table.insert(result, row.entry.path)
  end
  return result
end

describe('file tree order', function()
  local saved

  before_each(function()
    saved = {
      config = vim.deepcopy(config._config),
      entries = project._project_tree,
      buf = tree._bufnr,
      win = tree._tree_winnr,
      rows = tree._rows,
      root_doc_id = ol._state.root_doc_id,
      open_document = ol.open_document,
      focus_editor = tree._focus_editor,
      select = vim.ui.select,
    }
    config.setup({ tree_sort = 'name' })
    project._project_tree = {}
    tree._bufnr = nil
    tree._rows = {}
    tree._tree_winnr = vim.api.nvim_get_current_win()
    ol._state.root_doc_id = nil
  end)

  after_each(function()
    if tree._bufnr and vim.api.nvim_buf_is_valid(tree._bufnr) then
      if vim.api.nvim_win_get_buf(0) == tree._bufnr then vim.cmd('enew') end
      vim.api.nvim_buf_delete(tree._bufnr, { force = true })
    end
    config._config = saved.config
    project._project_tree = saved.entries
    tree._bufnr = saved.buf
    tree._tree_winnr = saved.win
    tree._rows = saved.rows
    ol._state.root_doc_id = saved.root_doc_id
    ol.open_document = saved.open_document
    tree._focus_editor = saved.focus_editor
    vim.ui.select = saved.select
  end)

  it('sorts folders first, naturally, with docs and files interleaved', function()
    project._project_tree = {
      entry('fig10', 'fig10.tex', 'fig10.tex', 'doc'),
      entry('fig2', 'fig2.png', 'fig2.png', 'file'),
      entry('file', '01-intro.c', '01-intro.c', 'file'),
      entry('appendix', '10-appendix.tex', '10-appendix.tex', 'doc'),
      entry('z', 'zeta', 'zeta/', 'folder'),
      entry('a', 'Alpha', 'Alpha/', 'folder'),
    }
    assert.same(
      { 'Alpha/', 'zeta/', '01-intro.c', '10-appendix.tex', 'fig2.png', 'fig10.tex' },
      paths(project.display_rows())
    )
  end)

  it('breaks equal numeric values by shorter digit run and case ties by upper first', function()
    project._project_tree = {
      entry('ab', 'alpha.tex', 'alpha.tex', 'doc'),
      entry('n2', 'fig02.tex', 'fig02.tex', 'doc'),
      entry('n1', 'fig2.tex', 'fig2.tex', 'doc'),
      entry('ac', 'Alpha.tex', 'Alpha.tex', 'doc'),
      entry('mixed', 'aLpha.tex', 'aLpha.tex', 'doc'),
      entry('n3', 'fig002.tex', 'fig002.tex', 'doc'),
    }
    assert.same(
      { 'Alpha.tex', 'aLpha.tex', 'alpha.tex', 'fig2.tex', 'fig02.tex', 'fig002.tex' },
      paths(project.display_rows())
    )
  end)

  it('builds nested hierarchy from paths and places appended children inside it', function()
    project._project_tree = {
      entry('top', 'top.tex', 'top.tex', 'doc'),
      entry('deep', 'deep', 'chapter/deep/', 'folder'),
      entry('chapter', 'chapter', 'chapter/', 'folder'),
      entry('old', 'old.tex', 'chapter/old.tex', 'doc'),
    }
    project.add_entry(entry('new', 'new.tex', 'chapter/deep/new.tex', 'doc'))
    local rows = project.display_rows()
    assert.same({ 'chapter/', 'chapter/deep/', 'chapter/deep/new.tex', 'chapter/old.tex', 'top.tex' }, paths(rows))
    assert.same({ 0, 1, 2, 1, 0 }, vim.tbl_map(function(row) return row.depth end, rows))
    tree._ensure_buffer()
    vim.api.nvim_win_set_buf(tree._tree_winnr, tree._bufnr)
    tree.refresh()
    assert.same(
      { '  chapter/', '    deep/', '      new.tex', '    old.tex', '  top.tex' },
      vim.api.nvim_buf_get_lines(tree._bufnr, 0, -1, false)
    )
  end)

  it('keeps the cursor on the renamed entry and opens that visible row', function()
    project._project_tree = {
      entry('b', 'beta.tex', 'beta.tex', 'doc'),
      entry('a', 'alpha.tex', 'alpha.tex', 'doc'),
    }
    tree._ensure_buffer()
    vim.api.nvim_win_set_buf(tree._tree_winnr, tree._bufnr)
    tree.refresh()
    vim.api.nvim_win_set_cursor(tree._tree_winnr, { 1, 0 })
    project.rename_entry('a', 'zeta.tex')
    tree.refresh()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(tree._tree_winnr)[1])
    assert.are.equal('a', tree._rows[2].entry.id)
    local opened
    tree._focus_editor = function() end
    ol.open_document = function(id) opened = id end
    tree._on_enter()
    assert.are.equal('a', opened)
  end)

  it('keeps sibling storage order in overleaf mode', function()
    config.setup({ tree_sort = 'overleaf' })
    project._project_tree = {
      entry('z', 'zeta', 'zeta/', 'folder'),
      entry('zd', 'z.tex', 'zeta/z.tex', 'doc'),
      entry('a', 'alpha', 'alpha/', 'folder'),
      entry('b', 'b.tex', 'b.tex', 'doc'),
      entry('f', 'a.png', 'a.png', 'file'),
    }
    assert.same({ 'zeta/', 'zeta/z.tex', 'alpha/', 'b.tex', 'a.png' }, paths(project.display_rows()))
  end)

  it('marks the main document subtly and orders the document picker like the tree', function()
    project._project_tree = {
      entry('z', 'z.tex', 'z.tex', 'doc'),
      entry('f', 'a.png', 'a.png', 'file'),
      entry('a', 'a.tex', 'a.tex', 'doc'),
    }
    ol._state.root_doc_id = 'z'
    tree._ensure_buffer()
    vim.api.nvim_win_set_buf(tree._tree_winnr, tree._bufnr)
    tree.refresh()
    assert.same({ '  a.png', '  a.tex', '  z.tex *' }, vim.api.nvim_buf_get_lines(tree._bufnr, 0, -1, false))
    vim.ui.select = function(items, _, callback)
      assert.same({ 'a.png', 'a.tex', 'z.tex' }, vim.tbl_map(function(item) return item.path end, items))
      callback(items[2])
    end
    local selected
    project.select_document(function(id) selected = id end)
    assert.are.equal('a', selected)
  end)

  it('rejects unsupported sort options', function()
    assert.are.equal('name', saved.config.tree_sort)
    assert.has_error(function()
      config.setup({ tree_sort = function() end })
    end)
    assert.has_error(function() config.setup({ tree_sort = 'unknown' }) end)
    assert.are.equal('name', config.get().tree_sort)
  end)
end)
