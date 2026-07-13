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

  it("reads display metadata for every merge parent", function()
    write(repo, "root.txt", "root")
    commit(repo, "root")
    local main_branch = git_run(repo, { "branch", "--show-current" })

    git_run(repo, { "checkout", "-b", "feature" })
    write(repo, "feature.txt", "feature")
    local feature_hash = commit(repo, "feature work")

    git_run(repo, { "checkout", main_branch })
    write(repo, "main.txt", "main")
    local main_hash = commit(repo, "mainline work")
    git_run(repo, { "merge", "--no-ff", "feature", "-m", "merge feature" })

    local merge = assert(git.read_commit(repo, "HEAD"))
    local choices = git.parent_choices(repo, merge)

    assert.are.same({ main_hash, feature_hash }, merge.parents)
    assert.are.same(2, #choices)
    assert.are.same("mainline work", choices[1].subject)
    assert.are.same("feature work", choices[2].subject)
    assert.are.same("GitDiff Tests", choices[2].author)
    assert.is_not.same("", choices[2].relative_date)
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
end)
