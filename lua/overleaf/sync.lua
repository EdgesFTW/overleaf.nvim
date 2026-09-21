--- Local file sync for external tool integration (e.g., Claude Code)
--- Mirrors Overleaf documents to disk and watches for external changes.
local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local diff = require('overleaf.diff')
local mode = require('overleaf.mode')

local M = {}

-- Synced documents are unpublished work, so the mirror is created private to
-- the user rather than inheriting a umask that usually yields world-readable
-- directories. Existing directories are left alone.
local SYNC_DIR_MODE = tonumber('700', 8)

M._sync_dir = nil
M._watchers = {} -- path -> {handle, doc_id}
M._write_timers = {} -- doc_id -> timer
-- path -> the exact bytes we last wrote. A watcher event whose content matches
-- this is our own write echoing back and is ignored. Identifying our writes by
-- CONTENT rather than by a time window matters twice over: a slow write used to
-- escape the window and be re-sent as an external change, and any genuine
-- external edit that landed inside the window was dropped outright.
M._last_written = {}

-- Text fileRefs mirrored on disk. Overleaf stores anything whose extension is
-- off its text whitelist (.asm, .c, ...) as an opaque "file" with no OT
-- document behind it, so these cannot go through the doc path above: the only
-- way to change one is to re-upload it whole, which Overleaf treats as a
-- replace (same folder, same name, new entity id).
M._files = {} -- doc path -> { entry = tree entry, content = last known bytes }
M._file_watchers = {} -- disk path -> fs_event handle
M._file_timers = {} -- disk path -> debounce timer
M._last_uploaded = {} -- disk path -> the exact bytes last sent to Overleaf
M._uploading = {} -- disk path -> bytes of an upload in flight (so the watcher does not resend them)
M._held = {} -- disk path -> true: changed on disk while the mode forbade sending it

--- Start sync for a project. Creates the sync directory.
---@param project_name string
function M.start(project_name)
  local sync_dir = config.get().sync_dir
  if not sync_dir then return end

  -- Expand ~ and resolve
  sync_dir = vim.fn.expand(sync_dir)

  -- Use project subdirectory
  M._sync_dir = sync_dir .. '/' .. project_name:gsub('[^%w%-_%.%s]', '_')
  vim.fn.mkdir(M._sync_dir, 'p', SYNC_DIR_MODE)

  config.log('info', 'File sync: %s', M._sync_dir)
end

--- Stop all watchers and timers
function M.stop()
  for _, w in pairs(M._watchers) do
    if w.handle and not w.handle:is_closing() then
      w.handle:stop()
      w.handle:close()
    end
  end
  M._watchers = {}

  for _, timer in pairs(M._write_timers) do
    vim.fn.timer_stop(timer)
  end
  M._write_timers = {}

  for path in pairs(M._file_watchers) do
    M._stop_file_watcher(path)
  end
  for _, timer in pairs(M._file_timers) do
    vim.fn.timer_stop(timer)
  end
  M._file_timers = {}
  M._files = {}
  M._last_uploaded = {}
  M._uploading = {}
  M._held = {}

  M._sync_dir = nil
end

--- Whether a sync directory is active for the current project
---@return boolean
function M.active() return M._sync_dir ~= nil end

--- Get the local file path for a document
---@param doc_path string Overleaf document path
---@return string|nil
function M.file_path(doc_path)
  if not M._sync_dir then return nil end
  return M._sync_dir .. '/' .. doc_path
end

--- Get the buffer name for a document.
--- Returns the real file path when sync_dir is enabled, otherwise overleaf:// URI.
---@param doc_path string Overleaf document path
---@return string
function M.buf_name(doc_path)
  if M._sync_dir then return M._sync_dir .. '/' .. doc_path end
  return 'overleaf://' .. doc_path
end

--- Check if a buffer name belongs to an Overleaf buffer (either URI or sync path)
---@param bufname string
---@return string|nil doc_path the document path if it's an Overleaf buffer
function M.parse_buf_name(bufname)
  if bufname:match('^overleaf://') then return bufname:gsub('^overleaf://', '') end
  if M._sync_dir and bufname:sub(1, #M._sync_dir) == M._sync_dir then
    return bufname:sub(#M._sync_dir + 2) -- +2 for the trailing /
  end
  return nil
end

--- Write a document's content to disk immediately
---@param doc table Document instance (needs .path, .content)
function M.write_doc(doc)
  if not M._sync_dir then return end
  if not doc.content then return end

  local path = M._sync_dir .. '/' .. doc.path

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p', SYNC_DIR_MODE)

  -- Atomic write: temp file + rename to prevent partial reads from fs_event race
  local tmp_path = path .. '.tmp.' .. vim.uv.getpid()
  local f = io.open(tmp_path, 'w')
  local renamed = false
  if f then
    f:write(doc.content)
    f:close()
    -- Match the directory: the mirrored document is private to the user.
    pcall(vim.uv.fs_chmod, tmp_path, tonumber('600', 8))
    local ok, err = os.rename(tmp_path, path)
    if ok then
      renamed = true
    else
      config.log('warn', 'Atomic write failed for %s: %s', doc.path, tostring(err))
      os.remove(tmp_path)
    end
  end

  if renamed then
    M._last_written[path] = doc.content
    -- rename() replaces the inode, leaving the fs_event watch bound to the old
    -- one, where it stops firing and inbound external edits are silently lost.
    if M._watchers[path] then M.watch(doc) end
  end
end

--- Schedule a debounced write to disk (call after content changes)
---@param doc table Document instance
function M.schedule_write(doc)
  if not M._sync_dir then return end

  if M._write_timers[doc.doc_id] then vim.fn.timer_stop(M._write_timers[doc.doc_id]) end

  M._write_timers[doc.doc_id] = vim.fn.timer_start(500, function()
    M._write_timers[doc.doc_id] = nil
    M.write_doc(doc)
  end)
end

--- Start watching a file for external changes
---@param doc table Document instance
function M.watch(doc)
  if not M._sync_dir then return end

  local path = M._sync_dir .. '/' .. doc.path

  -- Stop existing watcher for this path
  if M._watchers[path] then
    local old = M._watchers[path]
    if old.handle and not old.handle:is_closing() then
      old.handle:stop()
      old.handle:close()
    end
  end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  M._watchers[path] = { handle = handle, doc_id = doc.doc_id }

  handle:start(path, {}, function(err, _, _)
    if err then return end
    vim.schedule(function() M._on_file_changed(path, doc) end)
  end)
end

--- Stop watching a specific document's file
---@param doc table Document instance
function M.unwatch(doc)
  if not M._sync_dir then return end

  local path = M._sync_dir .. '/' .. doc.path
  local w = M._watchers[path]
  if w then
    if w.handle and not w.handle:is_closing() then
      w.handle:stop()
      w.handle:close()
    end
    M._watchers[path] = nil
  end
end

--- Remember a disk change the current mode would not let us send. It is kept,
--- not dropped, so leaving the mode can say how much is waiting.
---@param path string
---@param what string
local function hold(path, what)
  if not M._held[path] then
    config.log('warn', 'Not sending %s to Overleaf in %s mode: it changed on disk', what, mode.get())
  end
  M._held[path] = true
end

---@return number
function M.held_count()
  local n = 0
  for _ in pairs(M._held) do
    n = n + 1
  end
  return n
end

--- Handle external file change
---@param path string local file path
---@param doc table Document instance
function M._on_file_changed(path, doc)
  local f = io.open(path, 'r')
  if not f then return end
  local new_content = f:read('*a')
  f:close()

  -- No change
  if new_content == doc.content then return end

  -- Our own write coming back. Compared against what we actually wrote, not a
  -- timer, so it stays correct however long the write took and however much the
  -- document has moved on since.
  if new_content == M._last_written[path] then return end

  -- Read-only: leave the file as the external tool wrote it and send nothing.
  if not mode.writable() then
    hold(path, doc.path)
    return
  end
  M._held[path] = nil

  -- Guard: reject empty content when document has existing data.
  -- Prevents truncated file reads (race with external writes) from wiping the buffer.
  if #new_content == 0 and doc.content and #doc.content > 0 then
    config.log('debug', 'Ignoring empty file read for %s (doc has %d bytes)', doc.path, #doc.content)
    return
  end

  config.log('info', 'External change: %s', doc.path)
  -- The disk now holds this content and the doc is about to match it. Record
  -- it as the in-sync state, otherwise a later edit that restores the bytes we
  -- last wrote ourselves (an undo, a revert) would look like our own echo and
  -- be dropped.
  M._last_written[path] = new_content

  if doc.joined and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
    -- Doc is open in Neovim: change only what differs (triggers on_lines → OT →
    -- server), so comment highlights on the untouched text stay where they are.
    require('overleaf.buffer').replace_content(doc.bufnr, new_content)
  else
    -- Doc is NOT open: join, send OT ops directly, leave
    M._sync_closed_doc(doc, new_content)
  end
end

--- Sync a changed file for a document that is not open in Neovim
---@param doc table Document instance
---@param new_content string new file content
function M._sync_closed_doc(doc, new_content)
  bridge.request('joinDoc', { docId = doc.doc_id }, function(err, result)
    if err then
      config.log('error', 'Sync join failed for %s: %s', doc.path, err.message)
      return
    end

    local server_content = table.concat(result.lines, '\n')
    local version = result.version

    -- No change from server's perspective
    if new_content == server_content then
      bridge.request('leaveDoc', { docId = doc.doc_id }, function() end)
      return
    end

    -- Only the words that differ. Deleting the whole document and typing it
    -- back would wipe every comment and suggestion in it, because Overleaf drops
    -- those anchored to any text an op deletes.
    local ops = diff.ops(server_content, new_content, 0, { words = mode.tracked() })

    bridge.request('applyOtUpdate', {
      docId = doc.doc_id,
      op = ops,
      v = version,
      content = server_content,
      tracked = require('overleaf.mode').tracked(),
    }, function(ot_err, _)
      if ot_err then
        config.log('error', 'Sync OT failed for %s: %s', doc.path, ot_err.message)
      else
        config.log('info', 'Synced external change: %s', doc.path)
        -- Update doc state
        doc.content = new_content
        doc.server_content = new_content
        doc.version = (version or 0) + 1
      end

      -- Leave the doc
      bridge.request('leaveDoc', { docId = doc.doc_id }, function() end)
    end)
  end)
end

-- ── FileRefs ─────────────────────────────────────────────────────────────

-- Overleaf's doc/file split is decided by extension at upload time, so a
-- fileRef with one of these extensions is never text and is not worth
-- downloading again on every connect just to find that out.
local BINARY_EXTENSIONS = {}
for ext in
  (
    'png jpg jpeg gif bmp tif tiff webp ico heic pdf eps ps ai zip gz tgz bz2 xz tar 7z rar '
    .. 'ttf otf woff woff2 pfb pfm mp3 mp4 wav ogg mov avi mkv xls xlsx doc docx ppt pptx '
    .. 'jar exe dll so o a bin pyc class'
  ):gmatch('%S+')
do
  BINARY_EXTENSIONS[ext] = true
end

-- Overleaf refuses docs above 2MB, so a text fileRef larger than this could
-- never be a doc either and is not worth scanning.
local MAX_TEXT_FILE_SIZE = 2 * 1024 * 1024

local function is_valid_utf8(s)
  local byte = string.byte
  local i, n = 1, #s
  while i <= n do
    local c = byte(s, i)
    if c < 0x80 then
      i = i + 1
    else
      local len, min
      if c >= 0xC2 and c <= 0xDF then
        len, min = 2, 0x80
      elseif c >= 0xE0 and c <= 0xEF then
        len, min = 3, 0x800
      elseif c >= 0xF0 and c <= 0xF4 then
        len, min = 4, 0x10000
      else
        return false -- stray continuation byte, overlong lead, or > U+10FFFF
      end
      if i + len - 1 > n then return false end
      local cp = c % (2 ^ (7 - len))
      for k = 1, len - 1 do
        local cc = byte(s, i + k)
        if cc < 0x80 or cc > 0xBF then return false end
        cp = cp * 64 + (cc - 0x80)
      end
      if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return false end
      i = i + len
    end
  end
  return true
end

--- Whether a byte string is text by Overleaf's own definition: valid UTF-8
--- with no NUL bytes. This is the check Overleaf applies at upload time, so a
--- fileRef passing it would have been a doc had its extension been whitelisted.
---@param data string|nil
---@return boolean
function M.is_text(data)
  if type(data) ~= 'string' then return false end
  if #data > MAX_TEXT_FILE_SIZE then return false end
  if data:find('\0', 1, true) then return false end
  return is_valid_utf8(data)
end

--- Whether a fileRef may be opened as text, per the `editable_files` setting.
---@param entry table tree entry {name, ...}
---@return boolean|nil false = never; nil = decide from the content
function M.file_policy(entry)
  local mode = config.get().editable_files
  if mode == false or mode == nil then return false end
  local ext = (entry.name:match('%.([^%.]+)$') or ''):lower()
  if type(mode) == 'table' then
    for _, allowed in ipairs(mode) do
      if tostring(allowed):lower():gsub('^%.', '') == ext then return nil end
    end
    return false
  end
  if BINARY_EXTENSIONS[ext] then return false end
  return nil
end

local function read_bytes(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

-- Atomic private write, as write_doc does for docs. Returns true on success.
local function write_bytes(path, data)
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p', SYNC_DIR_MODE)
  local tmp_path = path .. '.tmp.' .. vim.uv.getpid()
  local f = io.open(tmp_path, 'wb')
  if not f then return false end
  f:write(data)
  f:close()
  pcall(vim.uv.fs_chmod, tmp_path, tonumber('600', 8))
  local ok, err = os.rename(tmp_path, path)
  if not ok then
    config.log('warn', 'Atomic write failed for %s: %s', path, tostring(err))
    os.remove(tmp_path)
    return false
  end
  return true
end

--- Download a fileRef, classify it, and mirror it to the sync directory.
--- Text fileRefs are always re-fetched so the mirror stays current (the
--- server copy wins, as it does for docs in sync_all) and are then watched
--- for edits; binaries are fetched once. Sets entry.text.
---@param entry table tree entry {id, name, path, type='file'}
---@param project_id string
---@param callback function|nil called with (err, local_path)
function M.fetch_file(entry, project_id, callback)
  callback = callback or function() end
  local policy = M.file_policy(entry)
  local dest = M._sync_dir and (M._sync_dir .. '/' .. entry.path) or nil

  if policy == false then
    entry.text = false
    -- Known binary already on disk: nothing to refresh (images don't change often)
    if dest and vim.fn.filereadable(dest) == 1 then
      callback(nil, dest)
      return
    end
  end

  bridge.request('downloadFile', {
    cookie = config.get().cookie,
    projectId = project_id,
    fileId = entry.id,
    fileName = entry.name,
  }, function(err, result)
    if err then
      config.log('debug', 'Download skip %s: %s', entry.path, err.message)
      callback(err)
      return
    end

    local data = read_bytes(result.path)
    if not data then
      callback({ code = 'READ_FAILED', message = 'Cannot read ' .. tostring(result.path) })
      return
    end

    entry.text = (policy == nil) and M.is_text(data) or false

    if not dest then
      -- No sync directory: the caller works with the temp download directly
      callback(nil, result.path)
      return
    end

    local on_disk = read_bytes(dest)
    if entry.text then
      -- _last_written holds what we believe is on disk (our mirror writes and
      -- confirmed uploads); anything else there is an edit nobody has synced.
      if on_disk and on_disk ~= data and on_disk ~= M._last_written[dest] then
        config.log(
          'warn',
          'Local copy of %s had unsynced changes and was replaced by the server copy '
            .. '(edits made while not connected are not synced)',
          entry.path
        )
      end
      M._files[entry.path] = { entry = entry, content = data }
    end

    -- Leave an identical file untouched so an open buffer does not see a
    -- spurious "changed on disk" for its own content.
    if on_disk ~= data then
      if not write_bytes(dest, data) then
        callback({ code = 'WRITE_FAILED', message = 'Cannot write ' .. dest })
        return
      end
      M._last_written[dest] = data
    end

    if entry.text then M.watch_file(entry) end
    config.log('debug', 'Downloaded: %s (%s)', entry.path, entry.text and 'text' or 'binary')
    callback(nil, dest)
  end)
end

function M._stop_file_watcher(path)
  local handle = M._file_watchers[path]
  if handle then
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
    M._file_watchers[path] = nil
  end
end

--- Watch a mirrored text fileRef and re-upload it when it changes on disk.
---@param entry table tree entry
function M.watch_file(entry)
  if not M._sync_dir then return end
  local path = M._sync_dir .. '/' .. entry.path
  M._stop_file_watcher(path)

  local handle = vim.uv.new_fs_event()
  if not handle then return end
  M._file_watchers[path] = handle

  local ok = handle:start(path, {}, function(err)
    if err then return end
    vim.schedule(function()
      -- Re-arm on every event: an editor that saves via temp-file-and-rename
      -- replaces the inode, and a watch bound to the old one goes silent.
      if M._file_watchers[path] == handle then M.watch_file(entry) end
      M._on_file_ref_changed(path, entry)
    end)
  end)
  if not ok then
    -- The file may be missing for an instant mid-rename; try once more shortly.
    M._stop_file_watcher(path)
    vim.defer_fn(function()
      if M._files[entry.path] and not M._file_watchers[path] then M.watch_file(entry) end
    end, 200)
  end
end

--- Stop tracking a fileRef (deleted on Overleaf, or sync stopping).
--- The mirrored file is left on disk, as it is for docs.
---@param entry table tree entry
function M.forget_file(entry)
  if not M._sync_dir then return end
  local path = M._sync_dir .. '/' .. entry.path
  M._stop_file_watcher(path)
  if M._file_timers[path] then
    vim.fn.timer_stop(M._file_timers[path])
    M._file_timers[path] = nil
  end
  M._files[entry.path] = nil
  M._last_uploaded[path] = nil
end

--- Follow a rename of a mirrored fileRef: move the disk copy and the watcher.
---@param old_path string previous Overleaf path
---@param entry table tree entry, already carrying the new path
function M.rename_file(old_path, entry)
  if not M._sync_dir then return end
  local state = M._files[old_path]
  if not state then return end
  local from = M._sync_dir .. '/' .. old_path
  local to = M._sync_dir .. '/' .. entry.path
  M._stop_file_watcher(from)
  M._files[old_path] = nil
  vim.fn.mkdir(vim.fn.fnamemodify(to, ':h'), 'p', SYNC_DIR_MODE)
  if os.rename(from, to) then
    M._last_written[to], M._last_written[from] = M._last_written[from], nil
    M._last_uploaded[to], M._last_uploaded[from] = M._last_uploaded[from], nil
  end
  state.entry = entry
  M._files[entry.path] = state
  M.watch_file(entry)
end

--- Handle a change to a mirrored fileRef (debounced: editors write in bursts)
---@param path string disk path
---@param entry table tree entry
function M._on_file_ref_changed(path, entry)
  if M._file_timers[path] then vim.fn.timer_stop(M._file_timers[path]) end
  M._file_timers[path] = vim.fn.timer_start(500, function()
    M._file_timers[path] = nil
    if not M._files[entry.path] then return end -- forgotten meanwhile

    local data = read_bytes(path)
    if not data then return end

    local known = M._files[entry.path]
    if data == M._last_written[path] then return end -- our own mirror write
    if data == M._last_uploaded[path] then return end -- already on Overleaf
    if data == M._uploading[path] then return end -- on its way (a :w in Neovim uploads directly)
    if known and data == known.content then return end

    -- Same guard as docs: a truncated read mid-write must not wipe the file
    if #data == 0 and known and known.content and #known.content > 0 then
      config.log('debug', 'Ignoring empty file read for %s', entry.path)
      return
    end

    config.log('info', 'External change: %s', entry.path)
    M.upload_file(entry, path, data)
  end)
end

--- Replace a fileRef on Overleaf with the given local file.
--- Uploading over an existing name in the same folder replaces it; Overleaf
--- answers with the replacement's new entity id, which the tree entry takes on.
---@param entry table tree entry
---@param local_path string file to send
---@param data string|nil the bytes at local_path, if already read
---@param callback function|nil called with (err, result)
function M.upload_file(entry, local_path, data, callback)
  callback = callback or function() end
  local ol = require('overleaf')
  local project = require('overleaf.project')
  local state = ol._state
  if not state.connected then
    config.log('warn', 'Not connected; %s not uploaded', entry.path)
    callback({ code = 'NOT_CONNECTED', message = 'Not connected' })
    return
  end

  -- Replacing a file wholesale cannot be a suggestion, and viewing sends nothing.
  if not mode.can_replace_files() then
    hold(local_path, entry.path)
    callback({ code = 'MODE', message = 'Not sent in ' .. mode.get() .. ' mode' })
    return
  end
  M._held[local_path] = nil

  data = data or read_bytes(local_path)
  if data then M._uploading[local_path] = data end
  config.log('info', 'Uploading %s...', entry.path)
  bridge.request('uploadFile', {
    cookie = config.get().cookie,
    csrfToken = state.csrf_token,
    projectId = state.project_id,
    filePath = local_path,
    fileName = entry.name,
    parentFolderId = project.get_parent_folder_id(entry),
  }, function(err, result)
    if M._uploading[local_path] == data then M._uploading[local_path] = nil end
    if err then
      config.log('error', 'Upload failed for %s: %s', entry.path, err.message)
      callback(err)
      return
    end
    if data then
      -- Disk and server now agree on these bytes (see _on_file_changed)
      M._last_uploaded[local_path] = data
      M._last_written[local_path] = data
      local known = M._files[entry.path]
      if known then known.content = data end
    end
    local new_id = result and result.entity_id
    if new_id and new_id ~= entry.id then
      config.log('debug', 'Replaced %s: %s -> %s', entry.path, entry.id, new_id)
      -- The entry may already carry the new id if the socket event beat us
      project.update_entry_id(entry.id, new_id)
      entry.id = new_id
    end
    config.log('info', 'Uploaded %s (replaced on Overleaf)', entry.path)
    callback(nil, result)
  end)
end

--- Sync all project documents and files to disk
---@param state table M._state from init.lua
---@param project_tree table[] project._project_tree
---@param callback function|nil called when done
function M.sync_all(state, project_tree, callback)
  if not M._sync_dir then
    if callback then callback() end
    return
  end

  local docs = {}
  local files = {}
  for _, entry in ipairs(project_tree) do
    if entry.type == 'doc' then
      table.insert(docs, entry)
    elseif entry.type == 'file' then
      table.insert(files, entry)
    elseif entry.type == 'folder' then
      -- Ensure folder exists on disk
      vim.fn.mkdir(M._sync_dir .. '/' .. entry.path, 'p', SYNC_DIR_MODE)
    end
  end

  -- Fetch fileRefs (async, fire-and-forget): binaries once, text ones every time
  local project_id = state.project_id
  if project_id and #files > 0 then
    config.log('info', 'Downloading %d file(s)...', #files)
    for _, entry in ipairs(files) do
      M.fetch_file(entry, project_id)
    end
  end

  -- Sync text documents
  if #docs == 0 then
    if callback then callback() end
    return
  end

  config.log('info', 'Syncing %d document(s) to disk...', #docs)

  local remaining = #docs
  local function on_done()
    remaining = remaining - 1
    if remaining <= 0 then
      config.log('info', 'Sync complete: %s', M._sync_dir)
      if callback then callback() end
    end
  end

  for _, entry in ipairs(docs) do
    local doc_id = entry.id
    local doc_path = entry.path

    -- Check if already open
    local existing = state.documents[doc_id]
    if existing and existing.content then
      -- Already joined, just write
      M.write_doc(existing)
      M.watch(existing)
      on_done()
    else
      -- Need to join, write, leave
      bridge.request('joinDoc', { docId = doc_id }, function(err, result)
        if err then
          config.log('debug', 'Sync skip %s: %s', doc_path, err.message)
          on_done()
          return
        end

        local content = table.concat(result.lines, '\n')

        -- Create a lightweight doc object for writing and watching
        local doc = state.documents[doc_id]
        if not doc then
          local Document = require('overleaf.document')
          doc = Document.new(doc_id, doc_path)
          doc.content = content
          doc.server_content = content
          doc.version = result.version
          -- Store it so watchers can find it
          state.documents[doc_id] = doc
        end

        M.write_doc(doc)
        M.watch(doc)

        -- Leave if no buffer (not opened by user)
        if not doc.bufnr then
          doc.joined = false
          bridge.request('leaveDoc', { docId = doc_id }, function() on_done() end)
        else
          on_done()
        end
      end)
    end
  end
end

--- Re-sync: read all disk files and push changes to Overleaf
---@param state table M._state from init.lua
function M.import_all(state)
  if not M._sync_dir then
    config.log('warn', 'File sync not enabled (set sync_dir in config)')
    return
  end
  if not mode.require_write('importing changed files') then return end

  local changed = 0
  for _, doc in pairs(state.documents) do
    local path = M._sync_dir .. '/' .. doc.path
    local f = io.open(path, 'r')
    if f then
      local disk_content = f:read('*a')
      f:close()

      if disk_content ~= doc.content then
        changed = changed + 1
        if doc.joined and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
          require('overleaf.buffer').replace_content(doc.bufnr, disk_content)
        else
          M._sync_closed_doc(doc, disk_content)
        end
      end
    end
  end

  for doc_path, known in pairs(M._files) do
    local path = M._sync_dir .. '/' .. doc_path
    local disk_content = read_bytes(path)
    if disk_content and disk_content ~= known.content then
      changed = changed + 1
      M.upload_file(known.entry, path, disk_content)
    end
  end

  if changed == 0 then
    config.log('info', 'No external changes detected')
  else
    config.log('info', 'Importing %d changed file(s)', changed)
  end
end

--- Export: write all open documents to disk
---@param state table M._state from init.lua
function M.export_all(state)
  if not M._sync_dir then
    config.log('warn', 'File sync not enabled (set sync_dir in config)')
    return
  end

  local count = 0
  for _, doc in pairs(state.documents) do
    if doc.content then
      M.write_doc(doc)
      count = count + 1
    end
  end

  for doc_path, known in pairs(M._files) do
    local path = M._sync_dir .. '/' .. doc_path
    if read_bytes(path) ~= known.content and write_bytes(path, known.content) then
      M._last_written[path] = known.content
      M.watch_file(known.entry)
    end
    count = count + 1
  end

  config.log('info', 'Exported %d document(s) to %s', count, M._sync_dir)
end

return M
