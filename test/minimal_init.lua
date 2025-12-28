-- test/minimal_init.lua
-- Keep the runtime isolated, fast, and reproducible.

vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/../plenary.nvim") -- if you vendor it in CI
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = "NONE"
vim.opt.termguicolors = false

-- Make timers deterministic-ish (still real timers, but tests won't rely on them).
vim.g.mapleader = " "

-- Quiet down noisy notify in CI unless tests want to assert it.
-- We'll override in tests when needed.
if vim.notify == nil then
	vim.notify = function(_) end
end
