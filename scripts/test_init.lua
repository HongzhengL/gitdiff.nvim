local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
local site = root .. "/.tests/site"

local function ensure_dependency(repository, name)
  local destination = site .. "/pack/deps/start/" .. name
  if not (vim.uv or vim.loop).fs_stat(destination) then
    vim.fn.mkdir(vim.fn.fnamemodify(destination, ":h"), "p")
    local output = vim.fn.system({
      "git", "clone", "--depth=1", "https://github.com/" .. repository .. ".git", destination,
    })
    assert(vim.v.shell_error == 0, output)
  end
  return destination
end

vim.cmd("set runtimepath=" .. vim.env.VIMRUNTIME)
vim.opt.runtimepath:append(root)
vim.opt.packpath = { site }

local dependency_path = vim.env.GITDIFF_DIFFVIEW_PATH
  or (vim.fn.fnamemodify(root, ":h") .. "/diffview.nvim")
if (vim.uv or vim.loop).fs_stat(dependency_path .. "/lua/diffview/init.lua") then
  vim.opt.runtimepath:append(dependency_path)
else
  vim.opt.runtimepath:append(ensure_dependency("sindrets/diffview.nvim", "diffview.nvim"))
end
vim.cmd("runtime plugin/diffview.lua")

ensure_dependency("nvim-lua/plenary.nvim", "plenary.nvim")
vim.cmd("packadd plenary.nvim")

vim.env.XDG_CONFIG_HOME = root .. "/.tests/config"
vim.env.XDG_DATA_HOME = root .. "/.tests/data"
vim.env.XDG_STATE_HOME = root .. "/.tests/state"
vim.env.XDG_CACHE_HOME = root .. "/.tests/cache"
