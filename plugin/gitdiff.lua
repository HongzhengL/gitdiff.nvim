if vim.g.gitdiff_nvim_loaded then return end
vim.g.gitdiff_nvim_loaded = 1

vim.api.nvim_create_user_command("GitDiff", function()
  require("gitdiff").open()
end, {
  desc = "Select and review a Git commit with Diffview",
  nargs = 0,
})

require("gitdiff").setup()
