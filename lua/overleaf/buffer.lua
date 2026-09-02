local ot = require('overleaf.ot')
local config = require('overleaf.config')

local M = {}

--- Create a Neovim buffer for an Overleaf document
---@param doc table Document instance
---@param lines string[] document lines
---@return number bufnr
function M.create(doc, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, require('overleaf.sync').buf_name(doc.path))

  -- Buffer options first
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false

  -- Set content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Clear undo history so 'u' doesn't wipe the buffer after initial load.
  -- Uses API calls instead of 'exe "normal a \<BS>\<Esc>"' to avoid
  -- literal garbage insertion when special keys aren't interpreted (Issue #5).
  local old_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { ' ' })
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 1, { '' })
  vim.bo[bufnr].undolevels = old_undolevels
  vim.bo[bufnr].modified = false

  doc.bufnr = bufnr

  -- :w clears modified flag and triggers compile (changes are already synced via OT)
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      vim.bo[bufnr].modified = false
      require('overleaf').compile()
    end,
  })

  -- Attach change detection
  M.attach(bufnr, doc)

  -- Verify buffer matches doc.content after undo-clear
  -- (guards against Issue #5: exe 'normal a \<BS>\<Esc>' inserting garbage)
  doc:check_content()

  -- Open buffer in current window FIRST (so FileType autocmds fire on current buffer)
  vim.api.nvim_set_current_buf(bufnr)

  -- Editor window options
  local winnr = vim.api.nvim_get_current_win()
  vim.wo[winnr].wrap = true
  vim.wo[winnr].linebreak = true
  vim.wo[winnr].number = true

  -- Set filetype AFTER buffer is current (triggers FileType autocmds for treesitter, copilot, etc.)
  local ext = doc.path:match('%.([^%.]+)$')
  local ft_map = {
    tex = 'tex',
    sty = 'tex',
    cls = 'tex',
    bib = 'bib',
    bbl = 'tex',
    txt = 'text',
    md = 'markdown',
  }
  if ft_map[ext] then vim.bo[bufnr].filetype = ft_map[ext] end

  -- Start syntax highlighting and LSP
  config.log('debug', 'Buffer create: ext=%s ft=%s', tostring(ext), tostring(ft_map[ext]))
  if ft_map[ext] then
    -- treesitter language name differs from filetype (tex -> latex)
    local ts_lang_map = { tex = 'latex', bib = 'bibtex' }
    local lang = ts_lang_map[ft_map[ext]] or ft_map[ext]
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local ok = pcall(vim.treesitter.start, bufnr, lang)
      if not ok then pcall(vim.cmd, 'syntax enable') end

      -- Attach LSP servers to overleaf buffer (lspconfig skips overleaf:// URIs)
      config.log('info', 'Attaching LSP for ft=%s bufnr=%d', ft_map[ext], bufnr)
      M._attach_lsp(bufnr, ft_map[ext])

      -- Run chktex linter for tex files
      if ft_map[ext] == 'tex' then
        M._run_chktex(bufnr)
        -- Re-lint on text changes (debounced)
        vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
          buffer = bufnr,
          callback = function() M._schedule_lint(bufnr) end,
        })
      end
    end)
  end

  return bufnr
end

--- Manually attach LSP servers to an Overleaf buffer
function M._attach_lsp(bufnr, ft)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- LSP language IDs differ from Neovim filetypes
  local lang_id_map = { tex = 'latex', bib = 'bibtex' }

  local servers = {}
  if ft == 'tex' or ft == 'bib' then
    table.insert(servers, {
      name = 'harper_ls',
      cmd = { 'harper-ls', '--stdio' },
      settings = {
        ['harper-ls'] = {
          linters = { spell_check = true, sentence_capitalization = false },
        },
      },
    })
    table.insert(servers, {
      name = 'ltex',
      cmd = { 'ltex-ls' },
      settings = { ltex = { language = 'en-US' } },
    })
    if ft == 'tex' then table.insert(servers, { name = 'texlab', cmd = { 'texlab' } }) end
  end

  -- Mason installs to ~/.local/share/nvim/mason/bin/
  local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/'

  for _, srv in ipairs(servers) do
    local cmd = srv.cmd[1]
    -- Check system PATH and mason bin
    if vim.fn.executable(cmd) ~= 1 then
      local mason_cmd = mason_bin .. cmd
      if vim.fn.executable(mason_cmd) == 1 then srv.cmd[1] = mason_cmd end
    end
    -- Skip if command not found anywhere
    if vim.fn.executable(srv.cmd[1]) ~= 1 then
      config.log('debug', 'LSP %s not found, skipping', srv.name)
    else
      pcall(vim.lsp.start, {
        name = srv.name,
        cmd = srv.cmd,
        root_dir = vim.fn.getcwd(),
        settings = srv.settings,
        get_language_id = function(_, filetype) return lang_id_map[filetype] or filetype end,
      }, { bufnr = bufnr })
    end
  end
end

--- Attach on_bytes listener to buffer for change detection
---@param bufnr number
---@param doc table Document instance
-- Buffer -> mirror reconciliation.
--
-- The buffer must NOT be read from inside an on_bytes/on_lines callback: the
-- state visible there is inconsistent (a join reports pre-change content, while
-- typing reports post-change), so any text reconstructed at that point may be
-- silently wrong. Instead a change only records WHICH lines are dirty, and the
-- text is read back on the next event-loop tick, when the buffer has settled.
--
-- The dirty region is anchored at both ends -- `first` counted from the top and
-- `from_end` counted from the bottom -- so that several changes in one tick,
-- which shift each other's line numbers, still union correctly. The unchanged
-- suffix has the same number of lines in the buffer and in the mirror, which is
-- what lets the same `from_end` anchor address both.

--- Byte offset of the start of line `idx` (0-based) within `lines`.
local function line_start_offset(lines, idx)
  local off = 0
  for i = 1, idx do
    off = off + #lines[i] + 1 -- +1 for the newline separator
  end
  return off
end

--- Walk back to a UTF-8 character boundary so a common prefix/suffix never
--- splits a multi-byte codepoint.
local function floor_char_boundary(str, n)
  while n > 0 and n < #str and bit.band(str:byte(n + 1), 0xC0) == 0x80 do
    n = n - 1
  end
  return n
end

--- Length of the common prefix of two strings, on a character boundary.
local function common_prefix_len(a, b)
  local max = math.min(#a, #b)
  local i = 0
  while i < max and a:byte(i + 1) == b:byte(i + 1) do
    i = i + 1
  end
  return floor_char_boundary(a, i)
end

--- Length of the common suffix, on a character boundary and not overlapping
--- the prefix already claimed.
local function common_suffix_len(a, b, prefix_len)
  local max = math.min(#a, #b) - prefix_len
  local i = 0
  while i < max and a:byte(#a - i) == b:byte(#b - i) do
    i = i + 1
  end
  -- Ensure the suffix starts on a character boundary in both strings.
  while i > 0 and bit.band(a:byte(#a - i + 1), 0xC0) == 0x80 do
    i = i - 1
  end
  return i
end

--- Record that lines [first, last_new) of `buf` changed.
local function mark_dirty(doc, buf, first, last_new)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local from_end = line_count - last_new
  if from_end < 0 then from_end = 0 end

  local d = doc._dirty
  if d then
    d.first = math.min(d.first, first)
    d.from_end = math.min(d.from_end, from_end)
  else
    doc._dirty = { first = first, from_end = from_end }
  end
end

--- Read the dirty span back and turn the difference into OT ops.
--- Safe to call at any time; a no-op when nothing is pending.
function M.reconcile(doc)
  doc._reconcile_scheduled = false

  local d = doc._dirty
  if not d then return end
  if not doc.joined or doc._rejoining then
    doc._dirty = nil
    return
  end
  if not doc.bufnr or not vim.api.nvim_buf_is_valid(doc.bufnr) then
    doc._dirty = nil
    return
  end
  -- Remote ops are applied straight to the buffer and the mirror together;
  -- diffing during that would attribute the remote text to this client.
  if doc.applying_remote then return end

  doc._dirty = nil

  local mirror_lines = vim.split(doc.content, '\n', { plain = true })
  local buf_count = vim.api.nvim_buf_line_count(doc.bufnr)

  -- Expand by one line on each side. When a change adds or removes whole lines,
  -- what actually differs is the newline joining the span to its neighbour, and
  -- that separator lies outside the reported range: above for a line opened
  -- below the cursor, below for one opened at the top of the buffer. Widening
  -- is always safe -- the prefix/suffix trim below discards the extra context.
  d.first = math.max(0, d.first - 1)
  d.from_end = math.max(0, d.from_end - 1)

  -- Same span, expressed in each coordinate space.
  local b_first = math.max(0, math.min(d.first, buf_count))
  local b_last = math.max(b_first, buf_count - d.from_end)
  local m_first = math.max(0, math.min(d.first, #mirror_lines))
  local m_last = math.max(m_first, #mirror_lines - d.from_end)

  local new_text = table.concat(vim.api.nvim_buf_get_lines(doc.bufnr, b_first, b_last, false), '\n')

  local old_slice = {}
  for i = m_first + 1, m_last do
    old_slice[#old_slice + 1] = mirror_lines[i]
  end
  local old_text = table.concat(old_slice, '\n')

  if old_text == new_text then return end

  local span_offset = line_start_offset(mirror_lines, m_first)
  local prefix = common_prefix_len(old_text, new_text)
  local suffix = common_suffix_len(old_text, new_text, prefix)

  local deleted = old_text:sub(prefix + 1, #old_text - suffix)
  local inserted = new_text:sub(prefix + 1, #new_text - suffix)
  if deleted == '' and inserted == '' then return end

  local byte_pos = span_offset + prefix
  local char_pos = ot.byte_to_char(doc.content, byte_pos)

  local ops = {}
  if #deleted > 0 then table.insert(ops, { p = char_pos, d = deleted }) end
  if #inserted > 0 then table.insert(ops, { p = char_pos, i = inserted }) end
  if #ops == 0 then return end

  local ok, updated = pcall(ot.apply, doc.content, ops)
  if not ok then
    config.log('warn', 'reconcile: could not apply local ops to mirror — rejoining')
    doc:rejoin()
    return
  end
  doc.content = updated
  doc:submit_op(ops)
  require('overleaf.sync').schedule_write(doc)
end

--- True while a change has been seen but not yet turned into ops. Callers that
--- compare the buffer against the mirror must skip during this window, or they
--- will see a difference that is about to be resolved and rejoin needlessly.
function M.has_pending(doc) return doc._dirty ~= nil end

--- Attach change listeners to a buffer.
---@param bufnr number
---@param doc table Document instance
function M.attach(bufnr, doc)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _changedtick, first, _last_old, last_new)
      if doc.applying_remote then return end
      if not doc.joined then return end

      mark_dirty(doc, buf, first, last_new)

      if not doc._reconcile_scheduled then
        doc._reconcile_scheduled = true
        vim.schedule(function() M.reconcile(doc) end)
      end
    end,
    on_detach = function()
      doc._dirty = nil
      doc._reconcile_scheduled = false
    end,
  })
end

function M.apply_remote(doc, ops)
  if not doc.bufnr or not vim.api.nvim_buf_is_valid(doc.bufnr) then return end

  vim.schedule(function()
    -- Turn any pending local edit into ops first, so the diff never sees the
    -- remote text and mistakes it for something this client typed.
    M.reconcile(doc)

    doc.applying_remote = true

    local had_error = false

    for _, op in ipairs(ops) do
      local ok, err = pcall(function()
        if op.d then
          local all_lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)
          local buf_content = table.concat(all_lines, '\n')
          -- Convert character offset to byte offset for Neovim
          local byte_p = ot.char_to_byte(buf_content, op.p)
          local start_row, start_col = ot.byte_offset_to_pos(buf_content, byte_p)
          local end_row, end_col = ot.byte_offset_to_pos(buf_content, byte_p + #op.d)
          vim.api.nvim_buf_set_text(doc.bufnr, start_row, start_col, end_row, end_col, { '' })
        end
        if op.i then
          local all_lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)
          local buf_content = table.concat(all_lines, '\n')
          -- Convert character offset to byte offset for Neovim
          local byte_p = ot.char_to_byte(buf_content, op.p)
          local row, col = ot.byte_offset_to_pos(buf_content, byte_p)
          local insert_lines = vim.split(op.i, '\n', { plain = true })
          vim.api.nvim_buf_set_text(doc.bufnr, row, col, row, col, insert_lines)
        end
      end)
      if not ok then
        config.log('error', 'Failed to apply remote op: %s', err)
        had_error = true
        break
      end
    end

    -- Fallback: if any op failed, replace buffer entirely from doc.content
    if had_error and doc.content then
      config.log('info', 'Falling back to full buffer replace')
      local new_lines = vim.split(doc.content, '\n', { plain = true })
      pcall(vim.api.nvim_buf_set_lines, doc.bufnr, 0, -1, false, new_lines)
    end

    vim.bo[doc.bufnr].modified = false
    doc.applying_remote = false
  end)
end

--- Run chktex linter on buffer content and report via vim.diagnostic
local _lint_ns = vim.api.nvim_create_namespace('overleaf_chktex')
local _lint_timer = nil

function M._run_chktex(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.fn.executable('chktex') ~= 1 then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, '\n')

  local stdout_chunks = {}

  local job_id = vim.fn.jobstart({ 'chktex', '-q', '-f', '%l:%c:%d:%k:%m\n', '--inputfiles=0' }, {
    stdin = 'pipe',
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_chunks = data end
    end,
    on_exit = function(_, _exit_code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end

        local diagnostics = {}
        for _, line in ipairs(stdout_chunks) do
          local lnum, col, len, kind, msg = line:match('^(%d+):(%d+):(%d+):(%w+):(.+)$')
          if lnum then
            local severity = vim.diagnostic.severity.WARN
            if kind == 'Error' then
              severity = vim.diagnostic.severity.ERROR
            elseif kind == 'Message' then
              severity = vim.diagnostic.severity.INFO
            end
            table.insert(diagnostics, {
              lnum = tonumber(lnum) - 1,
              col = tonumber(col) - 1,
              end_col = tonumber(col) - 1 + tonumber(len),
              severity = severity,
              message = msg,
              source = 'chktex',
            })
          end
        end

        vim.diagnostic.set(_lint_ns, bufnr, diagnostics)
      end)
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, content)
    vim.fn.chanclose(job_id, 'stdin')
  end
end

--- Schedule chktex lint with debounce
function M._schedule_lint(bufnr)
  if _lint_timer then _lint_timer:stop() end
  _lint_timer = vim.defer_fn(function() M._run_chktex(bufnr) end, 1000) -- 1 second debounce
end

--- Cleanup buffer resources
---@param doc table Document instance
function M.cleanup(doc)
  if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.api.nvim_buf_delete(doc.bufnr, { force = true }) end
  doc.bufnr = nil
end

return M
