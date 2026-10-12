local ot = require('overleaf.ot')

local function chars(s)
  local result = {}
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local width = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
    result[#result + 1] = s:sub(i, i + width - 1)
    i = i + width
  end
  return result
end

local alphabet = { 'a', 'b', ' ', '\n', 'é', '日', '😀', '𝔸' }
local function word(n)
  local out = {}
  for _ = 1, n do
    out[#out + 1] = alphabet[math.random(#alphabet)]
  end
  return table.concat(out)
end

local function offset(letters, index)
  local prefix = {}
  for i = 1, index do
    prefix[i] = letters[i]
  end
  return ot.u16_len(table.concat(prefix))
end

local function operation(s)
  local ops, current = {}, s
  for _ = 1, math.random(1, 4) do
    local letters = chars(current)
    local op
    if #letters == 0 or math.random(2) == 1 then
      op = { p = offset(letters, math.random(0, #letters)), i = word(math.random(1, 3)) }
    else
      local first = math.random(1, #letters)
      local count = math.random(1, math.min(3, #letters - first + 1))
      local deleted = {}
      for i = first, first + count - 1 do
        deleted[#deleted + 1] = letters[i]
      end
      op = { p = offset(letters, first - 1), d = table.concat(deleted) }
    end
    ops[#ops + 1] = op
    current = ot.apply(current, { op })
  end
  return ops
end

describe('text0 transforms', function()
  it('matches the seeded text0 reference fixtures on both sides', function()
    local path = 'tests/fixtures/ot_text0.json'
    local cases = vim.fn.json_decode(table.concat(vim.fn.readfile(path), '\n'))
    assert.are.equal(1000, #cases)
    for index, case in ipairs(cases) do
      local left, right = ot.transform_x(case.a, case.b)
      assert.are.same(case.left, left, 'left fixture ' .. index)
      assert.are.same(case.right, right, 'right fixture ' .. index)
      assert.are.same(case.left, ot.transform_ops(case.a, case.b, 'left'), 'left wrapper ' .. index)
      assert.are.same(case.right, ot.transform_ops(case.b, case.a, 'right'), 'right wrapper ' .. index)
    end
  end)

  it('converges for 2000 seeded sequential operation pairs', function()
    math.randomseed(0x517a2)
    for index = 1, 2000 do
      local s = word(math.random(0, 12))
      local a, b = operation(s), operation(s)
      local left, right = ot.transform_x(a, b)
      assert.are.same(left, ot.transform_ops(a, b, 'left'), 'left wrapper ' .. index)
      assert.are.same(right, ot.transform_ops(b, a, 'right'), 'right wrapper ' .. index)
      assert.are.equal(ot.apply(ot.apply(s, a), right), ot.apply(ot.apply(s, b), left), 'case ' .. index)
    end
  end)

  it('preserves each operation against an empty operation', function()
    math.randomseed(0x2fa81)
    for _ = 1, 200 do
      local ops = operation(word(math.random(0, 12)))
      assert.are.same(ops, ot.transform_ops(ops, {}, 'left'))
      assert.are.same(ops, ot.transform_ops(ops, {}, 'right'))
      local left, right = ot.transform_x(ops, {})
      assert.are.same(ops, left)
      assert.are.same({}, right)
    end
  end)
end)
