local api = vim.api

local M = {}

local namespace = api.nvim_create_namespace("gitdiff-unified")
local sign_group = "gitdiff-unified"
local add_sign = "GitDiffUnifiedAdd"
local delete_sign = "GitDiffUnifiedDelete"

M._namespace = namespace

local function source_lines(file)
  if not file or file.nulled or not file.bufnr or not api.nvim_buf_is_valid(file.bufnr) then
    return {}
  end
  return api.nvim_buf_get_lines(file.bufnr, 0, -1, false)
end

local function diff_indices(old_lines, new_lines)
  local function encode(lines)
    if #lines == 0 or (#lines == 1 and lines[1] == "") then return "" end
    return table.concat(lines, "\n") .. "\n"
  end

  return vim.diff(
    encode(old_lines),
    encode(new_lines),
    { result_type = "indices", algorithm = "histogram" }
  )
end

local function hunk_header(hunk)
  return ("@@ -%d,%d +%d,%d @@"):format(hunk[1], hunk[2], hunk[3], hunk[4])
end

local function set_virtual_hunk(buf, hunk, old_lines, line_count)
  local old_start, old_count, new_start, new_count = unpack(hunk)
  local virtual_lines = {
    { { hunk_header(hunk), "DiffText" } },
  }

  for index = old_start, old_start + old_count - 1 do
    virtual_lines[#virtual_lines + 1] = {
      { "- " .. (old_lines[index] or ""), "DiffDelete" },
    }
  end

  local anchor
  local above
  if new_count > 0 then
    anchor = math.max(new_start - 1, 0)
    above = true
  elseif new_start <= 0 then
    anchor = 0
    above = true
  else
    anchor = math.min(new_start - 1, math.max(line_count - 1, 0))
    above = false
  end

  api.nvim_buf_set_extmark(buf, namespace, anchor, 0, {
    virt_lines = virtual_lines,
    virt_lines_above = above,
    priority = 110,
    strict = false,
  })

  for row = new_start, new_start + new_count - 1 do
    if row >= 1 and row <= line_count then
      api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
        line_hl_group = "DiffAdd",
        number_hl_group = "DiffAdd",
        hl_eol = true,
        priority = 100,
      })
      vim.fn.sign_place(0, sign_group, add_sign, buf, {
        lnum = row,
        priority = 10,
      })
    end
  end

  return math.max(new_start, 1)
end

local function fold_unchanged(win, hunks, line_count, context)
  if not api.nvim_win_is_valid(win) or line_count == 0 or #hunks == 0 then return end

  local visible = {}
  for _, hunk in ipairs(hunks) do
    local start = math.max((hunk[3] > 0 and hunk[3] or 1) - context, 1)
    local changed_end = hunk[4] > 0 and (hunk[3] + hunk[4] - 1) or math.max(hunk[3], 1)
    local finish = math.min(changed_end + context, line_count)
    local previous = visible[#visible]

    if previous and start <= previous[2] + 1 then
      previous[2] = math.max(previous[2], finish)
    else
      visible[#visible + 1] = { start, finish }
    end
  end

  api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    local cursor = 1

    local function create_fold(first, last)
      if first <= last then
        pcall(vim.cmd, ("%d,%dfold"):format(first, last))
      end
    end

    for _, range in ipairs(visible) do
      create_fold(cursor, range[1] - 1)
      cursor = range[2] + 1
    end
    create_fold(cursor, line_count)
  end)
end

local function map_hunk_navigation(buf, win, anchors)
  local function jump(direction)
    if not api.nvim_win_is_valid(win) or api.nvim_get_current_win() ~= win then return end
    local row = api.nvim_win_get_cursor(win)[1]
    local count = vim.v.count1

    for _ = 1, count do
      local target
      if direction > 0 then
        for _, anchor in ipairs(anchors) do
          if anchor > row then
            target = anchor
            break
          end
        end
      else
        for index = #anchors, 1, -1 do
          if anchors[index] < row then
            target = anchors[index]
            break
          end
        end
      end

      if not target then return end
      row = target
    end

    api.nvim_win_set_cursor(win, { math.min(row, api.nvim_buf_line_count(buf)), 0 })
    vim.cmd("normal! zvzz")
  end

  vim.keymap.set("n", "]c", function() jump(1) end, {
    buffer = buf,
    desc = "Next unified diff hunk",
    silent = true,
  })
  vim.keymap.set("n", "[c", function() jump(-1) end, {
    buffer = buf,
    desc = "Previous unified diff hunk",
    silent = true,
  })
end

local function decorate(layout)
  local display = layout.b.file
  if not display or not display.bufnr or not api.nvim_buf_is_valid(display.bufnr) then return end

  local buf = display.bufnr
  local win = layout.b.id
  local old_lines = source_lines(layout.old_file)
  local new_lines = source_lines(layout.new_file)
  local display_lines = source_lines(display)
  local line_count = api.nvim_buf_line_count(buf)

  api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.fn.sign_unplace(sign_group, { buffer = buf })

  local hunks
  local anchors = {}
  if display.binary then
    api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
      virt_lines = {
        { { ("Binary file changed: %s"):format(display.path), "DiffText" } },
      },
      virt_lines_above = true,
      priority = 110,
      strict = false,
    })
    hunks = {}
  elseif layout.displaying_old then
    hunks = { { 1, #display_lines, 0, 0 } }
    for row = 1, line_count do
      api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
        line_hl_group = "DiffDelete",
        number_hl_group = "DiffDelete",
        hl_eol = true,
        priority = 100,
      })
      vim.fn.sign_place(0, sign_group, delete_sign, buf, {
        lnum = row,
        priority = 10,
      })
    end
    api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
      virt_lines = { { { hunk_header(hunks[1]), "DiffText" } } },
      virt_lines_above = true,
      priority = 110,
      strict = false,
    })
    anchors[1] = 1
  else
    hunks = diff_indices(old_lines, new_lines)
    for _, hunk in ipairs(hunks) do
      anchors[#anchors + 1] = set_virtual_hunk(buf, hunk, old_lines, line_count)
    end
  end

  if not layout.displaying_old and layout.context_lines ~= false then
    fold_unchanged(win, hunks, line_count, layout.context_lines)
  end
  map_hunk_navigation(buf, win, anchors)
  vim.b[buf].gitdiff_unified = true
  vim.b[buf].gitdiff_unified_hunks = anchors
end

local function load_layout_dependencies()
  local ok, deps = pcall(function()
    return {
      async = require("diffview.async"),
      Diff1 = require("diffview.scene.layouts.diff_1").Diff1,
      oop = require("diffview.oop"),
      Window = require("diffview.scene.window").Window,
    }
  end)

  if not ok then return nil, deps end
  return deps
end

local function build_layout(options)
  local deps, err = load_layout_dependencies()
  if not deps then return nil, err end

  local async = deps.async
  local await = async.await
  local UnifiedLayout = deps.oop.create_class("GitDiffUnifiedLayout", deps.Diff1)

  UnifiedLayout.name = "gitdiff_unified"

  function UnifiedLayout:init(opt)
    opt = opt or {}
    self:super({ b = opt.b })
    self.old_file = opt.a
    self.new_file = opt.b
    self.a = deps.Window({ file = self.old_file })
    self.a.parent = self
    if self.old_file then self.old_file.symbol = "a" end
    if self.new_file then self.new_file.symbol = "b" end
    self.displaying_old = self.new_file and self.new_file.nulled
      and self.old_file and not self.old_file.nulled
    self.generation = 0
    self.context_lines = UnifiedLayout.context_lines
    self.snapshot = UnifiedLayout.snapshot
    self.b:set_file(self.displaying_old and self.old_file or self.new_file)
  end

  function UnifiedLayout:clone()
    local clone = UnifiedLayout({
      a = self.old_file,
      b = self.new_file,
    })
    clone.b:set_id(self.b.id)
    return clone
  end

  function UnifiedLayout:files()
    if self.old_file == self.new_file then return { self.old_file } end
    return { self.old_file, self.new_file }
  end

  function UnifiedLayout:set_files(old_file, new_file)
    self.generation = self.generation + 1
    self.old_file = old_file
    self.new_file = new_file
    self.a:set_file(old_file)
    if old_file then old_file.symbol = "a" end
    if new_file then new_file.symbol = "b" end
    self.displaying_old = new_file and new_file.nulled and old_file and not old_file.nulled
    self.b:set_file(self.displaying_old and old_file or new_file)
  end

  function UnifiedLayout:detach_files()
    local file = self.b.file
    if file and file.bufnr and api.nvim_buf_is_valid(file.bufnr) then
      api.nvim_buf_clear_namespace(file.bufnr, namespace, 0, -1)
      vim.fn.sign_unplace(sign_group, { buffer = file.bufnr })
      pcall(api.nvim_buf_del_keymap, file.bufnr, "n", "]c")
      pcall(api.nvim_buf_del_keymap, file.bufnr, "n", "[c")
      vim.b[file.bufnr].gitdiff_unified = nil
      vim.b[file.bufnr].gitdiff_unified_hunks = nil
    end
    self.b:detach_file()
  end

  UnifiedLayout.use_entry = async.void(function(self, entry)
    local source = entry.layout
    self:set_files(source.old_file, source.new_file)
    if self:is_valid() then await(self:open_files()) end
  end)

  UnifiedLayout.open_files = async.void(function(self)
    if not self:is_valid() or not self.b.file then return end

    local generation = self.generation
    local display = self.b.file
    vim.cmd("diffoff!")
    local hidden = self.displaying_old and self.new_file or self.old_file
    if hidden and not hidden:is_valid() then
      await(hidden:create_buffer())
    end
    if self.generation ~= generation or self.b.file ~= display then return end

    if not display:is_valid() then
      await(display:create_buffer())
    end
    if display:is_valid()
        and not display.binary
        and display.rev.type == require("diffview.vcs.rev").RevType.LOCAL
    then
      vim.bo[display.bufnr].modifiable = false
      vim.bo[display.bufnr].readonly = true
      vim.bo[display.bufnr].buflisted = false
      if self.snapshot then self.snapshot:track_buffer(display.bufnr) end
    end

    await(async.scheduler())
    if not self:is_valid()
        or self.generation ~= generation
        or self.b.file ~= display
        or not display:is_valid()
    then
      return
    end

    local source_winopts = display.winopts or {}
    display.winopts = vim.tbl_extend("force", vim.deepcopy(source_winopts), {
      diff = false,
      scrollbind = false,
      cursorbind = false,
      foldmethod = "manual",
      foldenable = true,
      foldlevel = 0,
    })

    await(self.b:open_file())
    display.winopts = source_winopts
    if not self:is_valid()
        or self.generation ~= generation
        or self.b.file ~= display
    then
      return
    end
    decorate(self)
    self.emitter:emit("files_opened")
  end)

  function UnifiedLayout.should_null(rev, status, symbol)
    if symbol == "a" then return status == "A" or status == "?" end
    if symbol == "b" then return status == "D" end
    return true
  end

  return UnifiedLayout
end

local UnifiedLayout

local function entry_old_path(entry)
  if entry.oldpath and entry.oldpath ~= "" then return entry.oldpath end
  return entry.path
end

---@param files table
local function convert_files(files, options)
  for _, entry in files:iter() do
    if entry.layout.class ~= UnifiedLayout then
      local old_file = entry.layout.a and entry.layout.a.file
      local new_file = entry.layout.b and entry.layout.b.file
      if old_file and (entry.status == "A" or entry.status == "?") then
        old_file.nulled = true
      end
      if new_file and entry.status == "D" then new_file.nulled = true end

      if options.snapshot then
        local display
        if entry.status == "D" then
          local revision = old_file and old_file.rev and old_file.rev.commit
          local path = entry_old_path(entry)
          local ok, materialize_err = revision
            and options.snapshot:materialize(path, revision)
          if not ok then
            error("Failed to materialize deleted file: " .. tostring(materialize_err))
          end
          display = old_file
        else
          display = new_file
        end

        if display and not display.nulled then
          if display.binary == nil then
            local ok, binary = pcall(display.adapter.is_binary, display.adapter, display.path, display.rev)
            if ok then display.binary = binary end
          end

          local path = entry.status == "D" and entry_old_path(entry) or entry.path
          local absolute_path = options.snapshot.root .. "/" .. path
          local stat = (vim.uv or vim.loop).fs_stat(absolute_path)
          if stat and stat.type == "file" and stat.size == 0 then
            display.binary = false
          elseif stat and stat.type == "directory" then
            display.binary = true
          end

          display.rev = display.adapter.Rev(
            require("diffview.vcs.rev").RevType.LOCAL
          )
          display.absolute_path = absolute_path
          display.nulled = false
          display.winbar = " SNAPSHOT - " .. path
        end
      end

      entry:convert_layout(UnifiedLayout)
    end
  end
end

---@param view table
---@return boolean
---@return string? err
function M.prepare(view, options)
  options = options or {}
  if options.context_lines == nil then options.context_lines = 3 end
  if not UnifiedLayout then
    local err
    UnifiedLayout, err = build_layout(options)
    if not UnifiedLayout then return false, tostring(err) end
  end
  UnifiedLayout.context_lines = options.context_lines
  UnifiedLayout.snapshot = options.snapshot

  if type(view.get_updated_files) ~= "function" then
    return false, "Diffview does not expose get_updated_files"
  end

  vim.fn.sign_define(add_sign, {
    text = "+",
    texthl = "DiffAdd",
  })
  vim.fn.sign_define(delete_sign, {
    text = "-",
    texthl = "DiffDelete",
  })

  local async = require("diffview.async")
  local original = view.get_updated_files
  view.get_updated_files = async.wrap(function(self, callback)
    local err, files = async.await(original(self))
    async.await(async.scheduler())
    if options.snapshot and options.snapshot.closed then
      callback({ "Unified review was closed." }, files)
      return
    end
    if not err and files then convert_files(files, options) end
    callback(err, files)
  end)

  return true
end

return M
