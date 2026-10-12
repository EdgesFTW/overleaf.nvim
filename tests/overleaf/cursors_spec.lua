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
end)
