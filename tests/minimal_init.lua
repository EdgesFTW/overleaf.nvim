-- Minimal init for running tests with Plenary
local plenary_dir = vim.fn.getcwd() .. '/.tests/plenary.nvim'
vim.opt.rtp:append('.')
vim.opt.rtp:append(plenary_dir)
vim.cmd('runtime plugin/plenary.vim')

-- Never write the offline-edit manifest into the real state directory.
vim.env.XDG_STATE_HOME = vim.fn.tempname()
