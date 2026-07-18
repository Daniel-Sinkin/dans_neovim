-- View-only: render dans::logic predicate calls as their logical-operator form.
--   dans::logic::implies(P, Q)  ->  (P) => (Q)
-- The callee and the argument-list punctuation (the parens + the separating
-- comma) are concealed and re-shown as the infix operator; the two arguments are
-- kept verbatim, so they keep their normal frontend rendering -- and a nested
-- implies renders too, since treesitter sees each call. dans:: is hidden by
-- markers anyway, and this conceals the whole callee, so it doesn't matter
-- whether it's written dans::logic::implies or logic::implies. Treesitter-scoped
-- to a two-argument call, so a comma inside P or Q (a nested call's own args) is
-- never mistaken for the separator. Skips shared reveal and overlay-covered
-- rows (the shared skipper), like the other raw-line view modules.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_logic'
local vu = require 'custom.dans_frontend_cpp.util'

local CALL_QUERY = [[(call_expression) @call]]

-- dans::logic predicate -> the infix operator shown between its parenthesized
-- arguments. Keyed on the full callee text, with and without the dans:: prefix
-- (either spelling can appear; the prefix is concealed regardless).
local INFIX = {
  ['dans::logic::implies'] = '=>',
  ['logic::implies'] = '=>',
}

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vu.is_cpp(vim.bo[bufnr].filetype) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'logic') then
    return
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return
  end
  local okq, q = pcall(vim.treesitter.query.parse, parser:lang(), CALL_QUERY)
  if not okq or not q then
    return
  end

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)

  local function mark(row, s_col, e_col, text, hl)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, s_col, {
      end_col = e_col,
      conceal = '',
      virt_text = { { text, hl } },
      virt_text_pos = 'inline',
    })
  end

  -- Whether `node` sits inside an assert(...) / static_assert(...) call. markers
  -- grays that whole statement (DansAssert); the inserted operator is grayed to
  -- match, so it doesn't stand out in Normal against the grayed condition.
  local function in_assert(node)
    local n = node:parent()
    while n do
      if n:type() == 'call_expression' then
        local f = n:field('function')[1]
        local t = f and vim.treesitter.get_node_text(f, bufnr)
        if t == 'assert' or t == 'static_assert' then
          return true
        end
      end
      n = n:parent()
    end
    return false
  end

  for _, call in q:iter_captures(trees[1]:root(), bufnr, s0, e0) do
    local fn = call:field('function')[1]
    local args = call:field('arguments')[1]
    if fn and args and args:type() == 'argument_list' and args:named_child_count() == 2 then
      local op = INFIX[vim.treesitter.get_node_text(fn, bufnr)]
      local cr, _, cer = call:range()
      if op and cr == cer and not skip.skip(cr) then
        -- single-line calls only; a multi-line implies stays raw.
        local a, b = args:named_child(0), args:named_child(1)
        local _, fc = fn:range()
        local _, asc, _, aec = a:range()
        local _, bsc, _, bec = b:range()
        local _, _, _, gec = args:range()
        local hl = in_assert(call) and 'DansAssert' or 'Normal'
        mark(cr, fc, asc, '(', hl) -- callee + `(`  ->  `(`
        mark(cr, aec, bsc, ') ' .. op .. ' (', hl) -- the top-level `, `  ->  `) => (`
        mark(cr, bec, gec, ')', hl) -- the closing `)`  ->  `)`
      end
    end
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_logic', { clear = true })
  vu.on_decorate(group, { 'FileType', 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, refresh)
end

return M
