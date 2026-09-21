-- Text diff -> OT ops. What matters is that a bulk change touches only the text
-- that differs: Overleaf drops a comment or a suggestion anchored to any text an
-- op deletes, even when the same text is put straight back.
local diff = require('overleaf.diff')
local ot = require('overleaf.ot')

--- Total characters an op list deletes and inserts: how much anchored text it can hurt.
local function churn(ops)
  local n = 0
  for _, op in ipairs(ops) do
    n = n + ot.utf8_len(op.d or op.i or '')
  end
  return n
end

--- Hunks must be in descending position order and not overlap, or transforming
--- remote ops against them (which handles each component on its own) goes wrong.
local function assert_descending(ops)
  local last = math.huge
  for _, op in ipairs(ops) do
    assert.is_true(op.p <= last, 'ops must not ascend: ' .. vim.inspect(ops))
    last = op.p
  end
end

describe('diff.ops', function()
  local doc = 'alpha line\nThe quick brown fox jumps over the lazy dog.\nomega line'

  it('is empty for identical text', function() assert.are.same({}, diff.ops(doc, doc)) end)

  it('reproduces the new text', function()
    local new = doc:gsub('brown', 'red')
    assert.are.equal(new, ot.apply(doc, diff.ops(doc, new)))
  end)

  describe('leaves untouched text alone', function()
    it('for one edit', function()
      local ops = diff.ops(doc, (doc:gsub('brown', 'red')))
      assert.are.same({ { p = 21, d = 'brown' }, { p = 21, i = 'red' } }, ops)
    end)

    it('for two distant edits, without deleting what lies between them', function()
      local new = doc:gsub('alpha', 'ALPHA'):gsub('omega', 'OMEGA')
      local ops = diff.ops(doc, new)

      assert.are.equal(new, ot.apply(doc, ops))
      -- Two five-letter words out, two in. The middle line is 45 characters that
      -- must not appear in any op.
      assert.are.equal(20, churn(ops))
      for _, op in ipairs(ops) do
        assert.is_nil((op.d or op.i):find('quick', 1, true))
      end
    end)

    it('for a change that only rewraps a paragraph', function()
      local old = 'one two three four five six\nseven eight'
      local new = 'one two three\nfour five six seven\neight'
      local ops = diff.ops(old, new)

      assert.are.equal(new, ot.apply(old, ops))
      -- Only whitespace moved, so no word is deleted.
      for _, op in ipairs(ops) do
        assert.is_nil((op.d or op.i):find('%a'), 'a word was touched: ' .. vim.inspect(op))
      end
    end)
  end)

  it('orders hunks from the end of the text backwards', function()
    local new = doc:gsub('alpha', 'ALPHA'):gsub('quick', 'slow'):gsub('omega', 'OMEGA')
    local ops = diff.ops(doc, new)
    assert.is_true(#ops >= 6)
    assert_descending(ops)
    assert.are.equal(new, ot.apply(doc, ops))
  end)

  describe('whole words, for suggestions', function()
    local old = 'The lazy dog.'
    local new = 'The sleepy dog.'

    it(
      'is the smallest edit by default: "lazy" -> "sleepy" keeps the shared y',
      function() assert.are.same({ { p = 4, d = 'laz' }, { p = 4, i = 'sleep' } }, diff.ops(old, new)) end
    )

    it('replaces the whole word when asked, so a reviewer reads lazy -> sleepy', function()
      local ops = diff.ops(old, new, 0, { words = true })
      assert.are.same({ { p = 4, d = 'lazy' }, { p = 4, i = 'sleepy' } }, ops)
      assert.are.equal(new, ot.apply(old, ops))
    end)

    it('widens on both sides of a change in the middle of a word', function()
      local ops = diff.ops('a fooXbar b', 'a fooYbar b', 0, { words = true })
      assert.are.same({ { p = 2, d = 'fooXbar' }, { p = 2, i = 'fooYbar' } }, ops)
    end)

    it(
      'leaves a character typed inside a word as a one-character insertion',
      function()
        assert.are.same({ { p = 6, i = 'X' } }, diff.ops('The lazy dog.', 'The laXzy dog.', 0, { words = true }))
      end
    )

    it(
      'leaves a character deleted inside a word as a one-character deletion',
      function() assert.are.same({ { p = 6, d = 'z' } }, diff.ops('The lazy dog.', 'The lay dog.', 0, { words = true })) end
    )

    it('does not widen across punctuation', function()
      local ops = diff.ops('word.', 'word,', 0, { words = true })
      assert.are.same({ { p = 4, d = '.' }, { p = 4, i = ',' } }, ops)
    end)

    it('widens over whole multibyte words', function()
      local ops = diff.ops('a gęślą b', 'a gęsią b', 0, { words = true })
      assert.are.equal('a gęsią b', ot.apply('a gęślą b', ops))
      assert.are.same({ { p = 2, d = 'gęślą' }, { p = 2, i = 'gęsią' } }, ops)
    end)

    it('also applies with several separate changes', function()
      local text = 'lazy fox and lazy dog'
      local want = 'sleepy fox and sleepy dog'
      local ops = diff.ops(text, want, 0, { words = true })
      assert.are.equal(want, ot.apply(text, ops))
      for _, op in ipairs(ops) do
        assert.is_true(op.d == nil or op.d == 'lazy', vim.inspect(op))
      end
    end)
  end)

  describe('positions are characters, not bytes', function()
    it('counts a multibyte character as one', function()
      local old = 'zażółć gęślą jaźń\nend'
      local new = 'zażółć GĘŚLĄ jaźń\nEND'
      local ops = diff.ops(old, new)
      assert.are.equal(new, ot.apply(old, ops))
      assert.are.equal(1, #vim.tbl_filter(function(op) return op.d == 'gęślą' end, ops))
    end)

    it('shifts every position by base_char', function()
      local new = doc:gsub('alpha', 'ALPHA'):gsub('omega', 'OMEGA')
      local plain = diff.ops(doc, new)
      local shifted = diff.ops(doc, new, 100)

      assert.are.equal(#plain, #shifted)
      for i = 1, #plain do
        assert.are.equal(plain[i].p + 100, shifted[i].p)
      end
    end)
  end)

  describe('edges', function()
    it(
      'handles an insertion into empty text',
      function() assert.are.same({ { p = 0, i = 'hello' } }, diff.ops('', 'hello')) end
    )

    it('handles deleting everything', function() assert.are.same({ { p = 0, d = 'hello' } }, diff.ops('hello', '')) end)

    it('handles a change at the very end', function()
      local ops = diff.ops('abc\n', 'abc\ndef\n')
      assert.are.equal('abc\ndef\n', ot.apply('abc\n', ops))
    end)

    it('handles repeated tokens that could be matched several ways', function()
      local old = 'a a a a b a a a a'
      local new = 'a a a a c a a a a'
      assert.are.equal(new, ot.apply(old, diff.ops(old, new)))
    end)
  end)

  -- The failure this guards against is silent: a wrong op corrupts the document
  -- on the server while the mirror believes it is in sync.
  describe('random edits', function()
    local pieces = {
      'alpha',
      'beta',
      'gamma',
      'zażółć',
      '日本語',
      '\\section{x}',
      ' ',
      ' ',
      '\n',
      '\n\n',
      '.',
      ',',
      '%',
      '  ',
    }

    local function random_text(n)
      local t = {}
      for _ = 1, n do
        t[#t + 1] = pieces[math.random(#pieces)]
      end
      return table.concat(t)
    end

    local function random_edit(text)
      local roll = math.random(4)
      local cut = math.random(0, #text)
      -- Land on a character boundary.
      while cut > 0 and cut < #text and bit.band(text:byte(cut + 1), 0xC0) == 0x80 do
        cut = cut - 1
      end
      if roll == 1 then return text:sub(1, cut) .. random_text(math.random(1, 3)) .. text:sub(cut + 1) end
      local stop = math.min(#text, cut + math.random(1, 25))
      while stop < #text and bit.band(text:byte(stop + 1), 0xC0) == 0x80 do
        stop = stop - 1
      end
      if roll == 2 then return text:sub(1, cut) .. text:sub(stop + 1) end
      return text:sub(1, cut) .. random_text(math.random(1, 3)) .. text:sub(stop + 1)
    end

    it('always yields ops that turn old into new, in descending order', function()
      math.randomseed(20260920)
      local fallbacks_before = diff._fallbacks
      for _ = 1, 400 do
        local old = random_text(math.random(0, 40))
        local new = old
        for _ = 1, math.random(1, 4) do
          new = random_edit(new)
        end

        local base = math.random(0, 50)
        for _, words in ipairs({ false, true }) do
          local ops = diff.ops(old, new, base, { words = words })
          local got = ot.apply(string.rep('x', base) .. old, ops)

          assert.are.equal(
            string.rep('x', base) .. new,
            got,
            'words=' .. tostring(words) .. ' old=' .. vim.inspect(old) .. ' new=' .. vim.inspect(new)
          )
          assert_descending(ops)
        end
      end

      -- The coarse fallback is correct but would mask a bug in the hunk mapping.
      assert.are.equal(fallbacks_before, diff._fallbacks)
    end)

    it('never churns more than the naive single hunk would', function()
      math.randomseed(7)
      for _ = 1, 200 do
        local old = random_text(math.random(5, 40))
        local new = random_edit(random_edit(old))
        if old ~= new then
          local prefix, suffix = 0, 0
          while prefix < math.min(#old, #new) and old:byte(prefix + 1) == new:byte(prefix + 1) do
            prefix = prefix + 1
          end
          while suffix < math.min(#old, #new) - prefix and old:byte(#old - suffix) == new:byte(#new - suffix) do
            suffix = suffix + 1
          end
          local naive = ot.utf8_len(old:sub(prefix + 1, #old - suffix))
            + ot.utf8_len(new:sub(prefix + 1, #new - suffix))
          -- Byte-level trimming can split a multibyte character, so allow for it.
          assert.is_true(churn(diff.ops(old, new)) <= naive + 8)
        end
      end
    end)
  end)
end)
