# gitdiff.nvim

[![CI](https://github.com/HongzhengL/gitdiff.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/HongzhengL/gitdiff.nvim/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

`gitdiff.nvim` is a focused commit-review picker for Neovim. Choose a commit,
preview its metadata, and open an exact parent-to-commit comparison in either
a split Diffview or a GitHub-style unified source view.

Diffview provides the review shell, changed-file panel, and navigation.
GitDiff adds the unified source layout plus repository discovery, history
selection, merge-parent handling, shallow-clone checks, and the read-only
review boundary.

## Why GitDiff?

Diffview is excellent once you know what revision to open. GitDiff adds the
missing interactive step: search your history, preview a commit, and open the
correct historical comparison without copying hashes or constructing ranges.

| Capability | Diffview | GitDiff |
| --- | :---: | :---: |
| Render and navigate a diff | ✓ | Split and unified views |
| Search and select a commit | — | ✓ |
| Choose the correct parent automatically | — | ✓ |
| Handle root, merge, and shallow history | — | ✓ |
| Snacks, Telescope, fzf-lua, and native pickers | — | ✓ |
| Guard the historical review from index mutations | — | ✓ |

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

Press `<leader>gv` for the configured view, `<leader>gu` to go directly to a
unified review, or run:

```vim
:GitDiff
```

Choose a layout for one invocation with `:GitDiff split` or
`:GitDiff unified`.

Unified view keeps Diffview's changed-file panel and displays one selected
file at a time:

- `<Tab>` / `<S-Tab>` selects the next or previous changed file.
- `j`, `k`, and `<CR>` navigate and select entries in the file panel.
- `]c` / `[c` moves between inline hunks.
- `<leader>e` focuses the file panel; `<leader>b` toggles it.
- `q` closes the review and restores the previous editing context.

The displayed buffer contains the complete source text from the selected
commit—never patch headers or `+`/`-` prefixes. Added source lines are
highlighted in place, deleted parent lines are virtual decorations, and
unchanged regions are folded. Source line numbers therefore remain valid for
language tooling.

By default, unified reviews create a temporary detached Git worktree for the
selected commit. Files open from that worktree as normal `file://` source
buffers, allowing LSP servers to detect the historical project root and
dependencies. The worktree, its buffers, and worktree-scoped LSP clients are
cleaned up when the review closes. The original working tree and index are not
modified.

GitDiff resolves the repository from the current file or workspace, opens a
commit picker, and compares the selected commit with its direct parent. Root
commits are compared with Git's empty tree. Merge commits use the first parent
by default.

Historical reviews are always read-only. GitDiff blocks Diffview's stage,
unstage, and restore events for every review it creates.

If setup does not behave as expected, run `:checkhealth gitdiff`.

## Configuration

```lua
require("gitdiff").setup({
  keymap = "<leader>gv", -- false keeps only :GitDiff
  unified_keymap = "<leader>gu", -- false disables the direct unified mapping
  view = "split",       -- split or unified
  unified = {
    context_lines = 3, -- false shows all unchanged source without folds
    lsp = true,        -- use a temporary historical worktree and file:// buffers
  },
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

Both default mappings are conflict-safe: GitDiff will not replace existing
global mappings. `:GitDiff` remains available when a conflict exists.

## Development

```sh
make test
```

The test setup uses a sibling `diffview.nvim` checkout when available and
otherwise downloads the declared test dependencies into `.tests/`.

## License

GPL-3.0-or-later. This plugin originated from commit-review work developed
against Diffview and retains attribution in [LICENSE](LICENSE).
