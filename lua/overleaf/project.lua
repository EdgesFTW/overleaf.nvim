local config = require('overleaf.config')

local M = {}

M._projects = {}
M._project_tree = {} -- flat list of {id, name, path}
M._root_folder_id = nil -- the project's root folder; uploads need a real folder id

function M.set_projects(projects) M._projects = projects or {} end

function M.select_project(callback)
  if #M._projects == 0 then
    config.log('warn', 'No projects available')
    return
  end

  local items = {}
  for _, p in ipairs(M._projects) do
    table.insert(items, {
      label = p.name,
      id = p.id,
      detail = p.accessLevel or '',
    })
  end

  vim.ui.select(items, {
    prompt = 'Select Overleaf Project:',
    format_item = function(item) return item.label .. ' (' .. item.detail .. ')' end,
  }, function(choice)
    if choice then callback(choice.id, choice.label) end
  end)
end

function M.parse_project_tree(project)
  M._project_tree = {}
  if not project or not project.rootFolder then return M._project_tree end

  local root = project.rootFolder
  if type(root) == 'table' and root[1] then root = root[1] end
  M._root_folder_id = root and root._id or nil

  M._walk_folder(root, '')
  return M._project_tree
end

function M._walk_folder(folder, prefix, depth)
  depth = depth or 0

  -- Process subfolders first (for tree display order)
  if folder.folders then
    for _, subfolder in ipairs(folder.folders) do
      local subpath = prefix .. subfolder.name .. '/'
      table.insert(M._project_tree, {
        id = subfolder._id,
        name = subfolder.name,
        path = subpath,
        type = 'folder',
        depth = depth,
      })
      M._walk_folder(subfolder, subpath, depth + 1)
    end
  end

  -- Process docs (text files)
  if folder.docs then
    for _, doc in ipairs(folder.docs) do
      table.insert(M._project_tree, {
        id = doc._id,
        name = doc.name,
        path = prefix .. doc.name,
        type = 'doc',
        depth = depth,
      })
    end
  end

  -- Process file refs (binary files)
  if folder.fileRefs then
    for _, file in ipairs(folder.fileRefs) do
      table.insert(M._project_tree, {
        id = file._id,
        name = file.name,
        path = prefix .. file.name,
        type = 'file',
        depth = depth,
      })
    end
  end
end

-- Compare ASCII names like Overleaf's English numeric collator. Accented
-- letters fall back to byte order rather than Unicode collation.
local function name_less(a, b)
  local left, right = a:lower(), b:lower()
  local i, j = 1, 1
  while i <= #left and j <= #right do
    local x, y = left:sub(i, i), right:sub(j, j)
    if x:match('%d') and y:match('%d') then
      local xrun = left:match('^%d+', i)
      local yrun = right:match('^%d+', j)
      local xnum, ynum = xrun:gsub('^0+', ''), yrun:gsub('^0+', '')
      if #xnum ~= #ynum then return #xnum < #ynum end
      if xnum ~= ynum then return xnum < ynum end
      if #xrun ~= #yrun then return #xrun < #yrun end
      i, j = i + #xrun, j + #yrun
    else
      if x ~= y then return x < y end
      i, j = i + 1, j + 1
    end
  end
  if i <= #left or j <= #right then return i > #left end

  -- Only case differs: the first differing ASCII letter prefers upper case.
  for k = 1, math.min(#a, #b) do
    local x, y = a:sub(k, k), b:sub(k, k)
    if x ~= y and x:lower() == y:lower() and x:match('%a') then return x < y end
  end
  return a < b
end

--- Build rows from paths so newly appended entries still appear under their folder.
--- Returns { entry = tree_entry, depth = nesting_level } in display order.
function M.display_rows()
  local root = { children = {} }
  local folders = { [''] = root }
  for _, entry in ipairs(M._project_tree) do
    if entry.type == 'folder' then folders[entry.path] = { entry = entry, children = {} } end
  end
  for _, entry in ipairs(M._project_tree) do
    local parent_path = entry.path:match('^(.*/)') or ''
    if entry.type == 'folder' then parent_path = entry.path:sub(1, -2):match('^(.*/)') or '' end
    local parent = folders[parent_path] or root
    table.insert(parent.children, entry.type == 'folder' and folders[entry.path] or { entry = entry })
  end

  local rows = {}
  local function visit(folder, depth)
    if config.get().tree_sort ~= 'overleaf' then
      table.sort(folder.children, function(a, b)
        if (a.entry.type == 'folder') ~= (b.entry.type == 'folder') then return a.entry.type == 'folder' end
        return name_less(a.entry.name, b.entry.name)
      end)
    end
    for _, child in ipairs(folder.children) do
      table.insert(rows, { entry = child.entry, depth = depth })
      if child.children then visit(child, depth + 1) end
    end
  end
  visit(root, 0)
  return rows
end

function M.select_document(callback)
  if #M._project_tree == 0 then
    config.log('warn', 'No documents in project')
    return
  end

  local entries = {}
  for _, row in ipairs(M.display_rows()) do
    if row.entry.type ~= 'folder' then table.insert(entries, row.entry) end
  end
  if #entries == 0 then
    config.log('warn', 'No documents in project')
    return
  end

  vim.ui.select(entries, {
    prompt = 'Select Document:',
    format_item = function(item) return item.path end,
  }, function(choice)
    if choice then callback(choice.id, choice.path) end
  end)
end

function M.get_doc_by_id(doc_id)
  for _, doc in ipairs(M._project_tree) do
    if doc.id == doc_id then return doc end
  end
  return nil
end

function M.get_doc_by_path(path)
  for _, doc in ipairs(M._project_tree) do
    if doc.path == path then return doc end
  end
  return nil
end

--- Check if a path already exists in the tree
function M.path_exists(path)
  for _, entry in ipairs(M._project_tree) do
    if entry.path == path then return true end
  end
  return false
end

--- Add an entry to the tree (for after API create calls), dedup by ID
function M.add_entry(entry)
  for _, existing in ipairs(M._project_tree) do
    if existing.id == entry.id then
      return false -- already exists
    end
  end
  table.insert(M._project_tree, entry)
  return true
end

--- Rename an entry in the tree
function M.rename_entry(entity_id, new_name)
  for _, entry in ipairs(M._project_tree) do
    if entry.id == entity_id then
      local old_name = entry.name
      entry.name = new_name
      -- Update path: replace the last component
      if entry.type == 'folder' then
        local old_path = entry.path
        local parent = old_path:match('^(.-)' .. vim.pesc(old_name) .. '/$') or ''
        local new_path = parent .. new_name .. '/'
        entry.path = new_path
        -- Update all children whose path starts with old_path
        for _, child in ipairs(M._project_tree) do
          if child ~= entry and child.path:sub(1, #old_path) == old_path then
            child.path = new_path .. child.path:sub(#old_path + 1)
          end
        end
      else
        local parent = entry.path:match('^(.*/)') or ''
        entry.path = parent .. new_name
      end
      return entry
    end
  end
  return nil
end

--- Move an entry (and its descendants) under a new parent folder.
function M.move_entry(entity_id, parent_folder_id)
  local entry = M.get_doc_by_id(entity_id)
  if not entry then return nil end
  if parent_folder_id == entity_id then return nil end
  local parent_path = M.get_folder_path(parent_folder_id)
  if parent_folder_id and parent_folder_id ~= M._root_folder_id and parent_path == '' then return nil end
  if entry.type == 'folder' and parent_path:sub(1, #entry.path) == entry.path then return nil end
  local parent_depth = -1
  if parent_folder_id and parent_folder_id ~= M._root_folder_id then
    parent_depth = M.get_doc_by_id(parent_folder_id).depth or 0
  end
  local old_path = entry.path
  local new_path = parent_path .. entry.name .. (entry.type == 'folder' and '/' or '')
  local depth_delta = parent_depth + 1 - (entry.depth or 0)
  entry.path = new_path
  entry.depth = (entry.depth or 0) + depth_delta
  if entry.type == 'folder' then
    for _, child in ipairs(M._project_tree) do
      if child ~= entry and child.path:sub(1, #old_path) == old_path then
        child.path = new_path .. child.path:sub(#old_path + 1)
        child.depth = (child.depth or 0) + depth_delta
      end
    end
  end
  return entry
end

--- Update an entry's ID (used for file-restore where the doc gets a new _id)
function M.update_entry_id(old_id, new_id)
  for _, entry in ipairs(M._project_tree) do
    if entry.id == old_id then
      entry.id = new_id
      return entry
    end
  end
  return nil
end

--- Remove an entry from the tree by ID
function M.remove_entry(entity_id)
  for _, entry in ipairs(M._project_tree) do
    if entry.id == entity_id then
      local prefix = entry.type == 'folder' and entry.path or nil
      for j = #M._project_tree, 1, -1 do
        local child = M._project_tree[j]
        if child == entry or (prefix and child.path:sub(1, #prefix) == prefix) then table.remove(M._project_tree, j) end
      end
      return true
    end
  end
  return false
end

--- Get the id of the folder containing an entry (the root folder for
--- top-level entries).
---@param entry table tree entry
---@return string|nil
function M.get_parent_folder_id(entry)
  local parent_path = entry.path:match('^(.*/)') or ''
  if parent_path ~= '' then
    for _, e in ipairs(M._project_tree) do
      if e.type == 'folder' and e.path == parent_path then return e.id end
    end
  end
  return M._root_folder_id
end

--- Get the path prefix for a parent folder
function M.get_folder_path(folder_id)
  if not folder_id then return '' end
  for _, entry in ipairs(M._project_tree) do
    if entry.id == folder_id and entry.type == 'folder' then return entry.path end
  end
  return ''
end

return M
