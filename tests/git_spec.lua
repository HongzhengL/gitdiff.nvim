local git = require("gitdiff.git")

local commit_hash = string.rep("c", 40)
local first_parent = string.rep("1", 40)
local second_parent = string.rep("2", 40)
local null_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

describe("gitdiff.git", function()
  it("parses commit metadata and parents", function()
    local commit = git.parse_log_line(table.concat({
      commit_hash,
      "ccccccc",
      "Ada Lovelace",
      "2026-07-12T12:00:00Z",
      "Subject",
      "now",
      first_parent .. " " .. second_parent,
      "Body",
    }, "\31"))

    assert.are.same(commit_hash, commit.hash)
    assert.are.same("Ada Lovelace", commit.author)
    assert.are.same({ first_parent, second_parent }, commit.parents)
    assert.are.same("Body", commit.body)
  end)

  it("builds exact root, ordinary, and merge ranges", function()
    local root = assert(git.revision_range({ hash = commit_hash, parents = {} }))
    local ordinary = assert(git.revision_range({ hash = commit_hash, parents = { first_parent } }))
    local merge = assert(git.revision_range({
      hash = commit_hash,
      parents = { first_parent, second_parent },
    }, 2))

    assert.are.same(null_tree .. ".." .. commit_hash, root.rev_arg)
    assert.are.same(first_parent .. ".." .. commit_hash, ordinary.rev_arg)
    assert.are.same(second_parent .. ".." .. commit_hash, merge.rev_arg)
    assert.are.same("merge", merge.kind)
  end)

  it("uses a repository-specific empty tree", function()
    local empty_tree = string.rep("e", 64)
    local range = assert(git.revision_range({
      hash = string.rep("c", 64),
      parents = {},
      empty_tree = empty_tree,
    }))
    assert.are.same(empty_tree, range.parent)
  end)

  it("rejects invalid and unavailable merge parents", function()
    local range, err = git.revision_range({
      hash = commit_hash,
      parents = { first_parent, second_parent },
    }, 1.5)
    assert.is_nil(range)
    assert.is_truthy(err:find("parent 1.5 is unavailable", 1, true))

    range, err = git.revision_range({
      hash = commit_hash,
      short_hash = "ccccccc",
      parents = { first_parent },
      missing_parents = { [1] = true },
    })
    assert.is_nil(range)
    assert.is_truthy(err:find("shallow%-history boundary"))
  end)
end)
