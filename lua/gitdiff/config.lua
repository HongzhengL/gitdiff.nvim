local M = {}

local defaults = {
  keymap = "<leader>gv",
  unified_keymap = "<leader>gu",
  view = "split",
  unified = {
    context_lines = 3,
    lsp = true,
  },
  picker = "auto",
  max_count = 256,
  rev = "HEAD",
  all = false,
  preview = true,
  merge_parent = 1,
  history_args = {},
  diffview_args = {},
  notify_shallow = true,
  git_cmd = { "git" },
}

local current = vim.deepcopy(defaults)

local function validate(config)
  if config.keymap ~= false and type(config.keymap) ~= "string" then
    error("gitdiff.keymap must be a string or false")
  end
  if config.unified_keymap ~= false and type(config.unified_keymap) ~= "string" then
    error("gitdiff.unified_keymap must be a string or false")
  end
  if config.view ~= "split" and config.view ~= "unified" then
    error("gitdiff.view must be 'split' or 'unified'")
  end
  if type(config.unified) ~= "table" then
    error("gitdiff.unified must be a table")
  end
  if config.unified.context_lines ~= false
      and (type(config.unified.context_lines) ~= "number"
        or config.unified.context_lines % 1 ~= 0
        or config.unified.context_lines < 0)
  then
    error("gitdiff.unified.context_lines must be a non-negative integer or false")
  end
  if type(config.unified.lsp) ~= "boolean" then
    error("gitdiff.unified.lsp must be a boolean")
  end
  if type(config.git_cmd) == "string" then config.git_cmd = { config.git_cmd } end
  if type(config.git_cmd) ~= "table" or type(config.git_cmd[1]) ~= "string" then
    error("gitdiff.git_cmd must be a command string or list")
  end
  if type(config.history_args) ~= "table" or type(config.diffview_args) ~= "table" then
    error("gitdiff history_args and diffview_args must be lists")
  end
end

function M.setup(user_config)
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user_config or {})
  validate(current)
  return current
end

function M.get()
  return current
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
