local config = require("gitdiff.config")
local git = require("gitdiff.git")
local utils = require("gitdiff.util")

local api = vim.api
local M = {}

local state = {
  active = nil,
  mapped_lhs = nil,
  conflict_notified = {},
}

---@class GitDiffContext
---@field tabpage integer
---@field win integer
---@field buf integer
---@field cursor integer[]
---@field view table

---@return GitDiffContext
function M.capture_context()
  local win = api.nvim_get_current_win()
  return {
    tabpage = api.nvim_get_current_tabpage(),
    win = win,
    buf = api.nvim_get_current_buf(),
    cursor = api.nvim_win_get_cursor(win),
    view = vim.fn.winsaveview(),
  }
end

---@param context GitDiffContext
---@return boolean
function M.restore_context(context)
  if not context then return false end

  if api.nvim_tabpage_is_valid(context.tabpage) then
    pcall(api.nvim_set_current_tabpage, context.tabpage)
  end

  if api.nvim_win_is_valid(context.win) then
    pcall(api.nvim_set_current_win, context.win)
    if api.nvim_buf_is_valid(context.buf) then
      pcall(api.nvim_win_set_buf, context.win, context.buf)
    end

    pcall(api.nvim_win_set_cursor, context.win, context.cursor)
    if context.view then
      pcall(api.nvim_win_call, context.win, function()
        vim.fn.winrestview(context.view)
      end)
    end
    return true
  end

  return api.nvim_tabpage_is_valid(context.tabpage)
end

local function global_mapping(lhs)
  local target = api.nvim_replace_termcodes(lhs, true, true, true)
  for _, map in ipairs(api.nvim_get_keymap("n")) do
    local mapped = api.nvim_replace_termcodes(map.lhs, true, true, true)
    if mapped == target then return map end
  end
  return {}
end

local function owns_mapping(lhs)
  local map = global_mapping(lhs)
  return state.mapped_lhs == lhs
    and type(map) == "table"
    and map.desc == "GitDiff"
    and map.callback == M.open
end

local function delete_owned_mapping()
  if state.mapped_lhs and owns_mapping(state.mapped_lhs) then
    pcall(vim.keymap.del, "n", state.mapped_lhs)
  end
  state.mapped_lhs = nil
end

---@param opt? string|false|table
---@return boolean
---@return string? reason
function M.setup_mapping(opt)
  local lhs
  if type(opt) == "table" then
    lhs = opt.keymap
  elseif opt ~= nil then
    lhs = opt
  else
    lhs = config.get().keymap
  end

  if lhs == false or lhs == nil or lhs == "" then
    delete_owned_mapping()
    return true
  end

  if type(lhs) ~= "string" then
    utils.warn("GitDiff keymap must be a string or false; the mapping was not created.")
    return false, "invalid"
  end

  if state.mapped_lhs and state.mapped_lhs ~= lhs then
    delete_owned_mapping()
  end

  local existing = global_mapping(lhs)
  if type(existing) == "table" and next(existing) ~= nil and not owns_mapping(lhs) then
    if not state.conflict_notified[lhs] then
      state.conflict_notified[lhs] = true
      utils.warn((
        "GitDiff did not map %s because it is already in use. "
        .. "Set gitdiff.keymap to another key (or false) and use "
        .. ":GitDiff as the alternate entry."
      ):format(lhs))
    end
    return false, "conflict"
  end

  vim.keymap.set("n", lhs, M.open, {
    desc = "GitDiff",
    silent = true,
  })
  state.mapped_lhs = lhs
  return true
end

function M.setup(user_config)
  config.setup(user_config)
  return M.setup_mapping(config.get())
end

local function finish_active()
  state.active = nil
end

local function fail(context, message)
  finish_active()
  vim.schedule(function()
    M.restore_context(context)
    utils.err(message)
  end)
end

local function safe_diffview_args(args)
  local ret = {}
  for _, arg in ipairs(type(args) == "table" and args or {}) do
    if type(arg) == "string" and arg:match("^%-%-selected%-file=.+") then
      ret[#ret + 1] = arg
    else
      utils.warn((
        "Ignoring unsafe gitdiff.diffview_args value %s; commit review "
        .. "always enforces a read-only, all-files parent comparison."
      ):format(vim.inspect(arg)))
    end
  end
  return ret
end

local function revision_label(commit, range)
  local label = ("Commit %s"):format(commit.short_hash)
  if range.kind == "root" then
    return label .. " (root; compared with the empty tree)"
  elseif range.kind == "merge" then
    return label .. (" (compared with parent %d: %s)"):format(
      range.parent_index,
      range.parent:sub(1, #commit.short_hash)
    )
  end
  return label
end

local function get_diffview_lib()
  local ok, lib = pcall(require, "diffview.lib")
  if ok and lib and type(lib.diffview_open) == "function" then return lib end
end

local function missing_diffview_message()
  return table.concat({
    "GitDiff requires sindrets/diffview.nvim, but Diffview is unavailable.",
    "Install or enable diffview.nvim, then run :GitDiff again.",
  }, "\n")
end

local function open_view(repo, commit, range, context, conf)
  local lib = get_diffview_lib()
  if not lib then
    fail(context, missing_diffview_message())
    return
  end

  local args = { range.rev_arg, "-C=" .. repo }
  vim.list_extend(args, safe_diffview_args(conf.diffview_args))

  local ok_create, view = pcall(lib.diffview_open, args)

  if not ok_create or not view then
    if not ok_create then utils.log("Failed to prepare view: " .. tostring(view)) end
    fail(
      context,
      "Diffview could not prepare this commit. Your editing context was restored."
    )
    return
  end

  -- A historical COMMIT..COMMIT view has immutable buffers, but upstream
  -- Diffview still exposes a few index-mutating actions. Install guards after
  -- Diffview registers its listeners and before it emits view_opened.
  local post_open = view.post_open
  view.post_open = function(self, ...)
    local result = post_open(self, ...)
    for _, event_name in ipairs({
      "toggle_stage_entry",
      "stage_all",
      "unstage_all",
      "restore_entry",
    }) do
      self.emitter:on(event_name, function(event)
        event:stop_propagation()
        utils.warn("This GitDiff review is read-only.")
      end)
    end
    return result
  end

  if view.panel then view.panel.rev_pretty_name = revision_label(commit, range) end

  view.emitter:on("view_closed", function()
    finish_active()
    vim.schedule(function() M.restore_context(context) end)
  end)

  -- Mark the review active before opening: user hooks can synchronously close
  -- a freshly opened view, and the view_closed callback must win that race.
  state.active = {
    phase = "review",
    context = context,
    repo = repo,
    view = view,
  }

  utils.info(("Loading GitDiff for %s…"):format(commit.short_hash))
  local ok_open, open_err = pcall(view.open, view)
  if not ok_open then
    utils.log("Failed to open view: " .. tostring(open_err))
    pcall(view.close, view)
    lib.dispose_view(view)
    fail(
      context,
      "Diffview could not open this commit. Your editing context was restored."
    )
    return
  end

end

local function parent_choice_label(choice)
  local role = choice.index == 1 and "first parent" or ("parent %d"):format(choice.index)
  local label = ("%s  %s  %s"):format(role, choice.short_hash, choice.subject)
  local byline = table.concat(vim.tbl_filter(function(value) return value ~= "" end, {
    choice.author,
    choice.relative_date,
  }), ", ")
  if byline ~= "" then label = label .. " — " .. byline end
  if choice.unavailable then label = label .. " (unavailable locally)" end
  return label
end

local function open_range(repo, commit, parent_index, context, conf)
  local range, range_err = git.revision_range(commit, parent_index)
  if not range then
    fail(context, range_err or "The selected commit comparison could not be determined.")
    return
  end

  if range.kind == "merge" then
    utils.info((
      "Merge commit %s will be compared with parent %d (%s)."
    ):format(commit.short_hash, range.parent_index, range.parent:sub(1, #commit.short_hash)))
  end

  open_view(repo, commit, range, context, conf)
end

local function select_merge_parent(repo, commit, context, conf)
  local choices = git.parent_choices(repo, commit)
  state.active = {
    phase = "parent_picker",
    context = context,
    repo = repo,
    commit = commit,
  }

  local delivered = false
  local function on_select(choice)
    if delivered then return end
    delivered = true
    if not choice then
      finish_active()
      vim.schedule(function() M.restore_context(context) end)
      return
    end
    open_range(repo, commit, choice.index, context, conf)
  end

  local ok, select_err = pcall(vim.ui.select, choices, {
    prompt = ("Select parent for merge %s:"):format(commit.short_hash),
    kind = "gitdiff_parent",
    format_item = parent_choice_label,
  }, on_select)
  if not ok then
    utils.log("Parent picker error: " .. tostring(select_err))
    fail(context, "The merge-parent picker could not be opened.")
  end
end

---@param repo string
---@param hash string
---@param context? GitDiffContext
function M.open_commit(repo, hash, context)
  context = context or M.capture_context()
  local conf = config.get()
  local commit, commit_err = git.read_commit(repo, hash)
  if not commit then
    if commit_err then utils.log("Unable to read selected commit: " .. commit_err) end
    fail(context, table.concat({
      "The selected commit is no longer accessible in this repository.",
      "Open GitDiff again and choose another commit.",
    }, "\n"))
    return
  end

  if #(commit.parents or {}) > 1 and conf.merge_parent == "select" then
    select_merge_parent(repo, commit, context, conf)
    return
  end

  open_range(repo, commit, conf.merge_parent, context, conf)
end

local function selected_hash(item)
  if type(item) == "string" then return item end
  if type(item) ~= "table" then return nil end
  return item.hash or item.commit or item.value
end

function M.open()
  if state.active then
    utils.info("GitDiff is already open or loading. Close it before starting another review.")
    return
  end

  -- Dependency failure should be reported on entry, before a picker can alter
  -- the user's tab/window layout.
  if not get_diffview_lib() then
    utils.err(missing_diffview_message())
    return
  end

  local context = M.capture_context()
  local repo, reason = git.resolve_repository()
  if not repo then
    if reason == "git_unavailable" then
      utils.err("Git is unavailable. Install Git or configure gitdiff.git_cmd.")
    elseif reason == "ambiguous_repository" then
      utils.info(table.concat({
        "Multiple Git repositories are open, but the current context does not identify one.",
        "Focus a file in the repository you want to review and run GitDiff again.",
      }, "\n"))
    else
      utils.info("No Git repository found for the current workspace.")
    end
    return
  end

  local conf = config.get()
  if not git.has_commits(repo, { all = conf.all, rev = conf.rev }) then
    utils.info("This Git repository has no commits to review.")
    return
  end

  if conf.notify_shallow and git.is_shallow(repo) then
    utils.warn(
      "This is a shallow clone. GitDiff will show only locally available history; no network request was made."
    )
  end

  state.active = {
    phase = "picker",
    context = context,
    repo = repo,
  }

  local ok_picker, pickers = pcall(require, "gitdiff.pickers")
  if not ok_picker or not pickers or type(pickers.open) ~= "function" then
    fail(context, "No compatible commit picker is available.")
    return
  end

  local callback_done = false
  local function once(callback)
    return function(...)
      if callback_done then return end
      callback_done = true
      callback(...)
    end
  end

  local picker_ok, picker_err = pcall(pickers.open, {
    provider = conf.picker,
    repo = repo,
    git_cmd = git.command(),
    history_args = git.history_args({
      max_count = conf.max_count,
      rev = conf.rev,
      all = conf.all,
      args = conf.history_args,
    }),
    preview = conf.preview,
    on_select = once(function(item)
      local hash = selected_hash(item)
      if not hash then
        fail(context, "The picker returned an invalid commit selection.")
        return
      end
      vim.schedule(function() M.open_commit(repo, hash, context) end)
    end),
    on_cancel = once(function()
      finish_active()
      vim.schedule(function() M.restore_context(context) end)
    end),
    on_error = once(function(message)
      fail(context, message or "Commit history could not be loaded.")
    end),
  })

  if not picker_ok then
    utils.log("Picker error: " .. tostring(picker_err))
    fail(context, "Commit history could not be opened. See :DiffviewLog for details.")
  end
end

M._state = state

return M
