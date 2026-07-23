local function send(message)
  local payload = vim.json.encode(message)
  io.stdout:write(("Content-Length: %d\r\n\r\n%s"):format(#payload, payload))
  io.stdout:flush()
end

while true do
  local content_length
  while true do
    local line = io.stdin:read("*l")
    if not line then vim.cmd("qa!") end
    line = line:gsub("\r$", "")
    if line == "" then break end
    content_length = tonumber(line:match("^Content%-Length:%s*(%d+)$")) or content_length
  end

  if not content_length then vim.cmd("qa!") end
  local message = vim.json.decode(io.stdin:read(content_length))

  if message.method == "initialize" then
    send({
      jsonrpc = "2.0",
      id = message.id,
      result = {
        capabilities = {
          textDocumentSync = 1,
          hoverProvider = true,
        },
        serverInfo = {
          name = "gitdiff-test-lsp",
          version = "1",
        },
      },
    })
  elseif message.method == "shutdown" then
    send({
      jsonrpc = "2.0",
      id = message.id,
      result = vim.NIL,
    })
  elseif message.method == "exit" then
    vim.cmd("qa!")
  elseif message.id then
    send({
      jsonrpc = "2.0",
      id = message.id,
      result = vim.NIL,
    })
  end
end
