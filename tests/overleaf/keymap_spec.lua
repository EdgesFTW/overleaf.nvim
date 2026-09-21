-- Default keymaps: they all hang off config.keymap_prefix, so the whole set
-- can be moved aside when another plugin already owns '<leader>o'.
local overleaf = require('overleaf')
local config = require('overleaf.config')

--- Every normal-mode mapping this plugin registered, as lhs -> desc.
local function overleaf_maps()
  local maps = {}
  for _, m in ipairs(vim.api.nvim_get_keymap('n')) do
    if m.desc and m.desc:match('^Overleaf: ') then maps[m.lhs] = m.desc end
  end
  return maps
end

local function clear_overleaf_maps()
  for lhs in pairs(overleaf_maps()) do
    pcall(vim.keymap.del, 'n', lhs)
  end
end

local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

describe('default keymaps', function()
  local original_config, original_leader

  before_each(function()
    original_config = vim.deepcopy(config._config)
    original_leader = vim.g.mapleader
    -- '<leader>' is expanded when the mapping is created, so pin it to
    -- something the assertions can spell out.
    vim.g.mapleader = ' '
    clear_overleaf_maps()
  end)

  after_each(function()
    clear_overleaf_maps()
    config._config = original_config
    vim.g.mapleader = original_leader
  end)

  it('registers the whole set under the default prefix', function()
    overleaf._set_keymaps()

    local maps = overleaf_maps()
    assert.are.equal('Overleaf: Connect', maps[' oc'])
    assert.are.equal('Overleaf: Build (compile)', maps[' ob'])
    assert.are.equal('Overleaf: Set main document', maps[' om'])
    assert.are.equal('Overleaf: View PDF', maps[' ov'])
    assert.are.equal(14, #sorted_keys(maps))
  end)

  it('moves every key when the prefix changes', function()
    config.setup({ keymap_prefix = '<leader>ol' })
    overleaf._set_keymaps()

    local maps = overleaf_maps()
    assert.are.equal('Overleaf: Connect', maps[' olc'])
    assert.are.equal('Overleaf: Build (compile)', maps[' olb'])
    assert.are.equal(14, #sorted_keys(maps))

    -- The old prefix is left free for whatever claimed it.
    assert.is_nil(maps[' oc'])
    assert.is_nil(maps[' ob'])
  end)

  it('registers nothing when keymaps is false', function()
    config.setup({ keymaps = false })
    overleaf._set_keymaps()

    assert.are.same({}, overleaf_maps())
  end)
end)
