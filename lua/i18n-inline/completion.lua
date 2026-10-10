-- Catalog-backed key completion for configured React Intl shapes.
--
-- candidates(buf, row, byte_col) -> { key, insert, detail, start_col, end_col }
-- (0-based row/byte_col; start_col/end_col = key content on that line, no quotes).
-- insert is the suffix for a bound formatter, else the full key.
--
-- Enabled only when cfg.patterns includes the matching shape:
--   formatMessage({ id }) / FormattedMessage id= / bound or aliased recv('...').
-- Unbound foo('...'), { key }/{ useGlobal } overrides, and unknown shapes -> {}.

local api = vim.api
local util = require('i18n-inline.util')
local scan = require('i18n-inline.scan')
local resolve = require('i18n-inline.resolve')

local M = {}

local function eligible(buf, cfg)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= '' then
    return false
  end
  if not vim.tbl_contains(cfg.filetypes, vim.bo[buf].filetype) then
    return false
  end
  local lines = api.nvim_buf_line_count(buf)
  if lines > 0 and api.nvim_buf_get_offset(buf, lines) > cfg.max_filesize then
    return false
  end
  return true
end

-- Which configured pattern shapes completion may recognize (not a compiler).
local function pattern_shapes(patterns)
  local shapes = {}
  for _, pat in ipairs(patterns or {}) do
    if pat:find('formatMessage', 1, true) and pat:find('id', 1, true) then
      shapes.format_message = true
    end
    if pat:find('FormattedMessage', 1, true) then
      shapes.jsx = true
    end
    if pat:find('([%w_.$]+)', 1, true) and pat:find('%(', 1, true) then
      shapes.call = true
    end
  end
  return shapes
end

-- 0-based col of closing quote (content end exclusive), or nil.
local function close_quote_col(line, open_col)
  local quote = line:sub(open_col + 1, open_col + 1)
  local i = open_col + 2
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' then
      i = i + 2
    elseif c == quote then
      return i - 1
    elseif c == '\n' then
      return nil
    else
      i = i + 1
    end
  end
  return nil
end

-- open_col, end_col (exclusive), typed-before-cursor; or nil.
local function key_string_at(line, byte_col)
  if byte_col < 0 or byte_col > #line then
    return nil
  end
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' or c == "'" or c == '`' then
      local open_col = i - 1
      local close_col = close_quote_col(line, open_col)
      if close_col then
        if byte_col > open_col and byte_col <= close_col then
          local typed = line:sub(open_col + 2, byte_col)
          return open_col, close_col, typed
        end
        i = close_col + 2
      else
        if byte_col > open_col then
          local typed = line:sub(open_col + 2, byte_col)
          return open_col, byte_col, typed
        end
        return nil
      end
    else
      i = i + 1
    end
  end
  return nil
end

local function line_commented(text, pos)
  local line_start = text:sub(1, pos):match('.*\n()') or 1
  local i = line_start
  while i < pos do
    local c = text:sub(i, i)
    if c == '"' or c == "'" or c == '`' then
      local _, _, str_e = scan.parse_string_literal(text, i)
      if not str_e then
        return false
      end
      i = str_e + 1
    elseif text:sub(i, i + 1) == '//' then
      return true
    else
      i = i + 1
    end
  end
  return false
end

-- kind 'full' | 'call' (+ receiver). quote_pos is 1-based in text.
local function key_context(text, quote_pos, shapes)
  local before = text:sub(1, quote_pos - 1)
  if shapes.format_message and before:match('[%w_.]*formatMessage%s*%(%s*{%s*id%s*:%s*$') then
    return { kind = 'full' }
  end
  if shapes.jsx and before:match('FormattedMessage%s+id%s*=%s*$') then
    return { kind = 'full' }
  end
  if shapes.call then
    local recv = before:match('([%w_.$]+)%s*%(%s*$')
    if recv then
      return { kind = 'call', receiver = recv }
    end
  end
  return nil
end

local function unsupported_override(text, after)
  local rest = text:sub(after)
  local obj = rest:match('^%s*,%s*(%b{})')
  if not obj then
    return false
  end
  if obj:find('[%s,{]key%s*:') then
    return true
  end
  if obj:find('[%s,{]useGlobal%s*:') then
    return true
  end
  return false
end

local function insert_for(key, ns, sep)
  if not ns then
    return key
  end
  local prefix = ns .. sep
  if key:sub(1, #prefix) ~= prefix or #key <= #prefix then
    return nil
  end
  return key:sub(#prefix + 1)
end

local function add_keys(out, seen, keys, ns, sep, typed)
  if not keys then
    return
  end
  for key, value in pairs(keys) do
    if not seen[key] then
      local insert = insert_for(key, ns, sep)
      if insert and (typed == '' or insert:sub(1, #typed) == typed) then
        seen[key] = true
        out[#out + 1] = {
          key = key,
          insert = insert,
          detail = type(value) == 'string' and value or nil,
        }
      end
    end
  end
end

local function collect(view, cfg, ns, typed)
  local sep = cfg.separator or '.'
  local preview = cfg.preview_lang
  local source = cfg.source_lang
  if source == preview then
    source = nil
  end
  local seen, out = {}, {}
  for _, catalog in ipairs(view.catalogs) do
    add_keys(out, seen, resolve.keys(view, catalog, preview), ns, sep, typed)
  end
  if source then
    for _, catalog in ipairs(view.catalogs) do
      add_keys(out, seen, resolve.keys(view, catalog, source), ns, sep, typed)
    end
  end
  table.sort(out, function(a, b)
    if a.insert == b.insert then
      return a.key < b.key
    end
    return a.insert < b.insert
  end)
  return out
end

--- @param buf integer
--- @param row integer 0-based
--- @param byte_col integer 0-based byte column
--- @return table[]
function M.candidates(buf, row, byte_col)
  local project = resolve.project_for(buf)
  if not project then
    return {}
  end
  local cfg = project.cfg
  if not eligible(buf, cfg) then
    return {}
  end
  local shapes = pattern_shapes(cfg.patterns)
  if not (shapes.format_message or shapes.jsx or shapes.call) then
    return {}
  end

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if row < 0 or row >= #lines then
    return {}
  end
  local line = lines[row + 1]
  local open_col, end_col, typed = key_string_at(line, byte_col)
  if not open_col then
    return {}
  end

  local text = table.concat(lines, '\n')
  local offsets = util.build_line_offsets(text)
  local quote_pos = offsets[row + 1] + open_col
  if line_commented(text, quote_pos) then
    return {}
  end

  local ctx = key_context(text, quote_pos, shapes)
  if not ctx then
    return {}
  end

  local close_on_line = close_quote_col(line, open_col)
  local after = close_on_line and (offsets[row + 1] + close_on_line + 1) or (offsets[row + 1] + byte_col)
  if unsupported_override(text, after) then
    return {}
  end

  -- nil = full-key insert (direct id, JSX, alias, or root binding)
  local ns = nil
  if ctx.kind == 'call' then
    local bindings = scan.extract_bindings(text, cfg.namespace_patterns)
    local aliases = cfg.aliases and util.set(cfg.aliases)
    local probe = scan.resolve_key(ctx.receiver, '_', bindings, aliases, cfg.separator or '.')
    if not probe then
      return {}
    end
    local bound = bindings[ctx.receiver]
    if bound and bound ~= '' then
      ns = bound
    end
  end

  local view = resolve.view(project, resolve.buf_path(buf))
  local items = collect(view, cfg, ns, typed)
  local start_col = open_col + 1
  for _, item in ipairs(items) do
    item.start_col = start_col
    item.end_col = end_col
  end
  return items, { typed = typed, namespace = ns }
end

return M
