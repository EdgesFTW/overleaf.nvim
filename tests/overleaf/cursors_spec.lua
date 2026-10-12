local cursors = require('overleaf.cursors')

describe('collaborator cursor columns', function()
  it('converts a UTF-16 column after an astral character to a byte column', function()
    local state = require('overleaf')._state
    local old = state.documents.cursor_test
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'A😀B' })
    state.documents.cursor_test = { bufnr = buf }

    cursors._render_cursor('cursor_user', {
      doc_id = 'cursor_test',
      row = 0,
      col = 3,
      color_idx = 1,
      name = 'Ada',
    })
    local marks = vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {})
    assert.are.equal(1, #marks)
    assert.are.equal(5, marks[1][3])

    state.documents.cursor_test = old
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('rounds a stale column inside a surrogate pair down instead of raising', function()
    local state = require('overleaf')._state
    local old = state.documents.cursor_test
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a😀x' })
    state.documents.cursor_test = { bufnr = buf }

    cursors._render_cursor('cursor_user', { doc_id = 'cursor_test', row = 0, col = 2, color_idx = 1, name = 'Ada' })
    local marks = vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {})
    assert.are.equal(1, #marks)
    assert.are.equal(1, marks[1][3])

    state.documents.cursor_test = old
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('removes the mark from the old document when a collaborator switches documents', function()
    local state = require('overleaf')._state
    local a = vim.api.nvim_create_buf(true, false)
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { 'first doc' })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'second doc' })
    state.documents.cur_a, state.documents.cur_b = { bufnr = a }, { bufnr = b }

    cursors.on_client_updated({ id = 'mover', name = 'Ada', doc_id = 'cur_a', row = 0, column = 2 })
    cursors.on_client_updated({ id = 'mover', name = 'Ada', doc_id = 'cur_b', row = 0, column = 3 })
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(a, cursors._ns, 0, -1, {}))
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(b, cursors._ns, 0, -1, {}))

    cursors.on_client_disconnected({ id = 'mover' })
    state.documents.cur_a, state.documents.cur_b = nil, nil
    vim.api.nvim_buf_delete(a, { force = true })
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it('highlights the whole multibyte character under the cursor', function()
    local state = require('overleaf')._state
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'aéb' })
    state.documents.cursor_test = { bufnr = buf }
    cursors._render_cursor('cursor_user', { doc_id = 'cursor_test', row = 0, col = 1, color_idx = 1, name = 'Ada' })
    local mark = vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, { details = true })[1]
    assert.are.equal(1, mark[3])
    assert.are.equal(3, mark[4].end_col)
    state.documents.cursor_test = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
