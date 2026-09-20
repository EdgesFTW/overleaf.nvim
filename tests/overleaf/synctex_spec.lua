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
      callback(
        nil,
        {
          pdf = {
            { page = 2, h = 133.76, v = 191.0, width = 343.71, height = 45.19 },
            { page = 2, h = 133.76, v = 240.0, width = 100.0, height = 10.0 },
            { page = 3, h = 10.0, v = 20.0, width = 5.0, height = 5.0 },
          },
        }
      )
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
