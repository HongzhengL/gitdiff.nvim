local git = require("gitdiff.git")

local function run(command)
  local output = vim.fn.system(command)
  assert.are.same(0, vim.v.shell_error, table.concat(command, " ") .. "\n" .. output)
  return vim.trim(output)
end

local function git_run(repo, args)
  return run(vim.list_extend({ "git", "-C", repo }, args))
end

local function write(repo, name, content)
  vim.fn.writefile({ content }, repo .. "/" .. name)
end

local function commit(repo, message)
  git_run(repo, { "add", "--all" })
  git_run(repo, { "commit", "-m", message })
  return git_run(repo, { "rev-parse", "HEAD" })
end

local function lsp_clients(buf)
  if vim.lsp.get_clients then return vim.lsp.get_clients({ bufnr = buf }) end
  ---@diagnostic disable-next-line: deprecated
  return vim.lsp.get_active_clients({ bufnr = buf })
end

describe("gitdiff Git integration", function()
  local repo

  before_each(function()
    repo = vim.fn.tempname()
    run({ "git", "init", repo })
    git_run(repo, { "config", "user.name", "GitDiff Tests" })
    git_run(repo, { "config", "user.email", "gitdiff@example.invalid" })
    git_run(repo, { "config", "commit.gpgsign", "false" })
  end)

  after_each(function()
    vim.fn.delete(repo, "rf")
  end)

  it("reads root and ordinary commits from a repository", function()
    assert.is_false(git.has_commits(repo))
    write(repo, "root.txt", "root")
    local root_hash = commit(repo, "root")
    write(repo, "next.txt", "next")
    local next_hash = commit(repo, "next")

    local root = assert(git.read_commit(repo, root_hash))
    local next_commit = assert(git.read_commit(repo, next_hash))
    assert.are.same("root", assert(git.revision_range(root)).kind)
    assert.are.same(root_hash, assert(git.revision_range(next_commit)).parent)

    local nested = repo .. "/not-created/deeper/file.lua"
    assert.are.same((vim.uv or vim.loop).fs_realpath(repo), git.find_toplevel(nested))
  end)

  it("detects a shallow boundary without fetching", function()
    write(repo, "one.txt", "one")
    commit(repo, "one")
    write(repo, "two.txt", "two")
    commit(repo, "two")

    local shallow = vim.fn.tempname()
    run({ "git", "clone", "--depth=1", "file://" .. repo, shallow })
    local selected = assert(git.read_commit(shallow, "HEAD"))
    local range, err = git.revision_range(selected)
    assert.is_true(git.is_shallow(shallow))
    assert.is_nil(range)
    assert.is_truthy(err:find("shallow%-history boundary"))
    vim.fn.delete(shallow, "rf")
  end)

  it("opens an upstream Diffview review without allowing index mutation", function()
    write(repo, "root.txt", "root")
    commit(repo, "root")
    write(repo, "next.txt", "committed")
    local selected = commit(repo, "next")
    write(repo, "next.txt", "working tree change")

    local gitdiff = require("gitdiff")
    gitdiff.open_commit(repo, selected, gitdiff.capture_context())
    assert.is_true(vim.wait(5000, function()
      local active = gitdiff._state.active
      return active and active.phase == "review" and active.view.ready
    end, 20))

    local view = gitdiff._state.active.view
    view.emitter:emit("stage_all")
    assert.are.same("", git_run(repo, { "diff", "--cached", "--name-only" }))

    view:close()
    assert.is_true(vim.wait(2000, function() return gitdiff._state.active == nil end, 20))
  end)

  it("opens selectable source files in a read-only unified review", function()
    write(repo, "first.py", "first = 'old'")
    write(repo, "second.py", "second = 'old'")
    commit(repo, "root")
    write(repo, "first.py", "first = 'new'")
    write(repo, "second.py", "second = 'new'")
    local selected = commit(repo, "change files")

    local gitdiff = require("gitdiff")
    local context = gitdiff.capture_context()
    local lsp_client
    local lsp_autocmd = vim.api.nvim_create_autocmd("FileType", {
      pattern = "python",
      callback = function(event)
        local name = vim.api.nvim_buf_get_name(event.buf)
        if not name:find("%-gitdiff/") then return end

        if not lsp_client then
          lsp_client = vim.lsp.start_client({
            name = "gitdiff-test-lsp",
            cmd = {
              vim.v.progpath,
              "--headless",
              "-u",
              "NONE",
              "-l",
              vim.fn.getcwd() .. "/tests/mock_lsp_server.lua",
            },
            root_dir = vim.fn.fnamemodify(name, ":h"),
          })
        end
        if lsp_client then vim.lsp.buf_attach_client(event.buf, lsp_client) end
      end,
    })
    gitdiff.open_commit(repo, selected, context, "unified")

    assert.is_true(vim.wait(5000, function()
      local active = gitdiff._state.active
      local view = active and active.view
      return active
        and active.mode == "unified"
        and view.ready
        and view.cur_entry
        and view.cur_layout
        and view.cur_layout.name == "gitdiff_unified"
        and view.cur_layout:get_main_win().file.bufnr
        and vim.b[view.cur_layout:get_main_win().file.bufnr].gitdiff_unified == true
    end, 20))

    local view = gitdiff._state.active.view
    local snapshot_root = assert(gitdiff._state.active.snapshot).root
    local files = view.panel:ordered_file_list()
    assert.are.same(2, #files)
    assert.is_true(view.panel:is_open())
    assert.are.same(2, #vim.api.nvim_tabpage_list_wins(view.tabpage))

    local main = view.cur_layout:get_main_win()
    local first_buf = main.file.bufnr
    local first_lines = vim.api.nvim_buf_get_lines(first_buf, 0, -1, false)
    assert.are.same({ "first = 'new'" }, first_lines)
    assert.are.same("python", vim.bo[first_buf].filetype)
    assert.are.same("", vim.bo[first_buf].buftype)
    assert.is_truthy(vim.uri_from_bufnr(first_buf):find("^file://"))
    assert.is_truthy(
      vim.api.nvim_buf_get_name(first_buf):find(snapshot_root, 1, true)
    )
    assert.is_false(vim.bo[first_buf].modifiable)
    assert.is_true(vim.b[first_buf].gitdiff_unified)
    assert.are.same(
      "Next unified diff hunk",
      vim.fn.maparg("]c", "n", false, true).desc
    )

    local marks = vim.api.nvim_buf_get_extmarks(
      first_buf,
      require("gitdiff.unified")._namespace,
      0,
      -1,
      { details = true }
    )
    assert.is_true(#marks >= 2)
    local saw_addition = false
    local saw_deletion = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.line_hl_group == "DiffAdd" then saw_addition = true end
      for _, virtual_line in ipairs(details.virt_lines or {}) do
        for _, chunk in ipairs(virtual_line) do
          if chunk[1] == "- first = 'old'" and chunk[2] == "DiffDelete" then
            saw_deletion = true
          end
        end
      end
    end
    assert.is_true(saw_addition)
    assert.is_true(saw_deletion)
    assert.is_true(vim.wait(5000, function()
      if not lsp_client then return false end
      for _, client in ipairs(lsp_clients(first_buf)) do
        if client.id == lsp_client and client.initialized then return true end
      end
      return false
    end, 20))

    local second = files[1] == view.cur_entry and files[2] or files[1]
    view:set_file(second, true)
    assert.is_true(vim.wait(5000, function()
      local bufnr = view.cur_layout:get_main_win().file.bufnr
      return view.cur_entry == second
        and type(bufnr) == "number"
        and bufnr ~= first_buf
        and vim.b[bufnr].gitdiff_unified == true
    end, 20))
    local second_buf = view.cur_layout:get_main_win().file.bufnr
    local expected = second.path == "first.py" and "first = 'new'" or "second = 'new'"
    assert.are.same(
      { expected },
      vim.api.nvim_buf_get_lines(second_buf, 0, -1, false)
    )
    assert.are.same("python", vim.bo[second_buf].filetype)

    view:close()
    pcall(vim.api.nvim_del_autocmd, lsp_autocmd)
    assert.is_true(vim.wait(2000, function()
      local client = lsp_client and vim.lsp.get_client_by_id(lsp_client)
      return gitdiff._state.active == nil
        and vim.api.nvim_get_current_tabpage() == context.tabpage
        and not (vim.uv or vim.loop).fs_stat(snapshot_root)
        and (not client or client:is_stopped())
    end, 20))
  end)

  it("shows a deleted file as selectable parent source", function()
    write(repo, "gone.py", "value = 'before deletion'")
    commit(repo, "add file")
    vim.fn.delete(repo .. "/gone.py")
    local selected = commit(repo, "delete file")

    local gitdiff = require("gitdiff")
    local context = gitdiff.capture_context()
    gitdiff.open_commit(repo, selected, context, "unified")

    assert.is_true(vim.wait(5000, function()
      local active = gitdiff._state.active
      local view = active and active.view
      local layout = view and view.cur_layout
      local file = layout and layout:get_main_win().file
      return view
        and view.ready
        and view.cur_entry
        and view.cur_entry.status == "D"
        and layout.name == "gitdiff_unified"
        and layout.displaying_old
        and file.bufnr
        and vim.b[file.bufnr].gitdiff_unified == true
    end, 20))

    local active = gitdiff._state.active
    local view = active.view
    local layout = view.cur_layout
    local buf = layout:get_main_win().file.bufnr
    assert.are.same(
      { "value = 'before deletion'" },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
    assert.are.same("python", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_truthy(vim.api.nvim_buf_get_name(buf):find(active.snapshot.root, 1, true))

    local deleted = false
    local deleted_marks = vim.api.nvim_buf_get_extmarks(
      buf,
      require("gitdiff.unified")._namespace,
      0,
      -1,
      { details = true }
    )
    for _, mark in ipairs(deleted_marks) do
      if mark[4].line_hl_group == "DiffDelete" then deleted = true end
    end
    assert.is_true(deleted)

    local snapshot_root = active.snapshot.root
    view:close()
    assert.is_true(vim.wait(2000, function()
      return gitdiff._state.active == nil
        and vim.api.nvim_get_current_tabpage() == context.tabpage
        and not (vim.uv or vim.loop).fs_stat(snapshot_root)
    end, 20))
  end)
end)
