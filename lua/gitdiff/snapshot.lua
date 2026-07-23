local git = require("gitdiff.git")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}
local LSP_SHUTDOWN_TIMEOUT_MS = 1000

local function normalized(path)
  return vim.fn.fnamemodify(path, ":p"):gsub("\\", "/"):gsub("/$", "")
end

local function is_within(path, root)
  path = normalized(path)
  root = normalized(root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function clients_for_buffer(buf)
  if vim.lsp.get_clients then return vim.lsp.get_clients({ bufnr = buf }) end
  ---@diagnostic disable-next-line: deprecated
  return vim.lsp.get_active_clients({ bufnr = buf })
end

local function call_client_stop(client, force)
  -- Client methods became colon-style in Neovim 0.11. Calling the old
  -- closure-style method with `self` makes 0.9 and 0.10 treat it as `force`.
  if vim.fn.has("nvim-0.11") == 1 then
    return pcall(client.stop, client, force)
  end
  return pcall(client.stop, force)
end

local function stop_snapshot_client(client)
  local ok = call_client_stop(client, false)
  if not ok then
    call_client_stop(client, true)
    return
  end

  local client_id = client.id
  vim.defer_fn(function()
    local current = vim.lsp.get_client_by_id(client_id)
    if current == client then call_client_stop(current, true) end
  end, LSP_SHUTDOWN_TIMEOUT_MS)
end

---@class GitDiffSnapshot
---@field repo string
---@field root string
---@field closed boolean
---@field autocmd? integer
local Snapshot = {}
Snapshot.__index = Snapshot

---@param buf integer
function Snapshot:track_buffer(buf)
  self.buffers[buf] = true
end

---@param path string
---@param revision string
---@return boolean
---@return string? err
function Snapshot:materialize(path, revision)
  local _, code, err = git.exec({ "checkout", revision, "--", path }, self.root, {
    silent = true,
  })
  if code ~= 0 then return false, table.concat(err, "\n") end
  return true
end

function Snapshot:cleanup()
  if self.closed then return end
  self.closed = true

  if self.autocmd then pcall(api.nvim_del_autocmd, self.autocmd) end

  local clients = {}
  local buffers = vim.deepcopy(self.buffers)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) then
      local name = api.nvim_buf_get_name(buf)
      if name ~= "" and is_within(name, self.root) then buffers[buf] = true end
    end
  end

  for buf in pairs(buffers) do
    if api.nvim_buf_is_valid(buf) then
      for _, client in ipairs(clients_for_buffer(buf)) do clients[client.id] = client end
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end

  for _, client in pairs(clients) do
    local has_external_buffer = false
    for buf in pairs(client.attached_buffers or {}) do
      if api.nvim_buf_is_valid(buf) then
        local name = api.nvim_buf_get_name(buf)
        if name ~= "" and not is_within(name, self.root) then
          has_external_buffer = true
          break
        end
      end
    end
    if not has_external_buffer then stop_snapshot_client(client) end
  end

  git.exec({ "worktree", "remove", "--force", self.root }, self.repo, { silent = true })
  if uv.fs_stat(self.root) then vim.fn.delete(self.root, "rf") end
  git.exec({ "worktree", "prune" }, self.repo, { silent = true })
end

---@param repo string
---@param revision string
---@return GitDiffSnapshot?
---@return string? err
function M.create(repo, revision)
  local root = vim.fn.tempname() .. "-gitdiff"
  local _, code, err = git.exec({
    "worktree",
    "add",
    "--detach",
    "--force",
    root,
    revision,
  }, repo, { silent = true })

  if code ~= 0 then
    if uv.fs_stat(root) then vim.fn.delete(root, "rf") end
    return nil, table.concat(err, "\n")
  end

  local snapshot = setmetatable({
    repo = repo,
    root = normalized(root),
    closed = false,
    buffers = {},
  }, Snapshot)

  snapshot.autocmd = api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function() snapshot:cleanup() end,
    desc = "Clean up GitDiff historical source worktree",
  })
  return snapshot
end

return M
