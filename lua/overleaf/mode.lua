-- How this client is allowed to change the project: the same three modes as
-- Overleaf's own editor.
--
--   editing    edits go in as they are typed (the default)
--   suggesting edits are sent as tracked changes -- suggestions the owner can
--              accept or reject, anchored where they were made
--   viewing    nothing is sent: buffers are read-only and the disk mirror is
--              not pushed back. Comments still work, as they do on the web.
--
-- The mode is decided here and only here; the rest of the plugin asks. Editing
-- is what an unmodified client does, so nothing changes until it is left.
local config = require('overleaf.config')

local M = {}

M.EDITING = 'editing'
M.SUGGESTING = 'suggesting'
M.VIEWING = 'viewing'
M.ALL = { M.EDITING, M.SUGGESTING, M.VIEWING }

-- What the server lets each access level send. A `review` collaborator's plain
-- edits are rejected outright, so offering them a mode that cannot work would
-- only lose their typing.
local BY_PERMISSION = {
  owner = M.ALL,
  readAndWrite = M.ALL,
  review = { M.SUGGESTING, M.VIEWING },
  readOnly = { M.VIEWING },
}

M._mode = M.EDITING
M._permissions = nil -- permissionsLevel from the server
M._forced = false -- the project has track changes switched on for this user
M._listeners = {}

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

--- Whether the project has tracking switched on for `user_id`. The server sends
--- either a boolean (everyone) or a table keyed by user id.
---@param state boolean|table|nil trackChangesState from the joined project
---@param user_id string|nil
---@return boolean
function M.tracking_forced(state, user_id)
  if state == true then return true end
  if type(state) == 'table' and user_id then return state[user_id] == true end
  return false
end

--- The modes this session may use.
---@return string[]
function M.allowed()
  local base = BY_PERMISSION[M._permissions] or M.ALL
  -- An owner who turned tracking on for a collaborator is not bound by it; the
  -- collaborator is, and skipping it would defeat the point of turning it on.
  if M._forced and M._permissions ~= 'owner' then
    return vim.tbl_filter(function(m) return m ~= M.EDITING end, base)
  end
  return base
end

---@param mode string
---@return boolean
function M.is_allowed(mode) return contains(M.allowed(), mode) end

---@return string
function M.get() return M._mode end

--- Edits are sent as suggestions.
---@return boolean
function M.tracked() return M._mode == M.SUGGESTING end

--- Anything may be written to the project: text, files, structure.
---@return boolean
function M.writable() return M._mode ~= M.VIEWING end

--- Whole-file writes -- replacing a file on Overleaf -- cannot be a suggestion,
--- so they are only possible when edits are applied outright.
---@return boolean
function M.can_replace_files() return M._mode == M.EDITING end

---@return string
function M.label() return M._mode:sub(1, 1):upper() .. M._mode:sub(2) end

--- Ask before doing something that writes to the project. Logs why not.
---@param what string what was attempted, for the message
---@return boolean
function M.require_write(what)
  if M.writable() then return true end
  config.log('warn', 'Viewing mode: not %s. Switch with :Overleaf mode editing.', what)
  return false
end

--- Call `fn(new, old)` whenever the mode changes.
---@param fn fun(new: string, old: string)
function M.on_change(fn) table.insert(M._listeners, fn) end

--- Why `mode` cannot be entered, or nil if it can.
---@param mode string
---@return string|nil
function M.refusal(mode)
  if not contains(M.ALL, mode) then return string.format('Unknown mode "%s" (editing, suggesting or viewing)', mode) end
  if M.is_allowed(mode) then return nil end
  if M._forced and mode == M.EDITING then
    return 'Track changes is switched on for you in this project, so edits have to be suggestions'
  end
  return string.format('Your access to this project (%s) does not allow %s', M._permissions or 'unknown', mode)
end

--- Enter `mode`.
---@param mode string
---@return boolean ok, string|nil err
function M.set(mode)
  local err = M.refusal(mode)
  if err then return false, err end

  local old = M._mode
  if old == mode then return true, nil end

  M._mode = mode
  for _, fn in ipairs(M._listeners) do
    fn(mode, old)
  end
  return true, nil
end

--- Choose the starting mode for a freshly joined project.
---@param permissions_level string|nil
---@param tracking_state boolean|table|nil trackChangesState
---@param user_id string|nil
function M.init(permissions_level, tracking_state, user_id)
  M._permissions = permissions_level
  M._forced = M.tracking_forced(tracking_state, user_id)

  local wanted = config.get().mode
  local start

  if wanted ~= nil and wanted ~= 'auto' then
    if M.is_allowed(wanted) then
      start = wanted
    else
      config.log('warn', 'Mode "%s" is not available here: %s', tostring(wanted), M.refusal(wanted) or 'unknown mode')
    end
  end

  if not start then
    if M._forced then
      start = M.SUGGESTING
    else
      start = M.allowed()[1]
    end
    if not M.is_allowed(start) then start = M.allowed()[1] end
  end

  local old = M._mode
  M._mode = start
  if old ~= start then
    for _, fn in ipairs(M._listeners) do
      fn(start, old)
    end
  end
end

--- Back to the default, for a new connection.
function M.reset()
  M._permissions = nil
  M._forced = false
  local old = M._mode
  M._mode = M.EDITING
  if old ~= M.EDITING then
    for _, fn in ipairs(M._listeners) do
      fn(M.EDITING, old)
    end
  end
end

return M
