# Changelog

All notable changes to gitdiff.nvim will be documented in this file.

## Unreleased

- Add a read-only GitHub-style unified source view, selectable with
  `view = "unified"` or `:GitDiff unified`, while retaining Diffview's
  changed-file panel and per-file navigation.
- Render deleted lines virtually over the selected commit's unchanged source
  buffer and preserve source line coordinates.
- Add temporary historical worktrees for normal `file://` buffers, project
  root detection, and LSP support without touching the user's working tree.
- Shut down snapshot-only LSP clients gracefully, with a timed force fallback
  compatible with Neovim 0.9 and newer.
- Add unified hunk navigation and unchanged-context folds.
- Add a conflict-safe `<leader>gu` mapping that opens unified review directly.

## [0.1.0] - 2026-07-12

- Add commit history selection with Snacks, Telescope, fzf-lua, `vim.ui`, and
  a built-in native picker.
- Open exact parent-to-commit comparisons in Diffview.
- Handle root commits, merge parents, SHA-256 repositories, and shallow-history
  boundaries.
- Preserve the user's editing context and guard historical reviews from index
  mutations.
- Add zero-configuration `<leader>gv` mapping with conflict detection.
- Add `:GitDiff` and `:checkhealth gitdiff` entry points.

[0.1.0]: https://github.com/HongzhengL/gitdiff.nvim/releases/tag/v0.1.0
