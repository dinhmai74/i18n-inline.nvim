-- Optional blink.cmp source. User-registers via sources.providers; no blink require at load.
--
--   providers = {
--     i18n_inline = { name = 'i18n-inline', module = 'i18n-inline.blink' },
--   }
--
-- Prefer this *or* the opt-in LSP client, not both (duplicate suggestions).

local completion = require('i18n-inline.completion')

local source = {}

function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  return self
end

function source:get_trigger_characters()
  return { '"', "'", '.', '_' }
end

--- @param ctx blink.cmp.Context
--- @param callback fun(response?: blink.cmp.CompletionResponse)
--- @return fun()|nil cancel
function source:get_completions(ctx, callback)
  local done = false
  local function respond(response)
    if done then
      return
    end
    done = true
    callback(response)
  end

  -- ctx.cursor: (1,0)-indexed like nvim_win_get_cursor; character is utf-8 bytes.
  local row = ctx.cursor[1] - 1
  local col = ctx.cursor[2]
  local candidates = completion.candidates(ctx.bufnr, row, col)

  local items = {}
  for _, candidate in ipairs(candidates) do
    items[#items + 1] = {
      label = candidate.insert,
      kind = vim.lsp.protocol.CompletionItemKind.Text,
      detail = candidate.detail,
      filterText = candidate.insert,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      textEdit = {
        newText = candidate.insert,
        range = {
          start = { line = row, character = candidate.start_col },
          ['end'] = { line = row, character = candidate.end_col },
        },
      },
    }
  end

  respond({
    is_incomplete_forward = false,
    is_incomplete_backward = true,
    items = items,
  })

  return function()
    done = true
  end
end

return source
