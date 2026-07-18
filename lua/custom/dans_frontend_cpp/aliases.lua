-- Render C++ keywords/attributes as short aliases via inline virt_text +
-- concealment. The original text stays in the file (this is purely visual).
-- The `$` prefix signals the rendered form is a shorthand, not real C++.
--   static_cast       -> $sc
--   dynamic_cast      -> $dc
--   reinterpret_cast  -> $rc
--   const_cast        -> $cc
--   noexcept          -> $ne
--   [[nodiscard]]     -> $nd
--   static_assert     -> $as
--   VK_NULL_HANDLE    -> nullptr  (in the Vulkan color; a clearer disambiguator than {})

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_aliases'
local vu = require 'custom.dans_frontend_cpp.util'
local parse = require 'custom.dans_frontend_cpp.parse'

-- { keyword, replacement, highlight? }  -- highlight defaults to 'Comment'.
local ALIASES = {
  -- casts collapse to the long $Xcast form (the obfuscated view); both $sc and
  -- $scast expand back to static_cast (the short forms are expand-only atoms in
  -- cpp_type_snippets). dynamic_cast keeps $dc (no $dcast requested).
  { 'static_cast', '$scast' },
  { 'dynamic_cast', '$dc' },
  { 'reinterpret_cast', '$rcast' },
  { 'const_cast', '$ccast' },
  { 'noexcept', '$ne' },
  { '[[nodiscard]]', '$nd' },
  { '[[maybe_unused]]', '' }, -- '' = hidden entirely (incl one trailing space)
  { 'static_assert', '$sa' },
  { 'std::runtime_error', '$re' },
  { 'std::unique_ptr', '$up' },
  { 'std::shared_ptr', '$sp' },
  { 'VK_NULL_HANDLE', 'nullptr', 'DansVulkan' },
  -- dans-core macros read as Rust-style bang-macros, kept in the macro color
  -- (DansMacro) so they still scan as macros, not as gray keyword shorthands.
  -- DANS_PANIC matches at a word boundary, so it won't fire inside DANS_PANICF.
  { 'DANS_PANICF', 'panicf!', 'DansMacro' },
  { 'DANS_PANIC', 'panic!', 'DansMacro' },
  { 'DANS_CHECK_VALID', 'check!', 'DansMacro' },
  { 'DANS_VK_CHECK', 'check!', 'DansMacro' },
  { 'DANS_FORMAT_WITH_TO_STRING', 'format!', 'DansMacro' },
  { 'DANS_SCOPE_TIMER', 'time!', 'DansMacro' },
}

-- Exposed so arrow_align.lua can mirror these widths when it computes the
-- rendered arrow column (each alias shrinks its keyword to the replacement).
M.ALIASES = ALIASES

local function is_word_char(c)
  return c and c:match '[%w_]' ~= nil
end

-- Whether byte column col0 (0-based) sits inside a "..." string or a // comment,
-- so aliases stay out of non-code text. Naive (ignores raw strings, escaped
-- quotes, char literals), but enough for this.
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

-- First balanced (...) group -- the parameter list -- as 1-based open/close byte
-- positions, or nil. Skips the call operator's own `()` (`operator()(args)`) so
-- the args are found, not the empty operator parens; the trailing const after
-- the real `)` is then detected too. (operator[] / operator== have no `(` in the
-- name, so the scan isn't fooled by them.)
local function balanced_parens(line)
  local from = 1
  local _, op_e = line:find 'operator%s*%(%s*%)'
  if op_e then
    from = op_e + 1
  end
  local open = line:find('(', from, true)
  if not open then
    return nil
  end
  local depth = 0
  for i = open, #line do
    local c = line:sub(i, i)
    if c == '(' then
      depth = depth + 1
    elseif c == ')' then
      depth = depth - 1
      if depth == 0 then
        return open, i
      end
    end
  end
  return nil
end

-- Split an arg-list body on top-level commas. Returns { {text, from} } with
-- `from` the 1-based offset of the arg within `s`.
local function split_args(s)
  local args, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '(' or c == '<' or c == '[' or c == '{' then
      depth = depth + 1
    elseif c == ')' or c == '>' or c == ']' or c == '}' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      args[#args + 1] = { text = s:sub(start, i - 1), from = start }
      start = i + 1
    end
  end
  args[#args + 1] = { text = s:sub(start), from = start }
  return args
end

-- ===================== concept / type-trait rendering =====================
-- One mechanism renders a template `Keyword<...>` in a compact `~`-notation. `~`
-- reads as "the concept sigil" (otherwise only destructors / bitwise-not, so it's
-- free) and everything injected here is colored DansConcept. Each row of CONCEPTS
-- is string-matched exactly -- a hardcoded whitelist, no inference. Emit shapes:
--
--   infix  Keyword<A, B>   -> A ~> B / A ~= B   convertible_to, same_as
--   fixed  Keyword<A>      -> A ~> <rhs>        CharLike -> A ~> char (rhs baked)
--   suffix Keyword<A>      -> A<sym>            ValueOf -> A~value, RefOf -> A~&
--   uname  Keyword<A>      -> A~Keyword         input_range<R> -> R~input_range
--   call   Keyword<F, R..> -> F(R..)            invocable / invoke_result_t
--
-- The relation operators ` ~> ` / ` ~= ` are spaced; the postfix ~value / ~& /
-- ~name are tight. A relation is BRACKETED when an operand is itself compound (a
-- nested concept / template, i.e. contains `<`): convertible_to<ValueOf<R>, X> ->
-- (R~value ~> X). Nesting falls out because each occurrence is concealed/injected
-- independently. static_assert lines are skipped wholesale by the caller.
local CONCEPT_HL = 'DansConcept'
-- the std concepts that render as a tight postfix `A~name`.
local UNARY_CONCEPTS = {
  'input_range', 'output_range', 'forward_range', 'bidirectional_range',
  'random_access_range', 'contiguous_range', 'sized_range', 'common_range',
  'viewable_range', 'range', 'view', 'integral', 'signed_integral',
  'unsigned_integral', 'floating_point', 'regular', 'semiregular', 'movable',
  'copyable', 'default_initializable', 'equality_comparable', 'totally_ordered',
}
local CONCEPTS = {
  { kw = 'convertible_to', kind = 'infix', op = '~>' },
  { kw = 'same_as', kind = 'infix', op = '~=' },
  { kw = 'invocable', kind = 'call' }, -- T(S): callable with S
  { kw = 'invoke_result_t', kind = 'call', prefix = '{ ', suffix = ' }' }, -- { T(S) }: requires-expr spelling of the call's result type
  { kw = 'CharLike', kind = 'fixed', op = '~>', rhs = 'char' },
  { kw = 'BoolLike', kind = 'fixed', op = '~>', rhs = 'bool' },
  { kw = 'IntLike', kind = 'fixed', op = '~>', rhs = 'int' },
  { kw = 'StringLike', kind = 'fixed', op = '~>', rhs = 'string_view' },
  { kw = 'ValueOf', kind = 'suffix', sym = '~value' },
  { kw = 'RefOf', kind = 'suffix', sym = '~&' },
  { kw = 'iter_value_t', kind = 'suffix', sym = '~value' },
  { kw = 'range_value_t', kind = 'suffix', sym = '~value' },
  { kw = 'iter_reference_t', kind = 'suffix', sym = '~&' },
  { kw = 'range_reference_t', kind = 'suffix', sym = '~&' },
}
for _, kw in ipairs(UNARY_CONCEPTS) do
  CONCEPTS[#CONCEPTS + 1] = { kw = kw, kind = 'uname', sym = '~' .. kw }
end

-- the concept keywords with a dedicated spec above -- a user concept by one of
-- these names (unlikely) is left to its special spec, not the generic uname pass.
local STATIC_KW = {}
for _, s in ipairs(CONCEPTS) do
  STATIC_KW[s.kw] = true
end

-- User-defined concept names (`concept NAME = ...`) in the buffer, so a usage
-- `NAME<T>` renders T~NAME like the std unary concepts. Cached per changedtick.
local uc_cache = {}
local function user_concepts(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = uc_cache[bufnr]
  if c and c.tick == tick then
    return c.set
  end
  local set = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local name = line:match '^%s*concept%s+([%w_]+)'
    if name and not STATIC_KW[name] then
      set[name] = true
    end
  end
  uc_cache[bufnr] = { tick = tick, set = set }
  return set
end

-- Concept names usable as a bare unary template-param constraint (`BoolLike A` ->
-- `A~BoolLike`): the fixed + uname specs plus user-defined concepts. Relations
-- (convertible_to / same_as) need an explicit operand, so they're excluded here --
-- their constrained form (`convertible_to<bool> B` -> `B ~> bool`) is the infix
-- branch of render_concept.
local function unary_constraint_set(bufnr)
  local set = {}
  for _, s in ipairs(CONCEPTS) do
    if s.kind == 'fixed' or s.kind == 'uname' then
      set[s.kw] = true
    end
  end
  for name in pairs(user_concepts(bufnr)) do
    set[name] = true
  end
  return set
end

local function hide(bufnr, row0, s0, e0)
  if e0 > s0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s0, { end_col = e0, conceal = '' })
  end
end
local function hide_inject(bufnr, row0, s0, e0, text)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s0, {
    end_col = e0,
    conceal = '',
    virt_text = { { text, CONCEPT_HL } },
    virt_text_pos = 'inline',
  })
end

-- 1-based inclusive [start, end] of a trimmed arg within the line. `open` is the
-- 1-based column of the `<`; arg.from is the 1-based offset inside the `<...>` body.
local function arg_span(open, arg)
  local lead = #(arg.text:match '^%s*' or '')
  local s = open + arg.from + lead
  return s, s + #vim.trim(arg.text) - 1
end

-- Find the next `kw<...>` whose `kw` starts at a word boundary and isn't in a
-- string/comment. Returns ms (kw start), open (`<`), close (`>`), args, next-from.
local function find_concept(line, kw, from)
  while true do
    local ms, me = line:find(kw .. '%s*<', from)
    if not ms then
      return nil
    end
    from = me + 1
    local before = ms > 1 and line:sub(ms - 1, ms - 1) or nil
    if not is_word_char(before) and not in_string_or_comment(line, ms - 1) then
      local depth, close = 0, nil
      for i = me, #line do
        local c = line:sub(i, i)
        if c == '<' then
          depth = depth + 1
        elseif c == '>' then
          depth = depth - 1
          if depth == 0 then
            close = i
            break
          end
        end
      end
      if close then
        return ms, me, close, split_args(line:sub(me + 1, close - 1)), from
      end
    end
  end
end

-- A relation is bracketed only when it is NOT at the highest scope: either nested
-- inside another concept's `<...>` (an unbalanced `<` precedes it) or it's one
-- conjunct of an `and`/`or` constraint on the line. A relation that is the whole
-- expression stays unbracketed (`T ~= int`, `T~& ~> char`).
local function depth_before(line, pos)
  local d = 0
  for i = 1, pos - 1 do
    local c = line:sub(i, i)
    if c == '<' then
      d = d + 1
    elseif c == '>' then
      d = d - 1
    end
  end
  return d
end

local function render_concept(bufnr, row0, line, spec, has_conj)
  local from = 1
  while true do
    local ms, open, close, args, nxt = find_concept(line, spec.kw, from)
    if not ms then
      return
    end
    from = nxt
    local kind = spec.kind
    local nested = has_conj or depth_before(line, ms) > 0
    if kind == 'infix' and #args == 2 then
      local a_s, a_e = arg_span(open, args[1])
      local b_s, b_e = arg_span(open, args[2])
      local br = nested
      if br then
        hide_inject(bufnr, row0, ms - 1, a_s - 1, '(')
      else
        hide(bufnr, row0, ms - 1, a_s - 1)
      end
      hide_inject(bufnr, row0, a_e, b_s - 1, ' ' .. spec.op .. ' ')
      if br then
        hide_inject(bufnr, row0, b_e, close, ')')
      else
        hide(bufnr, row0, b_e, close)
      end
    elseif kind == 'infix' and #args == 1 then
      -- constrained template param: `convertible_to<bool> A` -> `A ~> bool`. The
      -- param name after the `>` is the implicit first operand, moved in front.
      local ws, pname = line:sub(close + 1):match '^(%s+)([%a_][%w_]*)'
      if pname then
        local a_s, a_e = arg_span(open, args[1])
        local pend = close + #ws + #pname
        hide_inject(bufnr, row0, ms - 1, a_s - 1, pname .. ' ' .. spec.op .. ' ')
        hide(bufnr, row0, a_e, pend) -- conceal `> <pname>` after the kept rhs
      end
    elseif kind == 'fixed' and #args == 1 then
      local a_s, a_e = arg_span(open, args[1])
      local br = nested
      if br then
        hide_inject(bufnr, row0, ms - 1, a_s - 1, '(')
      else
        hide(bufnr, row0, ms - 1, a_s - 1)
      end
      hide_inject(bufnr, row0, a_e, close, ' ' .. spec.op .. ' ' .. spec.rhs .. (br and ')' or ''))
    elseif (kind == 'suffix' or kind == 'uname') and #args == 1 then
      local ws, pname = line:sub(close + 1):match '^(%s+)([%a_][%w_]*)'
      if kind == 'uname' and pname and line:match '^%s*template%s*<' then
        -- constrained template param `Concept<Arg> Name` -> `Name~Concept<Arg>`
        -- (the param after the `>` is the constrained type, moved in front).
        local argtext = vim.trim(line:sub(open + 1, close - 1))
        local pend = close + #ws + #pname
        hide_inject(bufnr, row0, ms - 1, pend, pname .. spec.sym .. '<' .. argtext .. '>')
      else
        local a_s, a_e = arg_span(open, args[1])
        hide(bufnr, row0, ms - 1, a_s - 1)
        hide_inject(bufnr, row0, a_e, close, spec.sym)
      end
    elseif kind == 'call' and #args >= 1 then
      -- F(args): F kept, parens concept-colored, args keep their own colors. A
      -- prefix/suffix wraps it: invoke_result_t -> `{ F(args) }` (the requires
      -- compound-requirement spelling, so ` ~> string_view` reads as the trailing
      -- `-> convertible_to`).
      local f_s, f_e = arg_span(open, args[1])
      local tail = ')' .. (spec.suffix or '')
      if spec.prefix then
        hide_inject(bufnr, row0, ms - 1, f_s - 1, spec.prefix)
      else
        hide(bufnr, row0, ms - 1, f_s - 1)
      end
      if #args == 1 then
        hide_inject(bufnr, row0, f_e, close, '(' .. tail)
      else
        local b_s = arg_span(open, args[2])
        local _, last_e = arg_span(open, args[#args])
        hide_inject(bufnr, row0, f_e, b_s - 1, '(')
        hide_inject(bufnr, row0, last_e, close, tail)
      end
    end
    -- arity mismatch: leave verbatim (no extmarks)
  end
end

local function concepts(bufnr, row0, line)
  -- a line with a top-level `and`/`or` is a constraint conjunction, so every
  -- relation on it is a sub-term and gets bracketed.
  local has_conj = line:match '%f[%a]and%f[%A]' ~= nil or line:match '%f[%a]or%f[%A]' ~= nil
  for _, spec in ipairs(CONCEPTS) do
    render_concept(bufnr, row0, line, spec, has_conj)
  end
  -- user-defined concepts: NAME<T> -> T~NAME (the same unary postfix).
  for name in pairs(user_concepts(bufnr)) do
    render_concept(bufnr, row0, line, { kw = name, kind = 'uname', sym = '~' .. name }, has_conj)
  end
end

-- Template header compaction: `template <typename V>` -> `<V>`, `template
-- <typename T, usize N>` -> `<T, usize N>`. Conceals the `template ` keyword and
-- the `typename`/`class` param kinds. When the next line defines a concept, the
-- header instead reads `concept<...>` (the `concept` keyword is dropped from the
-- def line by concept_def_line below). A bare unary-concept constraint reads as a
-- postfix: `template <BoolLike A>` -> `<A~BoolLike>`. The introduced param names
-- get the concept color. Scoped to a line opening with `template`, so a dependent
-- `typename T::x` elsewhere is safe.
local function template_header(bufnr, row0, line)
  local indent = line:match '^(%s*)template%s*<'
  if not indent or in_string_or_comment(line, #indent) then
    return
  end
  local lt = line:find('<', #indent + 1, true)
  local depth, close = 0, nil
  for i = lt, #line do
    local c = line:sub(i, i)
    if c == '<' then
      depth = depth + 1
    elseif c == '>' then
      depth = depth - 1
      if depth == 0 then
        close = i
        break
      end
    end
  end
  if not close then
    return
  end
  local nextl = vim.api.nvim_buf_get_lines(bufnr, row0 + 1, row0 + 2, false)[1] or ''
  if nextl:match '^%s*concept%f[%A]' then
    hide_inject(bufnr, row0, #indent, lt - 1, 'concept') -- `template ` -> `concept`
  else
    hide(bufnr, row0, #indent, lt - 1) -- conceal `template ` (keep the `<`)
  end
  for _, kw in ipairs { 'typename', 'class' } do
    local j = lt
    while true do
      local s, e = line:find('%f[%w]' .. kw .. '%s+', j)
      if not s or s > close then
        break
      end
      hide(bufnr, row0, s - 1, e) -- conceal `typename ` / `class `
      j = e + 1
    end
  end
  -- Per param: a bare unary-concept constraint `BoolLike A` (no `<...>`, so the
  -- find_concept pass above misses it) renders as `A~BoolLike`. Otherwise color the
  -- introduced name (last identifier before a default) in the concept color, so the
  -- template parameters read as parameters. The `Concept<Arg> Name` and
  -- `convertible_to<bool> Name` constrained forms are handled by render_concept.
  local uset = unary_constraint_set(bufnr)
  for _, arg in ipairs(split_args(line:sub(lt + 1, close - 1))) do
    local atext = arg.text:gsub('%s*=.*$', '')
    local concept, pname = vim.trim(atext):match '^([%w_:]+)%s+([%a_][%w_]*)$'
    if concept and uset[concept:gsub('^.*::', '')] then
      local a_s, a_e = arg_span(lt, arg) -- span of the trimmed `Concept Name`
      hide_inject(bufnr, row0, a_s - 1, a_e, pname .. '~' .. concept:gsub('^.*::', ''))
    else
      local name, name_off
      for off, id in atext:gmatch '()([%a_][%w_]*)' do
        name, name_off = id, off
      end
      if name then
        local col = lt + arg.from + name_off - 2 -- 0-based col of the name
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, col, { end_col = col + #name, hl_group = CONCEPT_HL, priority = 200 })
      end
    end
  end
end

-- A concept definition line whose previous line is a template header: drop the
-- `concept ` keyword (the params moved up into `concept<...>`), so
-- `template <typename T>` / `concept CharLike = ...` reads `concept<T>` /
-- `CharLike = ...`.
local function concept_def_line(bufnr, row0, line)
  if row0 == 0 then
    return
  end
  local indent = line:match '^(%s*)concept%s'
  if not indent then
    return
  end
  local prev = vim.api.nvim_buf_get_lines(bufnr, row0 - 1, row0, false)[1] or ''
  if not prev:match '^%s*template%s*<' then
    return
  end
  local _, e = line:find '^%s*concept%s+'
  hide(bufnr, row0, #indent, e) -- conceal `concept ` (keep the concept name)
end

-- Syntax ownership predicates for transforms that replace a whole token.  A
-- multiline parameter is replaced as one unit by flip_param_line; a concrete
-- leading function return is moved by c_style_apply.  Token-level aliases must
-- defer in both positions or overlapping extmarks can display both spellings.
local function has_ancestor_type(bufnr, row0, col0, wanted)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col0 } })
  if not ok then
    return false
  end
  while node do
    if wanted[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

local PARAMETER_NODES = { parameter_declaration = true, optional_parameter_declaration = true }
local function in_parameter(bufnr, row0, col0)
  return has_ancestor_type(bufnr, row0, col0, PARAMETER_NODES)
end

local function contains_function_declarator(node, depth)
  if not node or depth > 8 then
    return false
  end
  if node:type() == 'function_declarator' then
    return true
  end
  for child in node:iter_children() do
    if child:type():match 'declarator$' and contains_function_declarator(child, depth + 1) then
      return true
    end
  end
  return false
end

local function position_in_node(node, row0, col0)
  local sr, sc, er, ec = node:range()
  if row0 < sr or row0 > er then
    return false
  end
  if row0 == sr and col0 < sc then
    return false
  end
  if row0 == er and col0 >= ec then
    return false
  end
  return true
end

local FUNCTION_OWNER_NODES = { function_definition = true, declaration = true, field_declaration = true }
local function in_moved_function_return(bufnr, row0, col0)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col0 } })
  if not ok then
    return false
  end
  while node do
    if FUNCTION_OWNER_NODES[node:type()] then
      local typ = node:field('type')[1]
      local declarator = node:field('declarator')[1]
      return typ ~= nil and position_in_node(typ, row0, col0) and contains_function_declarator(declarator, 0)
    end
    node = node:parent()
  end
  return false
end

-- `auto* const name` / `T* const name` (a const pointer) reads better with the
-- const in front: `const auto^ name`. The pointer module turns `*` into `^` on the
-- raw line; here the trailing pointer-const is moved ahead of the type. Only
-- `<type>* const <name>` (a decl shape), never a `a * b` expression.
local function const_pointer_reorder(bufnr, row0, line)
  local from = 1
  while true do
    local s, e, tstart, typ, cstart = line:find('()([%w_:]+)%s*%*+%s+()const%s', from)
    if not s then
      return
    end
    from = e
    local before = tstart > 1 and line:sub(tstart - 1, tstart - 1) or ''
    if
      not in_parameter(bufnr, row0, tstart - 1)
      and (before == '' or not before:match '[%w_]')
      and not in_string_or_comment(line, tstart - 1)
      and typ ~= 'return'
    then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, tstart - 1, {
        virt_text = { { 'const ', 'DansConst' } },
        virt_text_pos = 'inline',
      })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, cstart - 1, { end_col = cstart - 1 + 6, conceal = '' })
    end
  end
end

-- ImGui's assert macros read as their std spelling, grayed like a real assert:
-- IM_STATIC_ASSERT -> static_assert, IM_ASSERT -> assert, IM_ASSERT_USER_ERROR ->
-- assert_user_error. (Strip IM_, lowercase the rest.) Other IM_* keep the bordeaux
-- coloring from markers; only these asserts are reworded.
local function imgui_asserts(bufnr, row0, line)
  local i = 1
  while true do
    local s, e, tok = line:find('(IM_[%u][%u%d_]*)', i)
    if not s then
      return
    end
    i = e + 1
    local before = s > 1 and line:sub(s - 1, s - 1) or nil
    if (tok == 'IM_STATIC_ASSERT' or tok:match '^IM_ASSERT') and not is_word_char(before) and not in_string_or_comment(line, s - 1) then
      local repl = tok:gsub('^IM_', ''):lower()
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
        end_col = e,
        conceal = '',
        virt_text = { { repl, 'DansAssert' } },
        virt_text_pos = 'inline',
      })
    end
  end
end

-- Tree-sitter supplies CUDA_CHECK argument_list boundaries across rows, so
-- nested calls cannot confuse a byte-depth scan. Building that fact by querying
-- every parenthesis on every visible repaint would be needlessly expensive;
-- instead scan only literal CUDA_CHECK candidates once per changedtick and cache
-- row -> boundary-column sets. Each row then paints itself from an O(1) lookup,
-- so repainting only the closing row restores it without touching the opener.
local cuda_check_boundary_cache = {}
local function cuda_check_boundaries(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = cuda_check_boundary_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.rows
  end
  local rows = {}
  local function add(row0, col0)
    rows[row0] = rows[row0] or {}
    rows[row0][col0] = true
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row0, line in ipairs(lines) do
    local from = 1
    while true do
      local s, e = line:find('CUDA_CHECK', from, true)
      if not s then
        break
      end
      from = e + 1
      local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0 - 1, s - 1 } })
      while ok and node do
        if node:type() == 'call_expression' then
          local fn = node:field('function')[1]
          local args = node:field('arguments')[1]
          if fn and args and vim.treesitter.get_node_text(fn, bufnr) == 'CUDA_CHECK' then
            local sr, sc, er, ec = args:range()
            add(sr, sc)
            add(er, ec - 1)
            break
          end
        end
        node = node:parent()
      end
    end
  end
  cuda_check_boundary_cache[bufnr] = { tick = tick, rows = rows }
  return rows
end

local function cuda_check_delimiters(bufnr, row0)
  for col0 in pairs(cuda_check_boundaries(bufnr)[row0] or {}) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, col0, {
      end_col = col0 + 1,
      hl_group = 'DansCUDA',
      -- Above passive ancestor pairs (150), below the active scope pair (200).
      priority = 175,
    })
  end
end

-- CUDA runtime API rendering. A `cudaXxx(` CALL reads as its snake_case spelling
-- (cudaMalloc -> malloc, cudaStreamSynchronize -> stream_synchronize) in the CUDA
-- color; a `cudaXxx` NOT followed by `(` is an enum/handle constant
-- (cudaMemcpyDeviceToHost, the cudaError_t type) and is left to the markers
-- prefix-strip, keeping its CamelCase. CUDA_CHECK reads as `?` (an error-propagation
-- wrapper, like Rust's `?`); other CUDA_ macros (CUDA_NOCHECK, ...) keep the markers
-- prefix-strip. Full-token conceal + inject, so it wins over the markers prefix
-- conceal on the same token.
local function cuda_idents(bufnr, row0, line)
  cuda_check_delimiters(bufnr, row0)
  -- Precision-bearing CUDA complex aliases apply to every raw code position not
  -- already owned by a larger structured transform. parse.strip_glfw applies
  -- the same table inside overlays, parameters, template expressions, and moved
  -- return chunks. Full-token replacement (rather than hiding only `cu`) is what
  -- permits cuFloatComplex/cuComplex -> cf32 and cuDoubleComplex -> cf64.
  local exact_cuda_sources = {}
  for _, spec in ipairs(parse.cuda_type_aliases()) do
    exact_cuda_sources[spec.source] = true
    local i = 1
    while true do
      local s, e = line:find(spec.source, i, true)
      if not s then
        break
      end
      i = e + 1
      local before = s > 1 and line:sub(s - 1, s - 1) or nil
      local after = e < #line and line:sub(e + 1, e + 1) or nil
      if
        not is_word_char(before)
        and not is_word_char(after)
        and not in_string_or_comment(line, s - 1)
        and not in_parameter(bufnr, row0, s - 1)
        and not in_moved_function_return(bufnr, row0, s - 1)
      then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
          end_col = e,
          conceal = '',
          virt_text = { { spec.shown, 'DansCUDA' } },
          virt_text_pos = 'inline',
        })
      end
    end
  end

  -- CUDA complex helpers have semantic spellings rather than prefix-only
  -- shortenings (cuCabsf -> abs, cuConjf -> conj). Full-token injected text
  -- keeps CUDA provenance through its seafoam highlight. Declaration overlays
  -- use the same exact table through parse.strip_glfw.
  for _, spec in ipairs(parse.cuda_function_aliases()) do
    local i = 1
    while true do
      local s, e = line:find(spec.source, i, true)
      if not s then
        break
      end
      i = e + 1
      local before = s > 1 and line:sub(s - 1, s - 1) or nil
      local after = e < #line and line:sub(e + 1, e + 1) or nil
      if not is_word_char(before) and not is_word_char(after) and not in_string_or_comment(line, s - 1) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
          end_col = e,
          conceal = '',
          virt_text = { { spec.shown, 'DansCUDA' } },
          virt_text_pos = 'inline',
        })
      end
    end
  end

  local i = 1
  while true do
    local s, e, tok = line:find('(cuda%u[%w_]*)', i)
    if not s then
      break
    end
    i = e + 1
    local before = s > 1 and line:sub(s - 1, s - 1) or nil
    if
      not exact_cuda_sources[tok]
      and not is_word_char(before)
      and line:sub(e + 1):match '^%s*%('
      and not in_string_or_comment(line, s - 1)
    then
      local snake = tok:gsub('^cuda', ''):gsub('(%l)(%u)', '%1_%2'):gsub('(%u)(%u%l)', '%1_%2'):lower()
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
        end_col = e,
        conceal = '',
        virt_text = { { snake, 'DansCUDA' } },
        virt_text_pos = 'inline',
      })
    end
  end
  local j = 1
  while true do
    local s, e = line:find('CUDA_CHECK', j, true)
    if not s then
      break
    end
    j = e + 1
    local before = s > 1 and line:sub(s - 1, s - 1) or nil
    local after = e < #line and line:sub(e + 1, e + 1) or nil
    if not is_word_char(before) and not is_word_char(after) and not in_string_or_comment(line, s - 1) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
        end_col = e,
        conceal = '',
        virt_text = { { '?', 'DansCUDA' } },
        virt_text_pos = 'inline',
      })
    end
  end
end

-- A top-level single `&` in the type marks a non-const lvalue reference (default
-- stripped, template/paren/brace groups skipped). `&&` is an rvalue ref (no mut).
local function is_ref_param(typ)
  local depth = 0
  local i = 1
  while i <= #typ do
    local c = typ:sub(i, i)
    if c == '<' or c == '(' or c == '[' or c == '{' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' or c == '}' then
      depth = depth - 1
    elseif c == '&' and depth == 0 then
      if typ:sub(i + 1, i + 1) == '&' then
        i = i + 1 -- rvalue ref: mut is meaningless, skip
      else
        return true
      end
    end
    i = i + 1
  end
  return false
end

-- Render one parameter `type name` as `name: type` chunks (the flip). The type
-- goes through render.type_chunks (std:: stripped, *->^, string/lib coloring); a
-- non-const lvalue-ref gets a `mut`; leading const follows the validated
-- per-buffer reference profile (const-default in production).
-- A constrained-auto param `Concept auto[&*] name` renders `name: ~Concept` in the
-- concept color. Returns nil for an unnamed / unparseable param (left raw).
local function flip_param(p, bufnr)
  local main, default = p:match '^(.-)%s*=%s*(.+)$'
  main = vim.trim(main or p)
  -- drop leading attributes ([[maybe_unused]] etc.) -- pure noise, like the decl path
  main = vim.trim(main:gsub('^%s*%[%[.-%]%]%s*', ''))
  -- OPENBLAS_CONST (OpenBLAS's const macro, all over cblas.h prototypes) IS
  -- const: normalize it so every const rule below applies unchanged.
  main = main:gsub('%f[%w_]OPENBLAS_CONST%f[%W]', 'const')
  -- Auto-typed param: the type is deduced, so collapse `[cpy] [const] auto[&|&&]
  -- name` to the sigil form -- `name` (value), `name&` (const ref), `mut name&`
  -- (non-const ref), `name&&` (forwarding), `cpy name` (heavy value). This is what
  -- lets a lambda's `const auto& as` read `as&`; concrete params fall through to the
  -- `name: type` flip below, so lambda and function args stay aligned. Runs before
  -- the constrained-auto branch, whose `([%w_:]+) auto` pattern would otherwise bind
  -- a leading `const` as the "concept". `auto*` is left to the concrete path.
  do
    local rest = main
    local has_cpy = rest:match '^cpy%f[%A]' ~= nil
    if has_cpy then
      rest = vim.trim(rest:gsub('^cpy%s+', ''))
    end
    local a_const = rest:match '^const%f[%A]' ~= nil
    if a_const then
      rest = vim.trim(rest:gsub('^const%s+', ''))
    end
    local sig, aname = rest:match '^auto%s*(&*)%s*([%w_]+)$'
    if aname then
      local chunks = {}
      if has_cpy then
        chunks[#chunks + 1] = { 'cpy ', 'DansMarkerCpy' }
      end
      if sig == '&' and not a_const then
        chunks[#chunks + 1] = { 'mut ', 'DansMarkerMut' }
      end
      chunks[#chunks + 1] = { aname, 'Normal' }
      if sig == '&' or sig == '&&' then
        chunks[#chunks + 1] = { sig, 'Normal' }
      end
      if default then
        chunks[#chunks + 1] = { ' = ', 'Normal' }
        chunks[#chunks + 1] = { default, 'Normal' }
      end
      return chunks
    end
  end
  -- Constrained-auto param `Concept auto[&*] name` -> `name: ~Concept` (+ mut/&/^).
  -- `const` is excluded -- it's a cv-qualifier the auto-collapse above already ate,
  -- not a concept.
  local concept, asig, cname = main:match '^([%w_:]+)%s+auto([&*]*)%s*([%w_]+)$'
  if concept and concept ~= 'const' then
    local chunks = { { cname, 'Normal' }, { ': ', 'Normal' } }
    if asig == '&' then
      chunks[#chunks + 1] = { 'mut ', 'DansMarkerMut' }
    end
    chunks[#chunks + 1] = { '~' .. concept, CONCEPT_HL }
    if asig == '&' then
      chunks[#chunks + 1] = { '&', CONCEPT_HL }
    elseif asig == '&&' then
      chunks[#chunks + 1] = { '&&', CONCEPT_HL }
    elseif asig == '*' then
      chunks[#chunks + 1] = { '^', CONCEPT_HL }
    end
    return chunks
  end
  -- name = the TRAILING identifier (nothing after it but whitespace), at a type
  -- boundary. `const Camera&` has no trailing identifier (it ends in `&`), so it's
  -- unnamed and renders as just the type -- still std::-stripped + colored, so the
  -- width matches the display and arrow_align stays right.
  local npos = main:find '[%a_][%w_]*%s*$'
  local name = npos and main:match('([%a_][%w_]*)%s*$')
  local typ
  if name and npos > 1 and main:sub(npos - 1, npos - 1):match '[%s&*>]' then
    typ = vim.trim(main:sub(1, npos - 1))
  end
  if not typ or typ == '' then
    return require('custom.dans_frontend_cpp.render').type_chunks(main) -- unnamed
  end
  -- A top-level const on the pointer object (`T* const p`) belongs to the
  -- binding, not its pointee type.  Raw-line const_pointer_reorder deliberately
  -- defers inside parameters, so the flip owns the spelling without overlapping
  -- extmarks: `T* const p` -> `const p: T^`, while `const T* const p` keeps the
  -- independent pointee const as `const p: const T^`.
  local pointer_object_const = typ:match '%*+%s*const%s*$' ~= nil
  if pointer_object_const then
    typ = vim.trim(typ:gsub('%s*const%s*$', '', 1))
  end
  local chunks = {}
  if pointer_object_const then
    chunks[#chunks + 1] = { 'const ', 'DansConst' }
  end
  chunks[#chunks + 1] = { name, 'Normal' }
  chunks[#chunks + 1] = { ': ', 'Normal' }
  -- A non-const lvalue ref gets `mut`. The production profile hides leading
  -- const on a concrete reference (const-default); the explicit profile used by
  -- the style lab retains it. Pointer pointee const is never hidden here, and
  -- `const char*` still reaches type_chunks intact so it can read as CString.
  local was_const = typ:match '^const%f[%A]' ~= nil
  if is_ref_param(typ) and not was_const then
    chunks[#chunks + 1] = { 'mut ', 'DansMarkerMut' }
  end
  if was_const
    and is_ref_param(typ)
    and require('custom.dans_frontend_cpp.style').get(bufnr, 'concrete_reference_const') == 'const_default'
  then
    typ = vim.trim(typ:gsub('^const%s+', '', 1))
  end
  for _, c in ipairs(require('custom.dans_frontend_cpp.render').type_chunks(typ)) do
    chunks[#chunks + 1] = c
  end
  if default then
    chunks[#chunks + 1] = { ' = ', 'Normal' }
    chunks[#chunks + 1] = { default, 'Normal' }
  end
  return chunks
end

-- Locate the first binding/type separator emitted by flip_param and return its
-- visible-cell offset plus chunk index. Auto-reference parameters intentionally
-- have no colon and therefore do not participate in concrete-parameter columns.
local function colon_prefix(chunks)
  local width = 0
  for index, chunk in ipairs(chunks or {}) do
    if chunk[1] == ': ' then
      return width, index
    end
    width = width + vim.fn.strwidth(chunk[1])
  end
  return nil
end

-- Parameter-list alignment is derived from the entire Tree-sitter list, but the
-- decorator paints one visible row at a time. Cache the list-level target by
-- changedtick/profile so a P-parameter signature costs O(P), not O(P^2), during
-- a range refresh. The cache stores only derived display columns and is safe to
-- discard on every edit, style-profile change, or buffer wipe.
local multiline_colon_cache = {}
local function colon_cache_for(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local profile = require('custom.dans_frontend_cpp.style').profile(bufnr)
  local profile_key = vim.inspect(profile)
  local cache = multiline_colon_cache[bufnr]
  if not cache or cache.tick ~= tick or cache.profile ~= profile_key then
    cache = { tick = tick, profile = profile_key, lists = {} }
    multiline_colon_cache[bufnr] = cache
  end
  return cache.lists
end

local function parameter_list_colon_target(bufnr, plist)
  local sr, sc, er, ec = plist:range()
  if sr == er then
    return nil -- inline signatures retain compact comma-separated formatting
  end
  local key = table.concat({ sr, sc, er, ec }, ':')
  local cache = colon_cache_for(bufnr)
  if cache[key] ~= nil then
    return cache[key] or nil
  end

  local target, count, row_counts = 0, 0, {}
  for child in plist:iter_children() do
    local kind = child:type()
    if kind == 'parameter_declaration' or kind == 'optional_parameter_declaration' then
      local cr, cc, cer = child:range()
      if cr == cer then
        row_counts[cr] = (row_counts[cr] or 0) + 1
        local text = vim.treesitter.get_node_text(child, bufnr)
        local chunks = type(text) == 'string' and flip_param(vim.trim(text), bufnr) or nil
        local prefix_width = colon_prefix(chunks)
        if prefix_width then
          local line = vim.api.nvim_buf_get_lines(bufnr, cr, cr + 1, false)[1] or ''
          local source_prefix_width = vim.fn.strdisplaywidth(line:sub(1, cc))
          target = math.max(target, source_prefix_width + prefix_width)
          count = count + 1
        end
      end
    end
  end
  -- A vertical colon column is meaningful only for one-parameter-per-row
  -- formatting. If any row contains several parameters, aligning the first one
  -- against a later parameter's source column produces a giant gap and cannot
  -- align all colons anyway. The row still gets every parameter flipped, just in
  -- compact inline form.
  for _, row_count in pairs(row_counts) do
    if row_count > 1 then
      cache[key] = false
      return nil
    end
  end
  -- A column is a relationship between at least two concrete parameters. Avoid
  -- adding meaningless padding to a list with only one colon-bearing row.
  cache[key] = count >= 2 and target or false
  return cache[key] or nil
end

local function align_param_colon(bufnr, plist, line, source_col0, chunks)
  local prefix_width, colon_index = colon_prefix(chunks)
  local target = prefix_width and parameter_list_colon_target(bufnr, plist) or nil
  if not target then
    return chunks
  end
  local source_prefix_width = vim.fn.strdisplaywidth(line:sub(1, source_col0))
  local padding = target - source_prefix_width - prefix_width
  if padding > 0 then
    table.insert(chunks, colon_index, { string.rep(' ', padding), 'Normal' })
  end
  return chunks
end

-- Shared per-param renderer, reused by the lambda overlay (render.lua) so lambda
-- and function arguments render identically.
M.flip_param = flip_param

-- Is the `(` at 1-based col `open` the parameter list of a function declaration
-- (not a call / `if (...)`)? Treesitter: a function_declarator ancestor.
local function is_function_decl(bufnr, row0, open)
  if not bufnr or not row0 then
    return false
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, open - 1 } })
  if not ok or not node then
    return false
  end
  while node do
    if node:type() == 'function_declarator' then
      return true
    end
    node = node:parent()
  end
  return false
end

-- The param-list flip for a function signature `line`. Returns nil if it isn't a
-- function declaration, else { open, close, edits, width }:
--   open/close: 1-based source cols of `(` and `)`.
--   edits: { {s0, e0, chunks} } -- conceal source [s0,e0) (0-based) and inject chunks.
--   width: display width of the rendered `(...)` (so arrow_align lines up `->`).
-- Shared by the flip (display) and arrow_align (width) so they never disagree.
function M.flip_params(line, bufnr, row0)
  local open, close = balanced_parens(line)
  if not open or not is_function_decl(bufnr, row0, open) then
    return nil
  end
  local width = vim.fn.strwidth(line:sub(open, close))
  local edits = {}
  for _, arg in ipairs(split_args(line:sub(open + 1, close - 1))) do
    local lead = #(arg.text:match '^%s*' or '')
    local trimmed = vim.trim(arg.text)
    if trimmed ~= '' then
      local chunks = flip_param(trimmed, bufnr)
      if chunks then
        local s0 = open + arg.from + lead - 1
        local rw = 0
        for _, c in ipairs(chunks) do
          rw = rw + vim.fn.strwidth(c[1])
        end
        edits[#edits + 1] = { s0 = s0, e0 = s0 + #trimmed, chunks = chunks }
        width = width - vim.fn.strwidth(trimmed) + rw
      end
    end
  end
  return { open = open, close = close, edits = edits, width = width }
end

-- The single-line flip above needs the whole `(...)` on one line. For a parameter
-- list spanning rows, flip EVERY complete parameter on `row0`. Most formatters
-- use one parameter per row, but C headers often pack several onto a continuation
-- row; treating that as one parameter caused a half-rendered hybrid. Returns
-- flip_params-shaped edits ({s0,e0,chunks}) or nil.
function M.flip_param_line(bufnr, row0, line)
  if not bufnr or not row0 then
    return nil
  end
  -- A line carrying `(` is the declarator line: a one-line list is flip_params'
  -- job, and a multi-line opener (`f(` with the params below) has no standalone
  -- param to flip here. Either way, skip -- so this only fires on the param rows.
  if line:find('(', 1, true) then
    return nil
  end
  local first = #(line:match '^%s*' or '')
  if first >= #line then
    return nil
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, first } })
  if not ok or not node then
    return nil
  end
  local param
  while node do
    local t = node:type()
    if t == 'parameter_declaration' or t == 'optional_parameter_declaration' then
      param = node
      break
    end
    if t == 'parameter_list' or t == 'function_declarator' then
      break -- climbed past where a param would be; this row is not one
    end
    node = node:parent()
  end
  if not param then
    return nil
  end
  local plist = param:parent()
  if not plist or plist:type() ~= 'parameter_list' then
    return nil
  end
  if not plist:parent() or plist:parent():type() ~= 'function_declarator' then
    return nil -- a call's argument_list / lambda capture, not a function decl
  end
  local edits = {}
  for child in plist:iter_children() do
    local kind = child:type()
    if kind == 'parameter_declaration' or kind == 'optional_parameter_declaration' then
      local sr, sc, er, ec = child:range()
      if sr == row0 and er == row0 then
        local trimmed = vim.trim(line:sub(sc + 1, ec))
        local chunks = trimmed ~= '' and flip_param(trimmed, bufnr) or nil
        if chunks then
          chunks = align_param_colon(bufnr, plist, line, sc, chunks)
          edits[#edits + 1] = { s0 = sc, e0 = ec, chunks = chunks }
        end
      end
    end
  end
  return #edits > 0 and edits or nil
end

-- 0-based byte columns where a `mut ` should be injected before a function arg:
-- a non-const *reference* parameter. (Legacy: the param flip now owns this; kept
-- for any external caller.) Only on trailing-return decls (a `->` follows).
function M.arg_mut_cols(line)
  local open, close = balanced_parens(line)
  if not open or not line:sub(close + 1):find('->', 1, true) then
    return {}
  end
  local cols = {}
  for _, arg in ipairs(split_args(line:sub(open + 1, close - 1))) do
    local lead = #(arg.text:match '^%s*' or '')
    local body = arg.text:sub(lead + 1)
    local typ = body:gsub('%s*=.*$', '') -- drop the default value
    if typ ~= '' and not typ:match '^const%f[%A]' and is_ref_param(typ) then
      cols[#cols + 1] = open + arg.from + lead - 1 -- 0-based column of the arg start
    end
  end
  return cols
end

-- 0-based column right after the param `)` of a NON-const member function (where
-- the trailing `const`/`mut` sits), or nil. Member functions only -- a free
-- function has no receiver const. Needs treesitter to tell a member function
-- from a free one / a data member. Exposed for arrow_align.
function M.member_mut_col(line, bufnr, row0)
  if not bufnr or not row0 then
    return nil
  end
  local open, close = balanced_parens(line)
  if not open then
    return nil
  end
  if line:sub(close):match '^%)%s*const%f[%A]' then
    return nil -- already a const member function
  end
  if line:match '%f[%w]static%f[%A]' then
    return nil -- static member function: no receiver
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, open - 1 } })
  if not ok or not node then
    return nil
  end
  local is_member, is_func = false, false
  while node do
    local t = node:type()
    if t == 'field_declaration' then
      is_member = true
    elseif t == 'function_declarator' then
      is_func = true
    end
    node = node:parent()
  end
  if not (is_member and is_func) then
    return nil
  end
  -- 0-based column right after `)` (close is its 1-based position). Placing the
  -- marker here -- not at the first following token -- keeps it ahead of a
  -- `noexcept` that aliases renders as `$ne` at that token's own column.
  return close
end

-- 0-based column of a function declaration's leading `auto` return type on
-- `line` (the placeholder return of `auto f(...) -> T` / `auto f(...) { ... }`),
-- or nil. ONLY that auto: a local `auto x =`, a lambda `const auto f =`, and a
-- param `auto` are not a function-declarator's return type, so the treesitter
-- shape excludes them -- a placeholder_type_specifier that is the `type` of a
-- function_definition / declaration / field_declaration whose declarator resolves
-- to a function_declarator. Rendered as the green `def` (what the old
-- `#define def auto` used to be, now without the macro).
local function fn_auto_col(bufnr, row0, line)
  if not bufnr or not row0 then
    return nil
  end
  local from = 1
  while true do
    local s, e = line:find('auto', from, true)
    if not s then
      return nil
    end
    from = e + 1
    local before = s > 1 and line:sub(s - 1, s - 1) or nil
    local after = e < #line and line:sub(e + 1, e + 1) or nil
    if not is_word_char(before) and not is_word_char(after) and not in_string_or_comment(line, s - 1) then
      local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, s - 1 } })
      -- get_node lands on the leaf `auto` token; the placeholder is its parent.
      local ph = ok and node and (node:type() == 'placeholder_type_specifier' and node or node:parent()) or nil
      if ph and ph:type() == 'placeholder_type_specifier' then
        local parent = ph:parent()
        local pt = parent and parent:type()
        if pt == 'function_definition' or pt == 'declaration' or pt == 'field_declaration' then
          -- a function declares through a function_declarator (possibly wrapped in
          -- a pointer/reference declarator); a local auto resolves to an
          -- init_declarator / identifier instead, so it never matches.
          local decl = parent:field('declarator')[1]
          local guard = 0
          while decl and decl:type() ~= 'function_declarator' and guard < 4 do
            decl = decl:field('declarator')[1]
            guard = guard + 1
          end
          if decl and decl:type() == 'function_declarator' then
            return s - 1
          end
        end
      end
    end
  end
end

-- (line, bufnr, row0) order to match flip_params / member_mut_col -- arrow_align
-- calls this to mirror the 4->3 cell `auto`->`def` width when aligning `->`.
function M.fn_auto_def_col(line, bufnr, row0)
  return fn_auto_col(bufnr, row0, line)
end

-- C-style function declarations -- a concrete leading return type and NO trailing
-- `->` -- are shown Odin-style like the rest: the leading type is concealed and
-- re-injected as a trailing `-> type` after the params. Two layouts:
--   int foo(double x);              -> foo(x: double) -> int;
--   int                             (blank line -- we never merge lines)
--   foo(double x);                  -> foo(x: double) -> int;
-- The moved text is the raw source span from the type to the function name, so
-- pointer/reference/multi-word returns (`const char*`, `unsigned long`) ride along
-- without special-casing. Storage specifiers are stripped; `auto` returns are the
-- def path (fn_auto_col), not this one.
local c_fn_queries = {}
local function c_fn_query(lang)
  if c_fn_queries[lang] == nil then
    local ok, q = pcall(vim.treesitter.query.parse, lang, '[ (function_definition) (declaration) (field_declaration) ] @fn')
    c_fn_queries[lang] = ok and q or false
  end
  return c_fn_queries[lang] or nil
end

-- Unwrap a pointer/reference return declarator to its function_declarator.
-- pointer_declarator exposes the inner via field('declarator'); reference_declarator
-- keeps it as a plain child, so fall back to scanning for a *_declarator child.
local function unwrap_fn(d)
  local node = d
  local g = 0
  while node and node:type() ~= 'function_declarator' and g < 4 do
    local nxt = node:field('declarator')[1]
    if not nxt then
      for c in node:iter_children() do
        if c:type():match 'declarator$' then
          nxt = c
          break
        end
      end
    end
    node = nxt
    g = g + 1
  end
  return node
end

-- A real function declaration whose return type can be moved: a function_declarator
-- named by a plain name. A function pointer (`int (*fp)(double)`) or a
-- function returning a function pointer names a parenthesized_declarator instead;
-- moving its "return type" mangles it, so those are skipped (left raw).
local function is_real_fn(core)
  if not core or core:type() ~= 'function_declarator' then
    return false
  end
  local nm = core:field('declarator')[1]
  return nm == nil or nm:type() ~= 'parenthesized_declarator'
end

local TRAILING_QUALS = { const = true, volatile = true, noexcept = true, override = true, ['final'] = true }

-- 0-based col on `line` after the param `)` (col0) and any trailing qualifiers,
-- where the `-> type` should land; nil if the tail is not a clean decl end
-- (an initializer / `= 0` / `= default` -- leave those alone).
local function trailing_inject_col(line, col0)
  local i = col0 -- just past the param `)`; tracks the end of the last token
  while true do
    local j = i
    while j < #line and line:sub(j + 1, j + 1):match '%s' do
      j = j + 1
    end
    local rest = line:sub(j + 1)
    -- inject right after the last token (paren / qualifier), so the source
    -- whitespace before a `;`, `{`, or `= 0`|`= default`|`= delete` is preserved.
    if rest == '' or rest:match '^[;{=]' then
      return i
    end
    local word = rest:match '^([%a_]+)'
    if word and TRAILING_QUALS[word] then
      i = j + #word
    elseif rest:match '^&' then
      i = j + #(rest:match '^&+')
    else
      return nil
    end
  end
end

-- Build complete C-style function layout facts once per changedtick, then index
-- each fact by only the rows it decorates. The former per-row query assumed the
-- parameter close lived on the declarator's opening row; for a multiline C API
-- it measured `cc` against the wrong string and could neither move the return nor
-- restore the closing row independently after reveal transitions.
local c_style_cache = {}
local function c_style_facts(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = c_style_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.rows
  end
  local by_row = {}
  local function index(row0, fact)
    by_row[row0] = by_row[row0] or {}
    by_row[row0][#by_row[row0] + 1] = fact
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    c_style_cache[bufnr] = { tick = tick, rows = by_row }
    return by_row
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    c_style_cache[bufnr] = { tick = tick, rows = by_row }
    return by_row
  end
  local q = c_fn_query(parser:lang())
  if not q then
    c_style_cache[bufnr] = { tick = tick, rows = by_row }
    return by_row
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local oksm, sm = pcall(require, 'custom.dans_frontend_cpp.special_members')
  for _, fn in q:iter_captures(trees[1]:root(), bufnr, 0, -1) do
    local t = fn:field('type')[1]
    local d = fn:field('declarator')[1]
    -- Unwrap a pointer/reference return (`int* foo()`, `T& bar()`) to the
    -- function_declarator; the leading `*`/`&` is part of the moved return type.
    -- pointer.lua skips these return positions (is_cstyle_return) so its `*`->`^`
    -- and const-char* -> CString don't double-render inside the concealed lead.
    local core = unwrap_fn(d)
    local name_node = core and core:field('declarator')[1] or nil
    local function_name = name_node and vim.treesitter.get_node_text(name_node, bufnr) or ''
    local skip_special = function_name:match '^operator%s*=' ~= nil
    if t and is_real_fn(core) and t:type() ~= 'placeholder_type_specifier' and not skip_special then
      local trailing = false
      for c in core:iter_children() do
        if c:type() == 'trailing_return_type' then
          trailing = true
          break
        end
      end
      if not trailing then
        local tsr, tsc = t:range()
        local nsr, nsc = core:range()
        if oksm and sm.covers(bufnr, nsr) then
          goto continue
        end
        -- A leading `const`/`volatile` is a sibling of the type node, so t:range()
        -- starts after it; pull tsc back over it so `const char*` moves whole.
        local trow = lines[tsr + 1] or ''
        local qpos = trow:sub(1, tsc):match '()const%s+$' or trow:sub(1, tsc):match '()volatile%s+$'
        if qpos then
          tsc = qpos - 1
        end
        local cr, cc
        for c in core:iter_children() do
          if c:type() == 'parameter_list' then
            local _, _, er, ec = c:range()
            cr, cc = er, ec
          end
        end
        -- `cc` belongs to the row containing the closing `)`, not necessarily the
        -- opening declarator row. Measure qualifiers and the injection point on
        -- that exact row.
        local close_line = cr ~= nil and (lines[cr + 1] or '') or ''
        local icol = cr ~= nil and trailing_inject_col(close_line, cc) or nil
        if icol then
          -- the full leading return type: the source span from the type start to
          -- the function name (covers `*`/`&`/multi-word), storage stripped.
          local typ
          if tsr == nsr then
            typ = trow:sub(tsc + 1, nsc)
          else
            typ = trow:sub(tsc + 1)
          end
          typ = typ:gsub('^%s*', ''):gsub('%s+$', ''):gsub('^static%s+', ''):gsub('^inline%s+', ''):gsub('^extern%s+', '')
          local fact = { tsr = tsr, tsc = tsc, nsr = nsr, nsc = nsc, cr = cr, icol = icol, typ = typ }
          local seen = {}
          for _, owner_row in ipairs { tsr, nsr, cr } do
            if not seen[owner_row] then
              seen[owner_row] = true
              index(owner_row, fact)
            end
          end
        end
      end
    end
    ::continue::
  end
  c_style_cache[bufnr] = { tick = tick, rows = by_row }
  return by_row
end

local function c_style_apply(bufnr, row0, line)
  for _, fact in ipairs(c_style_facts(bufnr)[row0] or {}) do
    -- 1. leading return type -> green `def`, uniform with `auto` functions. Each
    -- row paints only itself so reveal cleanup cannot create cross-row extmarks.
    if fact.tsr == row0 and fact.nsr == row0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, fact.tsc, {
        end_col = fact.nsc,
        conceal = '',
        virt_text = { { 'def ', 'DansLambda' } },
        virt_text_pos = 'inline',
      })
    elseif fact.tsr == row0 and fact.nsr > row0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, 0, { end_col = #line, conceal = '' })
    end
    if fact.nsr == row0 and fact.tsr < row0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, fact.nsc, {
        virt_text = { { 'def ', 'DansLambda' } },
        virt_text_pos = 'inline',
      })
    end

    -- 2. trailing `-> [mut] type` belongs to the row containing the source `)`.
    if fact.cr == row0 and fact.typ ~= '' then
      local chunks = { { ' -> ', 'Normal' } }
      if fact.typ:match '&%s*$' and not fact.typ:match '&&%s*$' and not fact.typ:match '^const%f[%A]' then
        chunks[#chunks + 1] = { 'mut ', 'DansMarkerMut' }
      end
      for _, chunk in ipairs(require('custom.dans_frontend_cpp.render').type_chunks(fact.typ)) do
        chunks[#chunks + 1] = chunk
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, fact.icol, {
        virt_text = chunks,
        virt_text_pos = 'inline',
      })
    end
  end
end

-- Decorate one line: the concept notation, template-header compaction, the
-- $-aliases, the param flip, and the mut markers. Shared by the full
-- visible-range refresh and the two-row cursor repaint (render_rows below).
local function decorate_line(bufnr, row0, line)
  -- concept / type-trait `~`-notation (same_as -> ~=, convertible_to -> ~>,
  -- RefOf/ValueOf/CharLike/..., invocable -> ~(...)). Before the generic loop.
  concepts(bufnr, row0, line)
  -- template headers -> compact `<...>` / `concept<...>` (drop template /
  -- typename / class, color the params); concept def lines drop `concept `.
  template_header(bufnr, row0, line)
  concept_def_line(bufnr, row0, line)
  -- `auto* const x` -> `const auto^ x` (pointer-const moved in front).
  const_pointer_reorder(bufnr, row0, line)
  -- ImGui assert macros -> their std spelling, grayed.
  imgui_asserts(bufnr, row0, line)
  -- CUDA runtime calls -> snake_case (cudaMalloc -> malloc); CUDA_CHECK -> `?`.
  cuda_idents(bufnr, row0, line)
  for _, alias in ipairs(ALIASES) do
    local keyword, replacement, hl = alias[1], alias[2], alias[3] or 'Comment'
    local start_pos = 1
    while true do
      local s, e = line:find(keyword, start_pos, true)
      if not s then
        break
      end
      local before = s > 1 and line:sub(s - 1, s - 1) or nil
      local after = e < #line and line:sub(e + 1, e + 1) or nil
      -- the templated static_assert<...> is handled above, not as `$sa`.
      local templated_sa = keyword == 'static_assert' and after == '<'
      if not is_word_char(before) and not is_word_char(after) and not in_string_or_comment(line, s - 1) and not templated_sa then
        if replacement == '' then
          -- hide entirely: conceal the keyword plus one trailing space (if any)
          -- so the following token doesn't shift, and inject nothing.
          local ec = (line:sub(e + 1, e + 1) == ' ') and e + 1 or e
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, { end_col = ec, conceal = '' })
        else
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
            end_col = e,
            conceal = '',
            virt_text = { { replacement, hl } },
            virt_text_pos = 'inline',
          })
        end
      end
      start_pos = e + 1
    end
  end

  -- Inject `mut` before a non-const reference return type (`-> T&`): the
  -- mutability can't be annotated in the return position. A const ref shows
  -- as bare `T&` (const is hidden), so the marker's presence is the
  -- mut/const distinction. Colored like the mut/mut_unchecked markers.
  local pre, ws = line:match '^(.-%->)(%s*)'
  if pre then
    local rtyp = line:sub(#pre + #ws + 1):gsub('%s*[{;].*$', ''):gsub('%s*$', '')
    if rtyp:match '&%s*$' and not rtyp:match '&&%s*$' and not rtyp:match '^const%f[%A]' then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, #pre + #ws, {
        virt_text = { { 'mut ', 'DansMarkerMut' } },
        virt_text_pos = 'inline',
      })
    end
  end

  -- Leading `auto` of a function declaration -> the green `def` (the look of the
  -- old `#define def auto`, without the macro). Conceal the 4-cell `auto`, inject
  -- the 3-cell `def`; arrow_align mirrors that -1 so trailing `->` stay aligned.
  -- Only a function-declarator's placeholder return type qualifies (fn_auto_col);
  -- locals, lambda autos, and param autos are left alone.
  local adc = fn_auto_col(bufnr, row0, line)
  if adc then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, adc, {
      end_col = adc + 4,
      conceal = '',
      virt_text = { { 'def', 'DansLambda' } },
      virt_text_pos = 'inline',
    })
  end

  -- Flip the function params: `type name` -> `name: type` (types blue, mut on
  -- non-const refs). arrow_align mirrors the rendered width via M.flip_params
  -- so the trailing `->` columns still line up. Skip a special-member line
  -- (a copy/move ctor collapsed to $copy/$move by special_members) -- flipping
  -- its `const X&` param would double-render on top of that.
  local sm_ok, sm = pcall(require, 'custom.dans_frontend_cpp.special_members')
  local fp = not (sm_ok and sm.covers(bufnr, row0)) and M.flip_params(line, bufnr, row0)
  -- A multi-line param list (one param per line) is invisible to flip_params, so
  -- fall back to flipping the single param that lives on this row.
  local edits = fp and fp.edits or M.flip_param_line(bufnr, row0, line)
  if edits then
    for _, ed in ipairs(edits) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, ed.s0, {
        end_col = ed.e0,
        conceal = '',
        virt_text = ed.chunks,
        virt_text_pos = 'inline',
      })
    end
  end

  -- Inject `mut` right after the param `)` of a non-const member function
  -- (where the trailing `const` would sit). Leading-space ` mut` so it reads
  -- `) mut ...` and always lands before any following token -- in particular
  -- before a `noexcept`, which is rendered as `$ne` at its own later column.
  local mcol = M.member_mut_col(line, bufnr, row0)
  if mcol then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, mcol, {
      virt_text = { { ' mut', 'DansMarkerMut' } },
      virt_text_pos = 'inline',
    })
  end

  -- C-style leading return type -> trailing `-> type` (and blank a return-type
  -- line a formatter split off above the declarator). Last, so on a non-const
  -- member the inferred ` mut` (injected just above) renders before the arrow:
  -- `poke(a: int) mut -> void`. Cheap gate first: a declarator line carries `(`,
  -- and a split-off return-type line is a bare run of type tokens -- everything
  -- else skips the treesitter query.
  if line:find('(', 1, true) or line:find(')', 1, true) or line:match '^%s*[%w_][%w_:<>,&%*%s]*$' then
    c_style_apply(bufnr, row0, line)
  end
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
  if not vu.module_enabled(bufnr, 'aliases') then
    return
  end

  -- skip.skip hides our inline aliases on every shared reveal row, so the
  -- virt_text would otherwise double up with raw text like
  -- `$scstatic_cast`), and on lines the view overlay already rewrites (it would
  -- orphan our alias to the end of the line).
  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    if not skip.skip(row0, line) then
      decorate_line(bufnr, row0, line)
    end
  end
end

-- Repaint just the given reveal-delta rows. Cross-row structure (parameter colon
-- targets, C-style function ownership, CUDA_CHECK boundaries) is changedtick-
-- keyed and indexed back to each owner row, so this produces the same extmarks as
-- a full refresh without rescanning every visible line on each j/k.
local function render_rows(bufnr, rows)
  if not (vim.api.nvim_buf_is_valid(bufnr) and vu.is_cpp(vim.bo[bufnr].filetype) and vu.module_enabled(bufnr, 'aliases')) then
    return
  end
  local skip = vu.make_skipper(bufnr)
  for _, row0 in ipairs(rows) do
    vim.api.nvim_buf_clear_namespace(bufnr, ns, row0, row0 + 1)
    local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
    if line and not skip.skip(row0, line) then
      decorate_line(bufnr, row0, line)
    end
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_aliases', { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(ev)
      multiline_colon_cache[ev.buf] = nil
      cuda_check_boundary_cache[ev.buf] = nil
      c_style_cache[ev.buf] = nil
    end,
  })
  vu.on_decorate(group, { 'FileType', 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI' }, refresh, function(buf, row)
    render_rows(buf, { row })
  end)
end

return M
