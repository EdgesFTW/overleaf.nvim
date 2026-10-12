local ot = require('overleaf.ot')
local buffer = require('overleaf.buffer')
local Document = require('overleaf.document')

local FFFD = '\239\191\189'

describe('sanitize_inserts', function()
  it('rewrites astral characters as two U+FFFD, like Overleaf stores them', function()
    local ops, changed = ot.sanitize_inserts({ { p = 1, i = 'x😀y𝔸' }, { p = 0, d = '😀' } })
    assert.is_true(changed)
    assert.are.equal('x' .. FFFD .. FFFD .. 'y' .. FFFD .. FFFD, ops[1].i)
    assert.are.equal(ot.u16_len('x😀y𝔸'), ot.u16_len(ops[1].i))
    assert.are.equal('😀', ops[2].d, 'deletes must keep the text they delete')
  end)

  it('leaves BMP text alone', function()
    local ops = { { p = 0, i = 'é日本 δ' } }
    local out, changed = ot.sanitize_inserts(ops)
    assert.is_false(changed)
    assert.are.equal('é日本 δ', out[1].i)
  end)

  it('shows the stored text in the buffer and sends the sanitized op', function()
    local doc = Document.new('sanitize', 'sanitize.tex')
    doc.joined, doc.version, doc.content, doc.server_content = true, 1, 'ab', 'ab'
    local sent
    doc.submit_op = function(_, ops) sent = ops end
    doc.bufnr = vim.api.nvim_create_buf(true, false)
    vim.bo[doc.bufnr].swapfile = false
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, { 'ab' })
    buffer.attach(doc.bufnr, doc)

    vim.api.nvim_buf_set_text(doc.bufnr, 0, 1, 0, 1, { '😀' })
    buffer.reconcile(doc)

    local stored = 'a' .. FFFD .. FFFD .. 'b'
    assert.are.same({ { p = 1, i = FFFD .. FFFD } }, sent)
    assert.are.equal(stored, doc.content)
    assert.are.same({ stored }, vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false))
    -- The correction must not be read back as a new local edit.
    buffer.reconcile(doc)
    assert.are.equal(stored, doc.content)
    vim.api.nvim_buf_delete(doc.bufnr, { force = true })
  end)
end)
