local sent = {}
package.loaded['overleaf.bridge'] = {
  request = function(name, params, callback)
    if name == 'applyOtUpdate' then sent[#sent + 1] = vim.deepcopy(params.op) end
    if callback then callback(nil, {}) end
  end,
}

local ot = require('overleaf.ot')
local buffer = require('overleaf.buffer')
local Document = require('overleaf.document')
local history = require('overleaf.history')

local serial = 0
local function setup(content)
  serial = serial + 1
  local doc = Document.new('history-' .. serial, '/history-' .. serial .. '.unknown')
  doc.joined = true
  doc.version = 0
  doc.content = content
  doc.server_content = content
  doc._stopped = true
  buffer.create(doc, vim.split(content, '\n', { plain = true }))
  return doc
end

local function cleanup(doc)
  if doc._flush_timer then vim.fn.timer_stop(doc._flush_timer) end
  if doc._ack_timer then vim.fn.timer_stop(doc._ack_timer) end
  buffer.cleanup(doc)
end

local function keys(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), 'x', false)
  vim.wait(50, function() return false end)
end

local function text(doc) return table.concat(vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false), '\n') end

local function remote(doc, ops)
  buffer.reconcile(doc)
  doc:on_remote_op({ v = doc.version, op = ops }, function(applied) buffer.apply_remote(doc, applied) end)
end

local function ack(doc)
  buffer.reconcile(doc)
  doc.server_content = doc.content
  doc.pending_ops = nil
  doc.version = doc.version + 1
end

describe('own edit history', function()
  it('inverts sequential and UTF-16 operations in reverse order', function()
    local before = 'a日b'
    local ops = { { p = 1, i = 'é' }, { p = 3, d = 'b' }, { p = 0, i = 'x' } }
    local inverse = ot.invert(ops, before)
    assert.are.same({ { p = 0, d = 'x' }, { p = 3, i = 'b' }, { p = 1, d = 'é' } }, inverse)
    assert.are.equal(before, ot.apply(ot.apply(before, ops), inverse))
  end)

  it('groups separate insert sessions into separate undo steps', function()
    local doc = setup('')
    -- Headless feedkeys can coalesce adjacent sessions; make the boundary explicit.
    keys('iA<C-g>u<Esc>')
    keys('aB<Esc>')
    assert.are.equal(2, #doc.history.undo)
    keys('u')
    assert.are.equal('A', text(doc))
    keys('u')
    assert.are.equal('', text(doc))
    cleanup(doc)
  end)

  it('keeps one insert session in one step', function()
    local doc = setup('')
    keys('iABC<Esc>')
    assert.are.equal(1, #doc.history.undo)
    keys('u')
    assert.are.equal('', text(doc))
    cleanup(doc)
  end)

  for _, case in ipairs({
    { name = 'before', remote = { p = 0, i = 'THEIRS ' }, expected = 'THEIRS one  two three' },
    { name = 'after', remote = { p = 18, i = ' THEIRS' }, expected = 'one  two three THEIRS' },
    { name = 'at the insertion', remote = { p = 4, i = 'THEIRS ' }, expected = 'one THEIRS  two three' },
    { name = 'inside our text', remote = { p = 6, i = 'THEIRS ' }, expected = 'one THEIRS  two three' },
  }) do
    it('undoes only our text after a remote insert ' .. case.name, function()
      local doc = setup('one  two three')
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      keys('iMINE<Esc>')
      ack(doc)
      remote(doc, { case.remote })
      keys('u')
      assert.are.equal(case.expected, text(doc))
      assert.are.equal(text(doc), doc.content)
      cleanup(doc)
    end)
  end

  it('undoes the right line when a remote line arrives above unacknowledged typing', function()
    local doc = setup('one\ntwo\nthree')
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    keys('iMINE <Esc>')
    remote(doc, { { p = 0, i = 'THEIRS\n' } })
    keys('u')
    assert.are.equal('THEIRS\none\ntwo\nthree', text(doc))
    cleanup(doc)
  end)

  it('honors a count on the buffer-local undo map', function()
    local doc = setup('base')
    keys('iA<C-g>u<Esc>')
    keys('aB<Esc>')
    keys('2u')
    assert.are.equal('base', text(doc))
    cleanup(doc)
  end)

  it('undoes two local groups after a remote insert between them', function()
    local doc = setup('x')
    keys('iA<C-g>u<Esc>')
    keys('0iB<Esc>')
    ack(doc)
    remote(doc, { { p = 1, i = 'R' } })
    keys('u')
    assert.are.equal('RAx', text(doc))
    keys('u')
    assert.are.equal('Rx', text(doc))
    cleanup(doc)
  end)

  it('undoes a deletion of our earlier insertion, then that insertion', function()
    local doc = setup('x')
    keys('iA<C-g>u<Esc>')
    keys('0x')
    keys('u')
    assert.are.equal('Ax', text(doc))
    keys('u')
    assert.are.equal('x', text(doc))
    cleanup(doc)
  end)

  it('drops an edit whose text the collaborator deleted', function()
    local doc = setup('base')
    keys('iA<Esc>')
    keys('aB<Esc>')
    ack(doc)
    remote(doc, { { p = 1, d = 'B' } })
    assert.are.equal(1, #doc.history.undo)
    keys('u')
    assert.are.equal('base', text(doc))
    cleanup(doc)
  end)

  it('redoes after a remote insert and clears redo on new typing', function()
    local doc = setup('base')
    keys('iMINE<Esc>')
    keys('u')
    ack(doc)
    remote(doc, { { p = 0, i = 'THEIRS ' } })
    keys('<C-r>')
    assert.are.equal('THEIRS MINEbase', text(doc))
    keys('u')
    keys('iNEW<Esc>')
    assert.are.equal(0, #doc.history.redo)
    cleanup(doc)
  end)

  it('transforms history through an external submit without recording it', function()
    local doc = setup('base')
    keys('iMINE<Esc>')
    local ops = { { p = 0, i = 'DISK ' } }
    doc.content = ot.apply(doc.content, ops)
    doc:_replace_buffer(doc.content, false)
    doc:submit_external_op(ops)
    keys('u')
    assert.are.equal('DISK base', text(doc))
    cleanup(doc)
  end)

  it('clears both stacks on a wholesale replacement', function()
    local doc = setup('base')
    keys('iMINE<Esc>')
    doc:_replace_buffer('server')
    assert.are.equal(0, #doc.history.undo)
    assert.are.equal(0, #doc.history.redo)
    cleanup(doc)
  end)

  it('does nothing in viewing mode', function()
    local doc = setup('base')
    keys('iMINE<Esc>')
    vim.bo[doc.bufnr].modifiable = false
    history.undo(doc)
    assert.are.equal('MINEbase', text(doc))
    assert.are.equal(1, #doc.history.undo)
    cleanup(doc)
  end)

  it('keeps native undo away from collaborator text and preserves insert state', function()
    local doc = setup('base')
    keys('iMINE<Esc>')
    ack(doc)
    remote(doc, { { p = 0, i = 'THEIRS ' } })
    pcall(vim.cmd, 'undo')
    assert.are.equal('THEIRS MINEbase', text(doc))
    local mode_before, mode_after, cursor_before, cursor_after
    _G.undo_own_insert_check = function()
      mode_before = vim.api.nvim_get_mode().mode
      cursor_before = vim.api.nvim_win_get_cursor(0)
      doc.content = ot.apply(doc.content, { { p = ot.u16_len(doc.content), i = 'X' } })
      buffer.apply_remote(doc, { { p = ot.u16_len(doc.content) - 1, i = 'X' } })
      mode_after = vim.api.nvim_get_mode().mode
      cursor_after = vim.api.nvim_win_get_cursor(0)
      return ''
    end
    keys('i<C-r>=luaeval("_G.undo_own_insert_check()")<CR>z<Esc>')
    _G.undo_own_insert_check = nil
    assert.are.equal('i', mode_before)
    assert.are.equal(mode_before, mode_after)
    assert.are.same(cursor_before, cursor_after)
    cleanup(doc)
  end)

  it('submits the inverse as an OT update', function()
    local doc = setup('base')
    doc._stopped = false
    keys('iMINE<Esc>')
    doc:flush()
    doc:_on_ack({ v = doc.version })
    keys('u')
    doc:flush()
    assert.are.same({ { p = 0, d = 'MINE' } }, sent[#sent])
    cleanup(doc)
  end)

  it('marks the text an undo restores as an undo, so it cancels a tracked deletion', function()
    local doc = setup('alpha beta')
    doc._stopped = false
    keys('wdw')
    doc:flush()
    doc:_on_ack({ v = doc.version })
    keys('u')
    doc:flush()
    assert.are.same({ { p = 6, i = 'beta', u = true } }, sent[#sent])
    cleanup(doc)
  end)

  it('keeps the undo mark through a transform', function()
    local ops = ot.transform_ops({ { p = 6, i = 'beta', u = true } }, { { p = 0, i = 'X' } }, 'left')
    assert.are.same({ { p = 7, i = 'beta', u = true } }, ops)
  end)

  it('owns only the letters a change touched, so undo keeps a collaborator deletion beside them', function()
    local doc = setup('xa\nxa\nxa\nxa')
    vim.cmd('%s/a/bbbb/g')
    vim.wait(50, function() return false end)
    ack(doc)
    -- The collaborator deletes the x of line 2, which the substitution left alone.
    remote(doc, { { p = 6, d = 'x' } })
    keys('u')
    assert.are.equal('xa\na\nxa\nxa', text(doc))
    cleanup(doc)
  end)

  it('undoes two word changes made by one command without restoring a deleted word between them', function()
    local doc = setup('one two three')
    vim.cmd('s/one two three/ONE two THREE/')
    vim.wait(50, function() return false end)
    ack(doc)
    remote(doc, { { p = 4, d = 'two' } })
    keys('u')
    assert.are.equal('one  three', text(doc))
    cleanup(doc)
  end)

  it('trims a replacement to whole characters', function()
    local doc = setup('caf\195\169 x')
    vim.cmd('s/caf\195\169/caf\195\168/')
    vim.wait(50, function() return false end)
    ack(doc)
    assert.are.same({ { p = 3, d = '\195\169' }, { p = 3, i = '\195\168' } }, doc.history.undo[1].ops)
    keys('u')
    assert.are.equal('caf\195\169 x', text(doc))
    cleanup(doc)
  end)

  it('keeps typing in a reopened buffer apart from the last step of the closed one', function()
    local doc = setup('base')
    keys('iA<Esc>')
    local old = doc.bufnr
    doc.bufnr = nil
    vim.api.nvim_buf_delete(old, { force = true })
    buffer.create(doc, vim.split(doc.content, '\n', { plain = true }))
    keys('$aB<Esc>')
    keys('u')
    assert.are.equal('Abase', text(doc))
    cleanup(doc)
  end)

  it('keeps an undo insert apart from typing next to it through a transform', function()
    local ops = ot.transform_x({ { p = 6, i = 'beta', u = true }, { p = 10, i = ' X' } }, { { p = 0, i = 'R' } })
    assert.are.same({ { p = 7, i = 'beta', u = true }, { p = 11, i = ' X' } }, ops)
  end)
end)
