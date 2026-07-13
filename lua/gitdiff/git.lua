local config = require("gitdiff.config")

local M = {}

local FIELD_SEP = string.char(31)
local SHA1_EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
local SHA256_EMPTY_TREE = "6ef19b41225c5369f1c104d45d8d85ef0a7b9406c033a7c1df4353d4f246f321"

M.FIELD_SEP = FIELD_SEP

---@class GitDiffCommit
---@field hash string
---@field short_hash string
---@field author string
---@field iso_date string
---@field date string
---@field subject string
---@field relative_date string
---@field parents string[]
---@field missing_parents? table<integer, boolean>
---@field empty_tree? string
---@field body? string

---@class GitDiffRevisionRange
---@field rev_arg string
---@field kind "root"|"ordinary"|"merge"
---@field parent? string
---@field parent_index? integer

local function git_cmd()
  local cmd = config.get().git_cmd
  return type(cmd) == "table" and vim.deepcopy(cmd) or { cmd }
end

local function extend(target, values)
  for _, value in ipairs(values or {}) do target[#target + 1] = value end
  return target
end

---@param args string[]
---@param cwd? string
---@param opt? table
---@return string[], integer, string[]
function M.exec(args, cwd, opt)
  opt = opt or {}
  local command = git_cmd()
  if cwd and cwd ~= "" then extend(command, { "-C", cwd }) end
  extend(command, args)

  local output = vim.fn.systemlist(command, opt.writer)
  local code = vim.v.shell_error
  if type(output) == "string" then output = { output } end
  return output or {}, code, code == 0 and {} or (output or {})
end

---@return string[]
function M.command()
  return git_cmd()
end

---@return boolean
function M.is_available()
  local cmd = git_cmd()
  return type(cmd[1]) == "string" and vim.fn.executable(cmd[1]) == 1
end

local function indicative_paths()
  local paths = {}
  local bufnr = vim.api.nvim_get_current_buf()

  if vim.bo[bufnr].buftype == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      paths[#paths + 1] = vim.fn.fnamemodify(name, ":p")
    end
  end

  local cwd = (vim.uv or vim.loop).cwd()
  if cwd and cwd ~= "" then
    paths[#paths + 1] = cwd
  end

  return paths
end

local function open_buffer_paths()
  local paths = {}
  local current = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if bufnr ~= current and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then paths[#paths + 1] = vim.fn.fnamemodify(name, ":p") end
    end
  end
  return paths
end

---@param path string
---@return string?
function M.find_toplevel(path)
  if path == "" then return nil end

  local uv = vim.uv or vim.loop
  while path and path ~= "" do
    local stat = uv.fs_stat(path)
    if stat and stat.type == "directory" then break end

    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then return nil end
    path = parent
  end

  local out, code = M.exec({
    "-C",
    path,
    "rev-parse",
    "--path-format=absolute",
    "--show-toplevel",
  }, nil, { silent = true })

  if code ~= 0 or not out[1] or out[1] == "" then return nil end
  local toplevel = vim.fn.fnamemodify(vim.trim(out[1]), ":p")
  if toplevel == "/" or toplevel:match("^%a:[/\\]$") then return toplevel end
  return toplevel:gsub("[/\\]$", "")
end

---@return string? repo
---@return string? reason
function M.resolve_repository()
  if not M.is_available() then
    return nil, "git_unavailable"
  end

  local repos = {}
  for _, path in ipairs(indicative_paths()) do
    local repo = M.find_toplevel(path)
    if repo and not vim.tbl_contains(repos, repo) then
      repos[#repos + 1] = repo
    end
  end

  -- The current file is the strongest available repository signal. The cwd is
  -- only consulted when the current buffer cannot identify a repository.
  if repos[1] then return repos[1] end

  -- A workspace root can sit above multiple repositories. If the current file
  -- and cwd do not identify one, use another open buffer only when it yields a
  -- unique repository; otherwise require the user to focus an unambiguous file.
  for _, path in ipairs(open_buffer_paths()) do
    local repo = M.find_toplevel(path)
    if repo and not vim.tbl_contains(repos, repo) then repos[#repos + 1] = repo end
  end
  if #repos == 1 then return repos[1] end
  if #repos > 1 then return nil, "ambiguous_repository" end
  return nil, "not_repository"
end

---@param repo string
---@param opt? { all?: boolean, rev?: string }
---@return boolean
function M.has_commits(repo, opt)
  opt = opt or {}
  local args
  if opt.all then
    args = { "rev-list", "--all", "--max-count=1" }
  else
    args = { "rev-parse", "--verify", (opt.rev or "HEAD") .. "^{commit}" }
  end

  local out, code = M.exec(args, repo, {
    silent = true,
  })
  return code == 0 and out[1] ~= nil and out[1] ~= ""
end

---@param repo string
---@return boolean
function M.is_shallow(repo)
  local out, code = M.exec({ "rev-parse", "--is-shallow-repository" }, repo, {
    silent = true,
  })
  return code == 0 and vim.trim(out[1] or "") == "true"
end

---@param repo string
---@return string
function M.empty_tree(repo)
  local out, code = M.exec({ "rev-parse", "--show-object-format" }, repo, {
    silent = true,
  })
  if code == 0 and vim.trim(out[1] or "") == "sha256" then
    return SHA256_EMPTY_TREE
  end
  return SHA1_EMPTY_TREE
end

---@param line string
---@return GitDiffCommit?
function M.parse_log_line(line)
  if type(line) ~= "string" or line == "" then return nil end
  local fields = vim.split(line, FIELD_SEP, { plain = true, trimempty = false })
  if not fields[1] or fields[1] == "" then return nil end

  local parents = {}
  for parent in (fields[7] or ""):gmatch("%S+") do
    parents[#parents + 1] = parent
  end

  return {
    hash = fields[1],
    short_hash = fields[2] or fields[1]:sub(1, 8),
    author = fields[3] or "",
    iso_date = fields[4] or "",
    date = fields[4] or "",
    subject = fields[5] or "",
    relative_date = fields[6] or "",
    parents = parents,
    body = fields[8],
  }
end

---@param commit GitDiffCommit
---@param merge_parent? integer
---@return GitDiffRevisionRange?
---@return string? err
function M.revision_range(commit, merge_parent)
  if not commit or type(commit.hash) ~= "string" or commit.hash == "" then
    return nil, "Invalid commit object."
  end

  local parents = commit.parents or {}
  if #parents == 0 then
    local empty_tree = commit.empty_tree or SHA1_EMPTY_TREE
    return {
      rev_arg = empty_tree .. ".." .. commit.hash,
      kind = "root",
      parent = empty_tree,
    }
  end

  local parent_index = #parents > 1 and (merge_parent or 1) or 1
  if type(parent_index) ~= "number"
      or parent_index % 1 ~= 0
      or parent_index < 1
      or parent_index > #parents
  then
    return nil, ("Commit has %d parent(s); parent %s is unavailable."):format(
      #parents,
      tostring(parent_index)
    )
  end

  local kind = #parents > 1 and "merge" or "ordinary"
  if commit.missing_parents and commit.missing_parents[parent_index] then
    return nil, table.concat({
      ("Commit %s is at a shallow-history boundary."):format(commit.short_hash or commit.hash),
      "Its selected parent is not available locally; deepen the clone before reviewing it.",
    }, "\n")
  end
  return {
    rev_arg = parents[parent_index] .. ".." .. commit.hash,
    kind = kind,
    parent = parents[parent_index],
    parent_index = parent_index,
  }
end

---@param repo string
---@param rev string
---@return GitDiffCommit?
---@return string? err
function M.read_commit(repo, rev)
  local format = table.concat({
    "%H",
    "%h",
    "%an",
    "%aI",
    "%s",
    "%ar",
    "%P",
    "%B",
  }, "%x1f")

  local out, code, stderr = M.exec({
    "show",
    "-s",
    "--no-show-signature",
    "--format=" .. format,
    rev .. "^{commit}",
  }, repo, { silent = true })

  if code ~= 0 then
    local detail = vim.trim(table.concat(stderr or {}, "\n"))
    return nil, detail ~= "" and detail or "Commit is no longer accessible."
  end

  local commit = M.parse_log_line(table.concat(out, "\n"))
  if not commit then return nil, "Commit metadata could not be read." end

  -- Git deliberately hides parent links at a shallow boundary in `%P`. Read
  -- the raw commit headers to distinguish that case from a real root commit,
  -- then refuse only the parents whose objects are genuinely unavailable.
  if #commit.parents == 0 and M.is_shallow(repo) then
    local raw, raw_code, raw_stderr = M.exec({ "cat-file", "-p", commit.hash }, repo, {
      silent = true,
    })
    if raw_code ~= 0 then
      local detail = vim.trim(table.concat(raw_stderr or {}, "\n"))
      return nil, detail ~= "" and detail or "Raw commit metadata could not be read."
    end

    local raw_parents = {}
    for _, line in ipairs(raw) do
      if line == "" then break end
      local parent = line:match("^parent (%x+)$")
      if parent then raw_parents[#raw_parents + 1] = parent end
    end

    if #raw_parents > 0 then
      commit.parents = raw_parents
      commit.missing_parents = {}
      for index, parent in ipairs(raw_parents) do
        local _, parent_code = M.exec({ "cat-file", "-e", parent .. "^{commit}" }, repo, {
          silent = true,
        })
        if parent_code ~= 0 then commit.missing_parents[index] = true end
      end
    end
  end

  if #commit.parents == 0 then commit.empty_tree = M.empty_tree(repo) end
  return commit
end

---@param opt table
---@return string[]
function M.history_args(opt)
  opt = opt or {}
  local args = {
    "--no-color",
    "--no-show-signature",
    "--date=iso-strict",
    "--pretty=format:%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f%ar%x1f%P",
  }

  if opt.max_count and tonumber(opt.max_count) and tonumber(opt.max_count) > 0 then
    args[#args + 1] = "--max-count=" .. math.floor(tonumber(opt.max_count))
  end

  if type(opt.args) == "table" then
    vim.list_extend(args, opt.args)
  end

  if opt.all then
    args[#args + 1] = "--all"
  elseif opt.rev and opt.rev ~= "" then
    args[#args + 1] = opt.rev
  else
    args[#args + 1] = "HEAD"
  end

  return args
end

---@param repo string
---@param history_args string[]
---@param callbacks { on_line: fun(commit: GitDiffCommit), on_exit: fun(ok: boolean, err?: string), on_error?: fun(err: string) }
---@return integer?
function M.stream_history(repo, history_args, callbacks)
  local cmd = git_cmd()
  extend(cmd, { "log" })
  extend(cmd, history_args)
  local stderr = {}
  local job = vim.fn.jobstart(cmd, {
    cwd = repo,
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, lines)
      for _, line in ipairs(lines or {}) do
        local commit = M.parse_log_line(line)
        if commit then callbacks.on_line(commit) end
      end
    end,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines or {}) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      callbacks.on_exit(code == 0, #stderr > 0 and table.concat(stderr, "\n") or nil)
    end,
  })

  if type(job) ~= "number" or job <= 0 then
    if callbacks.on_error then callbacks.on_error("Git process could not be started.") end
    return nil
  end

  return job
end

return M
