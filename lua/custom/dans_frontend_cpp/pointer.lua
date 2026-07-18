-- Treesitter-driven C/C++ type decorations (off shared reveal rows):
--
--   1. pointer-type `*` -> `^` (Pascal/Odin style). Only the `*` of a pointer
--      *declarator* is rewritten, so multiplication (`a * b`) and dereference
--      (`*p`) keep their `*`. The `*` is concealed and `^` shown as grayed
--      (DansPointer) inline virt_text (width-neutral).
--   2. a leading `const` is concealed on a *value* declaration (const is the
--      hidden default) but kept on a *pointer/reference* one, where the
--      const-vs-mut distinction is meaningful.
--   3. Semantic standard wrappers use the shared recursive type grammar:
--      optional/expected, unique/shared/weak pointers, arrays, and compositions
--      inside ordinary containers all match declaration/parameter rendering.
--
-- All three skip variable-declaration lines that view overlays (it renders
-- these itself), so this mainly covers function signatures and other raw decls.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_pointer'
local vu = require 'custom.dans_frontend_cpp.util'
local P = require 'custom.dans_frontend_cpp.parse'

local PTR_QUERY = [[
  (pointer_declarator "*" @star)
  (abstract_pointer_declarator "*" @star)
]]

local CONST_QUERY = [[
  (declaration (type_qualifier) @const)
  (field_declaration (type_qualifier) @const)
]]

-- Every `Foo<...>`; the shared grammar decides whether the displayed type has a
-- semantic transformation.
local SEMANTIC_TYPE_QUERY = [[
  (template_type) @tt
]]

-- Whether byte column col0 (0-based) sits inside a "..." string or after a //
-- comment, so the CString rewrite stays out of non-code text. Naive (ignores
-- raw strings, escaped quotes, char literals), but enough for a raw-line scan;
-- mirrors aliases.lua's helper of the same name.
local function in_string_or_comment(line, col0)
  local cstart = line:find('//', 1, true)
  if cstart and col0 >= cstart - 1 then
    return true
  end
  local i = 1
  while true do
    local s = line:find('"', i)
    if not s then
      return false
    end
    local e = line:find('"', s + 1)
    if not e then
      return false
    end
    if col0 >= s - 1 and col0 < e then
      return true
    end
    i = e + 1
  end
end

-- Whether a declaration declares a pointer or reference (so a leading const
-- qualifies a pointee/referent and should stay visible).
local function declares_ptr_ref(decl)
  for child in decl:iter_children() do
    local t = child:type()
    if t == 'pointer_declarator' or t == 'reference_declarator' then
      return true
    end
    if t == 'init_declarator' then
      for c in child:iter_children() do
        local ct = c:type()
        if ct == 'pointer_declarator' or ct == 'reference_declarator' then
          return true
        end
      end
    end
  end
  return false
end

-- Whether `node` (a `*`/`&`, or a node sitting on one) is the leading `*`/`&` of a
-- C-style function RETURN type -- `int* foo()`, `const char* baz()` -- with no
-- trailing `->`. aliases.lua moves that whole return type to a trailing `-> T`
-- (sugaring `*`->`^` / const char* -> CString itself), so the pointer pass here
-- leaves it alone; otherwise both render it and the `^`/CString lands inside the
-- concealed lead. A pointer/ref PARAMETER is not a return, so it stays handled.
local function is_cstyle_return(node)
  if not node then
    return false
  end
  -- the CString scan's get_node lands on the pointer_declarator itself; the
  -- `*`->`^` query capture lands on the `*` token (its child). Accept either.
  local pd = node
  if pd:type() ~= 'pointer_declarator' and pd:type() ~= 'reference_declarator' then
    pd = node:parent()
  end
  if not pd or (pd:type() ~= 'pointer_declarator' and pd:type() ~= 'reference_declarator') then
    return false
  end
  local inner = pd:field('declarator')[1]
  local g = 0
  while inner and inner:type() ~= 'function_declarator' and g < 3 do
    inner = inner:field('declarator')[1]
    g = g + 1
  end
  if not inner or inner:type() ~= 'function_declarator' then
    return false
  end
  for c in inner:iter_children() do
    if c:type() == 'trailing_return_type' then
      return false
    end
  end
  local dt = pd:parent() and pd:parent():type()
  return dt == 'declaration' or dt == 'function_definition' or dt == 'field_declaration'
end

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if not vu.is_cpp(ft) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'pointer') then
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
  local root = trees[1]:root()
  local lang = parser:lang()

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)

  -- When the flip (aliases module) is on it renders the WHOLE function parameter
  -- -- type, pointers, optional, const, cstring -- so this module must stay out of
  -- param regions or every one of those doubles up (e.g. `GLFWwindow*` -> window^^).
  local flip_on = vu.module_enabled(bufnr, 'aliases')
  local function in_func_param(node)
    local p = node
    while p do
      local t = p:type()
      if t == 'parameter_declaration' or t == 'optional_parameter_declaration' then
        return true
      end
      if t == 'function_definition' or t == 'compound_statement' or t == 'field_declaration' then
        return false -- reached the body / a data member: not a param
      end
      p = p:parent()
    end
    return false
  end
  local function param_skip(node)
    return flip_on and node ~= nil and in_func_param(node)
  end

  -- `hide` once held concealed return-type ranges from the classic-function ->
  -- trailing-return reorder pass; that pass was removed (it only ever fired on
  -- most-vexing-parse false positives, e.g. `vector<T> v(n)`), so it stays empty.
  local hide = {} -- row -> { {s, e}, ... }
  local function in_reorder(row, col)
    for _, r in ipairs(hide[row] or {}) do
      if col >= r[1] and col < r[2] then
        return true
      end
    end
    return false
  end

  -- 0.5 raw-line `const char*` -> a single `CString` token (the obfuscated-string
  -- type, in DansString). Text-scanned (not treesitter) so it lands on function
  -- signatures, parameters, return types and other raw decls the view overlay
  -- doesn't touch. `const char**` collapses the inner level too -> `CString` + the
  -- outer `*` (which the `*`->`^` pass below turns into a `^`, giving `CString^`).
  -- The concealed `const char*` span is recorded in `hide` so that pass skips the
  -- `*` we just swallowed (its `in_reorder` check then covers it).
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    if not skip.skip(row0) then
      local from = 1
      while true do
        local ms, me = line:find('const%s+char%s*%*', from)
        if not ms then
          break
        end
        -- me is the byte index of the `*`. The 0-based column of the `*` is me-1.
        local _, cn = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, me - 1 } })
        if not in_string_or_comment(line, me - 1) and not in_reorder(row0, me - 1) and not param_skip(cn) and not is_cstyle_return(cn) then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, ms - 1, {
            end_col = me,
            conceal = '',
            virt_text = { { 'CString', 'DansString' } },
            virt_text_pos = 'inline',
          })
          hide[row0] = hide[row0] or {}
          hide[row0][#hide[row0] + 1] = { ms - 1, me }
        end
        from = me + 1
      end
    end
  end

  -- 1. pointer `*` -> `^` (virt_text; shared reveal rows retain the real `*`)
  local okp, pq = pcall(vim.treesitter.query.parse, lang, PTR_QUERY)
  if okp and pq then
    for _, node in pq:iter_captures(root, bufnr, s0, e0) do
      local sr, sc, _, ec = node:range()
      if not skip.skip(sr) and not in_reorder(sr, sc) and not param_skip(node) and not is_cstyle_return(node) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, {
          end_col = ec,
          conceal = '',
          virt_text = { { '^', 'Normal' } },
          virt_text_pos = 'inline',
        })
      end
    end
  end

  -- 2. leading `const` on a value declaration -> concealed (cchar-less; the
  -- conceal respects concealcursor, so the cursor line still shows it). Pointer/
  -- reference declarations keep their const (DansConst grays it).
  local okc, cq = pcall(vim.treesitter.query.parse, lang, CONST_QUERY)
  if okc and cq then
    for _, node in cq:iter_captures(root, bufnr, s0, e0) do
      local sr, sc, _, ec = node:range()
      if not skip.skip_conceal(sr) and vim.treesitter.get_node_text(node, bufnr) == 'const' then
        local decl = node:parent()
        if decl and not declares_ptr_ref(decl) then
          local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ''
          if sc == #(line:match '^%s*' or '') then -- leading const only
            local k = ec
            while k < #line and line:sub(k + 1, k + 1):match '%s' do
              k = k + 1
            end
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_col = k, conceal = '' })
          end
        end
      end
    end
  end

  -- 3. Raw semantic type templates. Render only the outermost changed template
  -- so nested wrappers compose once instead of producing overlapping extmarks.
  local function exact_qualifier(node)
    local nm = node:field('name')[1]
    if not nm then
      return false
    end
    local nr, nc = nm:range()
    local line = vim.api.nvim_buf_get_lines(bufnr, nr, nr + 1, false)[1] or ''
    local qualifier = line:sub(1, nc):match '([%w_]+)::%s*$'
    return qualifier == nil or qualifier == 'std'
  end

  local function changed_template(node)
    if node:type() ~= 'template_type' or not exact_qualifier(node) then
      return false
    end
    local sr, _, er = node:range()
    if sr ~= er then
      return false
    end
    local _, semantic = P.type_segments(vim.treesitter.get_node_text(node, bufnr))
    return semantic
  end

  local okt, tq = pcall(vim.treesitter.query.parse, lang, SEMANTIC_TYPE_QUERY)
  if okt and tq then
    for _, node in tq:iter_captures(root, bufnr, s0, e0) do
      if changed_template(node) then
        local nested = false
        local owner = node:parent()
        while owner do
          if changed_template(owner) then
            nested = true
            break
          end
          local kind = owner:type()
          if kind == 'declaration' or kind == 'parameter_declaration' or kind == 'function_definition' then
            break
          end
          owner = owner:parent()
        end
        local sr, sc, _, ec = node:range()
        if not nested and not skip.skip(sr) and not in_reorder(sr, sc) and not param_skip(node) and not is_cstyle_return(node) then
          local chunks = require('custom.dans_frontend_cpp.render').type_chunks(vim.treesitter.get_node_text(node, bufnr), bufnr)
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, {
            end_col = ec,
            conceal = '',
            virt_text = chunks,
            virt_text_pos = 'inline',
          })
        end
      end
    end
  end

end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_pointer', { clear = true })
  vu.on_decorate(group, { 'FileType', 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, refresh)
end

return M
