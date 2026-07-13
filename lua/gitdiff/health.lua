local M = {}

local function report_picker(health, configured)
  if type(configured) == "function" then
    health.ok("Custom picker function configured")
    return
  end

  local available = { "native" }
  if pcall(require, "snacks") then available[#available + 1] = "snacks" end
  if pcall(require, "telescope") then available[#available + 1] = "telescope" end
  if pcall(require, "fzf-lua") then available[#available + 1] = "fzf-lua" end

  health.ok("Picker available: " .. table.concat(available, ", "))
  health.info("Configured picker: " .. tostring(configured))
end

function M.check()
  local api = vim.health or require("health")
  local health = {
    start = api.start or api.report_start,
    ok = api.ok or api.report_ok,
    info = api.info or api.report_info,
    error = api.error or api.report_error,
  }
  local config = require("gitdiff.config").get()

  health.start("gitdiff.nvim")

  if vim.fn.has("nvim-0.9") == 1 then
    health.ok("Neovim 0.9 or newer")
  else
    health.error("Neovim 0.9 or newer is required")
  end

  local git_command = type(config.git_cmd) == "table" and config.git_cmd[1] or config.git_cmd
  if type(git_command) == "string" and vim.fn.executable(git_command) == 1 then
    health.ok("Git executable found: " .. git_command)
  else
    health.error("Git executable not found", {
      "Install Git or configure require('gitdiff').setup({ git_cmd = { '/path/to/git' } })",
    })
  end

  local diffview_ok, diffview = pcall(require, "diffview")
  local lib_ok, lib = pcall(require, "diffview.lib")
  if diffview_ok and type(diffview) == "table"
      and lib_ok and type(lib) == "table"
      and type(lib.diffview_open) == "function"
  then
    health.ok("sindrets/diffview.nvim is available")
  else
    health.error("sindrets/diffview.nvim is unavailable", {
      "Install sindrets/diffview.nvim and nvim-lua/plenary.nvim as dependencies",
    })
  end

  report_picker(health, config.picker)
end

return M
