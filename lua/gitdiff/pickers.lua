local M = {}
local util = require("gitdiff.util")

---@class GitDiffPickerItem
---@field hash string
---@field short_hash string
---@field author string
---@field time string
---@field message string
---@field commit string Alias for hash.
---@field display string
---@field text string Searchable text containing all displayed metadata.

---@class GitDiffPickerOpts
---@field provider? "auto"|"snacks"|"telescope"|"fzf"|"native"|"vim_ui"|fun(opts: GitDiffPickerOpts): any
---@field repo string Absolute repository root.
---@field git_cmd string[] Git command and any leading global arguments.
---@field history_args string[] Arguments appended after `git log`.
---@field preview boolean
---@field on_select fun(item: GitDiffPickerItem)
---@field on_cancel fun()
---@field on_error? fun(message: string)

local FIELD_SEPARATOR = string.char(31)
local LOG_FORMAT = table.concat({ "%H", "%h", "%an", "%aI", "%s" }, "%x1f")

local function schedule(callback)
  if vim.schedule then
    vim.schedule(callback)
  else
    callback()
  end
end

local function notify_error(message)
  local level = vim.log and vim.log.levels and vim.log.levels.ERROR or nil
  vim.notify(message, level, { title = "GitDiff" })
end

local function log_error(message)
  util.log(message)
end

local function copy_list(list)
  local result = {}
  for _, value in ipairs(list or {}) do
    result[#result + 1] = value
  end
  return result
end

local function extend(list, values)
  for _, value in ipairs(values or {}) do
    list[#list + 1] = value
  end
  return list
end

local function split_record(line)
  local fields = {}
  local start = 1

  while true do
    local position = line:find(FIELD_SEPARATOR, start, true)
    if not position then break end
    fields[#fields + 1] = line:sub(start, position - 1)
    start = position + 1
  end

  fields[#fields + 1] = line:sub(start)
  return fields
end

local function parse_item(line)
  if not line or line == "" then return nil end

  local fields = split_record(line)
  if not fields or fields[1] == "" then return nil end

  local hash, short_hash, author, time, message = unpack(fields)
  if #fields > 5 then
    message = table.concat(fields, FIELD_SEPARATOR, 5)
  end
  short_hash = short_hash or hash:sub(1, 8)
  author, time, message = author or "", time or "", message or ""
  local display = string.format("%s  %s  %s  %s", short_hash, time, author, message)

  return {
    hash = hash,
    short_hash = short_hash,
    author = author,
    time = time,
    message = message,
    -- These aliases make the item useful to picker integrations without making
    -- callers translate it back into a Git-specific shape.
    commit = hash,
    date = time,
    msg = message,
    display = display,
    text = table.concat({ message, author, time, short_hash, hash }, " "),
  }
end

local function history_command(opts)
  local command = copy_list(opts.git_cmd)
  extend(command, {
    "log",
    "--no-color",
    "--no-show-signature",
    -- `tformat` terminates the final record with a newline. Telescope's
    -- streaming line reader otherwise waits forever on the last commit, never
    -- runs its completion/initial-selection step, and cannot refilter.
    "--pretty=tformat:" .. LOG_FORMAT,
  })

  local skip_next = false
  for _, argument in ipairs(opts.history_args) do
    if skip_next then
      skip_next = false
    elseif argument == "--pretty" or argument == "--format" then
      skip_next = true
    elseif argument ~= "--oneline"
        and not argument:match("^%-%-pretty=")
        and not argument:match("^%-%-format=")
    then
      command[#command + 1] = argument
    end
  end

  return command
end

local function preview_command(opts, hash)
  local command = copy_list(opts.git_cmd)
  extend(command, {
    "--no-pager",
    "show",
    "--no-ext-diff",
    "--no-color",
    "--format=fuller",
    -- --no-patch must precede --stat: Git otherwise lets the later
    -- --no-patch suppress the diffstat along with the patch.
    "--no-patch",
    "--stat",
    "--summary",
    hash,
  })
  return command
end

local function new_session(opts)
  local outcome

  local function reserve(kind, callback)
    if outcome then return nil end
    outcome = kind

    local delivered = false
    return function()
      if delivered then return end
      delivered = true
      callback()
    end
  end

  return {
    prepare_select = function(item)
      return reserve("select", function() opts.on_select(item) end)
    end,
    prepare_cancel = function()
      return reserve("cancel", opts.on_cancel)
    end,
    prepare_error = function(message)
      return reserve("error", function()
        if opts.on_error then
          opts.on_error(message)
        else
          notify_error(message)
        end
      end)
    end,
  }
end

local function load_snacks()
  local snacks = rawget(_G, "Snacks")
  if not snacks then
    local ok, module = pcall(require, "snacks")
    if ok then snacks = module end
  end

  local ok, proc = pcall(require, "snacks.picker.source.proc")
  if
    type(snacks) ~= "table"
    or type(snacks.picker) ~= "table"
    or type(snacks.picker.pick) ~= "function"
    or not ok
    or type(proc.proc) ~= "function"
  then
    return nil
  end

  return { snacks = snacks, proc = proc }
end

local function load_telescope(preview)
  local modules = {}
  local names = {
    "telescope.pickers",
    "telescope.finders",
    "telescope.actions",
    "telescope.actions.state",
    "telescope.config",
  }
  if preview then names[#names + 1] = "telescope.previewers" end

  for _, name in ipairs(names) do
    local ok, module = pcall(require, name)
    if not ok then return nil end
    modules[name] = module
  end

  if
    type(modules["telescope.pickers"].new) ~= "function"
    or type(modules["telescope.finders"].new_oneshot_job) ~= "function"
  then
    return nil
  end

  return modules
end

local function load_fzf()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok or type(fzf) ~= "table" or type(fzf.fzf_exec) ~= "function" then
    return nil
  end
  return fzf
end

local function shell_join(command)
  return table.concat(vim.tbl_map(function(arg)
    return vim.fn.shellescape(arg)
  end, command), " ")
end

local function fzf_history_command(opts)
  local command = copy_list(opts.git_cmd)
  extend(command, {
    "log",
    "--no-color",
    "--no-show-signature",
    "--pretty=format:%H%x09%h%x09%an%x09%aI%x09%s",
  })

  local skip_next = false
  for _, argument in ipairs(opts.history_args) do
    if skip_next then
      skip_next = false
    elseif argument == "--pretty" or argument == "--format" then
      skip_next = true
    elseif argument ~= "--oneline"
        and not argument:match("^%-%-pretty=")
        and not argument:match("^%-%-format=")
    then
      command[#command + 1] = argument
    end
  end

  return shell_join(command)
end

local function open_snacks(opts, session, loaded)
  loaded = loaded or load_snacks()
  if not loaded then return nil, "Snacks picker is not available." end

  local snacks = loaded.snacks
  local process = loaded.proc
  local command = history_command(opts)
  local executable = command[1]
  local arguments = {}
  for i = 2, #command do
    arguments[#arguments + 1] = command[i]
  end

  local picker
  picker = snacks.picker.pick({
    source = "commit_diff",
    title = "GitDiff",
    cwd = opts.repo,
    finder = function(_, ctx)
      return process.proc({
        cmd = executable,
        args = arguments,
        cwd = opts.repo,
        notify = true,
        transform = function(raw)
          local item = parse_item(raw.text)
          if not item then return false end
          item.cwd = opts.repo
          return item
        end,
      }, ctx)
    end,
    format = function(item)
      return {
        { item.short_hash, "SnacksPickerGitCommit" },
        { "  " .. item.time, "SnacksPickerGitDate" },
        { "  " .. item.author, "SnacksPickerGitAuthor" },
        { "  " .. item.message },
      }
    end,
    preview = opts.preview and function(ctx)
      return snacks.picker.preview.cmd(preview_command(opts, ctx.item.hash), ctx, { ft = "git" })
    end or "none",
    layout = opts.preview and nil or { preview = false },
    confirm = function(current_picker, item)
      if not item then return end
      local deliver = session.prepare_select(item)
      if not deliver then return end

      current_picker:close()
      schedule(deliver)
    end,
    on_close = function()
      local deliver = session.prepare_cancel()
      if not deliver then return end

      -- Snacks schedules its window teardown after on_close returns. Defer one
      -- additional turn so on_cancel observes a fully closed picker.
      schedule(function() schedule(deliver) end)
    end,
  })

  return picker
end

local function telescope_entry(line)
  local item = parse_item(line)
  if not item then return nil end

  return {
    value = item.hash,
    ordinal = item.text,
    display = item.display,
    item = item,
    hash = item.hash,
    short_hash = item.short_hash,
    author = item.author,
    time = item.time,
    message = item.message,
  }
end

local function open_telescope(opts, session, loaded)
  loaded = loaded or load_telescope(opts.preview)
  if not loaded then return nil, "Telescope picker is not available." end

  local pickers = loaded["telescope.pickers"]
  local finders = loaded["telescope.finders"]
  local actions = loaded["telescope.actions"]
  local action_state = loaded["telescope.actions.state"]
  local config = loaded["telescope.config"].values
  local previewers = loaded["telescope.previewers"]

  local previewer
  if opts.preview then
    if not previewers or type(previewers.new_termopen_previewer) ~= "function" then
      return nil, "Telescope commit preview is not available."
    end
    previewer = previewers.new_termopen_previewer({
      title = "Commit Preview",
      cwd = opts.repo,
      get_command = function(entry)
        return preview_command(opts, entry.hash)
      end,
    })
  end

  local function confirm(prompt_bufnr)
    local entry = action_state.get_selected_entry()
    if not entry then return end

    local deliver = session.prepare_select(entry.item or entry)
    if not deliver then return end

    actions.close(prompt_bufnr)
    schedule(deliver)
  end

  local function replace(action)
    if action and type(action.replace) == "function" then action:replace(confirm) end
  end

  local picker = pickers.new({ cwd = opts.repo }, {
    prompt_title = "GitDiff",
    finder = finders.new_oneshot_job(history_command(opts), {
      cwd = opts.repo,
      entry_maker = telescope_entry,
    }),
    previewer = previewer,
    sorter = config.generic_sorter({}),
    attach_mappings = function()
      replace(actions.select_default)
      replace(actions.select_horizontal)
      replace(actions.select_vertical)
      replace(actions.select_tab)
      return true
    end,
  })

  if type(picker.close_windows) == "function" then
    local close_windows = picker.close_windows
    picker.close_windows = function(status)
      local deliver = session.prepare_cancel()
      close_windows(status)
      if deliver then schedule(deliver) end
    end
  end

  picker:find()
  return picker
end

local function open_fzf(opts, session, loaded)
  local fzf = loaded or load_fzf()
  if not fzf then return nil, "fzf-lua is not available." end

  local preview
  if opts.preview then
    local command = preview_command(opts, "__COMMIT_DIFF_HASH__")
    command[#command] = nil
    preview = shell_join(command) .. " {1}"
  end

  return fzf.fzf_exec(fzf_history_command(opts), {
    cwd = opts.repo,
    prompt = "GitDiff> ",
    preview = preview,
    no_hide = true,
    no_resume = true,
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--nth"] = "1..",
      ["--tiebreak"] = "index",
      ["--no-multi"] = true,
    },
    fn_selected = function(selected)
      local line = selected and selected[1]
      if not line then return end
      local fields = vim.split(line, "\t", { plain = true, trimempty = false })
      if not fields[1] or fields[1] == "" then return end

      local deliver = session.prepare_select({
        hash = fields[1],
        commit = fields[1],
        short_hash = fields[2],
        author = fields[3],
        time = fields[4],
        message = table.concat(fields, "\t", 5),
      })
      if deliver then schedule(deliver) end
    end,
    winopts = {
      on_close = function()
        -- `fn_selected` runs immediately after fzf-lua closes its UI.
        -- Deferring cancellation lets a real selection reserve the outcome.
        schedule(function()
          schedule(function()
            local deliver = session.prepare_cancel()
            if deliver then deliver() end
          end)
        end)
      end,
    },
  })
end

local function open_native(opts, session)
  local ok, native = pcall(require, "gitdiff.pickers.native")
  if not ok or type(native) ~= "table" or type(native.open) ~= "function" then
    return nil, "The native GitDiff picker is unavailable."
  end
  return native.open(opts, session)
end

local function compact_error(stderr)
  local lines = {}
  for _, line in ipairs(stderr) do
    if line and line ~= "" then lines[#lines + 1] = line end
  end
  local detail = table.concat(lines, "\n")
  if #detail > 1000 then detail = detail:sub(1, 1000) .. "..." end
  return detail
end

local function open_vim_ui(opts, session)
  if not (vim.ui and type(vim.ui.select) == "function") then
    return nil, "vim.ui.select is not available."
  end

  local stdout = {}
  local stderr = {}
  local command = history_command(opts)

  local ok, job = pcall(vim.fn.jobstart, command, {
    cwd = opts.repo,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      extend(stdout, data)
    end,
    on_stderr = function(_, data)
      extend(stderr, data)
    end,
    on_exit = function(_, code)
      schedule(function()
        if code ~= 0 then
          local detail = compact_error(stderr)
          if detail ~= "" then log_error("Git history failed: " .. detail) end
          local message = "Unable to load Git history. Check :DiffviewLog for details."
          local deliver = session.prepare_error(message)
          if deliver then deliver() end
          return
        end

        local items = {}
        for _, line in ipairs(stdout) do
          local item = parse_item(line)
          if item then items[#items + 1] = item end
        end

        if #items == 0 then
          local deliver = session.prepare_error("No commits found in repository.")
          if deliver then deliver() end
          return
        end

        local select_ok, select_error = pcall(vim.ui.select, items, {
          prompt = "GitDiff",
          format_item = function(item) return item.display end,
        }, function(item)
          local deliver
          if item then
            deliver = session.prepare_select(item)
          else
            deliver = session.prepare_cancel()
          end
          if deliver then deliver() end
        end)

        if not select_ok then
          log_error("vim.ui.select failed: " .. tostring(select_error))
          local message = "Unable to open the commit picker. Check :DiffviewLog for details."
          local deliver = session.prepare_error(message)
          if deliver then deliver() end
        end
      end)
    end,
  })

  if not ok or type(job) ~= "number" or job <= 0 then
    local reason = ok and "Git process could not be started." or tostring(job)
    return nil, "Unable to load Git history: " .. reason
  end

  return job
end

local function active_lazyvim_picker()
  local lazyvim = rawget(_G, "LazyVim")
  if type(lazyvim) ~= "table" then return nil end

  local ok, name = pcall(function()
    return lazyvim.pick and lazyvim.pick.picker and lazyvim.pick.picker.name
  end)
  if not ok or type(name) ~= "string" then return nil end
  return name:lower()
end

local function normalize(opts)
  opts = opts or {}
  local normalized = {}
  for key, value in pairs(opts) do
    normalized[key] = value
  end

  normalized.provider = normalized.provider or "auto"
  normalized.repo = normalized.repo or (vim.loop and vim.loop.cwd()) or vim.fn.getcwd()
  normalized.git_cmd = copy_list(normalized.git_cmd or { "git" })
  normalized.history_args = copy_list(normalized.history_args or {})
  normalized.preview = normalized.preview ~= false
  if type(normalized.on_select) ~= "function" then normalized.on_select = function() end end
  if type(normalized.on_cancel) ~= "function" then normalized.on_cancel = function() end end

  return normalized
end

local function open_custom(provider, opts, session)
  local custom_opts = {}
  for key, value in pairs(opts) do
    custom_opts[key] = value
  end
  custom_opts.provider = provider
  custom_opts.on_select = function(item)
    local deliver = session.prepare_select(item)
    if deliver then deliver() end
  end
  custom_opts.on_cancel = function()
    local deliver = session.prepare_cancel()
    if deliver then deliver() end
  end
  custom_opts.on_error = function(message)
    local deliver = session.prepare_error(message)
    if deliver then deliver() end
  end

  return provider(custom_opts)
end

---Open a commit history picker.
---@param opts GitDiffPickerOpts
---@return any
function M.open(opts)
  opts = normalize(opts)
  local session = new_session(opts)
  local provider = opts.provider

  if type(provider) == "function" then
    local ok, result = pcall(open_custom, provider, opts, session)
    if ok then return result end

    log_error("Custom commit picker failed: " .. tostring(result))
    local deliver = session.prepare_error("The custom commit picker failed. Check :DiffviewLog for details.")
    if deliver then deliver() end
    return nil
  end

  if type(provider) ~= "string" then
    local deliver = session.prepare_error("Invalid commit picker provider.")
    if deliver then deliver() end
    return nil
  end

  provider = provider:lower()
  local loaded
  if provider == "auto" then
    local preferred = active_lazyvim_picker()
    if preferred == "snacks" then
      loaded = load_snacks()
      if loaded then provider = "snacks" end
    elseif preferred == "telescope" then
      loaded = load_telescope(opts.preview)
      if loaded then provider = "telescope" end
    elseif preferred == "fzf" or preferred == "fzf-lua" or preferred == "fzf_lua" then
      loaded = load_fzf()
      provider = loaded and "fzf" or "native"
    end

    if provider == "auto" then
      loaded = load_snacks()
      if loaded then
        provider = "snacks"
      else
        loaded = load_telescope(opts.preview)
        provider = loaded and "telescope" or "native"
      end
    end
  end

  local opener = ({
    snacks = open_snacks,
    telescope = open_telescope,
    fzf = open_fzf,
    fzf_lua = open_fzf,
    ["fzf-lua"] = open_fzf,
    native = open_native,
    vim_ui = open_vim_ui,
  })[provider]

  if not opener then
    local deliver = session.prepare_error("Unknown commit picker provider: " .. provider)
    if deliver then deliver() end
    return nil
  end

  local ok, result, err = pcall(opener, opts, session, loaded)
  if ok and result ~= nil then return result end

  local message = ok and err or result
  if not ok then
    log_error(("%s picker failed: %s"):format(provider, tostring(result)))
    message = ("Unable to open the %s commit picker. Check :DiffviewLog for details."):format(provider)
  end
  message = message or ("Unable to open " .. provider .. " commit picker.")
  local deliver = session.prepare_error(message)
  if deliver then deliver() end
  return nil
end

return M
