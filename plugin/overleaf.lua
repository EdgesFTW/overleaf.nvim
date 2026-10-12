-- Main :Overleaf command with subcommands
local subcommands = {
  connect = function() require('overleaf').connect() end,
  disconnect = function() require('overleaf').disconnect() end,
  compile = function() require('overleaf').compile() end,
  main = function(args) require('overleaf').set_main_file(args) end,
  tree = function() require('overleaf').toggle_tree() end,
  open = function(args) require('overleaf').open_document(args) end,
  projects = function() require('overleaf').select_project() end,
  status = function() require('overleaf').status() end,
  preview = function() require('overleaf').preview_file() end,
  pdf = function() require('overleaf').open_pdf() end,
  forward = function() require('overleaf').forward_search() end,
  mode = function(args)
    if args and args ~= '' then
      require('overleaf').set_mode(args)
    else
      require('overleaf').select_mode()
    end
  end,
  new = function(args) require('overleaf').create_doc(args) end,
  mkdir = function(args) require('overleaf').create_folder(args) end,
  delete = function() require('overleaf').delete_entity() end,
  rename = function() require('overleaf').rename_entity() end,
  upload = function(args) require('overleaf').upload_file(args) end,
  search = function(args) require('overleaf').search(args) end,
  comments = function(args)
    if args == 'refresh' then
      require('overleaf').refresh_comments()
    else
      require('overleaf').list_comments()
    end
  end,
  history = function() require('overleaf').history() end,
  sync = function(args)
    if args == 'import' then
      require('overleaf').sync_import()
    elseif args == 'export' then
      require('overleaf').sync_export()
    elseif args == 'status' then
      require('overleaf').sync_status()
    else
      require('overleaf').sync_all()
    end
  end,
}

local rest_of_line = { open = true, new = true, mkdir = true, main = true, upload = true, search = true }

local function parse_args(raw)
  local sub, args = raw:match('^%s*(%S+)%s*(.-)%s*$')
  if not sub then return nil, nil end
  if not rest_of_line[sub] then args = args:match('^(%S+)') end
  return sub, args
end

vim.api.nvim_create_user_command('Overleaf', function(opts)
  local sub, args = parse_args(opts.args)

  if not sub or sub == '' then
    -- No subcommand: if connected, show status; otherwise connect
    local ol = require('overleaf')
    if ol._state.connected then
      ol.status()
    else
      ol.connect()
    end
    return
  end

  local handler = subcommands[sub]
  if handler then
    handler(args)
  else
    vim.notify(
      'Unknown subcommand: ' .. sub .. '\nAvailable: ' .. table.concat(vim.tbl_keys(subcommands), ', '),
      vim.log.levels.ERROR
    )
  end
end, {
  nargs = '*',
  desc = 'Overleaf commands',
  complete = function(arglead, line, _)
    local parts = vim.split(line, '%s+', { trimempty = true })
    -- Complete subcommand name
    if #parts <= 2 and not (line:match('%s$') and #parts >= 2) then
      local prefix = arglead or ''
      local completions = {}
      for name in pairs(subcommands) do
        if name:find(prefix, 1, true) == 1 then table.insert(completions, name) end
      end
      table.sort(completions)
      return completions
    end
    -- Complete subcommand arguments
    local sub = parts[2]
    if sub == 'main' then
      local ok, project = pcall(require, 'overleaf.project')
      if not ok then return {} end
      local out = {}
      for _, e in ipairs(project._project_tree) do
        if e.type == 'doc' and e.path:match('%.tex$') and e.path:find(arglead or '', 1, true) == 1 then
          table.insert(out, e.path)
        end
      end
      table.sort(out)
      return out
    end
    if sub == 'mode' then
      return vim.tbl_filter(function(m) return m:find(arglead or '', 1, true) == 1 end, require('overleaf.mode').ALL)
    end
    if sub == 'comments' then return { 'refresh' } end
    if sub == 'sync' then return { 'import', 'export', 'status' } end
    return {}
  end,
})

return { parse_args = parse_args }
