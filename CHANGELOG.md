# Changelog

All notable changes to gitdiff.nvim will be documented in this file.

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
