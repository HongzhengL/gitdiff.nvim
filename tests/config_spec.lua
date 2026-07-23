local config = require("gitdiff.config")

describe("gitdiff configuration", function()
  after_each(function() config.setup({}) end)

  it("provides zero-configuration defaults", function()
    local value = config.setup({})
    assert.are.same("<leader>gv", value.keymap)
    assert.are.same("<leader>gu", value.unified_keymap)
    assert.are.same("split", value.view)
    assert.are.same({ context_lines = 3, lsp = true }, value.unified)
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
    assert.has_error(function() config.setup({ unified_keymap = 42 }) end)
  end)

  it("accepts unified view and rejects unknown views", function()
    local unified = config.setup({
      view = "unified",
      unified = { context_lines = false, lsp = false },
    })
    assert.are.same("unified", unified.view)
    assert.are.same({ context_lines = false, lsp = false }, unified.unified)
    assert.has_error(function() config.setup({ view = "stacked" }) end)
    assert.has_error(function() config.setup({ unified = { context_lines = -1 } }) end)
    assert.has_error(function() config.setup({ unified = { lsp = "yes" } }) end)
  end)
end)
