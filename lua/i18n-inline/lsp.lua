local api = vim.api
local resolve = require('i18n-inline.resolve')
local completion = require('i18n-inline.completion')

local M = {}
local name = 'i18n-inline'

local function utf16_col(line, byte_col)
  if vim.fn.has('nvim-0.11') == 1 then
    return vim.str_utfindex(line, 'utf-16', byte_col)
  end
  local _, col = vim.str_utfindex(line, byte_col)
  return col
end

local function byte_col(line, utf16)
  if vim.fn.has('nvim-0.11') == 1 then
    return vim.str_byteindex(line, 'utf-16', utf16)
  end
  return vim.str_byteindex(line, utf16, true)
end

local function complete(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  if not api.nvim_buf_is_loaded(bufnr) then
    return { isIncomplete = false, items = {} }
  end
  local row = params.position.line
  local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return { isIncomplete = false, items = {} }
  end
  local col = byte_col(line, params.position.character)
  local candidates, context = completion.candidates(bufnr, row, col)
  if context and context.typed == '' and not context.namespace then
    return { isIncomplete = true, items = {} }
  end
  local items = {}
  for _, candidate in ipairs(candidates) do
    items[#items + 1] = {
      label = candidate.insert,
      kind = vim.lsp.protocol.CompletionItemKind.Text,
      detail = candidate.detail,
      textEdit = {
        newText = candidate.insert,
        range = {
          start = { line = row, character = utf16_col(line, candidate.start_col) },
          ['end'] = { line = row, character = utf16_col(line, candidate.end_col) },
        },
      },
    }
  end
  return { isIncomplete = context ~= nil, items = items }
end

local function cmd(dispatchers)
  local closing, request_id = false, 0
  local function close()
    if closing then
      return
    end
    closing = true
    dispatchers.on_exit(0, 15)
  end
  return {
    request = function(method, params, callback, notify_reply_callback)
      request_id = request_id + 1
      local id = request_id
      vim.schedule(function()
        if method == 'initialize' then
          callback(nil, { capabilities = { completionProvider = {} } }, id)
        elseif method == 'textDocument/completion' then
          callback(nil, complete(params), id)
        else
          callback(nil, nil, id)
        end
        if notify_reply_callback then
          notify_reply_callback(id)
        end
      end)
      return true, id
    end,
    notify = function(method)
      if method == 'exit' then
        close()
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = close,
  }
end

function M.stop()
  for _, client in ipairs(vim.lsp.get_clients({ name = name, _uninitialized = true })) do
    client:stop(true)
  end
end

function M.start(buf)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return
  end
  local project = resolve.project_for(buf)
  if not project or not vim.tbl_contains(project.cfg.filetypes, vim.bo[buf].filetype) then
    return
  end
  vim.lsp.start({ name = name, cmd = cmd, root_dir = project.root, offset_encoding = 'utf-16' }, {
    bufnr = buf,
    reuse_client = function(client, config)
      return client.name == config.name and client.root_dir == config.root_dir and not client:is_stopped()
    end,
  })
end

return M
