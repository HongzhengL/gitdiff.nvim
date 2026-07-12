local M = {}
local util = require("gitdiff.util")

local api = vim.api
local FIELD_SEPARATOR = string.char(31)
local LOG_FORMAT = table.concat({ "%H", "%h", "%an", "%aI", "%s" }, "%x1f")

local function copy_list(list)
  local ret = {}
  for _, value in ipairs(list or {}) do
    ret[#ret + 1] = value
  end
  return ret
end

local function history_command(opts)
  local command = copy_list(opts.git_cmd)
  vim.list_extend(command, {
    "log",
    "--no-color",
    "--no-show-signature",
    "--pretty=format:" .. LOG_FORMAT,
  })

  local skip_next = false
  for _, arg in ipairs(opts.history_args or {}) do
    if skip_next then
      skip_next = false
    elseif arg == "--pretty" or arg == "--format" then
      skip_next = true
    elseif arg ~= "--oneline"
        and not arg:match("^%-%-pretty=")
        and not arg:match("^%-%-format=")
    then
      command[#command + 1] = arg
    end
  end

  return command
end

local function preview_command(opts, hash)
  local command = copy_list(opts.git_cmd)
  vim.list_extend(command, {
    "--no-pager",
    "show",
    "--no-ext-diff",
    "--no-color",
    "--format=fuller",
    "--no-patch",
    "--stat",
    "--summary",
    hash,
  })
  return command
end

local function parse_item(line)
  if type(line) ~= "string" or line == "" then return nil end
  local fields = vim.split(line, FIELD_SEPARATOR, { plain = true, trimempty = false })
  if not fields[1] or fields[1] == "" then return nil end
  local message = table.concat(fields, FIELD_SEPARATOR, 5)

  return {
    hash = fields[1],
    commit = fields[1],
    short_hash = fields[2] or fields[1]:sub(1, 8),
    author = fields[3] or "",
    time = fields[4] or "",
    message = message,
    text = table.concat({
      fields[1],
      fields[2] or "",
      fields[3] or "",
      fields[4] or "",
      message,
    }, " "):lower(),
  }
end

local function set_lines(buf, lines)
  if not api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function configure_scratch(buf, filetype)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = filetype or ""
end

local function matches(item, query)
  for word in query:lower():gmatch("%S+") do
    if not item.text:find(word, 1, true) then return false end
  end
  return true
end

local function compact_error(lines)
  local ret = {}
  for _, line in ipairs(lines or {}) do
    if line and line ~= "" then ret[#ret + 1] = line end
  end
  local message = table.concat(ret, "\n")
  if #message > 1000 then message = message:sub(1, 1000) .. "…" end
  return message
end

local function log_error(message)
  util.log(message)
end

---@param opts table
---@param session table
---@return table?
---@return string?
function M.open(opts, session)
  local state = {
    items = {},
    filtered = {},
    selected = 1,
    loading = true,
    closed = false,
    render_pending = false,
    history_job = nil,
    preview_job = nil,
    preview_hash = nil,
    preview_generation = 0,
    stdout_partial = "",
  }

  local ok_tab, tab_err = pcall(vim.cmd, "tabnew")
  if not ok_tab then return nil, "Unable to open the native picker: " .. tostring(tab_err) end

  state.tabpage = api.nvim_get_current_tabpage()
  state.list_win = api.nvim_get_current_win()
  state.list_buf = api.nvim_create_buf(false, true)
  configure_scratch(state.list_buf, "gitdiff_picker")
  api.nvim_win_set_buf(state.list_win, state.list_buf)
  vim.wo[state.list_win].cursorline = true
  vim.wo[state.list_win].number = false
  vim.wo[state.list_win].relativenumber = false

  if opts.preview then
    vim.cmd("rightbelow vsplit")
    state.preview_win = api.nvim_get_current_win()
    state.preview_buf = api.nvim_create_buf(false, true)
    configure_scratch(state.preview_buf, "git")
    api.nvim_win_set_buf(state.preview_win, state.preview_buf)
    vim.wo[state.preview_win].wrap = false
    set_lines(state.preview_buf, { "Select a commit to load its summary." })
    api.nvim_set_current_win(state.list_win)
  end

  vim.cmd("topleft 1new")
  state.prompt_win = api.nvim_get_current_win()
  state.prompt_buf = api.nvim_get_current_buf()
  vim.bo[state.prompt_buf].buftype = "prompt"
  vim.bo[state.prompt_buf].bufhidden = "wipe"
  vim.bo[state.prompt_buf].swapfile = false
  vim.bo[state.prompt_buf].buflisted = false
  vim.wo[state.prompt_win].winfixheight = true
  state.prompt = "GitDiff> "
  vim.fn.prompt_setprompt(state.prompt_buf, state.prompt)

  local function valid()
    return not state.closed
      and api.nvim_tabpage_is_valid(state.tabpage)
      and api.nvim_win_is_valid(state.list_win)
      and api.nvim_buf_is_valid(state.list_buf)
  end

  local function stop_job(job)
    if type(job) == "number" and job > 0 then pcall(vim.fn.jobstop, job) end
  end

  local function close_ui()
    if state.closed then return end
    state.closed = true
    stop_job(state.history_job)
    stop_job(state.preview_job)
    if state.augroup then pcall(api.nvim_del_augroup_by_id, state.augroup) end

    if api.nvim_tabpage_is_valid(state.tabpage) then
      pcall(api.nvim_set_current_tabpage, state.tabpage)
      if #api.nvim_list_tabpages() > 1 then pcall(vim.cmd, "tabclose") end
    end
  end

  local function deliver(kind, value)
    local callback
    if kind == "select" then
      callback = session.prepare_select(value)
    elseif kind == "error" then
      callback = session.prepare_error(value)
    else
      callback = session.prepare_cancel()
    end
    if not callback then return end

    close_ui()
    vim.schedule(callback)
  end

  local function selected_item()
    if api.nvim_win_is_valid(state.list_win) and #state.filtered > 0 then
      local row = api.nvim_win_get_cursor(state.list_win)[1]
      state.selected = math.max(1, math.min(row, #state.filtered))
    end
    return state.filtered[state.selected]
  end

  local function update_preview()
    if not opts.preview or not valid() then return end
    local item = selected_item()
    if not item then
      state.preview_hash = nil
      state.preview_generation = state.preview_generation + 1
      stop_job(state.preview_job)
      set_lines(state.preview_buf, { state.loading and "Loading commits…" or "No matching commits." })
      return
    end
    if state.preview_hash == item.hash then return end

    state.preview_hash = item.hash
    state.preview_generation = state.preview_generation + 1
    local generation = state.preview_generation
    stop_job(state.preview_job)
    set_lines(state.preview_buf, { "Loading commit summary…" })

    local stdout, stderr = {}, {}
    state.preview_job = vim.fn.jobstart(preview_command(opts, item.hash), {
      cwd = opts.repo,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data) vim.list_extend(stdout, data or {}) end,
      on_stderr = function(_, data) vim.list_extend(stderr, data or {}) end,
      on_exit = function(_, code)
        vim.schedule(function()
          if not valid()
              or state.preview_hash ~= item.hash
              or state.preview_generation ~= generation
          then
            return
          end
          local lines = code == 0 and stdout or stderr
          while lines[#lines] == "" do lines[#lines] = nil end
          if #lines == 0 then lines = { code == 0 and "No summary available." or "Preview failed." } end
          set_lines(state.preview_buf, lines)
        end)
      end,
    })
  end

  local function render()
    state.render_pending = false
    if not valid() then return end

    local current = selected_item()
    local current_hash = current and current.hash
    local prompt_line = api.nvim_buf_is_valid(state.prompt_buf)
        and (api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or "")
        or ""
    local query = prompt_line
    -- Neovim includes the prompt prefix in a live prompt-buffer line, while
    -- API-driven/test updates can contain only the input. Support both forms.
    if query:sub(1, #state.prompt) == state.prompt then
      query = query:sub(#state.prompt + 1)
    end

    state.filtered = {}
    for _, item in ipairs(state.items) do
      if matches(item, query) then state.filtered[#state.filtered + 1] = item end
    end

    state.selected = 1
    if current_hash then
      for index, item in ipairs(state.filtered) do
        if item.hash == current_hash then
          state.selected = index
          break
        end
      end
    end

    local lines = {}
    for _, item in ipairs(state.filtered) do
      lines[#lines + 1] = ("%s  %s  %s  %s"):format(
        item.short_hash,
        item.time,
        item.author,
        item.message
      )
    end
    if #lines == 0 then
      lines[1] = state.loading and "Loading commits…" or "No matching commits."
    end
    set_lines(state.list_buf, lines)

    if api.nvim_win_is_valid(state.list_win) then
      pcall(api.nvim_win_set_cursor, state.list_win, { math.max(1, state.selected), 0 })
    end
    update_preview()
  end

  local function schedule_render()
    if state.render_pending or state.closed then return end
    state.render_pending = true
    vim.defer_fn(render, 25)
  end

  local function move(delta)
    if #state.filtered == 0 then return end
    state.selected = (state.selected - 1 + delta) % #state.filtered + 1
    if api.nvim_win_is_valid(state.list_win) then
      pcall(api.nvim_win_set_cursor, state.list_win, { state.selected, 0 })
    end
    update_preview()
  end

  local function select_current()
    local item = selected_item()
    if item then deliver("select", item) end
  end

  local function focus_prompt()
    if api.nvim_win_is_valid(state.prompt_win) then
      api.nvim_set_current_win(state.prompt_win)
      pcall(vim.cmd, "startinsert")
    end
  end

  local function map(buf, mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true })
  end

  for _, lhs in ipairs({ "<C-n>", "<Down>" }) do
    map(state.prompt_buf, { "i", "n" }, lhs, function() move(1) end)
  end
  for _, lhs in ipairs({ "<C-p>", "<Up>" }) do
    map(state.prompt_buf, { "i", "n" }, lhs, function() move(-1) end)
  end
  map(state.prompt_buf, { "i", "n" }, "<Esc>", function() deliver("cancel") end)
  map(state.prompt_buf, { "i", "n" }, "<C-c>", function() deliver("cancel") end)
  map(state.prompt_buf, "n", "<CR>", select_current)
  vim.fn.prompt_setcallback(state.prompt_buf, function() select_current() end)

  map(state.list_buf, "n", "j", function() move(1) end)
  map(state.list_buf, "n", "k", function() move(-1) end)
  map(state.list_buf, "n", "<Down>", function() move(1) end)
  map(state.list_buf, "n", "<Up>", function() move(-1) end)
  map(state.list_buf, "n", "<CR>", select_current)
  map(state.list_buf, "n", "q", function() deliver("cancel") end)
  map(state.list_buf, "n", "<Esc>", function() deliver("cancel") end)
  map(state.list_buf, "n", "/", focus_prompt)
  map(state.list_buf, "n", "i", focus_prompt)

  state.augroup = api.nvim_create_augroup("GitDiffPicker" .. state.prompt_buf, { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    buffer = state.prompt_buf,
    callback = schedule_render,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    buffer = state.list_buf,
    callback = function()
      if not valid() or #state.filtered == 0 then return end
      local row = api.nvim_win_get_cursor(state.list_win)[1]
      local selected = math.max(1, math.min(row, #state.filtered))
      if selected ~= state.selected then
        state.selected = selected
        update_preview()
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = state.augroup,
    buffer = state.list_buf,
    once = true,
    callback = function()
      if not state.closed then deliver("cancel") end
    end,
  })

  local stderr = {}
  local function append_history_chunk(data)
    if not data or #data == 0 then return end

    local first = state.stdout_partial .. (data[1] or "")
    if #data == 1 then
      state.stdout_partial = first
      return
    end

    local item = parse_item(first)
    if item then state.items[#state.items + 1] = item end
    for index = 2, #data - 1 do
      item = parse_item(data[index])
      if item then state.items[#state.items + 1] = item end
    end
    state.stdout_partial = data[#data] or ""
  end

  state.history_job = vim.fn.jobstart(history_command(opts), {
    cwd = opts.repo,
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if state.closed then return end
      append_history_chunk(data)
      schedule_render()
    end,
    on_stderr = function(_, data) vim.list_extend(stderr, data or {}) end,
    on_exit = function(_, code)
      vim.schedule(function()
        if state.closed then return end
        state.loading = false
        if code ~= 0 then
          local detail = compact_error(stderr)
          if detail ~= "" then log_error("Native history failed: " .. detail) end
          deliver("error", "Unable to load Git history. Check :DiffviewLog for details.")
          return
        end
        local item = parse_item(state.stdout_partial)
        if item then state.items[#state.items + 1] = item end
        state.stdout_partial = ""
        render()
      end)
    end,
  })

  if type(state.history_job) ~= "number" or state.history_job <= 0 then
    deliver("error", "Unable to start the Git history process.")
    return nil
  end

  set_lines(state.list_buf, { "Loading commits…" })
  focus_prompt()
  return state
end

return M
