-- What a finished compile does with the PDF. The file is rewritten in place on
-- every build, so relaunching the viewer is only about focus: it pulls the
-- window manager away from the buffer, which makes compiling on every :w
-- unusable.
local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local overleaf = require('overleaf')

local OUTPUT_FILES = { { path = 'output.pdf', url = '/project/p1/output/output.pdf' } }

describe('pdf viewer handoff', function()
  local original_config, original_request, original_open
  local pdf_path, opened

  before_each(function()
    original_config = vim.deepcopy(config._config)
    original_request = bridge.request
    original_open = vim.ui.open

    pdf_path = vim.fn.tempname() .. '.pdf'
    local f = assert(io.open(pdf_path, 'wb'))
    f:write('%PDF-1.4\n')
    f:close()

    opened = {}
    vim.ui.open = function(path)
      table.insert(opened, path)
      return nil, nil
    end

    bridge.request = function(method, _, callback)
      if method == 'downloadUrl' then
        callback(nil, { path = pdf_path })
      else
        callback({ message = 'unexpected request: ' .. method })
      end
    end

    overleaf._state.pdf_path = nil
    overleaf._state.pdf_opened = {}
  end)

  after_each(function()
    config._config = original_config
    bridge.request = original_request
    vim.ui.open = original_open
    os.remove(pdf_path)
  end)

  --- Run a compile's PDF step and let the scheduled open (if any) run.
  local function compile_output()
    overleaf._open_pdf(OUTPUT_FILES, 'clsi-1')
    vim.wait(50, function() return #opened > 0 end)
  end

  it("launches the viewer once and then refreshes in place ('once')", function()
    config.setup({ pdf_auto_open = 'once' })

    compile_output()
    assert.are.same({ pdf_path }, opened)

    compile_output()
    compile_output()
    assert.are.equal(1, #opened)
  end)

  it('records the path even when the viewer is not launched', function()
    config.setup({ pdf_auto_open = false })

    compile_output()
    assert.are.equal(0, #opened)
    assert.are.equal(pdf_path, overleaf._state.pdf_path)
  end)

  it("launches on every compile with 'always'", function()
    config.setup({ pdf_auto_open = 'always' })

    compile_output()
    opened = {}
    compile_output()
    assert.are.equal(1, #opened)
  end)

  it('open_pdf launches the viewer whatever the setting', function()
    config.setup({ pdf_auto_open = false })
    compile_output()
    assert.are.equal(0, #opened)

    overleaf.open_pdf()
    assert.are.same({ pdf_path }, opened)
  end)

  it('open_pdf reports when there is nothing compiled yet', function()
    config.setup({ pdf_auto_open = false })

    overleaf.open_pdf()
    assert.are.equal(0, #opened)
  end)

  it('a later compile does not relaunch after open_pdf', function()
    config.setup({ pdf_auto_open = 'once' })

    compile_output()
    assert.are.equal(1, #opened)

    overleaf.open_pdf()
    assert.are.equal(2, #opened)

    compile_output()
    assert.are.equal(2, #opened)
  end)
end)
