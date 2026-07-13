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
  local original_parent_choices
  local original_ui_select

  before_each(function()
    original_lib = package.loaded["diffview.lib"]
    original_read_commit = git.read_commit
    original_revision_range = git.revision_range
    original_parent_choices = git.parent_choices
    original_ui_select = vim.ui.select
    config.setup({ keymap = false })
  end)

  after_each(function()
    package.loaded["diffview.lib"] = original_lib
    git.read_commit = original_read_commit
    git.revision_range = original_revision_range
    git.parent_choices = original_parent_choices
    vim.ui.select = original_ui_select
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

  it("interactively compares a merge commit with the selected parent", function()
    local merge_hash = string.rep("c", 40)
    local first_parent = string.rep("1", 40)
    local second_parent = string.rep("2", 40)
    local captured_args
    local captured_prompt
    local captured_labels
    local view = { emitter = emitter(), panel = {} }
    function view:post_open() end
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
      return {
        hash = merge_hash,
        short_hash = "ccccccc",
        parents = { first_parent, second_parent },
      }
    end
    git.parent_choices = function()
      return {
        {
          index = 1,
          hash = first_parent,
          short_hash = "1111111",
          subject = "mainline work",
          author = "Ada",
          relative_date = "2 days ago",
          unavailable = true,
        },
        {
          index = 2,
          hash = second_parent,
          short_hash = "2222222",
          subject = "feature work",
          author = "Grace",
          relative_date = "1 day ago",
          unavailable = false,
        },
      }
    end
    vim.ui.select = function(items, opts, callback)
      captured_prompt = opts.prompt
      captured_labels = vim.tbl_map(opts.format_item, items)
      callback(items[2])
    end

    gitdiff.open_commit("/tmp/repo", merge_hash, gitdiff.capture_context())

    assert.are.same(second_parent .. ".." .. merge_hash, captured_args[1])
    assert.are.same("Select parent for merge ccccccc:", captured_prompt)
    assert.is_truthy(captured_labels[1]:find("first parent", 1, true))
    assert.is_truthy(captured_labels[1]:find("unavailable locally", 1, true))
    assert.is_truthy(captured_labels[2]:find("feature work", 1, true))
    assert.is_truthy(captured_labels[2]:find("Grace, 1 day ago", 1, true))
    assert.are.same(
      "Commit ccccccc (compared with parent 2: 2222222)",
      view.panel.rev_pretty_name
    )
    assert.are.same("review", gitdiff._state.active.phase)
  end)

  it("restores the session when merge-parent selection is cancelled", function()
    local merge_hash = string.rep("c", 40)
    local opened = false
    package.loaded["diffview.lib"] = {
      diffview_open = function()
        opened = true
        return nil
      end,
      dispose_view = function() end,
    }
    git.read_commit = function()
      return {
        hash = merge_hash,
        short_hash = "ccccccc",
        parents = { string.rep("1", 40), string.rep("2", 40) },
      }
    end
    git.parent_choices = function()
      return {
        { index = 1, short_hash = "1111111", subject = "one", author = "", relative_date = "" },
        { index = 2, short_hash = "2222222", subject = "two", author = "", relative_date = "" },
      }
    end
    vim.ui.select = function(_, _, callback) callback(nil) end

    gitdiff.open_commit("/tmp/repo", merge_hash, gitdiff.capture_context())

    assert.is_false(opened)
    assert.is_nil(gitdiff._state.active)
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
end)
