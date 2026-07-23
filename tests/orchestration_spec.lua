local config = require("gitdiff.config")
local git = require("gitdiff.git")
local gitdiff = require("gitdiff")

local function emitter()
  local listeners = {}
  return {
    on = function(_, name, callback)
      listeners[name] = listeners[name] or {}
      table.insert(listeners[name], 1, callback)
    end,
    emit = function(_, name)
      local event = {
        stopped = false,
        stop_propagation = function(self) self.stopped = true end,
      }
      for _, callback in ipairs(listeners[name] or {}) do
        callback(event)
        if event.stopped then break end
      end
    end,
  }
end

describe("gitdiff orchestration", function()
  local original_lib
  local original_read_commit
  local original_revision_range

  before_each(function()
    original_lib = package.loaded["diffview.lib"]
    original_read_commit = git.read_commit
    original_revision_range = git.revision_range
    config.setup({ keymap = false })
  end)

  after_each(function()
    package.loaded["diffview.lib"] = original_lib
    git.read_commit = original_read_commit
    git.revision_range = original_revision_range
    gitdiff._state.active = nil
  end)

  it("passes repository paths literally and blocks mutating Diffview events", function()
    local captured_args
    local mutation_count = 0
    local view = { emitter = emitter(), panel = {} }
    function view:post_open()
      self.emitter:on("stage_all", function() mutation_count = mutation_count + 1 end)
    end
    function view:open() self:post_open() end
    function view:close() end

    package.loaded["diffview.lib"] = {
      diffview_open = function(args)
        captured_args = args
        return view
      end,
      dispose_view = function() end,
    }
    git.read_commit = function()
      return { hash = string.rep("b", 40), short_hash = "bbbbbbb", parents = { string.rep("a", 40) } }
    end
    git.revision_range = function()
      return { rev_arg = string.rep("a", 40) .. ".." .. string.rep("b", 40), kind = "ordinary" }
    end

    local context = gitdiff.capture_context()
    gitdiff.open_commit("/tmp/repository with spaces", string.rep("b", 40), context)

    assert.are.same("-C=/tmp/repository with spaces", captured_args[2])
    assert.are.same("Commit bbbbbbb", view.panel.rev_pretty_name)
    view.emitter:emit("stage_all")
    assert.are.same(0, mutation_count)
  end)

  it("preserves an existing default mapping", function()
    local lhs = "<leader>gv"
    vim.keymap.set("n", lhs, "<cmd>let g:gitdiff_test = 1<cr>", { desc = "User mapping" })
    local ok, reason = gitdiff.setup_mapping(lhs)
    assert.is_false(ok)
    assert.are.same("conflict", reason)
    assert.are.same("User mapping", vim.fn.maparg(lhs, "n", false, true).desc)
    vim.keymap.del("n", lhs)
  end)

  it("creates a direct unified mapping", function()
    local lhs = "<leader>gu"
    pcall(vim.keymap.del, "n", lhs)
    assert.is_true(gitdiff.setup_unified_mapping(lhs))
    local map = vim.fn.maparg(lhs, "n", false, true)
    assert.are.same("GitDiff unified", map.desc)
    assert.are.same(gitdiff.open_unified, map.callback)
    assert.is_true(gitdiff.setup_unified_mapping(false))
    assert.are.same({}, vim.fn.maparg(lhs, "n", false, true))
  end)
end)
