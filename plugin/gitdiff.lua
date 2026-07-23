if vim.g.gitdiff_nvim_loaded then return end
vim.g.gitdiff_nvim_loaded = 1

vim.api.nvim_create_user_command("GitDiff", function(opts)
  require("gitdiff").open(opts.args ~= "" and opts.args or nil)
end, {
  desc = "Select and review a Git commit",
  nargs = "?",
  complete = function() return { "split", "unified" } end,
})

require("gitdiff").setup()
