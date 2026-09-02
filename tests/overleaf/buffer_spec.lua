local ot = require('overleaf.ot')
local buffer = require('overleaf.buffer')

-- Counter for unique buffer names
local test_counter = 0

-- Buffer changes are reconciled into ops on the next event-loop tick, so tests
-- must let that run before asserting on the ops that were produced.
local function settle() vim.wait(50, function() return false end) end

-- Minimal mock document for testing buffer creation and on_bytes
local function make_doc(content, path)
  test_counter = test_counter + 1
  return {
    doc_id = 'test_doc_' .. test_counter,
    path = path or ('/test_' .. test_counter .. '.tex'),
    bufnr = nil,
    version = 1,
    content = content,
    server_content = content,
    joined = true,
    inflight_op = nil,
    pending_ops = nil,
    applying_remote = false,
    _rejoining = false,
    _flush_timer = nil,
    _submitted_ops = {},
    _rejoin_called = false,

    submit_op = function(self, ops) table.insert(self._submitted_ops, vim.deepcopy(ops)) end,

    check_content = function(self)
      if not self.joined or self._rejoining then return true end
      if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return true end
      if self.applying_remote then return true end
      local buf_lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      if buf_content ~= self.content then
        self._rejoin_called = true
        return false
      end
      return true
    end,

    rejoin = function(self) self._rejoin_called = true end,
  }
end

describe('buffer', function()
  describe('create', function()
    it('preserves content after undo-clear for ASCII', function()
      local content = '\\documentclass{article}\n\\begin{document}\nHello World\n\\end{document}'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves content after undo-clear for CJK text', function()
      local content = '日本語のテスト\n二行目'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves content after undo-clear for emoji', function()
      local content = 'Hello 😀 World\nLine 2 🎉'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves empty document', function()
      local content = ''
      local lines = { '' }
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves single-line document', function()
      local content = 'just one line'
      local lines = { 'just one line' }
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('detects divergence via check_content after undo-clear', function()
      local content = 'original content'
      local lines = { 'original content' }
      local doc = make_doc(content)
      -- Force content to differ (simulating Issue #5 garbage)
      doc.content = 'different content'

      local bufnr = buffer.create(doc, lines)

      -- check_content should have detected the mismatch
      assert.is_true(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('change reconciliation', function()
    local doc, bufnr

    before_each(function()
      local content = 'Hello World'
      local lines = { 'Hello World' }
      doc = make_doc(content)

      bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      settle()
      doc.bufnr = bufnr

      buffer.attach(bufnr, doc)
    end)

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end)

    it('generates insert op at end', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 11, 0, 11, { '!' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, #ops)
      assert.are.equal(11, ops[1].p)
      assert.are.equal('!', ops[1].i)
      assert.are.equal('Hello World!', doc.content)
    end)

    it('generates insert op at beginning', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(0, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('XHello World', doc.content)
    end)

    it('generates delete op', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 6, 0, 11, { '' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(6, ops[1].p)
      assert.are.equal('World', ops[1].d)
      assert.are.equal('Hello ', doc.content)
    end)

    it('generates replace op (delete + insert)', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 6, 0, 11, { 'Lua' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops)
      assert.are.equal(6, ops[1].p)
      assert.are.equal('World', ops[1].d)
      assert.are.equal(6, ops[2].p)
      assert.are.equal('Lua', ops[2].i)
      assert.are.equal('Hello Lua', doc.content)
    end)

    it('generates newline insert op', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 5, { '', '' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(5, ops[1].p)
      assert.are.equal('\n', ops[1].i)
      assert.are.equal('Hello\n World', doc.content)
    end)

    it('tracks content correctly after multiple edits', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      settle()
      vim.api.nvim_buf_set_text(bufnr, 0, 12, 0, 12, { 'Y' })
      settle()

      assert.are.equal(2, #doc._submitted_ops)
      assert.are.equal('XHello WorldY', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(doc.content, buf_content)
    end)

    it('ignores changes when applying_remote is set', function()
      doc.applying_remote = true
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      settle()
      doc.applying_remote = false

      assert.are.equal(0, #doc._submitted_ops)
      assert.are.equal('Hello World', doc.content)
    end)

    it('ignores changes when doc is not joined', function()
      doc.joined = false
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      settle()
      doc.joined = true

      assert.are.equal(0, #doc._submitted_ops)
      assert.are.equal('Hello World', doc.content)
    end)
  end)

  describe('on_bytes multibyte', function()
    it('generates correct char offset for CJK insert', function()
      local content = '日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { 'X' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('日X本語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for CJK delete', function()
      local content = '日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 3, 0, 6, { '' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, ops[1].p)
      assert.are.equal('本', ops[1].d)
      assert.are.equal('日語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for emoji insert', function()
      local content = 'A😀B'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'X' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('A😀XB', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for mixed multibyte content', function()
      local content = 'café日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'X' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('caféX日本語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('maintains content sync across multiline multibyte edits', function()
      local content = '日本語\nHello\n世界'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      settle()
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 1, 0, 1, 5, { '' })
      settle()

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, ops[1].p)
      assert.are.equal('Hello', ops[1].d)
      assert.are.equal('日本語\n\n世界', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(doc.content, buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('apply_remote', function()
    it('applies remote insert to buffer', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, i = ' Beautiful' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello Beautiful World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote delete to buffer', function()
      local content = 'Hello Beautiful World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, d = ' Beautiful' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote CJK insert to buffer', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      settle()
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, i = '日本' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello日本 World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote multiline insert to buffer', function()
      local content = 'Line 1\nLine 2'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      settle()
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 6, i = '\nNew Line' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Line 1\nNew Line\nLine 2', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Issue #6: Content divergence edge cases
  --
  -- These tests verify what happens when doc.content and buffer have
  -- diverged. In this state, on_bytes generates WRONG ops because:
  --   1. byte_offset from Neovim is relative to buffer content
  --   2. byte_to_char(doc.content, byte_offset) uses wrong content
  --   3. doc.content:sub() extracts wrong deleted text
  --
  -- Root causes of divergence:
  --   - Issue #5: undo-clear inserts garbage before on_bytes is attached
  --   - ot.apply error in on_bytes (no pcall)
  --   - nvim_buf_get_text failure drops insert op
  -- ═══════════════════════════════════════════════════════════════════════

  -- These scenarios used to be characterisation tests for issue #6: they set the
  -- buffer and the mirror deliberately out of sync and asserted that editing
  -- made things WORSE, because ops were built from stale, wrongly-sliced text.
  --
  -- The reconciliation pipeline computes ops by diffing the mirror against what
  -- the buffer actually contains, so the same scenarios now converge instead of
  -- compounding. They are kept, asserting the property we want: however the two
  -- got out of step, one edit brings the mirror back in line with the buffer.
  describe('divergence recovery', function()
    local function make_diverged(buf_content, doc_content)
      local doc = make_doc(doc_content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(buf_content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)
      return doc, buf
    end

    local function buf_text(buf)
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    end

    --- Edit, let reconciliation run, and assert the mirror caught up.
    local function assert_converges(doc, buf, edit)
      edit()
      settle()
      assert.are.equal(buf_text(buf), doc.content)
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    it('same-length divergence converges after a delete', function()
      local doc, buf = make_diverged('ABCDE', 'XYZWE')
      assert_converges(doc, buf, function() vim.api.nvim_buf_set_text(buf, 0, 1, 0, 4, { '' }) end)
    end)

    it('leading garbage in the buffer converges after a middle insert', function()
      local doc, buf = make_diverged('GAR Hello World', 'Hello World')
      assert_converges(doc, buf, function() vim.api.nvim_buf_set_text(buf, 0, 10, 0, 10, { 'X' }) end)
    end)

    it('buffer longer than mirror converges', function()
      local doc, buf = make_diverged('Hello World extra', 'Hello')
      assert_converges(doc, buf, function() vim.api.nvim_buf_set_text(buf, 0, 0, 0, 5, { 'Howdy' }) end)
    end)

    it('offset past the end of the mirror converges', function()
      local doc, buf = make_diverged('a very much longer buffer line', 'short')
      assert_converges(doc, buf, function() vim.api.nvim_buf_set_text(buf, 0, 25, 0, 25, { '!' }) end)
    end)

    it('multibyte buffer against ascii mirror converges', function()
      local doc, buf = make_diverged('日本語のテキスト', 'plain ascii')
      assert_converges(doc, buf, function() vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { 'X' }) end)
    end)

    it('successive edits stay converged rather than compounding', function()
      local doc, buf = make_diverged('ABCDE', 'XYZWE')
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { 'Q' })
      settle()
      assert.are.equal(buf_text(buf), doc.content)
      vim.api.nvim_buf_set_text(buf, 0, 2, 0, 2, { 'M' })
      settle()
      assert.are.equal(buf_text(buf), doc.content)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('multiline divergence converges', function()
      local doc, buf = make_diverged('one\ntwo\nthree', 'ONE\nTWO')
      assert_converges(doc, buf, function() vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'TWO!' }) end)
    end)
  end)
end)
