--- Local file sync for external tool integration (e.g., Claude Code)
--- Mirrors Overleaf documents to disk and watches for external changes.
local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local diff = require('overleaf.diff')
local ot = require('overleaf.ot')
local mode = require('overleaf.mode')
local merge = require('overleaf.merge')

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
M._deleted = {} -- path -> true: deleted on disk, watcher gone until we rewrite it

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
M._dir_watchers = {} -- directory -> fs_event handle (Linux events are not recursive)
M._dir_inodes = {} -- directory -> inode, for rename-replaced folders
M._new_file_timers = {} -- disk path -> stability timer
M._creating = {} -- project path -> true while create/upload is in flight
M._folder_pending = {} -- project folder path -> waiting callbacks
M._new_file_state = nil -- state passed to sync_all, for directory events
M._generation = 0 -- invalidates callbacks when switching projects

-- Overleaf's default editable document extensions. There is no extension list
-- in the bridge or project modules; they classify existing fileRefs by content.
local TEXT_EXTENSIONS = {}
for ext in
  (
    'tex latex sty cls bst bib bibtex txt tikz mtx rtex md asy lbx bbx cbx m lco '
    .. 'dtx ins ist def clo ldf rmd qmd lua py gv mf yml yaml lhs lean lean4 '
    .. 'hs mk xmpdata cfg rnw ltx inc fd'
  ):gmatch('%S+')
do
  TEXT_EXTENSIONS[ext] = true
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
  if M._new_file_state then M.watch_directory(dir) end
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

--- Start sync for a project. Creates the sync directory.
---@param project_name string
function M.start(project_name)
  local sync_dir = config.get().sync_dir
  if not sync_dir then return end
  M._generation = M._generation + 1

  -- Expand ~ and resolve
  sync_dir = vim.fn.expand(sync_dir)

  -- Use project subdirectory
  M._sync_dir = sync_dir .. '/' .. project_name:gsub('[^%w%-_%.%s]', '_')
  vim.fn.mkdir(M._sync_dir, 'p', SYNC_DIR_MODE)

  config.log('info', 'File sync: %s', M._sync_dir)
end

--- Stop all watchers and timers
function M.stop()
  M._generation = M._generation + 1
  for _, handle in pairs(M._dir_watchers) do
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  M._dir_watchers = {}
  M._dir_inodes = {}
  for _, timer in pairs(M._new_file_timers) do
    vim.fn.timer_stop(timer)
  end
  M._new_file_timers = {}
  M._creating = {}
  M._folder_pending = {}
  M._new_file_state = nil
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
  M._last_written = {}
  M._last_uploaded = {}
  M._uploading = {}
  M._held = {}
  M._deleted = {}

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

  local existing = io.open(path, 'rb')
  local on_disk = existing and existing:read('*a')
  if existing then existing:close() end

  -- A watcher may have missed an external save while this write was debounced.
  -- In viewing mode _on_file_changed holds it; do not overwrite that disk edit.
  -- An empty file is a write caught half-done, which _on_file_changed ignores;
  -- fall through and rewrite it rather than leave it empty.
  if
    M._last_written[path] ~= nil
    and on_disk ~= nil
    and on_disk ~= ''
    and on_disk ~= M._last_written[path]
    and on_disk ~= doc.content
  then
    M._on_file_changed(path, doc)
    return
  end

  -- Already there: leave the file alone, so a tool that checks the file's
  -- modification time before editing does not see a change that is not one.
  if on_disk == doc.content then
    M._last_written[path] = on_disk
    if M._deleted[path] then
      M._deleted[path] = nil
      M.watch(doc)
    end
    return
  end

  M._write_text(doc, doc.content)
end

--- Write `content` to a document's mirror file, without the check write_doc
--- makes for an unprocessed external edit. Returns true on success.
---@param doc table Document instance
---@param content string
---@return boolean
function M._write_text(doc, content)
  if not M._sync_dir then return false end
  local path = M._sync_dir .. '/' .. doc.path

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p', SYNC_DIR_MODE)
  if M._new_file_state then M.watch_directory(dir) end

  -- Atomic write: temp file + rename to prevent partial reads from fs_event race
  local tmp_path = path .. '.tmp.' .. vim.uv.getpid()
  local f = io.open(tmp_path, 'w')
  local renamed = false
  if f then
    f:write(content)
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
    M._last_written[path] = content
    -- Our rename() replaces the inode, so re-watch here. External renames are
    -- handled in watch, which re-arms before processing their event.
    if M._watchers[path] or M._deleted[path] then
      M._deleted[path] = nil
      M.watch(doc)
    end
  end
  return renamed
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
function M.watch(doc, retrying)
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

  local ok = handle:start(path, {}, function(err, _, _)
    if err then return end
    vim.schedule(function()
      -- A rename-replace leaves the old inode's watcher silent. Re-arm before
      -- processing this event so another external save cannot be missed.
      if M._watchers[path] and M._watchers[path].handle == handle then
        M.watch(doc)
        M._on_file_changed(path, doc)
      end
    end)
  end)
  if not ok then
    handle:close()
    local pending = { doc_id = doc.doc_id }
    M._watchers[path] = pending
    if retrying then
      M._watchers[path] = nil
      if not vim.uv.fs_stat(path) then
        -- Remembered so the next write of this document recreates the file
        -- and watches it again.
        M._deleted[path] = true
        config.log('warn', '%s was deleted on disk; it is not deleted on Overleaf', doc.path)
      end
    else
      -- A rename may leave the path briefly absent; retry once after it settles.
      vim.defer_fn(function()
        if M._watchers[path] == pending then M.watch(doc, true) end
      end, 200)
    end
  end
end

--- Stop watching a specific document's file
---@param doc table Document instance
function M.unwatch(doc, cancel_write)
  if not M._sync_dir then return end

  if cancel_write and M._write_timers[doc.doc_id] then
    vim.fn.timer_stop(M._write_timers[doc.doc_id])
    M._write_timers[doc.doc_id] = nil
  end

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

--- Follow a document path change without rewriting its mirrored content.
---@param old_path string previous Overleaf path
---@param doc table document already carrying its new path
function M.move_doc(old_path, doc)
  if not M._sync_dir or old_path == doc.path then return end
  local from = M._sync_dir .. '/' .. old_path
  local to = M._sync_dir .. '/' .. doc.path
  local watcher = M._watchers[from]
  if watcher then
    if watcher.handle and not watcher.handle:is_closing() then
      watcher.handle:stop()
      watcher.handle:close()
    end
    M._watchers[from] = nil
  end
  if vim.uv.fs_stat(from) then
    vim.fn.mkdir(vim.fn.fnamemodify(to, ':h'), 'p', SYNC_DIR_MODE)
    local ok, err = os.rename(from, to)
    if not ok then config.log('warn', 'Could not move mirror %s: %s', old_path, tostring(err)) end
    -- Drop directories the move left empty (fs_rmdir refuses non-empty ones).
    local dir = vim.fn.fnamemodify(from, ':h')
    while #dir > #M._sync_dir and vim.uv.fs_rmdir(dir) do
      dir = vim.fn.fnamemodify(dir, ':h')
    end
  end
  M._last_written[to], M._last_written[from] = M._last_written[from], nil
  M._deleted[to], M._deleted[from] = M._deleted[from], nil
  M._held[to], M._held[from] = M._held[from], nil
  if watcher then M.watch(doc) end
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

--- Whether a document keeps its own live text: joined, or rejoining. Disk
--- edits to one are merged into that text and sent through the Document.
local function is_live(doc) return doc.content ~= nil and (doc.joined == true or doc._rejoining == true) end

local function has_buffer(doc) return doc.bufnr ~= nil and vim.api.nvim_buf_is_valid(doc.bufnr) end

--- Keep a disk edit to a document that is not syncing with Overleaf (stopped
--- after a failure, or open but not joined). It is merged once the document
--- rejoins: the rejoin's mirror write finds it (see write_doc).
local function hold_unsynced(path, doc)
  if not M._held[path] then
    config.log(
      'warn',
      'Not sending the disk edit to %s: the document is not syncing with Overleaf. '
        .. 'The edit stays on disk and is merged when the document rejoins',
      doc.path
    )
  end
  M._held[path] = true
end

--- A name next to `path` that no file has yet.
local function conflict_path(path)
  local n = 1
  while vim.uv.fs_lstat(path .. '.overleaf-conflict.' .. n) do
    n = n + 1
  end
  return path .. '.overleaf-conflict.' .. n
end

--- A document that appears on Overleaf where a file already exists only on
--- disk (an agent's file not yet imported, or one made while sync_new_files
--- is off) would be overwritten by the mirror. Keep those bytes first.
---@param doc table Document instance with content
function M.preserve_disk_only(doc)
  if not M._sync_dir or doc.content == nil then return end
  local path = M.file_path(doc.path)
  if M._last_written[path] ~= nil then return end
  local on_disk = read_bytes(path)
  if not on_disk or on_disk == doc.content then return end
  local copy = conflict_path(path)
  if write_bytes(copy, on_disk) then
    config.log(
      'warn',
      '%s was created on Overleaf over a file only on disk; the disk file was kept as %s',
      doc.path,
      copy
    )
  else
    config.log('error', '%s was created on Overleaf over a file only on disk, which could not be saved', doc.path)
  end
end

--- Merge an external write into the current text. `base` is what the writer
--- read: the bytes the plugin last wrote. Returns the text Overleaf should
--- hold, or nil when the two sides' edits overlap. Then nothing may be sent:
--- the writer's version goes to a conflict copy and the file is put back to
--- `theirs`.
---@param path string disk path
---@param doc table Document instance
---@param base string|nil
---@param mine string the disk content
---@param theirs string the current text
---@return string|nil
function M._merge_external(path, doc, base, mine, theirs)
  if base == nil then
    config.log('warn', '%s changed on disk before the plugin wrote it; sent as it is, without a merge', doc.path)
    return mine
  end
  local merged = merge.three_way(base, mine, theirs)
  if merged then return merged end
  local copy = conflict_path(path)
  if not write_bytes(copy, mine) then
    -- The disk holds the writer's only copy. Keep the base, so a later
    -- write_doc does not take it for our own echo and write over it.
    M._last_written[path] = base
    M._held[path] = true
    config.log(
      'error',
      'The disk edit to %s overlaps edits made on Overleaf, and could not be saved to %s. '
        .. 'Nothing was sent and the file was left as it is',
      doc.path,
      copy
    )
    return nil
  end
  M._write_text(doc, theirs)
  config.log(
    'warn',
    'The disk edit to %s overlaps edits made on Overleaf since it was read. Nothing was sent: '
      .. '%s now holds the Overleaf text and the disk edit is in %s',
    doc.path,
    doc.path,
    copy
  )
  return nil
end

--- Send `merged` from a live document's current text `theirs`, showing it in
--- the buffer if the document is open. Returns the text Overleaf will hold,
--- which differs from `merged` where it had characters Overleaf cannot store.
---@param doc table Document instance
---@param theirs string
---@param merged string
---@return string
local function apply_merged(doc, theirs, merged)
  local ops, replaced = ot.sanitize_inserts(diff.ops(theirs, merged, 0, { words = mode.tracked() }))
  if #ops == 0 then return theirs end
  local content = ot.apply(theirs, ops)
  doc.content = content
  if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
    -- Shown the way a remote edit is: the change is already in doc.content,
    -- so the buffer must not diff it a second time.
    local ok, err = pcall(doc._replace_buffer, doc, content)
    if not ok then config.log('warn', 'Could not show the disk edit to %s in its buffer: %s', doc.path, err) end
  end
  doc:submit_op(ops)
  config.log('info', 'Synced external change: %s', doc.path)
  if replaced then
    config.log('warn', 'Characters outside the Basic Multilingual Plane in %s were stored as U+FFFD', doc.path)
  end
  return content
end

--- Merge a disk edit into a live document and write the result back.
local function sync_live_doc(path, doc, mine)
  local theirs = doc.content
  local merged = M._merge_external(path, doc, M._last_written[path], mine, theirs)
  if not merged then return end
  local content = apply_merged(doc, theirs, merged)
  if content ~= mine then
    -- The writer's file gets the edits it had not seen.
    M._write_text(doc, content)
  else
    -- The disk holds the document's text. Record it as the in-sync state,
    -- otherwise a later edit that restores the bytes we last wrote ourselves
    -- (an undo, a revert) would look like our own echo and be dropped.
    M._last_written[path] = mine
  end
  -- Catches a later external save whose watcher event is lost (see write_doc).
  M.schedule_write(doc)
end

--- Handle external file change
---@param path string local file path
---@param doc table Document instance
function M._on_file_changed(path, doc)
  local mine = read_bytes(path)
  if not mine then return end

  -- Our own write coming back. Compared against what we actually wrote, not a
  -- timer, so it stays correct however long the write took and however much the
  -- document has moved on since.
  if mine == M._last_written[path] then return end

  -- The buffer's latest typing becomes part of the text the edit is merged into.
  if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then require('overleaf.buffer').reconcile(doc) end

  -- No change
  if mine == doc.content then
    M._last_written[path] = mine
    return
  end

  -- Read-only: leave the file as the external tool wrote it and send nothing.
  if not mode.writable() then
    hold(path, doc.path)
    return
  end

  -- Guard: reject empty content when document has existing data.
  -- Prevents truncated file reads (race with external writes) from wiping the buffer.
  if #mine == 0 and doc.content and #doc.content > 0 then
    config.log('debug', 'Ignoring empty file read for %s (doc has %d bytes)', doc.path, #doc.content)
    return
  end

  config.log('info', 'External change: %s', doc.path)
  if doc._joining then
    -- A join is under way (a restore, or a first join): merge once it has the
    -- text, reading the disk again then.
    if not doc._external_waiting then
      doc._external_waiting = true
      local generation = M._generation
      doc:join(function(err)
        doc._external_waiting = nil
        if M._generation ~= generation then return end
        if err then
          hold_unsynced(path, doc)
          return
        end
        M._on_file_changed(path, doc)
      end)
    end
  elseif doc._stopped or (has_buffer(doc) and not is_live(doc)) then
    hold_unsynced(path, doc)
  elseif is_live(doc) then
    M._held[path] = nil
    sync_live_doc(path, doc, mine)
  else
    M._held[path] = nil
    M._sync_closed_doc(doc, mine)
  end
end

--- Send a disk change for a document that stays joined without a buffer.
--- Joining again and leaving, as the closed-document path does, would detach
--- the socket from a document the client still tracks as joined.
---@param doc table Document instance (joined)
---@param new_content string file content
function M._sync_joined_doc(doc, new_content)
  local ops, replaced = ot.sanitize_inserts(diff.ops(doc.content, new_content, 0, { words = mode.tracked() }))
  if #ops == 0 then return end
  doc.content = ot.apply(doc.content, ops)
  doc:submit_op(ops)
  config.log('info', 'Synced external change: %s', doc.path)
  -- Emoji are stored as U+FFFD; put what Overleaf has back on disk.
  if replaced then
    config.log('warn', 'Characters outside the Basic Multilingual Plane in %s were stored as U+FFFD', doc.path)
    M.schedule_write(doc)
  end
end

--- Sync a disk change for a document the mirror could not keep joined: join,
--- merge against the server text, send, and leave. Live documents are merged
--- into their own text instead.
---@param doc table Document instance
---@param new_content string new file content
---@param callback function|nil called with an error after the edit completes
function M._sync_closed_doc(doc, new_content, callback)
  callback = callback or function() end
  local path = M._sync_dir .. '/' .. doc.path
  if is_live(doc) then
    sync_live_doc(path, doc, new_content)
    callback(nil)
    return
  end
  -- The base is what the writer read. The disk now holds its edit; record that
  -- as the in-sync state at once, so that a revert to these bytes while the
  -- join is under way is not taken for our own echo. A failure puts the base
  -- back (see `unsent`).
  local base = M._last_written[path]
  M._last_written[path] = new_content
  local function snapshot(text, version)
    doc.content = text
    doc.server_content = text
    doc.version = version
  end
  local function restore_base()
    if M._last_written[path] == new_content then M._last_written[path] = base end
  end
  -- The edit did not reach Overleaf: keep it on disk and held, and keep the
  -- base, so a later write_doc does not take the writer's only copy for our
  -- own echo and write over it.
  local function unsent(why, err)
    restore_base()
    M._held[path] = true
    config.log('error', '%s for %s: %s; the disk edit was not sent and stays on disk', why, doc.path, err.message)
  end
  -- A Document joined this document meanwhile (it was opened, or the mirror
  -- joined it again): it owns the text now, and a leaveDoc would stop its
  -- updates.
  local function taken_over() return doc.joined or doc._joining end
  local generation = M._generation
  bridge.request('joinDoc', { docId = doc.doc_id }, function(err, result)
    local function leave(done_err)
      if not taken_over() then bridge.request('leaveDoc', { docId = doc.doc_id }, function() end) end
      callback(done_err)
    end
    if err then
      if M._generation == generation then unsent('Sync join failed', err) end
      callback(err)
      return
    end
    if M._generation ~= generation then return leave() end
    if taken_over() then
      restore_base()
      M._on_file_changed(path, doc)
      callback(nil)
      return
    end

    local theirs = table.concat(result.lines, '\n')
    local version = result.version
    if new_content == theirs then
      snapshot(theirs, version)
      leave()
      return
    end
    local merged = M._merge_external(path, doc, base, new_content, theirs)
    if not merged then
      snapshot(theirs, version)
      leave()
      return
    end

    -- Only the words that differ. Deleting the whole document and typing it
    -- back would wipe every comment and suggestion in it, because Overleaf drops
    -- those anchored to any text an op deletes.
    local ops, replaced = ot.sanitize_inserts(diff.ops(theirs, merged, 0, { words = mode.tracked() }))
    if replaced then merged = ot.apply(theirs, ops) end
    if #ops == 0 then
      snapshot(theirs, version)
      M._write_text(doc, theirs)
      leave()
      return
    end

    bridge.request('applyOtUpdate', {
      docId = doc.doc_id,
      op = ops,
      v = version,
      content = theirs,
      tracked = mode.tracked(),
    }, function(ot_err, _)
      if M._generation ~= generation then return leave(ot_err) end
      if ot_err then
        unsent('Sync OT failed', ot_err)
      elseif taken_over() then
        -- The Document catches up with this op from the server.
        config.log('info', 'Synced external change: %s', doc.path)
      else
        config.log('info', 'Synced external change: %s', doc.path)
        snapshot(merged, (version or 0) + 1)
        if replaced then
          config.log('warn', 'Characters outside the Basic Multilingual Plane in %s were stored as U+FFFD', doc.path)
        end
        -- The writer's file gets what Overleaf now has.
        if merged ~= new_content then M._write_text(doc, merged) end
      end
      leave(ot_err)
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

local function new_files_enabled()
  local setting = config.get().sync_new_files
  return setting == true or type(setting) == 'table'
end

local function binary_allowed(ext)
  local setting = config.get().sync_new_files
  if type(setting) ~= 'table' then return false end
  for _, allowed in ipairs(setting.binary or {}) do
    if tostring(allowed):lower():gsub('^%.', '') == ext then return true end
  end
  return false
end

local IGNORED_DIRECTORIES = { build = true, out = true, output = true, _build = true, node_modules = true }
local IGNORED_EXTENSIONS = {
  aux = true,
  log = true,
  out = true,
  fdb_latexmk = true,
  fls = true,
  bbl = true,
  blg = true,
}

local function ignored_name(name, directory)
  if name:sub(1, 1) == '.' or name == '4913' or name:sub(-1) == '~' then return true end
  if name:match('%.overleaf%-conflict%.') or name:match('%.tmp%.') then return true end
  if name:match('%.sw[ponx]$') or name:match('%.bak$') or name:match('%.orig$') or name:match('%.rej$') then
    return true
  end
  if
    name:match('%.part$')
    or name:match('%.crdownload$')
    or name:match('%.tmp$')
    or name:match('%.temp$')
    or name:match('%.new$')
    or name:match('^#.*#$')
  then
    return true
  end
  if directory then return IGNORED_DIRECTORIES[name:lower()] == true end
  local ext = (name:match('%.([^%.]+)$') or ''):lower()
  if IGNORED_EXTENSIONS[ext] or name:lower():match('%.synctex%.gz$') then return true end
  return ext == 'pdf' and not binary_allowed('pdf')
end

local function tree_refresh()
  vim.schedule(function() require('overleaf.tree').refresh() end)
end

local function entry_depth(parent_id, project)
  local parent = project.get_doc_by_id(parent_id)
  return parent and (parent.depth or 0) + 1 or 0
end

local function request_params(state)
  return { cookie = config.get().cookie, csrfToken = state.csrf_token, projectId = state.project_id }
end

-- Several files may appear in a new folder at once. Queue them behind one
-- createFolder request, and build parents from the root outward.
local function ensure_folder(folder_path, state, callback)
  local generation = M._generation
  local project = require('overleaf.project')
  if folder_path == '' then
    callback(nil, project._root_folder_id)
    return
  end
  local existing = project.get_doc_by_path(folder_path)
  if existing then
    callback(nil, existing.id)
    return
  end
  if M._folder_pending[folder_path] then
    table.insert(M._folder_pending[folder_path], callback)
    return
  end
  M._folder_pending[folder_path] = { callback }
  local parent_path = folder_path:sub(1, -2):match('^(.*/)') or ''
  ensure_folder(parent_path, state, function(parent_err, parent_id)
    local function finish(err, id)
      local pending = M._folder_pending[folder_path] or {}
      M._folder_pending[folder_path] = nil
      for _, cb in ipairs(pending) do
        cb(err, id)
      end
    end
    if parent_err then
      finish(parent_err)
      return
    end
    local name = folder_path:sub(#parent_path + 1, -2)
    local params = request_params(state)
    params.name, params.parentFolderId = name, parent_id
    bridge.request('createFolder', params, function(err, result)
      if M._generation ~= generation then return end
      if err then
        finish(err)
        return
      end
      local id = (result and (result._id or result.id)) or (project.get_doc_by_path(folder_path) or {}).id
      if not id then
        finish({ message = 'createFolder returned no id' })
        return
      end
      project.add_entry({
        id = id,
        name = name,
        path = folder_path,
        type = 'folder',
        depth = entry_depth(parent_id, project),
      })
      tree_refresh()
      finish(nil, id)
    end)
  end)
end

--- Import one stable, new disk file. The path must be inside the mirror.
function M._import_new_file(path, state)
  if not M._sync_dir or not state or not state.connected then return end
  local project = require('overleaf.project')
  local rel = path:sub(#M._sync_dir + 2)
  if path:sub(1, #M._sync_dir + 1) ~= M._sync_dir .. '/' then return end
  if project.path_exists(rel) or M._last_written[path] ~= nil or M._creating[rel] or M._held[path] then return end
  local name = rel:match('([^/]+)$')
  local ext = (name:match('%.([^%.]+)$') or ''):lower()
  if ignored_name(name, false) then return end
  local is_doc = TEXT_EXTENSIONS[ext] == true
  if not is_doc and not binary_allowed(ext) then return end
  local data = read_bytes(path)
  if not data then return end
  if is_doc and not M.is_text(data) then
    hold(path, rel)
    config.log('warn', 'Not creating %s: it is not valid UTF-8 text', rel)
    return
  end
  if not mode.writable() or (not is_doc and not mode.can_replace_files()) then
    hold(path, rel)
    return
  end

  M._creating[rel] = true
  local generation = M._generation
  local parent_path = rel:match('^(.*/)') or ''
  ensure_folder(parent_path, state, function(folder_err, parent_id)
    if M._generation ~= generation then return end
    if folder_err then
      M._creating[rel] = nil
      hold(path, rel)
      config.log('warn', 'Could not create parent folder for %s: %s', rel, folder_err.message or tostring(folder_err))
      return
    end
    if not vim.uv.fs_stat(path) then
      M._creating[rel] = nil
      return
    end
    local params = request_params(state)
    params.name, params.parentFolderId = name, parent_id
    if is_doc then
      bridge.request('createDoc', params, function(err, result)
        if M._generation ~= generation then return end
        if err then
          M._creating[rel] = nil
          hold(path, rel)
          config.log('warn', 'Could not create %s on Overleaf: %s', rel, err.message or tostring(err))
          return
        end
        local id = (result and (result._id or result.id)) or (project.get_doc_by_path(rel) or {}).id
        if not id then
          M._creating[rel] = nil
          hold(path, rel)
          config.log('warn', 'Could not create %s: createDoc returned no id', rel)
          return
        end
        local entry = { id = id, name = name, path = rel, type = 'doc', depth = entry_depth(parent_id, project) }
        project.add_entry(entry)
        tree_refresh()
        local Document = require('overleaf.document')
        local doc = state.documents[id] or Document.new(id, rel)
        state.documents[id] = doc
        -- Joined through the Document, which then stays joined: the content
        -- goes out as an ordinary op with acks, resends and rejoins handled
        -- there, and as a tracked insertion in suggesting mode (decision D4).
        doc:join(function(join_err)
          if M._generation ~= generation then return end
          if join_err then
            M._creating[rel] = nil
            hold(path, rel)
            config.log('warn', 'Could not join new document %s: %s', rel, join_err.message or tostring(join_err))
            return
          end
          M._creating[rel] = nil
          if doc.content ~= '' then
            hold(path, rel)
            config.log('warn', 'New document %s already has server content; local content was held', rel)
            return
          end
          M._held[path] = nil
          M._last_written[path] = data
          M._sync_joined_doc(doc, data)
          M.watch(doc)
        end)
      end)
    else
      local entry = { name = name, path = rel, type = 'file', depth = entry_depth(parent_id, project) }
      M.upload_file(entry, path, data, function(err, result)
        if M._generation ~= generation then return end
        M._creating[rel] = nil
        if err then
          hold(path, rel)
          return
        end
        entry.id = (result and result.entity_id) or (project.get_doc_by_path(rel) or {}).id
        if entry.id then
          project.add_entry(entry)
          tree_refresh()
        end
      end, state)
    end
  end)
end

local function check_stable_file(path, state, manual)
  if M._new_file_timers[path] then return end
  local initial = vim.uv.fs_stat(path)
  if not initial or initial.type ~= 'file' then return end
  M._new_file_timers[path] = vim.fn.timer_start(500, function()
    M._new_file_timers[path] = nil
    if not M._sync_dir or (not manual and M._new_file_state ~= state) then return end
    local current = vim.uv.fs_stat(path)
    if not current or current.type ~= 'file' then return end
    if current.size ~= initial.size then
      check_stable_file(path, state, manual)
    else
      M._import_new_file(path, state)
    end
  end)
end

--- Watch a mirrored folder. Each directory needs its own fs_event on Linux.
function M.watch_directory(dir)
  if not M._sync_dir or not M._new_file_state then return end
  local stat = vim.uv.fs_stat(dir)
  if not stat or stat.type ~= 'directory' then return end
  if M._dir_watchers[dir] then
    if M._dir_inodes[dir] == stat.ino then return end
    local old = M._dir_watchers[dir]
    if not old:is_closing() then
      old:stop()
      old:close()
    end
    M._dir_watchers[dir] = nil
  end
  local handle = vim.uv.new_fs_event()
  if not handle then return end
  local ok = handle:start(dir, {}, function(err)
    if err then return end
    vim.schedule(function()
      if M._dir_watchers[dir] == handle then M.scan_new_files(M._new_file_state) end
    end)
  end)
  if not ok then
    handle:close()
    return
  end
  M._dir_watchers[dir] = handle
  M._dir_inodes[dir] = stat.ino
end

--- Scan current folders and add watches for folders created after connect.
--- Called on directory events as well as at the end of the initial sync.
function M.scan_new_files(state, manual)
  if not M._sync_dir then return end
  local seen = {}
  local function visit(dir, prefix)
    seen[dir] = true
    if new_files_enabled() then M.watch_directory(dir) end
    local scan = vim.uv.fs_scandir(dir)
    if not scan then return end
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then break end
      local path = dir .. '/' .. name
      if kind == 'directory' and not ignored_name(name, true) then
        visit(path, prefix .. name .. '/')
      elseif kind == 'file' and (new_files_enabled() or manual) and not ignored_name(name, false) then
        local rel = prefix .. name
        local project = require('overleaf.project')
        if
          not project.path_exists(rel)
          and M._last_written[path] == nil
          and not M._creating[rel]
          and not M._held[path]
        then
          check_stable_file(path, state, manual)
        end
      end
    end
  end
  visit(M._sync_dir, '')
  for dir, handle in pairs(M._dir_watchers) do
    if not seen[dir] or not new_files_enabled() then
      if not handle:is_closing() then
        handle:stop()
        handle:close()
      end
      M._dir_watchers[dir] = nil
      M._dir_inodes[dir] = nil
    end
  end
end

--- Compare regular disk files with the project tree, including held edits.
function M.status(project_tree)
  if not M._sync_dir then
    config.log('warn', 'File sync not enabled (set sync_dir in config)')
    return nil
  end
  local known = {}
  for _, entry in ipairs(project_tree or {}) do
    if entry.type == 'doc' or entry.type == 'file' then known[entry.path] = true end
  end
  local disk = {}
  local function visit(dir, prefix)
    local scan = vim.uv.fs_scandir(dir)
    if not scan then return end
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then break end
      if kind == 'directory' then
        visit(dir .. '/' .. name, prefix .. name .. '/')
      elseif kind == 'file' then
        disk[prefix .. name] = true
      end
    end
  end
  visit(M._sync_dir, '')
  local result = { disk_only = {}, missing_on_disk = {}, held = {} }
  for path in pairs(disk) do
    if not known[path] then table.insert(result.disk_only, path) end
  end
  for path in pairs(known) do
    if not disk[path] then table.insert(result.missing_on_disk, path) end
  end
  for path in pairs(M._held) do
    if path:sub(1, #M._sync_dir + 1) == M._sync_dir .. '/' then
      table.insert(result.held, path:sub(#M._sync_dir + 2))
    end
  end
  for _, list in pairs(result) do
    table.sort(list)
  end
  local lines = { 'Mirror status:' }
  for _, group in ipairs({
    { 'Disk only', result.disk_only },
    { 'Missing on disk', result.missing_on_disk },
    { 'Held changes', result.held },
  }) do
    table.insert(lines, string.format('%s (%d):', group[1], #group[2]))
    for _, path in ipairs(group[2]) do
      table.insert(lines, '  ' .. path)
    end
  end
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
  return result
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
function M.upload_file(entry, local_path, data, callback, state_override)
  callback = callback or function() end
  local ol = require('overleaf')
  local project = require('overleaf.project')
  local state = state_override or ol._state
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
  local function finish()
    if new_files_enabled() then
      M._new_file_state = state
      M.scan_new_files(state)
    end
    if callback then callback() end
  end
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
    finish()
    return
  end

  config.log('info', 'Syncing %d document(s) to disk...', #docs)

  local remaining = #docs
  local function on_done()
    remaining = remaining - 1
    if remaining <= 0 then
      config.log('info', 'Sync complete: %s', M._sync_dir)
      finish()
    end
  end

  local Document = require('overleaf.document')
  local generation = M._generation

  -- Fallback for a document the Document could not join: mirror a snapshot
  -- and leave, as before. Its file does not follow remote edits, and disk
  -- edits to it are merged against a fresh join (_sync_closed_doc).
  local function snapshot(doc)
    bridge.request('joinDoc', { docId = doc.doc_id }, function(err, result)
      if M._generation ~= generation then return end
      if err then
        config.log('warn', 'Could not mirror %s: %s', doc.path, err.message or tostring(err))
        if state.documents[doc.doc_id] == doc and doc.content == nil then state.documents[doc.doc_id] = nil end
        on_done()
        return
      end
      -- A Document joined it meanwhile, which owns it now: no leave.
      if doc.joined or doc._joining then return on_done() end
      if state.documents[doc.doc_id] ~= doc then
        -- Deleted while the join was under way.
        bridge.request('leaveDoc', { docId = doc.doc_id }, function() end)
        return on_done()
      end
      local content = table.concat(result.lines, '\n')
      doc.content = content
      doc.server_content = content
      doc.version = result.version
      M.write_doc(doc)
      M.watch(doc)
      bridge.request('leaveDoc', { docId = doc.doc_id }, function() on_done() end)
    end)
  end

  for _, entry in ipairs(docs) do
    local doc = state.documents[entry.id]
    local open = doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr)
    if doc and doc.content ~= nil and (doc.joined or doc._rejoining or open) then
      -- Already joined, just write
      M.write_doc(doc)
      M.watch(doc)
      on_done()
    else
      if not doc then
        doc = Document.new(entry.id, entry.path)
        state.documents[entry.id] = doc
      end
      -- Every mirrored document stays joined, so remote edits keep its file
      -- current and a disk edit is merged into live text.
      doc:join(function(err)
        if M._generation ~= generation then return end
        if state.documents[entry.id] ~= doc then
          -- Deleted while the join was under way.
          if not err then doc:leave() end
          return on_done()
        end
        if err then
          config.log(
            'warn',
            'Could not keep %s joined (%s); its mirror is a snapshot that does not follow remote edits',
            doc.path,
            err.message or tostring(err)
          )
          snapshot(doc)
          return
        end
        M.write_doc(doc)
        M.watch(doc)
        on_done()
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
        -- The same merge as for a watcher event.
        M._on_file_changed(path, doc)
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

  -- An explicit import also discovers disk-only files when automatic creation
  -- is disabled. The same extension and mode rules still apply.
  M.scan_new_files(state, true)

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
