-- Forward search: cursor position -> Overleaf's SyncTeX lookup -> viewer jump.
local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local viewer = require('overleaf.viewer')
local overleaf = require('overleaf')

describe('forward search', function()
  local original_request, original_show, original_config
  local requests, shows, logs

  before_each(function()
    original_request = bridge.request
    original_show = viewer.show
    original_config = vim.deepcopy(config._config)

    requests, shows, logs = {}, {}, {}
    bridge.request = function(method, params, callback)
      table.insert(requests, { method = method, params = params })
      callback(nil, {
        pdf = {
          { page = 2, h = 133.76, v = 191.0, width = 343.71, height = 45.19 },
          { page = 2, h = 133.76, v = 240.0, width = 100.0, height = 10.0 },
          { page = 3, h = 10.0, v = 20.0, width = 5.0, height = 5.0 },
        },
      })
    end
    viewer.show = function(pdf_path, page, rects, pid)
      table.insert(shows, { pdf_path = pdf_path, page = page, rects = rects, pid = pid })
      return true, nil
    end

    overleaf._state.connected = true
    overleaf._state.project_id = 'proj1'
    overleaf._state.documents = {}
    overleaf._state.build_id = 'build-1'
    overleaf._state.clsi_server_id = 'clsi-1'
    overleaf._state.pdf_path = '/tmp/out.pdf'
    overleaf._state.pdf_pid = 4321
  end)

  after_each(function()
    -- Drain any scheduled viewer call so it cannot land inside the next test.
    vim.wait(30)
    bridge.request = original_request
    viewer.show = original_show
    config._config = original_config
    overleaf._state.connected = false
    overleaf._state.documents = {}
    overleaf._state.build_id = nil
  end)

  --- A buffer standing in for an open Overleaf document at `path`.
  local function doc_buffer(path, lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { 'one line', 'two line', 'three line', 'four line' })
    overleaf._state.documents['doc1'] = { path = path, bufnr = bufnr }
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  it('asks about the path and cursor position of the current document', function()
    doc_buffer('chapters/intro.tex')
    vim.api.nvim_win_set_cursor(0, { 3, 4 })

    overleaf.forward_search()

    assert.are.equal(1, #requests)
    assert.are.equal('syncCode', requests[1].method)
    local p = requests[1].params
    assert.are.equal('chapters/intro.tex', p.file)
    assert.are.equal(3, p.line)
    assert.are.equal(5, p.column) -- cursor columns are 0-based, SyncTeX's are not
    assert.are.equal('build-1', p.buildId)
    assert.are.equal('clsi-1', p.clsiServerId)
  end)

  it('turns SyncTeX baselines into boxes on a single page', function()
    doc_buffer('main.tex')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    overleaf.forward_search()
    vim.wait(50, function() return #shows > 0 end)

    assert.are.equal(1, #shows)
    assert.are.equal('/tmp/out.pdf', shows[1].pdf_path)
    assert.are.equal(2, shows[1].page)
    assert.are.equal(4321, shows[1].pid)

    -- Only the hits on the first hit's page, and each box grows up from its
    -- baseline: { h, v - height, h + width, v }.
    assert.are.equal(2, #shows[1].rects)
    local r = shows[1].rects[1]
    assert.is_true(math.abs(r[1] - 133.76) < 0.01)
    assert.is_true(math.abs(r[2] - (191.0 - 45.19)) < 0.01)
    assert.is_true(math.abs(r[3] - (133.76 + 343.71)) < 0.01)
    assert.is_true(math.abs(r[4] - 191.0) < 0.01)
  end)

  it('works from a file opened out of the mirror', function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'xxxxx', 'yyyyy' })
    vim.b[bufnr].overleaf_file = 'src/prog.asm'
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    overleaf.forward_search()

    assert.are.equal('src/prog.asm', requests[1].params.file)
  end)

  it('does nothing for a buffer outside the project', function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)

    overleaf.forward_search()

    assert.are.equal(0, #requests)
    assert.are.equal(0, #shows)
  end)

  it('does not ask before anything has been compiled', function()
    doc_buffer('main.tex')
    overleaf._state.build_id = nil

    overleaf.forward_search()

    assert.are.equal(0, #requests)
  end)

  it('leaves the viewer alone when the line produced no output', function()
    doc_buffer('main.tex')
    bridge.request = function(method, params, callback)
      table.insert(requests, { method = method, params = params })
      callback(nil, { pdf = {} })
    end

    overleaf.forward_search()
    vim.wait(30)

    assert.are.equal(1, #requests)
    assert.are.equal(0, #shows)
  end)

  it('reports a failed lookup without touching the viewer', function()
    doc_buffer('main.tex')
    bridge.request = function(_, _, callback) callback({ message = 'build is gone' }) end

    overleaf.forward_search()
    vim.wait(30)

    assert.are.equal(0, #shows)
  end)
end)

-- Inverse search: a ctrl+click in zathura comes back as an Edit signal naming a
-- path inside the build container, which has to be mapped onto the project.
describe('inverse search', function()
  local overleaf = require('overleaf')
  local viewer = require('overleaf.viewer')

  describe('signal parsing', function()
    it('reads the file, line and column out of a monitor line', function()
      local file, line, column =
        viewer._parse_edit("/org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/./main.tex', uint32 71, uint32 4)")
      assert.are.equal('/compile/./main.tex', file)
      assert.are.equal(71, line)
      assert.are.equal(4, column)
    end)

    it("turns SyncTeX's -1 column into zero", function()
      local _, _, column = viewer._parse_edit(
        "/org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/./main.tex', uint32 71, uint32 4294967295)"
      )
      assert.are.equal(0, column)
    end)

    it('ignores other signals', function()
      assert.is_nil(viewer._parse_edit('/org/pwmt/zathura: org.freedesktop.DBus.NameAcquired (":1.5",)'))
      assert.is_nil(viewer._parse_edit(''))
    end)
  end)

  describe('path mapping', function()
    it('strips the build container prefix', function()
      assert.are.equal('main.tex', overleaf._synctex_source_path('/compile/./main.tex'))
      assert.are.equal('main.tex', overleaf._synctex_source_path('/compile/main.tex'))
    end)

    it('keeps folders', function()
      assert.are.equal('chapters/intro.tex', overleaf._synctex_source_path('/compile/./chapters/intro.tex'))
      assert.are.equal('chapters/intro.tex', overleaf._synctex_source_path('/compile/chapters/./intro.tex'))
    end)

    it('rejects anything outside the project', function()
      assert.is_nil(overleaf._synctex_source_path('/usr/local/texlive/2024/texmf-dist/tex/latex/base/article.cls'))
      assert.is_nil(overleaf._synctex_source_path('/compile/'))
      assert.is_nil(overleaf._synctex_source_path(nil))
    end)
  end)

  describe('jumping', function()
    local bufnr

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 100 do
        lines[i] = 'line ' .. i
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      overleaf._state.documents = { doc1 = { path = 'main.tex', bufnr = bufnr } }
    end)

    after_each(function()
      overleaf._state.documents = {}
      if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end)

    it('moves the cursor to the clicked line of an open document', function()
      overleaf._on_viewer_edit('/compile/./main.tex', 42, 0)
      vim.wait(100, function() return vim.api.nvim_get_current_buf() == bufnr end)

      assert.are.equal(bufnr, vim.api.nvim_get_current_buf())
      assert.are.equal(42, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('clamps a line past the end of the buffer', function()
      overleaf._on_viewer_edit('/compile/./main.tex', 5000, 0)
      vim.wait(100, function() return vim.api.nvim_get_current_buf() == bufnr end)

      assert.are.equal(100, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it('does nothing for a click that lands in a package', function()
      local before = vim.api.nvim_get_current_buf()
      overleaf._on_viewer_edit('/usr/local/texlive/2024/texmf-dist/tex/latex/base/article.cls', 10, 0)
      vim.wait(60)

      assert.are.equal(before, vim.api.nvim_get_current_buf())
    end)
  end)
end)

-- The link between the monitor process and the handler: a line arriving on the
-- job's stdout has to come back out as a jump. There is no zathura to click on
-- here, so the monitor command is swapped for one that prints a canned signal.
describe('inverse search wiring', function()
  local viewer = require('overleaf.viewer')
  local original_command, original_find

  before_each(function()
    original_command = viewer._monitor_command
    original_find = viewer.find
    viewer.find = function() return 'org.pwmt.zathura.PID-1' end
  end)

  after_each(function()
    viewer.stop_watching()
    viewer._monitor_command = original_command
    viewer.find = original_find
  end)

  it('turns a signal on the monitor into an on_edit call', function()
    viewer._monitor_command = function()
      return { 'echo', "/org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/./main.tex', uint32 71, uint32 4294967295)" }
    end

    local seen = {}
    local ok, err = viewer.watch_edits(
      '/tmp/x.pdf',
      nil,
      function(file, line, column) table.insert(seen, { file = file, line = line, column = column }) end
    )
    assert.is_true(ok, tostring(err))

    vim.wait(2000, function() return #seen > 0 end)
    assert.are.equal(1, #seen)
    assert.are.equal('/compile/./main.tex', seen[1].file)
    assert.are.equal(71, seen[1].line)
    assert.are.equal(0, seen[1].column)
  end)

  it('ignores chatter that is not an Edit signal', function()
    viewer._monitor_command = function()
      return { 'echo', '/org/pwmt/zathura: org.freedesktop.DBus.NameAcquired (":1.5",)' }
    end

    local seen = 0
    viewer.watch_edits('/tmp/x.pdf', nil, function() seen = seen + 1 end)
    vim.wait(400)
    assert.are.equal(0, seen)
  end)

  it('refuses to watch when no viewer is showing the pdf', function()
    viewer.find = function() return nil end
    local ok, err = viewer.watch_edits('/tmp/x.pdf', nil, function() end)
    assert.is_false(ok)
    assert.is_truthy(err)
  end)
end)
