-- First-party C/C++/CUDA authoring engine.
--
-- This module is deliberately the only owner of authoring-session behavior:
-- structured templates, the `$` type language, live suggestions, include
-- insertion, and placeholder navigation all enter through this API.  It uses
-- Neovim's built-in LSP-snippet primitive for tabstop tracking; there is no
-- plugin-owned snippet state and no second catalog to reconcile.
--
-- Structured templates expand explicitly on Space (`$class0 `, `$forx `) or
-- Tab.  Type expressions use the same gesture (`$?$Foo `).  Unknown/partial
-- input is preserved: authoring assistance is never allowed to delete source
-- text just because a token failed to parse.

local M = {}
local types = require 'custom.cpp_type_snippets'

local CPP_FT = { c = true, cpp = true, cuda = true }
local preview_ns = vim.api.nvim_create_namespace 'ds_cpp_authoring_preview'

local function class_name()
  return types.enclosing_class_name()
end

local function rule_body(five)
  local name = class_name() or 'T'
  local lines = {
    name .. '(const ' .. name .. '&) = default;',
    'def operator=(const ' .. name .. '&) -> ' .. name .. '& = default;',
  }
  if five then
    lines[#lines + 1] = name .. '(' .. name .. '&&) noexcept = default;'
    lines[#lines + 1] = 'def operator=(' .. name .. '&&) noexcept -> ' .. name .. '& = default;'
  end
  lines[#lines + 1] = '~' .. name .. '() = default;'
  return table.concat(lines, '\n')
end

-- Bodies use the standard LSP snippet grammar consumed by vim.snippet.expand.
-- The old dsk_* names remain aliases so existing muscle memory does not break,
-- but the discoverable spelling is the single `$name` language.
local CATALOG = {
  {
    trigger = '//',
    aliases = { 'dsk_comment' },
    description = 'block comment',
    body = '/* ${0} */',
    filetypes = { c = true, cpp = true, cuda = true, lua = true, python = true },
  },
  {
    trigger = 'class0',
    aliases = { 'dsk_class0' },
    description = 'rule-of-zero class',
    body = 'class ${1:MyClass}\n{\npublic:\n    $0\n};',
  },
  {
    trigger = 'class3',
    aliases = { 'dsk_class3' },
    description = 'copyable rule-of-three class',
    body = table.concat({
      'class ${1:MyClass}',
      '{',
      'public:',
      '    $1() = default;',
      '    ~$1() = default;',
      '    $1(const $1&) = default;',
      '    def operator=(const $1&) -> $1& = default;',
      '',
      'private:',
      '    $0',
      '};',
    }, '\n'),
  },
  {
    trigger = 'class5',
    aliases = { 'dsk_class5' },
    description = 'copyable/movable rule-of-five class',
    body = table.concat({
      'class ${1:MyClass}',
      '{',
      'public:',
      '    $1() = default;',
      '    ~$1() = default;',
      '    $1(const $1&) = default;',
      '    def operator=(const $1&) -> $1& = default;',
      '    $1($1&&) noexcept = default;',
      '    def operator=($1&&) noexcept -> $1& = default;',
      '',
      'private:',
      '    $0',
      '};',
    }, '\n'),
  },
  {
    trigger = 'rule3',
    aliases = { 'dsk_rule3' },
    description = 'special members for enclosing class',
    condition = function()
      return class_name() ~= nil
    end,
    body = function()
      return rule_body(false)
    end,
  },
  {
    trigger = 'rule5',
    aliases = { 'dsk_rule5' },
    description = 'special members for enclosing class',
    condition = function()
      return class_name() ~= nil
    end,
    body = function()
      return rule_body(true)
    end,
  },
  {
    trigger = 'irange',
    aliases = { 'dsk_irange' },
    description = 'indexed range loop (i)',
    body = 'for (usize ${1:i}{0zu}; $1 < ${2:container}.size(); ++$1)\n{\n    $0\n}',
  },
  {
    trigger = 'jrange',
    aliases = { 'dsk_jrange' },
    description = 'indexed range loop (j)',
    body = 'for (usize ${1:j}{0zu}; $1 < ${2:container}.size(); ++$1)\n{\n    $0\n}',
  },
  {
    trigger = 'krange',
    aliases = { 'dsk_krange' },
    description = 'indexed range loop (k)',
    body = 'for (usize ${1:k}{0zu}; $1 < ${2:container}.size(); ++$1)\n{\n    $0\n}',
  },
  {
    trigger = 'forx',
    aliases = { 'dsk_forx' },
    description = 'range loop by mutable reference',
    body = 'for (auto& ${1:value} : ${2:container})\n{\n    $0\n}',
  },
  {
    trigger = 'println',
    aliases = { 'dsk_println' },
    description = 'std::println value',
    body = 'std::println("{}", ${1:value});$0',
  },
  {
    trigger = 'printx',
    aliases = { 'dsk_printx' },
    description = 'std::println named value',
    body = 'std::println("${1:value}={}", $1);$0',
  },
  {
    trigger = 'vec5i',
    aliases = { 'dsk_vec5i' },
    description = 'five-element int vector',
    body = 'std::vector<int> ${1:values}{${2:a}, ${3:b}, ${4:c}, ${5:d}, ${6:e}};$0',
  },
  {
    trigger = 'cuda',
    aliases = { 'dsk_cudalaunch' },
    description = 'CUDA kernel launch',
    body = '${1:kernel}<<<${2:grid}, ${3:block}, ${4:0}, ${5:stream}>>>(${0:args});',
  },
}

M.CATALOG = CATALOG

local by_trigger, by_alias = {}, {}
for _, item in ipairs(CATALOG) do
  by_trigger[item.trigger] = item
  for _, alias in ipairs(item.aliases or {}) do
    by_alias[alias] = item
  end
end

local function allowed(item)
  if item.filetypes and not item.filetypes[vim.bo.filetype] then
    return false
  end
  if not item.filetypes and not CPP_FT[vim.bo.filetype] then
    return false
  end
  return not item.condition or item.condition()
end

local function body_for(item)
  return type(item.body) == 'function' and item.body() or item.body
end

local function structured_block(line, col)
  local before = line:sub(1, col)
  local block = before:match '(%$//)$' or before:match '(%$[%w_]+)$'
  if not block then
    return nil
  end
  return { text = block, head = block:sub(2), bs = col - #block }
end

local function alias_block(line, col)
  local before = line:sub(1, col)
  local block = before:match '([%a_][%w_]*)$'
  if block and by_alias[block] then
    return { text = block, item = by_alias[block], bs = col - #block }
  end
  return nil
end

local function insert_plain_space(row0, col0)
  vim.api.nvim_buf_set_text(0, row0, col0, row0, col0, { ' ' })
  vim.api.nvim_win_set_cursor(0, { row0 + 1, col0 + 1 })
end

local function replace_range(row0, start_col, end_col, text)
  vim.api.nvim_buf_set_text(0, row0, start_col, row0, end_col, { text })
  vim.api.nvim_win_set_cursor(0, { row0 + 1, start_col + #text })
end

local function expand_item(item, row0, start_col, end_col)
  if not item or not allowed(item) then
    return false
  end
  local body = body_for(item)
  if not body then
    return false
  end
  vim.api.nvim_buf_set_text(0, row0, start_col, row0, end_col, { '' })
  vim.api.nvim_win_set_cursor(0, { row0 + 1, start_col })
  pcall(vim.cmd, 'undojoin')
  vim.snippet.expand(body)
  return true
end

local function apply_type_resolution(resolution, row0, col0, trailing_space)
  if not resolution or resolution.action ~= 'expand' then
    return false
  end
  local suffix = trailing_space and ' ' or ''
  local replacement = resolution.text .. suffix
  vim.api.nvim_buf_set_text(0, row0, resolution.bs, row0, col0, { replacement })
  local cursor_row = row0 + 1
  local cursor_col = resolution.bs + #replacement
  pcall(vim.cmd, 'undojoin')
  local inserted_at, count = types.add_std_includes(0, resolution.text)
  if inserted_at and inserted_at <= row0 then
    cursor_row = cursor_row + count
  end
  vim.api.nvim_win_set_cursor(0, { cursor_row, cursor_col })
  return true
end

local function on_space()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row0, col0 = pos[1] - 1, pos[2]
  local line = vim.api.nvim_get_current_line()
  local block = structured_block(line, col0)
  if block and not types.protected_at(0, row0, block.bs) then
    local item = by_trigger[block.head]
    if item and expand_item(item, row0, block.bs, col0) then
      return
    end
  end
  if not types.protected_at(0, row0, math.max(0, col0 - 1)) then
    local resolution = types.resolve(line, col0, class_name)
    if apply_type_resolution(resolution, row0, col0, true) then
      return
    end
  end
  insert_plain_space(row0, col0)
end

local function structured_candidates(partial)
  local out = {}
  for _, item in ipairs(CATALOG) do
    if item.trigger:sub(1, #partial) == partial and allowed(item) then
      out[#out + 1] = item
    end
  end
  table.sort(out, function(a, b)
    return a.trigger < b.trigger
  end)
  return out
end

-- Public completion state: nvim-cmp asks this instead of duplicating the `$`
-- grammar.  This keeps popup suppression and the actual expander on one parser.
function M.completion_active()
  if not CPP_FT[vim.bo.filetype] then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  return structured_block(line, pos[2]) ~= nil or types.block_at(line, pos[2]) ~= nil
end

-- Tab is the only navigation API nvim-cmp needs.  Exact templates and complete
-- `$` expressions expand; a partial head chooses the first displayed candidate
-- deterministically; otherwise the caller should perform normal Tab behavior.
function M.tab(direction)
  direction = direction or 1
  if vim.snippet.active { direction = direction } then
    vim.snippet.jump(direction)
    return true
  end
  if direction < 0 or not CPP_FT[vim.bo.filetype] then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local row0, col0 = pos[1] - 1, pos[2]
  local line = vim.api.nvim_get_current_line()
  local alias = alias_block(line, col0)
  if alias and expand_item(alias.item, row0, alias.bs, col0) then
    return true
  end
  local structured = structured_block(line, col0)
  if structured and not types.protected_at(0, row0, structured.bs) then
    local exact = by_trigger[structured.head]
    if exact and expand_item(exact, row0, structured.bs, col0) then
      return true
    end
  end
  if not types.protected_at(0, row0, math.max(0, col0 - 1)) then
    local resolution = types.resolve(line, col0, class_name)
    if apply_type_resolution(resolution, row0, col0, false) then
      return true
    end
  end
  -- Only the simple `$partial` form is head-completed.  Completing inside a
  -- nested type expression would require guessing which operand the user means.
  if structured then
    local candidates, seen = {}, {}
    for _, item in ipairs(structured_candidates(structured.head)) do
      candidates[#candidates + 1], seen[item.trigger] = item.trigger, true
    end
    for _, head in ipairs(types.head_candidates(structured.head)) do
      if not seen[head] then
        candidates[#candidates + 1] = head
      end
    end
    table.sort(candidates)
    if #candidates >= 1 then
      replace_range(row0, structured.bs, col0, '$' .. candidates[1])
      return true
    end
  end
  return false
end

local function clear_preview(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
  end
end

local function preview_chunks(line, col0)
  local structured = structured_block(line, col0)
  if structured then
    local exact = by_trigger[structured.head]
    if exact and allowed(exact) then
      return {
        { '  [template] ', 'Comment' },
        { '$' .. exact.trigger, 'DansLambda' },
        { '  ' .. exact.description, 'DansInlayType' },
      }
    end
    local names, seen = {}, {}
    for _, item in ipairs(structured_candidates(structured.head)) do
      names[#names + 1], seen[item.trigger] = { item.trigger, item.description }, true
    end
    for _, head in ipairs(types.head_candidates(structured.head)) do
      if not seen[head] then
        names[#names + 1] = { head, 'type expression' }
      end
    end
    table.sort(names, function(a, b)
      return a[1] < b[1]
    end)
    if #names > 0 then
      local chunks = { { '  $ ', 'Comment' } }
      for i = 1, math.min(#names, 6) do
        if i > 1 then
          chunks[#chunks + 1] = { '  ', 'Comment' }
        end
        chunks[#chunks + 1] = { names[i][1], 'DansLambda' }
        chunks[#chunks + 1] = { ':' .. names[i][2], 'Comment' }
      end
      return chunks
    end
  end
  local preview = types.preview(line, col0, class_name)
  if not preview then
    return nil
  end
  if preview.candidates then
    local chunks = { { '  $ ', 'Comment' } }
    for index, candidate in ipairs(preview.candidates) do
      if index > 1 then
        chunks[#chunks + 1] = { '  ', 'Comment' }
      end
      chunks[#chunks + 1] = { candidate.head, 'DansLambda' }
      chunks[#chunks + 1] = { ':' .. candidate.name, 'Comment' }
    end
    return chunks
  end
  return {
    { '  [', 'Comment' },
    { preview.name, 'DansLambda' },
    { '] ', 'Comment' },
    { preview.text, 'DansInlayType' },
  }
end

function M.refresh_preview()
  local bufnr = vim.api.nvim_get_current_buf()
  clear_preview(bufnr)
  if not CPP_FT[vim.bo[bufnr].filetype] or vim.api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  if types.protected_at(bufnr, pos[1] - 1, math.max(0, pos[2] - 1)) then
    return
  end
  local chunks = preview_chunks(line, pos[2])
  if chunks then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, preview_ns, pos[1] - 1, 0, {
      virt_text = chunks,
      virt_text_pos = 'eol',
    })
  end
end

function M.expand_trigger(trigger)
  local item = by_trigger[trigger] or by_alias[trigger]
  if not item then
    return false, 'unknown template: ' .. tostring(trigger)
  end
  if not allowed(item) then
    return false, 'template is not valid in this context: ' .. tostring(trigger)
  end
  vim.snippet.expand(body_for(item))
  return true
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_authoring', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(event)
      for _, lhs in ipairs { '<Space>', '<S-Space>' } do
        vim.keymap.set('i', lhs, on_space, {
          buffer = event.buf,
          desc = 'Expand C++ authoring expression or insert Space',
        })
      end
      -- These are fallbacks for a minimal/no-cmp startup.  nvim-cmp calls the
      -- same M.tab API from its own mappings when it is loaded.
      vim.keymap.set({ 'i', 's' }, '<Tab>', function()
        if M.tab(1) then
          return
        end
        vim.api.nvim_feedkeys(vim.keycode '<Tab>', 'n', false)
      end, { buffer = event.buf, silent = true, desc = 'Next authoring field or expand template' })
      vim.keymap.set({ 'i', 's' }, '<S-Tab>', function()
        if M.tab(-1) then
          return
        end
        vim.api.nvim_feedkeys(vim.keycode '<S-Tab>', 'n', false)
      end, { buffer = event.buf, silent = true, desc = 'Previous authoring field' })
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'CursorMovedI' }, {
    group = group,
    callback = M.refresh_preview,
  })
  vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
    group = group,
    callback = function(event)
      clear_preview(event.buf)
    end,
  })
  vim.api.nvim_create_user_command('DansSnippet', function(options)
    local ok, err = M.expand_trigger(options.args)
    if not ok then
      vim.notify('DansSnippet: ' .. err, vim.log.levels.WARN)
    end
  end, {
    nargs = 1,
    complete = function(prefix)
      local out = {}
      for _, item in ipairs(CATALOG) do
        if item.trigger:sub(1, #prefix) == prefix then
          out[#out + 1] = item.trigger
        end
      end
      return out
    end,
    desc = 'Expand a first-party C++ authoring template',
  })
  vim.api.nvim_create_user_command('DansCppFormat', function()
    types.format()
  end, { desc = 'Format the C++ file to the dans layout (path line + StdLib group)' })
end

return M
