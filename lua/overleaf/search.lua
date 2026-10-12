local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local project = require('overleaf.project')

local M = {}

--- Search all project documents for a Lua pattern
--- Results are shown in quickfix list
function M.grep(pattern, state)
  if not pattern or pattern == '' then return end

  local docs = {}
  for _, entry in ipairs(project._project_tree) do
    if entry.type == 'doc' then table.insert(docs, entry) end
  end

  if #docs == 0 then
    config.log('info', 'No documents to search')
    return
  end

  local results = {}
  local total = #docs
  local processed = 0

  config.log('info', 'Searching %d documents...', total)

  local function finish()
    vim.schedule(function()
      if #results == 0 then
        config.log('info', 'No matches found for: %s', pattern)
        return
      end

      -- Build quickfix entries
      local qf_items = {}
      for _, r in ipairs(results) do
        table.insert(qf_items, {
          filename = require('overleaf.sync').buf_name(r.path),
          lnum = r.lnum,
          col = r.col,
          text = r.text,
        })
      end

      vim.fn.setqflist({}, 'r', {
        title = 'Overleaf Search: ' .. pattern,
        items = qf_items,
      })
      vim.cmd('copen')
      -- Map q to close quickfix window
      local qf_buf = vim.api.nvim_get_current_buf()
      vim.keymap.set('n', 'q', '<cmd>cclose<CR>', { buffer = qf_buf, nowait = true })
      config.log('info', 'Found %d matches in %d documents', #results, total)
    end)
  end

  local function search_content(doc_path, content)
    local lines = vim.split(content, '\n', { plain = true })
    for lnum, line in ipairs(lines) do
      local col = line:find(pattern)
      if col then
        table.insert(results, {
          path = doc_path,
          lnum = lnum,
          col = col,
          text = vim.trim(line),
        })
      end
    end
  end

  local function process_next(idx)
    if idx > total then
      finish()
      return
    end

    local doc_entry = docs[idx]
    processed = processed + 1

    -- Check if document is already open (has content in memory)
    local doc = state and state.documents and state.documents[doc_entry.id]
    if doc and doc.content then
      search_content(doc_entry.path, doc.content)
      process_next(idx + 1)
      return
    end

    -- A document the plugin tracks, or any document while the mirror keeps
    -- them all joined, is joined through its Document and stays joined: a
    -- leaveDoc would stop the updates it depends on. `join` shares a join
    -- already in flight.
    local sync = require('overleaf.sync')
    if doc or (state and state.documents and sync.active()) then
      local created = doc == nil
      if created then
        doc = require('overleaf.document').new(doc_entry.id, doc_entry.path)
        state.documents[doc_entry.id] = doc
      end
      doc:join(function(err)
        if state.documents[doc_entry.id] ~= doc then
          -- Deleted (or the project closed) while the join was under way.
          if not err then doc:leave() end
          process_next(idx + 1)
          return
        end
        if err and created then state.documents[doc_entry.id] = nil end
        if not err and doc.content then
          search_content(doc_entry.path, doc.content)
          if sync.active() then
            sync.write_doc(doc)
            sync.watch(doc)
          end
        end
        process_next(idx + 1)
      end)
      return
    end

    -- Join doc temporarily to search
    bridge.request('joinDoc', { docId = doc_entry.id }, function(err, result)
      if not err and result and result.lines then
        local content = table.concat(result.lines, '\n')
        search_content(doc_entry.path, content)
      end

      -- Leave the doc after searching
      bridge.request('leaveDoc', { docId = doc_entry.id }, function() process_next(idx + 1) end)
    end)
  end

  process_next(1)
end

return M
