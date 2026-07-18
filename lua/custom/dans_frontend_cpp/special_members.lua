-- View-only: collapse a class's copy/move special-member declarations to a short
-- generic name, so you read intent instead of boilerplate. X is the enclosing
-- class. The default constructor `X()` and destructor `~X()` are deliberately
-- left as written -- they often carry real init/teardown, and the class name
-- reads clearer than a generic token (the copy/move members are the real
-- ceremony worth hiding).
--   X(const X&)                                  -> $copy
--   X(X&&)                                       -> $move
--   X& operator=(const X&) / def ... -> X&       -> $copya
--   X& operator=(X&&)      / def ... -> X&       -> $movea
-- Only the signature is concealed; the `= default` / `= delete` / `{ body }` /
-- `;` / `noexcept` tail stays. Conceal + inline virt_text, source untouched;
-- shared reveal rows are raw (skipper), like the other view modules. The inverse
-- ($copy -> signature) is the space expander.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_special_members'
local vu = require 'custom.dans_frontend_cpp.util'

local BODY_QUERY = [[(field_declaration_list) @body]]

-- Signature forms for class `x` (patterns over the post-indent code) -> role.
-- The default ctor `X()` / dtor `~X()` are intentionally absent (left raw). Both
-- operator= spellings are matched (leading return `X& operator=` and trailing
-- `def/auto operator= ... -> X&`).
local function forms_for(x)
  local q = vim.pesc(x)
  return {
    { 'copy', '^' .. q .. '%s*%(%s*const%s+' .. q .. '%s*&%s*%)' },
    { 'move', '^' .. q .. '%s*%(%s*' .. q .. '%s*&&%s*%)' },
    { 'copya', '^' .. q .. '%s*&%s*operator%s*=%s*%(%s*const%s+' .. q .. '%s*&%s*%)' },
    { 'copya', '^%a[%w_]*%s+operator%s*=%s*%(%s*const%s+' .. q .. '%s*&%s*%)%s*%->%s*' .. q .. '%s*&' },
    { 'movea', '^' .. q .. '%s*&%s*operator%s*=%s*%(%s*' .. q .. '%s*&&%s*%)' },
    { 'movea', '^%a[%w_]*%s+operator%s*=%s*%(%s*' .. q .. '%s*&&%s*%)%s*%->%s*' .. q .. '%s*&' },
  }
end

-- Per-buffer cache of which rows this module collapses (so arrow_align and the
-- like can defer), keyed on changedtick.
local cover_cache = {}

local function compute(bufnr)
  local rows = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return rows
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return rows
  end
  local okq, q = pcall(vim.treesitter.query.parse, parser:lang(), BODY_QUERY)
  if not okq or not q then
    return rows
  end
  for _, body in q:iter_captures(trees[1]:root(), bufnr, 0, -1) do
    local cls = body:parent()
    if cls and (cls:type() == 'class_specifier' or cls:type() == 'struct_specifier') then
      local nmnode = cls:field('name')[1]
      if nmnode and nmnode:type() == 'type_identifier' then
        local forms = forms_for(vim.treesitter.get_node_text(nmnode, bufnr))
        local bsr, _, ber = body:range()
        local lines = vim.api.nvim_buf_get_lines(bufnr, bsr, ber + 1, false)
        for k, line in ipairs(lines) do
          local indent = #(line:match '^%s*')
          local code = line:sub(indent + 1)
          for _, form in ipairs(forms) do
            local _, mend = code:find(form[2])
            if mend then
              rows[bsr + k - 1] = { col = indent, len = mend, role = form[1] }
              break
            end
          end
        end
      end
    end
  end
  return rows
end

-- Cached row map for `bufnr`. arrow_align consults this to leave our lines alone.
function M.rows(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cover_cache[bufnr]
  if not c or c.tick ~= tick then
    c = { tick = tick, rows = compute(bufnr) }
    cover_cache[bufnr] = c
  end
  return c.rows
end

function M.covers(bufnr, row0)
  return M.rows(bufnr)[row0] ~= nil
end

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
  if not vu.module_enabled(bufnr, 'special_members') then
    return
  end

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  for row, info in pairs(M.rows(bufnr)) do
    if row >= s0 and row < e0 and not skip.skip(row) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, info.col, {
        end_col = info.col + info.len,
        conceal = '',
        virt_text = { { '$' .. info.role, 'DansSpecialMember' } },
        virt_text_pos = 'inline',
      })
    end
  end
end

M.refresh = refresh

function M.setup()
  require('custom.dans_frontend_cpp.highlights').apply()
  local group = vim.api.nvim_create_augroup('ds_cpp_special_members', { clear = true })
  vu.on_decorate(group, { 'FileType', 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, refresh)
end

return M
