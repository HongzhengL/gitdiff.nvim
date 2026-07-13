local M = {}

local defaults = {
  keymap = "<leader>gv",
  picker = "auto",
  max_count = 256,
  rev = "HEAD",
  all = false,
  preview = true,
  -- Prompt for a parent when reviewing a merge commit. Set this to a positive
  -- integer to always compare merges with that parent instead.
  merge_parent = "select",
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
  if type(config.git_cmd) == "string" then config.git_cmd = { config.git_cmd } end
  if type(config.git_cmd) ~= "table" or type(config.git_cmd[1]) ~= "string" then
    error("gitdiff.git_cmd must be a command string or list")
  end
  if type(config.history_args) ~= "table" or type(config.diffview_args) ~= "table" then
    error("gitdiff history_args and diffview_args must be lists")
  end
  if config.merge_parent ~= "select"
      and (type(config.merge_parent) ~= "number"
        or config.merge_parent % 1 ~= 0
        or config.merge_parent < 1)
  then
    error('gitdiff.merge_parent must be "select" or a positive integer')
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
