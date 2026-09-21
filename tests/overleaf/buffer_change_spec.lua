-- Buffer -> OT mirror consistency, organised by the SHAPE of the change rather
-- than by the command that produced it. Anything that mutates a buffer must
-- flow through the same path: keystrokes, but equally LSP edits, formatters,
-- snippet expansion and any other plugin using the API.
--
-- The invariant under test is always the same: after the change settles,
-- doc.content (the mirror we send OT ops against) must equal the buffer.
local buffer = require('overleaf.buffer')

local test_counter = 0

local function make_doc(content)
  test_counter = test_counter + 1
  return {
    doc_id = 'change_doc_' .. test_counter,
    path = '/change_' .. test_counter .. '.tex',
    bufnr = nil,
    version = 1,
    content = content,
    server_content = content,
    joined = true,
    applying_remote = false,
    _rejoining = false,
    _submitted_ops = {},
    _rejoin_called = false,
    submit_op = function(self, ops) table.insert(self._submitted_ops, vim.deepcopy(ops)) end,
    check_content = function() return true end,
    rejoin = function(self) self._rejoin_called = true end,
  }
end

--- Attach a doc to a scratch buffer seeded with `content`.
local function setup(content)
  local doc = make_doc(content)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, '\n', { plain = true }))
  doc.bufnr = bufnr
  buffer.attach(bufnr, doc)
  return doc, bufnr
end

local function teardown(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
end

local function buf_text(bufnr) return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') end

--- Drive a change with real keystrokes, then let any deferred work run.
local function keys(bufnr, k)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
  vim.wait(50, function() return false end)
end

--- Let deferred work run after an API-driven change.
local function settle()
  vim.wait(50, function() return false end)
end

--- The whole point: mirror must match the buffer.
local function assert_in_sync(doc, bufnr, note)
  assert.are.equal(buf_text(bufnr), doc.content, note or 'mirror diverged from buffer')
end

describe('buffer change shapes', function()
  -- shape: several separate places changed at once, e.g. an external tool
  -- rewriting the whole buffer. The text between them must not be deleted and
  -- retyped: Overleaf drops comments and suggestions anchored to it.
  describe('a rewrite that changes several distant places', function()
    it('sends one small hunk per place rather than one hunk spanning them all', function()
      local text = 'alpha line\nThe quick brown fox jumps over the lazy dog.\nomega line'
      local doc, bufnr = setup(text)
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        vim.split((text:gsub('alpha', 'ALPHA'):gsub('omega', 'OMEGA')), '\n', { plain = true })
      )
      settle()

      assert_in_sync(doc, bufnr)
      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, #ops)
      for _, op in ipairs(ops) do
        assert.is_nil((op.d or op.i):find('quick', 1, true), 'the untouched middle line was sent')
      end
      -- Descending, so each position is valid against the text as it was.
      assert.is_true(ops[1].p > ops[3].p)
      teardown(bufnr)
    end)

    it('keeps a multibyte document in sync', function()
      local text = 'zażółć gęślą\nmiddle line stays\njaźń end'
      local doc, bufnr = setup(text)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'ZAŻÓŁĆ gęślą', 'middle line stays', 'jaźń END' })
      settle()

      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: text inserted inside an existing line
  describe('insert within a line', function()
    it('via keystrokes', function()
      local doc, bufnr = setup('alpha beta')
      keys(bufnr, 'A!')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('via API (LSP/snippet style)', function()
      local doc, bufnr = setup('alpha beta')
      vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 5, { ' GAMMA' })
      settle()
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: a new line boundary is introduced
  describe('insert at a line boundary', function()
    it('via keystrokes (o)', function()
      local doc, bufnr = setup('alpha')
      keys(bufnr, 'obeta')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('via keystrokes (O)', function()
      local doc, bufnr = setup('alpha')
      keys(bufnr, 'Ozero')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('via API', function()
      local doc, bufnr = setup('alpha')
      vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { 'beta' })
      settle()
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: N lines collapse into 1
  describe('join lines', function()
    it('two lines via J', function()
      local doc, bufnr = setup('line one\nline two')
      keys(bufnr, 'J')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('three lines via 3J', function()
      local doc, bufnr = setup('aaa\nbbb\nccc')
      keys(bufnr, '3J')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('join with leading whitespace', function()
      local doc, bufnr = setup('line one\n      indented')
      keys(bufnr, 'J')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('via API', function()
      local doc, bufnr = setup('line one\nline two')
      vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, { 'line one line two' })
      settle()
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: 1 line splits into N
  describe('split a line', function()
    it('via keystrokes', function()
      local doc, bufnr = setup('alphabeta')
      keys(bufnr, '5|i\r')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('multi-line paste via API', function()
      local doc, bufnr = setup('first\nlast')
      vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { 'a', 'b', 'c' })
      settle()
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: replacement spanning several lines (:%s, code action)
  describe('replace spanning lines', function()
    it('via substitute', function()
      local doc, bufnr = setup('one\ntwo\nthree')
      keys(bufnr, ':%s/o/0/g\r')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('via API', function()
      local doc, bufnr = setup('one\ntwo\nthree')
      vim.api.nvim_buf_set_lines(bufnr, 0, 3, false, { 'X', 'Y' })
      settle()
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: whole lines removed
  describe('delete lines', function()
    it('via dd', function()
      local doc, bufnr = setup('aaa\nbbb\nccc')
      keys(bufnr, 'jdd')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('delete to end of buffer', function()
      local doc, bufnr = setup('aaa\nbbb\nccc')
      keys(bufnr, 'jdG')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: the entire buffer is rewritten (formatter, :e!)
  describe('whole-buffer rewrite', function()
    it('via API set_lines', function()
      local doc, bufnr = setup('one\ntwo\nthree')
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'completely', 'different', 'content', 'here' })
      settle()
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- shape: undo / redo
  describe('undo and redo', function()
    it('undo of a join', function()
      local doc, bufnr = setup('line one\nline two')
      keys(bufnr, 'J')
      keys(bufnr, 'u')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('redo after undo', function()
      local doc, bufnr = setup('alpha')
      keys(bufnr, 'obeta')
      keys(bufnr, 'u')
      keys(bufnr, '<C-r>')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)

  -- multibyte across the same shapes; issue #16 reports .bib failing every time,
  -- and accented names are exactly where byte/char offset bugs hide
  describe('multibyte', function()
    it('join lines containing accented text', function()
      local doc, bufnr = setup('author = {Émile Borel}\n  title = {Sur les probabilités}')
      keys(bufnr, 'J')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('join lines containing CJK', function()
      local doc, bufnr = setup('日本語のテキスト\n二行目です')
      keys(bufnr, 'J')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('insert at line boundary after emoji', function()
      local doc, bufnr = setup('emoji 🎉 line')
      keys(bufnr, 'onext')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)

    it('bibtex-style multi-entry join', function()
      local doc, bufnr = setup('@article{key,\n  author = {Müller, Jörg},\n  year = {2026}\n}')
      keys(bufnr, 'jJ')
      assert_in_sync(doc, bufnr)
      teardown(bufnr)
    end)
  end)
end)
