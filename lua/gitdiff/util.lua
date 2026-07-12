local M = {}

local function notify(message, level)
  vim.notify(message, level, { title = "GitDiff" })
end

function M.info(message)
  notify(message, vim.log.levels.INFO)
end

function M.warn(message)
  notify(message, vim.log.levels.WARN)
end

function M.err(message)
  notify(message, vim.log.levels.ERROR)
end

function M.log(message)
  local ok, logger = pcall(require, "diffview.logger")
  if ok and logger and logger.s_error then
    logger.s_error("[GitDiff] " .. tostring(message))
  end
end

return M
