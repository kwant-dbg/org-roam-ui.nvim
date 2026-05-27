local source = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fs.dirname(vim.fs.dirname(source))
local lazy_root = vim.env.LAZY_PATH or vim.fn.stdpath("data") .. "/lazy"

vim.opt.runtimepath:prepend(lazy_root .. "/plenary.nvim")
vim.opt.runtimepath:prepend(repo_root)
