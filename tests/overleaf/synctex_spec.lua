local config = require('overleaf.config')
local viewer = require('overleaf.viewer')
local profiles = require('overleaf.viewer.profiles')
local zathura = require('overleaf.viewer.zathura')
local evince = require('overleaf.viewer.evince')
local overleaf = require('overleaf')

describe('viewer profiles', function()
  local saved
  before_each(function() saved = vim.deepcopy(config._config) end)
  after_each(function() config._config = saved end)

  it('keeps the default opener and zathura search', function()
    config._config.pdf_viewer = nil
    local p = viewer.profile()
    assert.is_nil(p.open)
    assert.are.same(profiles.zathura.forward, p.forward)
    assert.are.equal('zathura', p.listen)
  end)

  it('resolves names and executable paths', function()
    config._config.pdf_viewer = '/usr/bin/okular'
    local p = viewer.profile()
    assert.are.equal('/usr/bin/okular', p.open[1])
    assert.are.equal('/usr/bin/okular', p.forward[1])
    assert.are.equal('okular', p.name)
    config._config.pdf_viewer = 'evince'
    assert.are.equal('evince', viewer.profile().forward)
  end)

  it('allows an unknown opener without a forward command', function()
    config._config.pdf_viewer = 'papers'
    local p = viewer.profile()
    assert.are.same({ 'papers', '@pdf' }, p.open)
    assert.is_nil(p.forward)
    assert.are.equal('zathura', p.listen)
  end)

  it('accepts user profiles and reports invalid ones', function()
    local custom = { name = 'sioyek', open = { 'sioyek', '@pdf' }, forward = { 'sioyek', '@file' } }
    config._config.pdf_viewer = custom
    assert.are.equal(custom, viewer.profile())
    config._config.pdf_viewer = { open = 'wrong' }
    local p, err = viewer.profile()
    assert.is_nil(p)
    assert.matches('pdf_viewer.open', err)
    config._config.pdf_viewer = { open = { 'x' }, listen = 'papers' }
    _, err = viewer.profile()
    assert.matches('pdf_viewer.listen', err)
    config._config.pdf_viewer = { open = { 'x' }, unique_bus = 5 }
    _, err = viewer.profile()
    assert.matches('pdf_viewer.unique_bus', err)
  end)

  it('checks the configured unique bus name before reusing an instance', function()
    local original = vim.system
    local command
    vim.system = function(argv)
      command = argv
      return { wait = function() return { code = 0, stdout = '(true,)\n' } end }
    end
    assert.is_true(viewer.unique_running(profiles.okular))
    assert.are.equal('org.kde.okular', command[#command])
    vim.system = original
    assert.is_false(viewer.unique_running(profiles.zathura))
  end)

  it('expands known placeholders once and leaves other syntax alone', function()
    local values = { pdf = "/tmp/a @line % 'x'.pdf", file = '/tmp/@line %/main.tex', line = 42, column = 3 }
    assert.are.same(
      { "/tmp/a @line % 'x'.pdf", '/tmp/@line %/main.tex', '42:3', '%{line}', '%f', '@unknown' },
      viewer.expand({ '@pdf', '@file', '@line:@column', '%{line}', '%f', '@unknown' }, values, false)
    )
  end)

  it('builds the three built-in open commands', function()
    local values = { pdf = '/tmp/a b.pdf', callback = 'nvim --clean -l script state' }
    assert.are.same({ 'zathura', '/tmp/a b.pdf' }, viewer.command(profiles.zathura, 'open', values, true))
    assert.are.same({ 'evince', '/tmp/a b.pdf' }, viewer.command(profiles.evince, 'open', values, true))
    assert.are.same(
      { 'okular', '--editor-cmd', 'nvim --clean -l script state %f %l %c', '--unique', '/tmp/a b.pdf' },
      viewer.command(profiles.okular, 'open', values, true)
    )
  end)

  it('splices optional inverse argv after the executable, on open only', function()
    local values = {
      pdf = '/tmp/x.pdf',
      file = '/compile/main.tex',
      line = 4,
      column = 5,
      callback = "'nvim' --clean -l 'script' 'state'",
    }
    assert.are.same({ 'okular', '--unique', '/tmp/x.pdf' }, viewer.command(profiles.okular, 'open', values, false))
    assert.are.same(
      { 'okular', '--unique', '/tmp/x.pdf#src:4 /compile/main.tex' },
      viewer.command(profiles.okular, 'forward', values, true)
    )
    assert.are.same(
      { 'zathura', '--synctex-forward', '4:5:/compile/main.tex', '/tmp/x.pdf' },
      viewer.command(profiles.zathura, 'forward', values, true)
    )
  end)
end)

describe('Okular open', function()
  it('omits --editor-cmd only when the unique instance owns its bus name', function()
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, 'p', tonumber('700', 8))
    local pdf = temp_dir .. '/output.pdf'
    vim.fn.writefile({ 'pdf' }, pdf)
    local old_config = vim.deepcopy(config._config)
    local old_path, old_state_path, old_address =
      overleaf._state.pdf_path, overleaf._server_state_path, overleaf._server_address
    local old_unique, old_job = viewer.unique_running, viewer._start_job
    config._config.pdf_viewer = 'okular'
    config._config.inverse_search = true
    overleaf._state.pdf_path = pdf
    overleaf._state.synctex_path = nil
    overleaf._server_address = function() return '/tmp/test-nvim-server' end
    overleaf._server_state_path = function() return temp_dir .. '/server-state' end
    local commands = {}
    viewer._start_job = function(argv)
      commands[#commands + 1] = argv
      return 1
    end
    viewer.unique_running = function() return true end
    overleaf.open_pdf()
    viewer.unique_running = function() return false end
    overleaf.open_pdf()
    assert.are.same({ 'okular', '--unique', pdf }, commands[1])
    assert.are.equal('--editor-cmd', commands[2][2])
    assert.is_true(commands[2][3]:find('server-state', 1, true) ~= nil)
    viewer.unique_running, viewer._start_job = old_unique, old_job
    overleaf._server_state_path, overleaf._server_address = old_state_path, old_address
    overleaf._state.pdf_path = old_path
    config._config = old_config
    vim.fn.delete(temp_dir, 'rf')
  end)
end)

describe('forward search', function()
  local saved_config, start_job, request
  local commands
  before_each(function()
    saved_config = vim.deepcopy(config._config)
    start_job = viewer._start_job
    request = require('overleaf.bridge').request
    commands = {}
    viewer._start_job = function(argv)
      commands[#commands + 1] = argv
      return 1
    end
    require('overleaf.bridge').request = function() error('forward search must not use HTTP') end
    overleaf._state.connected = true
    overleaf._state.pdf_path = '/tmp/output.pdf'
    overleaf._state.synctex_path = '/tmp/output.synctex.gz'
    overleaf._state.synctex_root = '/compile'
    overleaf._state.pdf_pid = 4321
    overleaf._state.documents = {}
    config._config.inverse_search = false
  end)
  after_each(function()
    viewer._start_job = start_job
    require('overleaf.bridge').request = request
    config._config = saved_config
    overleaf._state.connected = false
    overleaf._state.documents = {}
    overleaf._state.synctex_path = nil
    overleaf._state.synctex_root = nil
    overleaf._state.pdf_pid = nil
  end)
  local function source()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc', 'def' })
    overleaf._state.documents = { one = { path = 'chapters/intro.tex', bufnr = buf } }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
  end

  it('passes the exact absolute database path to zathura', function()
    config._config.pdf_viewer = 'zathura'
    source()
    overleaf.forward_search()
    assert.are.same(
      { 'zathura', '--synctex-forward', '2:2:/compile/chapters/intro.tex', '/tmp/output.pdf' },
      commands[1]
    )
  end)

  it('does not launch zathura when the system opener has no zathura window', function()
    config._config.pdf_viewer = nil
    source()
    local original_find, original_log = zathura.find, config.log
    local warning
    local found_pdf, found_pid
    zathura.find = function(pdf, pid)
      found_pdf, found_pid = pdf, pid
      return nil
    end
    config.log = function(level, format, ...)
      if level == 'warn' then warning = string.format(format, ...) end
    end
    overleaf.forward_search()
    zathura.find, config.log = original_find, original_log
    assert.are.equal(0, #commands)
    assert.are.same({ '/tmp/output.pdf', 4321 }, { found_pdf, found_pid })
    assert.matches('No zathura is showing /tmp/output.pdf', warning)
    assert.matches('set pdf_viewer', warning)
  end)

  it('warns when default search lacks D-Bus tools', function()
    config._config.pdf_viewer = nil
    source()
    local original_executable, original_log = vim.fn.executable, config.log
    local warning
    vim.fn.executable = function(name)
      if name == 'busctl' or name == 'gdbus' then return 0 end
      return original_executable(name)
    end
    config.log = function(level, format, ...)
      if level == 'warn' then warning = string.format(format, ...) end
    end
    overleaf.forward_search()
    assert.is_nil(zathura.find('/tmp/output.pdf', 4321))
    assert.is_nil(evince.find('/tmp/output.pdf'))
    vim.fn.executable, config.log = original_executable, original_log
    assert.are.equal(0, #commands)
    assert.matches('gdbus and busctl are needed', warning)
  end)

  it('passes the rewritten mirror path to Okular', function()
    config._config.pdf_viewer = 'okular'
    overleaf._state.synctex_root = "/tmp/mirror's place"
    source()
    overleaf.forward_search()
    assert.are.same(
      { 'okular', '--unique', "/tmp/output.pdf#src:2 /tmp/mirror's place/chapters/intro.tex" },
      commands[1]
    )
  end)

  it('uses Evince SyncView with the same recorded source path', function()
    config._config.pdf_viewer = 'evince'
    source()
    local original = evince.forward
    local received
    evince.forward = function(...)
      received = { ... }
      return true
    end
    overleaf.forward_search()
    evince.forward = original
    assert.are.same({ '/tmp/output.pdf', '/compile/chapters/intro.tex', 2, 2 }, received)
    assert.are.equal(0, #commands)
  end)

  it('requires the database and an associated buffer', function()
    source()
    overleaf._state.synctex_path = nil
    overleaf.forward_search()
    assert.are.equal(0, #commands)
  end)
end)

describe('inverse search', function()
  local saved_root, saved_state_path, state_dir
  before_each(function()
    saved_root = overleaf._state.synctex_root
    saved_state_path = overleaf._server_state_path
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, 'p', tonumber('700', 8))
    overleaf._server_state_path = function(pdf)
      return state_dir .. '/overleaf-inverse-' .. vim.fn.sha256(pdf):sub(1, 16)
    end
  end)
  after_each(function()
    overleaf._state.synctex_root = saved_root
    overleaf._server_state_path = saved_state_path
    vim.fn.delete(state_dir, 'rf')
  end)

  it('parses both D-Bus signal forms', function()
    local file, line, col =
      zathura.parse_edit("/org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/main.tex', uint32 71, uint32 4294967295)")
    assert.are.same({ '/compile/main.tex', 71, 0 }, { file, line, col })
    file, line, col = evince.parse_edit(
      "/org/gnome/evince/Window/0: org.gnome.evince.Window.SyncSource ('file:///compile/main.tex', (12, -1), uint32 3)"
    )
    assert.are.same({ 'file:///compile/main.tex', 12, 0 }, { file, line, col })
  end)

  -- gdbus switches to double quotes for a string holding a single quote, and
  -- escapes the quote character, backslashes and control characters inside.
  -- The zathura line is verbatim from a live ctrl+click on such a path.
  it('reads paths gdbus prints in double quotes or with escapes', function()
    local file, line, col = zathura.parse_edit(
      [[/org/pwmt/zathura: org.pwmt.zathura.Edit ("/home/u/it's proj/chapters/intro.tex", uint32 1, uint32 4294967295)]]
    )
    assert.are.same({ "/home/u/it's proj/chapters/intro.tex", 1, 0 }, { file, line, col })

    file = zathura.parse_edit([[/org/pwmt/zathura: org.pwmt.zathura.Edit ('/a/"q" \'s\\x', uint32 2, uint32 3)]])
    assert.are.equal([[/a/"q" 's\x]], file)

    file, line = evince.parse_edit(
      [[/org/gnome/evince/Window/0: org.gnome.evince.Window.SyncSource ("file:///home/u/author's.tex", (5, -1), uint32 9)]]
    )
    assert.are.same({ "file:///home/u/author's.tex", 5 }, { file, line })
  end)

  -- Evince's daemon compares URIs as strings, and GLib escapes in upper case.
  -- The expected value is what Gio.File.get_uri() returns for this path.
  it("spells a PDF's URI the way Evince filed it", function()
    assert.are.equal(
      "file:///tmp/overleaf_it's%20%5Bx%5D%20proj.pdf",
      evince._document_uri("/tmp/overleaf_it's [x] proj.pdf")
    )
    assert.are.equal('file:///tmp/a%3Bb%23c%25%C3%A9.pdf', evince._document_uri('/tmp/a;b#c%é.pdf'))
  end)

  it('decodes GVariant string escapes', function()
    local gvariant = require('overleaf.viewer.gvariant')
    assert.are.equal('a\tb\nc', (gvariant.read_string([['a\tb\nc']], 1)))
    assert.are.equal('é', (gvariant.read_string([['é']], 1)))
    assert.is_nil(gvariant.read_string("'unterminated", 1))
    assert.is_nil(gvariant.read_string('no quote', 1))
  end)

  it('maps build and mirror paths and file URIs', function()
    overleaf._state.synctex_root = "/tmp/mirror's place"
    assert.are.equal('main.tex', overleaf._synctex_source_path('/compile/./main.tex'))
    assert.are.equal('chapters/intro.tex', overleaf._synctex_source_path('/compile/chapters/./intro.tex'))
    assert.are.equal('main.tex', overleaf._synctex_source_path("/tmp/mirror's place/./main.tex"))
    assert.are.equal('main.tex', overleaf._synctex_source_path(vim.uri_from_fname("/tmp/mirror's place/main.tex")))
    assert.is_nil(overleaf._synctex_source_path('/usr/texlive/main.tex'))
  end)

  it('clamps negative columns and keeps positive ones when jumping', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abcdef', 'ghijkl' })
    overleaf._state.documents = { one = { path = 'main.tex', bufnr = buf } }
    overleaf._on_viewer_edit('/compile/main.tex', 2, -1)
    vim.wait(100, function() return vim.api.nvim_get_current_buf() == buf end)
    assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    overleaf._on_viewer_edit('/compile/main.tex', 1, 4)
    vim.wait(100, function() return vim.api.nvim_win_get_cursor(0)[1] == 1 end)
    assert.are.same({ 1, 3 }, vim.api.nvim_win_get_cursor(0))
    overleaf._state.documents = {}
  end)

  it('writes and removes only its own server state', function()
    local old_address = overleaf._server_address
    overleaf._server_address = function() return '/tmp/test-nvim-server' end
    local path = state_dir .. '/test.pdf'
    local statefile = overleaf._server_state_path(path)
    overleaf._write_server_state(path)
    assert.are.equal('/tmp/test-nvim-server', vim.fn.readfile(statefile)[1])
    assert.are.equal(tonumber('600', 8), bit.band(vim.uv.fs_stat(statefile).mode, tonumber('777', 8)))
    overleaf._remove_server_state(path)
    assert.are.equal(0, vim.fn.filereadable(statefile))
    vim.fn.writefile({ 'some-other-server' }, statefile)
    overleaf._remove_server_state(path)
    assert.are.equal(1, vim.fn.filereadable(statefile))
    overleaf._server_address = old_address
  end)

  it('names state files by PDF hash in a stable runtime directory', function()
    local path = '/tmp/Results 5%lower #é.pdf'
    local expected = vim.fn.stdpath('run') .. '/overleaf-inverse-' .. vim.fn.sha256(path):sub(1, 16)
    assert.are.equal(expected, saved_state_path(path))
  end)

  it('quotes the callback as four shell words', function()
    local old_address = overleaf._server_address
    local old_inverse = config._config.inverse_search
    overleaf._server_address = function() return '/tmp/test-nvim-server' end
    config._config.inverse_search = true
    local pdf = "/tmp/a space/it's @line 5%lower.pdf"
    local command = overleaf._callback_command(pdf)
    local result = vim.system({ 'sh', '-c', 'set -- ' .. command .. '; printf "[%s]" "$@"' }, { text = true }):wait()
    assert.are.equal(0, result.code)
    assert.is_true(result.stdout:find('[--clean][-l]', 1, true) ~= nil)
    assert.is_true(result.stdout:find('[' .. overleaf._server_state_path(pdf) .. ']', 1, true) ~= nil)
    assert.is_nil(overleaf._server_state_path(pdf):find('%%'))
    overleaf._server_address = old_address
    config._config.inverse_search = old_inverse
  end)

  it('exits once with a clear error for a stale server', function()
    local path = state_dir .. '/stale-state'
    vim.fn.writefile({ '/tmp/nonexistent-nvim-server' }, path)
    local result = vim
      .system({
        vim.v.progpath,
        '--clean',
        '-l',
        vim.fn.getcwd() .. '/scripts/overleaf-inverse.lua',
        path,
        '/compile/main.tex',
        '23',
        '0',
      }, { text = true })
      :wait()
    assert.are.equal(1, result.code)
    assert.are.equal('overleaf inverse search: Neovim server is unavailable\n', result.stderr)
  end)

  it('rejects state files another user could rewrite', function()
    local path = state_dir .. '/writable-state'
    vim.fn.writefile({ '/tmp/nonexistent-nvim-server' }, path)
    vim.uv.fs_chmod(path, tonumber('666', 8))
    local result = vim
      .system({
        vim.v.progpath,
        '--clean',
        '-l',
        vim.fn.getcwd() .. '/scripts/overleaf-inverse.lua',
        path,
        '/compile/main.tex',
        '23',
        '0',
      }, { text = true })
      :wait()
    assert.are.equal(1, result.code)
    assert.are.equal('overleaf inverse search: insecure server state file\n', result.stderr)
  end)

  it('sends a viewer edit through the callback script when RPC is available', function()
    if vim.v.servername == '' then
      local ok = pcall(vim.fn.serverstart, state_dir .. '/nvim-server')
      if not ok then
        pending('sandbox does not allow a Neovim RPC server')
        return
      end
    end
    local path = state_dir .. '/rpc.pdf'
    overleaf._write_server_state(path)
    local script = vim.fn.getcwd() .. '/scripts/overleaf-inverse.lua'
    local original = overleaf._on_viewer_edit
    local seen
    overleaf._on_viewer_edit = function(file, line, column) seen = { file, line, column } end
    local process = vim.system({
      vim.v.progpath,
      '--clean',
      '-l',
      script,
      overleaf._server_state_path(path),
      '/compile/main.tex',
      '23',
      '-1',
    })
    vim.wait(5000, function() return seen ~= nil end)
    local result = process:wait()
    assert.are.equal(0, result.code)
    assert.are.same({ '/compile/main.tex', 23, -1 }, seen)
    overleaf._on_viewer_edit = original
    overleaf._remove_server_state(path)
  end)
end)

describe('D-Bus inverse listener', function()
  local cases = {
    {
      name = 'zathura',
      driver = zathura,
      signal = "/org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/./main.tex', uint32 71, uint32 4294967295)",
      expected = { '/compile/./main.tex', 71, 0 },
    },
    {
      name = 'evince',
      driver = evince,
      signal = "/org/gnome/evince/Window/0: org.gnome.evince.Window.SyncSource ('file:///compile/main.tex', (12, -1), uint32 3)",
      expected = { 'file:///compile/main.tex', 12, 0 },
    },
  }

  for _, case in ipairs(cases) do
    it('delivers ' .. case.name .. ' edits, ignores chatter and stops its monitor', function()
      local old_find, old_command = case.driver.find, case.driver.monitor_command
      case.driver.find = function() return 'test-bus' end
      case.driver.monitor_command = function()
        return { 'sh', '-c', [[printf '%s\n' "unrelated chatter" "]] .. case.signal .. [["; sleep 5]] }
      end
      local received = {}
      local ok, err = viewer.watch_edits(
        profiles[case.name],
        '/tmp/output.pdf',
        nil,
        function(file, line, column) received[#received + 1] = { file, line, column } end
      )
      assert.is_true(ok, tostring(err))
      assert.is_true(vim.wait(2000, function() return #received > 0 end))
      assert.are.same({ case.expected }, received)
      assert.is_true(viewer.watching())
      viewer.stop_watching()
      assert.is_false(viewer.watching())
      case.driver.find, case.driver.monitor_command = old_find, old_command
    end)
  end

  it('restarts when the same PDF moves to another bus name', function()
    local old_find, old_command, old_start = zathura.find, zathura.monitor_command, viewer._start_monitor
    local bus = 'first-bus'
    local starts = {}
    zathura.find = function() return bus end
    zathura.monitor_command = function(name) return { 'monitor', name } end
    viewer._start_monitor = function(argv)
      starts[#starts + 1] = argv
      return 100 + #starts
    end
    local ok = viewer.watch_edits(profiles.zathura, '/tmp/output.pdf', nil, function() end)
    assert.is_true(ok)
    ok = viewer.watch_edits(profiles.zathura, '/tmp/output.pdf', nil, function() end)
    assert.is_true(ok)
    assert.are.equal(1, #starts)
    bus = 'second-bus'
    ok = viewer.watch_edits(profiles.zathura, '/tmp/output.pdf', nil, function() end)
    assert.is_true(ok)
    assert.are.same({ 'monitor', 'second-bus' }, starts[2])
    bus = nil
    ok = viewer.watch_edits(profiles.zathura, '/tmp/output.pdf', nil, function() end)
    assert.is_false(ok)
    assert.is_false(viewer.watching())
    zathura.find, zathura.monitor_command, viewer._start_monitor = old_find, old_command, old_start
  end)

  it('assembles a signal split across stdout chunks before parsing it', function()
    local old_find, old_command, old_start = zathura.find, zathura.monitor_command, viewer._start_monitor
    local options
    zathura.find = function() return 'test-bus' end
    zathura.monitor_command = function() return { 'monitor' } end
    viewer._start_monitor = function(_, opts)
      options = opts
      return 101
    end
    local received = {}
    assert.is_true(
      viewer.watch_edits(
        profiles.zathura,
        '/tmp/output.pdf',
        nil,
        function(file, line, col) received[#received + 1] = { file, line, col } end
      )
    )
    options.on_stdout(101, { "/org/pwmt/zathura: org.pwmt.zathura.Edit ('/compile/main" })
    assert.are.equal(0, #received)
    options.on_stdout(101, { ".tex', uint32 71, uint32 4294967295)", '' })
    assert.are.same({ { '/compile/main.tex', 71, 0 } }, received)
    viewer.stop_watching()
    zathura.find, zathura.monitor_command, viewer._start_monitor = old_find, old_command, old_start
  end)
end)

describe('compile SyncTeX download', function()
  local bridge = require('overleaf.bridge')
  local sync = require('overleaf.sync')
  local old_request, old_dir, old_config, old_state_path, temp_dir
  local calls
  before_each(function()
    old_request = bridge.request
    old_dir = sync._sync_dir
    old_config = vim.deepcopy(config._config)
    old_state_path = overleaf._server_state_path
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, 'p', tonumber('700', 8))
    overleaf._server_state_path = function(pdf) return temp_dir .. '/overleaf-inverse-' .. vim.fn.sha256(pdf):sub(1, 16) end
    calls = {}
    config._config.inverse_search = false
    config._config.pdf_auto_open = false
    config._config.pdf_dir = temp_dir
    config._config.cookie = 'test=1'
    overleaf._state.project_name = 'example'
    bridge.request = function(method, params, callback)
      calls[#calls + 1] = { method, params }
      callback(nil, { path = params.outputDir .. '/overleaf_' .. params.fileName })
    end
  end)
  after_each(function()
    bridge.request = old_request
    sync._sync_dir = old_dir
    config._config = old_config
    overleaf._state.synctex_path = nil
    overleaf._state.synctex_root = nil
    overleaf._state.pdf_path = nil
    overleaf._server_state_path = old_state_path
    vim.fn.delete(temp_dir, 'rf')
  end)

  local function compile()
    overleaf._open_pdf({
      { path = 'output.pdf', url = '/pdf' },
      { path = 'output.synctex.gz', url = '/db' },
    })
  end

  it('downloads the database even with inverse search disabled', function()
    sync._sync_dir = nil
    compile()
    assert.are.equal('downloadUrl', calls[2][1])
    assert.is_nil(calls[2][2].synctexRoot)
    assert.are.equal('/compile', overleaf._state.synctex_root)
    assert.are.equal(temp_dir .. '/overleaf_example.synctex.gz', overleaf._state.synctex_path)
  end)

  it('passes the mirror root for byte rewriting', function()
    sync._sync_dir = temp_dir .. "//mirror's place//"
    compile()
    assert.are.equal(temp_dir .. "/mirror's place", calls[2][2].synctexRoot)
    assert.are.equal(temp_dir .. "/mirror's place", overleaf._state.synctex_root)
    assert.are.equal('main.tex', overleaf._synctex_source_path(temp_dir .. "/mirror's place/main.tex"))
  end)

  it('normalises a relative mirror to an absolute database root', function()
    sync._sync_dir = './relative-mirror//'
    compile()
    local expected = vim.fs.normalize(vim.fn.fnamemodify(sync._sync_dir, ':p')):gsub('/+$', '')
    assert.are.equal(expected, calls[2][2].synctexRoot)
    assert.are.equal(expected, overleaf._state.synctex_root)
    assert.are.equal('main.tex', overleaf._synctex_source_path(expected .. '/main.tex'))
  end)

  it('warns when the SyncTeX database download fails', function()
    local old_log = config.log
    local warning
    config.log = function(level, format, ...)
      if level == 'warn' then warning = string.format(format, ...) end
    end
    bridge.request = function(_, params, callback)
      if params.fileName:match('synctex') then
        callback({ message = 'download failed' })
      else
        callback(nil, { path = temp_dir .. '/overleaf_' .. params.fileName })
      end
    end
    compile()
    config.log = old_log
    assert.matches('No SyncTeX database this build: download failed', warning)
  end)
end)
