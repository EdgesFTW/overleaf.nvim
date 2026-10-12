local command = dofile('plugin/overleaf.lua')

describe(':Overleaf argument parsing', function()
  it('keeps the full argument for paths and search text', function()
    for _, sub in ipairs({ 'open', 'new', 'mkdir', 'main', 'upload', 'search' }) do
      local parsed, arg = command.parse_args('  ' .. sub .. '  chapter one.tex  ')
      assert.are.equal(sub, parsed)
      assert.are.equal('chapter one.tex', arg)
    end
  end)

  it('keeps single-token subcommands and argument-free commands', function()
    assert.are.same({ 'sync', 'import' }, { command.parse_args('sync import extra') })
    assert.are.same({ 'comments', 'refresh' }, { command.parse_args('comments refresh extra') })
    assert.are.same({ 'connect' }, { command.parse_args('connect') })
    assert.is_nil(command.parse_args('  '))
  end)
end)
