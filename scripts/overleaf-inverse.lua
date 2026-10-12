-- Viewers run: nvim --clean -l overleaf-inverse.lua STATEFILE FILE LINE COLUMN.
-- Read the current Neovim server address and send the source jump by RPC.
local statefile, file, line, column = unpack(_G.arg)
local function fail(message)
  io.stderr:write('overleaf inverse search: ' .. message .. '\n')
  vim.cmd('cquit 1')
end

-- The state file is a local RPC capability: never trust one that another user
-- could replace or rewrite, even when the path came from a viewer command.
local stat = vim.uv.fs_stat(statefile or '')
if not stat then fail('missing server state file') end
if stat.type ~= 'file' or stat.uid ~= vim.uv.getuid() or bit.band(stat.mode, tonumber('022', 8)) ~= 0 then
  fail('insecure server state file')
end
local input = io.open(statefile or '', 'r')
if not input then fail('missing server state file') end
local server = input:read('*l')
input:close()
if not server or server == '' then fail('missing server address') end
local connected, channel = pcall(vim.fn.sockconnect, 'pipe', server, { rpc = true })
if not connected or channel <= 0 then fail('Neovim server is unavailable') end
local ok, err = pcall(
  vim.rpcrequest,
  channel,
  'nvim_exec_lua',
  'return require("overleaf")._on_viewer_edit(...)',
  { file, tonumber(line), tonumber(column) }
)
if not ok then fail('Neovim server rejected the jump: ' .. tostring(err)) end
vim.fn.chanclose(channel)
