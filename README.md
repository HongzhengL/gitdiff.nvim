# gitdiff.nvim

`gitdiff.nvim` is a focused commit-review picker for Neovim. Choose a commit,
preview its metadata, and open an exact parent-to-commit comparison in
[`sindrets/diffview.nvim`](https://github.com/sindrets/diffview.nvim).

The plugin is intentionally small: Diffview remains responsible for rendering
and navigation, while GitDiff owns repository discovery, history selection,
merge-parent handling, shallow-clone checks, and the read-only review boundary.

## Requirements

- Neovim 0.9 or newer
- Git
- `sindrets/diffview.nvim`
- `nvim-lua/plenary.nvim` (required by Diffview)
- Optional picker: Snacks, Telescope, or fzf-lua. A native picker is included.

## Installation

With lazy.nvim:

```lua
{
  "HongzhengL/gitdiff.nvim",
  dependencies = {
    "sindrets/diffview.nvim",
    "nvim-lua/plenary.nvim",
  },
  opts = {},
}
```

For local development:

```lua
{
  dir = "~/Documents/gitdiff.nvim",
  dependencies = {
    "sindrets/diffview.nvim",
    "nvim-lua/plenary.nvim",
  },
  opts = {},
}
```

## Usage

Press `<leader>gv` or run:

```vim
:GitDiff
```

GitDiff resolves the repository from the current file or workspace, opens a
commit picker, and compares the selected commit with its direct parent. Root
commits are compared with Git's empty tree. Merge commits use the first parent
by default.

Historical reviews use immutable commit buffers. GitDiff additionally blocks
Diffview's stage, unstage, and restore events for the review it creates.

## Configuration

```lua
require("gitdiff").setup({
  keymap = "<leader>gv", -- false keeps only :GitDiff
  picker = "auto",      -- auto, snacks, telescope, fzf, native, vim_ui
  max_count = 256,
  rev = "HEAD",
  all = false,
  preview = true,
  merge_parent = 1,
  history_args = {},
  diffview_args = {},   -- only --selected-file=... is accepted
  notify_shallow = true,
  git_cmd = { "git" },
})
```

`picker` may also be a function receiving the picker options. It must call one
of `on_select(item)`, `on_cancel()`, or `on_error(message)`.

The default mapping is conflict-safe: GitDiff will not replace an existing
global `<leader>gv` mapping. `:GitDiff` remains available when a conflict exists.

## Development

```sh
make test
```

The test setup uses a sibling `diffview.nvim` checkout when available and
otherwise downloads the declared test dependencies into `.tests/`.

## License

GPL-3.0-or-later. This plugin originated from commit-review work developed
against Diffview and retains attribution in [LICENSE](LICENSE).
