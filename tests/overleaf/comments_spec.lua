-- Comments must stay attached to their words as the document is edited. The
-- server keeps the ranges correct; what this checks is that the plugin's own
-- view of them does too -- what is highlighted, and which thread "read the
-- comment at the cursor" finds.
local comments = require('overleaf.comments')

local DOC = 'doc_c'
local TEXT = 'alpha line\nThe quick brown fox jumps.\nomega line'

--- Comment on "quick brown fox", as joinDoc reports it: a character offset.
local function ranges_for(text, needle, thread)
  local start = text:find(needle, 1, true) - 1
  local chars = vim.str_utfindex(text:sub(1, start), 'utf-32')
  return { comments = { { id = 'c_' .. thread, op = { c = needle, p = chars, t = thread } } } }
end

local function open(text, ranges)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.api.nvim_set_current_buf(bufnr)
  comments.parse_ranges(DOC, ranges)
  comments.render(bufnr, DOC, text)
  return bufnr
end

local function text_of(bufnr) return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') end

--- Where the comment highlight currently sits: { row, col, end_row, end_col } (0-based), or nil.
local function highlight(bufnr)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, comments._ns, 0, -1, { details = true })) do
    if m[4].hl_group == 'OverleafComment' then return { m[2], m[3], m[4].end_row, m[4].end_col } end
  end
  return nil
end

describe('comments', function()
  local bufnr

  before_each(
    function()
      comments._threads = {
        t1 = { id = 't1', messages = { { content = 'why fox?', user = { first_name = 'Ada' } } }, resolved = false },
      }
    end
  )

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    comments._doc_comments = {}
    comments._threads = {}
  end)

  describe('placement', function()
    it('highlights exactly the commented words', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      assert.are.same({ 1, 4, 1, 19 }, highlight(bufnr))
    end)

    it('counts characters, not bytes, when the document has multibyte text before the comment', function()
      local text = 'zażółć gęślą\nThe quick brown fox jumps.'
      bufnr = open(text, ranges_for(text, 'quick brown fox', 't1'))
      -- Overleaf offsets are characters. Read as bytes, the highlight would start
      -- several columns too early on the same line.
      assert.are.same({ 1, 4, 1, 19 }, highlight(bufnr))
    end)

    it('measures the comment by characters too', function()
      local text = 'The zażółć gęślą jaźń end.'
      bufnr = open(text, ranges_for(text, 'zażółć gęślą jaźń', 't1'))
      local h = highlight(bufnr)
      assert.are.equal('zażółć gęślą jaźń', vim.api.nvim_buf_get_text(bufnr, h[1], h[2], h[3], h[4], {})[1])
    end)
  end)

  describe('when an external tool rewrites the file', function()
    local buffer = require('overleaf.buffer')

    it('keeps the highlight on the same words if the comment text was not touched', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))

      -- Two distant changes, like a formatter or a search-and-replace.
      buffer.replace_content(bufnr, (TEXT:gsub('alpha', 'ALPHA'):gsub('omega', 'OMEGA')))
      assert.are.equal('ALPHA line\nThe quick brown fox jumps.\nOMEGA line', text_of(bufnr))

      comments.render(bufnr, DOC, text_of(bufnr))
      local h = highlight(bufnr)
      assert.is_not_nil(h, 'the highlight disappeared')
      assert.are.equal('quick brown fox', vim.api.nvim_buf_get_text(bufnr, h[1], h[2], h[3], h[4], {})[1])
    end)

    it('lets the comment follow a word that changed inside it', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))

      buffer.replace_content(bufnr, (TEXT:gsub('brown', 'red')))

      comments.render(bufnr, DOC, text_of(bufnr))
      local h = highlight(bufnr)
      assert.are.equal('quick red fox', vim.api.nvim_buf_get_text(bufnr, h[1], h[2], h[3], h[4], {})[1])
    end)

    it('produces exactly the requested content', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      local new = 'zażółć\n\nTotally different\n'
      buffer.replace_content(bufnr, new)
      assert.are.equal(new, text_of(bufnr))
    end)
  end)

  describe('after the document is edited', function()
    it('stays on the same words when text is inserted above it', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'INSERTED SEVERAL WORDS BEFORE THE COMMENT ' })

      comments.render(bufnr, DOC, text_of(bufnr)) -- e.g. after resolving another thread

      local h = highlight(bufnr)
      assert.are.equal('quick brown fox', vim.api.nvim_buf_get_text(bufnr, h[1], h[2], h[3], h[4], {})[1])
    end)

    it('is still found under the cursor', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'INSERTED SEVERAL WORDS BEFORE THE COMMENT ' })

      vim.api.nvim_win_set_cursor(0, { 2, 16 }) -- on "fox"
      local thread = comments.get_thread_at_cursor(DOC, text_of(bufnr))

      assert.is_not_nil(thread, 'the thread was lost once earlier text changed')
      assert.are.equal('t1', thread.id)
    end)

    it('is not found where the comment used to be', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'INSERTED SEVERAL WORDS BEFORE THE COMMENT ' })

      -- Offset ~20 was inside the comment before the edit; now it is line 1.
      vim.api.nvim_win_set_cursor(0, { 1, 20 })
      assert.is_nil(comments.get_thread_at_cursor(DOC, text_of(bufnr)))
    end)

    it('grows when text is typed inside it', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      vim.api.nvim_buf_set_text(bufnr, 1, 10, 1, 10, { 'VERY ' })

      comments.render(bufnr, DOC, text_of(bufnr))
      local h = highlight(bufnr)
      assert.are.equal('quick VERY brown fox', vim.api.nvim_buf_get_text(bufnr, h[1], h[2], h[3], h[4], {})[1])
    end)

    it('goes away when all of its text is deleted', function()
      bufnr = open(TEXT, ranges_for(TEXT, 'quick brown fox', 't1'))
      vim.api.nvim_buf_set_text(bufnr, 1, 4, 1, 19, { '' })

      comments.render(bufnr, DOC, text_of(bufnr))

      assert.is_nil(highlight(bufnr))
      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      assert.is_nil(comments.get_thread_at_cursor(DOC, text_of(bufnr)))
    end)
  end)
end)
