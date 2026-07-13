local config = require("gitdiff.config")

describe("gitdiff configuration", function()
  after_each(function() config.setup({}) end)

  it("provides zero-configuration defaults", function()
    local value = config.setup({})
    assert.are.same("<leader>gv", value.keymap)
    assert.are.same("auto", value.picker)
    assert.are.same({ "git" }, value.git_cmd)
  end)

  it("accepts a custom command and disabled mapping", function()
    local value = config.setup({ git_cmd = "gita", keymap = false })
    assert.are.same({ "gita" }, value.git_cmd)
    assert.is_false(value.keymap)
  end)

  it("rejects invalid mappings", function()
    assert.has_error(function() config.setup({ keymap = 42 }) end)
  end)
end)
