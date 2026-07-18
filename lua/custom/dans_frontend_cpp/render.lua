-- Chunk building for the dans-cpp-frontend declaration view: turn a parsed declaration line
-- into the list of { text, highlight } pieces the overlay draws. Depends on
-- parse for the structural analysis; holds the render-side config (the
-- lambda-as-function rendering toggle and the cosmetic separators).

local P = require 'custom.dans_frontend_cpp.parse'
local style = require 'custom.dans_frontend_cpp.style'

local M = {}

local function exact_std_start(text, start1)
  if start1 == #'std::' + 1 then
    return true
  end
  local std_start = start1 - #'std::'
  return std_start >= 3
    and text:sub(std_start - 2, std_start - 1) == '::'
    and (std_start == 3 or not text:sub(std_start - 3, std_start - 3):match '[%w_:]')
end

-- Experimental: render a lambda-assigned-to-auto as a function-style decl,
--   const auto f = [&c](int x) -> R   ->   lambda f(c& | x: int) -> R
-- args flip like function params (shared aliases.flip_param), and `|` divides the
-- captures from the params, shown only when the lambda captures (a non-capturing
-- lambda reads as a plain nested function). Intro line only; the body keeps its
-- own indentation. Toggle :DansFrontend lambda.
local lambda_render = true
local LAMBDA_KEYWORD = 'lambda'
-- Divider between a lambda's capture list and its params -- shown iff the lambda
-- captures, so it marks closure state: `lambda f(a& | x: int)`, capture-only
-- `lambda f(& |)`, non-capturing `lambda f(x: int)` (reads as a nested function).
local LAMBDA_CAP_SEP = '|'
-- Range-for binding sigil position: true -> `vertex&` (after the name), false ->
-- `&vertex` (before it). const is hidden; a non-const binding shows `mut`.
local FOR_REF_SUFFIX = true

-- Marker word -> highlight group, shared with markers.lua. Only `cpy` can
-- still appear as a real prefix (mut/mut_unchecked are source-removed), but the
-- mut entries stay so an inferred-mut prefix colors correctly.
local MARKER_HL = {
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
  cpy = 'DansMarkerCpy',
}

-- Marker keywords that should pop wherever they appear in an expression
-- (e.g. `copy(x)` in a value), so the overlay matches the matchadd coloring on
-- real text.
local EXPR_MARKERS = {
  copy = 'DansMarkerMut', -- `copy` joins the mut/move/forward ownership red, not the cpy yellow
  cpy = 'DansMarkerCpy',
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
}

-- All-caps stdlib tokens that aren't user macros worth coloring -- left normal.
local MACRO_DENY = { FILE = true, SEEK_SET = true, SEEK_CUR = true, SEEK_END = true, EOF = true, NULL = true }

-- Single-word C++ aliases ($sc, $dc, ...) reused from aliases so casts in
-- frontend-rendered value expressions read the same as on non-overlaid lines. This
-- overlay conceals the whole source line, so aliases defers here (its inline
-- alias would be orphaned); without this the casts rendered verbatim. Built
-- lazily and cached from aliases.ALIASES, keeping only identifier-shaped
-- keywords (`[[nodiscard]]` is dropped -- it can't occur inside a value).
local expr_aliases_cache = nil
local function expr_aliases()
  if expr_aliases_cache then
    return expr_aliases_cache
  end
  local map = {}
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      if a[1]:match '^[%a_][%w_]*$' then
        map[a[1]] = { a[2], a[3] or 'Comment' } -- { replacement, highlight }
      end
    end
  end
  if next(map) then
    expr_aliases_cache = map
  end
  return map
end

-- Index of the `>` matching the `<` at 1-based `open` (nested `<>` balanced), or
-- nil. Used to bound a cast's template args.
local function match_angle(s, open)
  local depth = 0
  for j = open, #s do
    local c = s:sub(j, j)
    if c == '<' then
      depth = depth + 1
    elseif c == '>' then
      depth = depth - 1
      if depth == 0 then
        return j
      end
    end
  end
  return nil
end

-- Forward declaration: colorize (below) colors a CamelCase `Type::` qualifier by
-- its type color, and type_hl is defined further down.
local type_hl

-- Split `text` into chunks: string literals colored green (contents untouched),
-- namespace qualifiers grayed/hidden, cast keywords aliased, marker/Vk/SDL/macro
-- words colored. Mirrors the raw-line matchadd coloring inside the overlay.
local function colorize(text, bufnr)
  local out = {}
  local i, n = 1, #text
  -- A hidden namespace can carry a semantic color to the following qualified
  -- identifier.  This is currently used by qnpeps::; keeping it as state rather
  -- than a one-token regexp also handles qnpeps::detail::name without losing the
  -- provenance after the first segment.
  local qualified_hl
  while i <= n do
    local q = text:find('"', i, true)
    local s, e = text:find('[%a_][%w_]*', i)
    if q and (not s or q <= s) then
      -- String literal: emit the gap before it, then consume "..." (with escapes)
      -- as one green chunk so nothing inside gets recolored or concealed.
      if q > i then
        out[#out + 1] = { text:sub(i, q - 1), 'Normal' }
      end
      local j = q + 1
      while j <= n do
        local c = text:sub(j, j)
        if c == '\\' then
          j = j + 2
        elseif c == '"' then
          j = j + 1
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = { text:sub(q, j - 1), 'DansString' }
      i = j
    elseif s then
      if s > i then
        out[#out + 1] = { text:sub(i, s - 1), 'Normal' }
      end
      local word = text:sub(s, e)
      if text:sub(e + 1, e + 2) == '::' then
        if word == 'std' or word == 'dans' then
          -- std::/dans:: hidden; std::move / std::forward keep a red flag (the
          -- ownership-transfer points -- the source is left moved-from).
          local mv = word == 'std' and (text:match('^move%f[%W]', e + 3) or text:match('^forward%f[%W]', e + 3))
          if mv then
            out[#out + 1] = { mv, 'DansMarkerMut' }
            i = e + 3 + #mv
          else
            i = e + 3
            if word == 'std' then
              -- swallow std::ranges:: / std::ranges::views:: / std::views:: too,
              -- so ranges algorithms / views render at their bare name (matches
              -- the matchadd conceals on raw lines).
              while true do
                local seg = text:sub(i)
                local q2 = seg:match '^ranges::' or seg:match '^views::'
                if not q2 then
                  break
                end
                i = i + #q2
              end
            end
          end
        elseif word == 'qnpeps' then
          -- Namespace text is noise, but its information is not: hide qnpeps::
          -- and color the remaining qualified chain orchid.
          qualified_hl = 'DansQnpeps'
          i = e + 3
        elseif qualified_hl then
          out[#out + 1] = { P.strip_glfw(word), qualified_hl }
          out[#out + 1] = { '::', 'DansNamespace' }
          i = e + 3
        elseif word:match '^%u' then
          -- A type/class used as a qualifier (ApiVersion::vulkan(), VkResult::eFoo,
          -- SBTarget::...): it's a type, not namespace noise, so keep it in its type
          -- color (orange Vk, LLDB orange, blue user type); only the `::` is gray.
          out[#out + 1] = { P.strip_glfw(word), type_hl(word) }
          out[#out + 1] = { '::', 'DansNamespace' }
          i = e + 3
        else
          -- lowercase qualifier = a namespace: gray the whole thing.
          out[#out + 1] = { word .. '::', 'DansNamespace' }
          i = e + 3
        end
      else
        local alias = expr_aliases()[word]
        if qualified_hl then
          out[#out + 1] = { P.strip_glfw(word), qualified_hl }
          qualified_hl = nil
        elseif word == 'nullopt'
          and s > #'std::'
          and text:sub(s - #'std::', s - 1) == 'std::'
          and exact_std_start(text, s)
          and style.get(bufnr, 'nullopt_spelling') == 'empty_set'
        then
          out[#out + 1] = { '∅', style.optional_marker_hl(bufnr) }
        elseif alias then
          out[#out + 1] = { alias[1], alias[2] }
        elseif word:match '^VMA_' or word:match '^Vma' or word:match '^vma%u' then
          out[#out + 1] = { P.strip_glfw(word), 'DansVMA' } -- VMA prefix hidden, darker orange
        elseif word:match '^VKAPI_' then
          out[#out + 1] = { word, 'DansVulkan' } -- lib macro, full name, muted
        elseif word:match '^VK%u' or word:match '^vk_' then
          out[#out + 1] = { word, 'DansVulkanMine' } -- user's wrapper/var, not stripped, brighter
        elseif word:match '^Vk' or word:match '^VK_' or word:match '^vk%u' or word:match '^GL_' or word:match '^gl%u' then
          -- prefix hidden in the value too (VK_DEBUG_UTILS_X -> X), matching the
          -- raw-line conceal; strip_glfw leaves lowercase vk functions verbatim.
          out[#out + 1] = { P.strip_glfw(word), 'DansVulkan' }
        elseif word:match '^stb' or word:match '^STB' then
          out[#out + 1] = { word, 'DansSTB' } -- stb*/STB*, matches markers (not stripped)
        elseif word:match '^cblas_' or word:match '^CBLAS_' or word:match '^Cblas%u' or word:match '^openblas_' or word:match '^OPENBLAS_' or word:match '^lapacke?_' or word:match '^LAPACKE?_' or word == 'blasint' then
          out[#out + 1] = { word, 'DansBLAS' } -- BLAS/LAPACK family, full name kept
        elseif word:match '^cu%u' or word:match '^CU%l' or word:match '^CUDA_' then
          out[#out + 1] = { P.strip_glfw(word), 'DansCUDA' }
        elseif word:match '^Im%u' or word:match '^IM_' then
          out[#out + 1] = { P.strip_glfw(word), 'DansImGui' } -- imgui prefix hidden
        elseif word:match '^SDL_' or word:match '^GLFW' or word:match '^glfw%u' or word:match '^_GLFW' or word:match '^_glfw' then
          out[#out + 1] = { P.strip_glfw(word), 'DansSDL' } -- GLFW prefix hidden, SDL_ kept
        elseif word:match '^LLDB_' or word:match '^SB%u' or word == 'StateType' then
          out[#out + 1] = { word, 'DansLLDB' } -- LLDB_*/SB*/StateType, matches markers
        elseif word:match '^qnpeps_' or word:match '^QNPEPS_' or word:match '^Qnpeps' or word:match '^qn_' then
          out[#out + 1] = { P.strip_glfw(word), 'DansQnpeps' }
        elseif word:match '^[A-Z][A-Z0-9_]+$' and not MACRO_DENY[word] then
          out[#out + 1] = { word, 'DansMacro' } -- other all-caps macro
        else
          out[#out + 1] = { word, EXPR_MARKERS[word] or 'Normal' }
        end
        i = e + 1
        -- A cast's template args are a type, so every `*` inside is a pointer:
        -- emit it as a grayed `^`. The value path is otherwise blind to
        -- pointer-vs-multiply, but inside `_cast<...>` it's unambiguous.
        if alias and word:match '_cast$' and text:sub(i, i) == '<' then
          local close = match_angle(text, i)
          if close then
            out[#out + 1] = { '<', 'Normal' }
            local inner, pos = text:sub(i + 1, close - 1), 1
            while true do
              local star = inner:find('*', pos, true)
              if not star then
                vim.list_extend(out, colorize(inner:sub(pos), bufnr))
                break
              end
              if star > pos then
                vim.list_extend(out, colorize(inner:sub(pos, star - 1), bufnr))
              end
              out[#out + 1] = { '^', 'Normal' }
              pos = star + 1
            end
            out[#out + 1] = { '>', 'Normal' }
            i = close + 1
          end
        end
      end
    else
      out[#out + 1] = { text:sub(i), 'Normal' }
      break
    end
  end
  return out
end

-- Whether the type has a pointer/reference declarator at top level (`Foo^`,
-- `Foo&`), as opposed to a `^`/`&` buried in template args (`pair<int&, V>`,
-- `function<void(int&)>`) which does NOT make the variable a pointer/reference.
-- Drives the const/mut marking on the type, so it must not be fooled by nesting.
local function top_level_ptr_ref(t)
  local depth = 0
  for i = 1, #t do
    local c = t:sub(i, i)
    if c == '<' or c == '(' or c == '[' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' then
      depth = depth - 1
    elseif (c == '^' or c == '&') and depth == 0 then
      return true
    end
  end
  return false
end

-- The top-level sigils separately (caret, amp): the mut rule distinguishes
-- them -- a reference is a mutable borrow wherever it lives, but a pointer
-- MEMBER is plain struct data, so only pointer locals/globals read as mut.
local function top_level_sigils(t)
  local depth, caret, amp = 0, false, false
  for i = 1, #t do
    local c = t:sub(i, i)
    if c == '<' or c == '(' or c == '[' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' then
      depth = depth - 1
    elseif depth == 0 then
      if c == '^' then
        caret = true
      elseif c == '&' then
        amp = true
      end
    end
  end
  return caret, amp
end

-- Highlight for a type in declaration position: Vulkan types (Vk*/VK_*) keep
-- their purple even here, so a type doesn't flip blue<->purple as the cursor
-- enters/leaves its line; everything else is the blue inlay-type color.
function type_hl(t)
  -- Qualifiers are presentation modifiers, not provenance. Classify the
  -- underlying type so `const cuFloatComplex*` stays CUDA-colored just like
  -- `cuFloatComplex&`, and `const VkFoo*` stays Vulkan-colored.
  t = vim.trim(t:gsub('^const%s+', ''):gsub('^volatile%s+', ''))
  if t:sub(1, 7) == '::std::' then
    t = t:sub(8)
  elseif t:sub(1, 5) == 'std::' then
    t = t:sub(6)
  elseif t:sub(1, 6) == 'dans::' then
    t = t:sub(7)
  end
  -- std::string (-> stripped to `string`, with an optional &/^ suffix) reads as
  -- a string: the "..."-literal green, matching the raw-line matchadd.
  if t:match '^string[&^]?$' then
    return 'DansString'
  end
  if t:match '^VMA_' or t:match '^Vma' then
    return 'DansVMA'
  end
  if t:match '^VKAPI_' then
    return 'DansVulkan' -- lib macro, full name kept (not a first-party wrapper)
  end
  if t:match '^VK%u' or t:match '^vk_' then
    return 'DansVulkanMine' -- the user's wrapper type / raw-vk var, brighter
  end
  if t:match '^Vk' or t:match '^VK_' or t:match '^GL_' then
    return 'DansVulkan'
  end
  if t:match '^SDL_' or t:match '^GLFW' or t:match '^_GLFW' or t:match '^_glfw' then
    return 'DansSDL'
  end
  if t:match '^stb' or t:match '^STB' then
    return 'DansSTB'
  end
  if t:match '^cu%u' or t:match '^CU%l' or t:match '^cuda%u' or t:match '^CUDA_' then
    return 'DansCUDA'
  end
  if
    t:match '^cublas'
    or t:match '^cusolver'
    or t:match '^cusparse'
    or t:match '^cufft'
    or t:match '^CUBLAS_'
    or t:match '^CUSOLVER_'
    or t:match '^CUSPARSE_'
    or t:match '^CUFFT_'
  then
    return 'DansCUBLAS'
  end
  if t:match '^cblas_' or t:match '^CBLAS_' or t:match '^Cblas%u' or t:match '^openblas_' or t:match '^OPENBLAS_' or t:match '^lapacke?_' or t:match '^LAPACKE?_' or t:match '^blasint' then
    return 'DansBLAS'
  end
  if t:match '^qnpeps::' or t:match '^qnpeps_' or t:match '^QNPEPS_' or t:match '^Qnpeps' or t:match '^qn_' then
    return 'DansQnpeps'
  end
  if t:match '^Im%u' or t:match '^IM_' then
    return 'DansImGui'
  end
  if t:match '^LLDB_' or t:match '^SB%u' or t == 'StateType' then
    return 'DansLLDB'
  end
  return 'DansInlayType'
end

-- A type token that reads as a string: std::string / string_view, the C-string
-- CString, the gsl `*zstring` aliases (zstring/czstring/wzstring/cwzstring/
-- u16zstring/.../basic_zstring), and the CamelCase string types -- the z-string
-- family (ZString / CZString / ...) and FString / CFString (Unreal / CoreFoundation).
-- Whole-word only, so string_view IS one but u32string / MyString / MyCString are not.
local function is_string_type(w)
  return w == 'string'
    or w == 'string_view'
    or w == 'CString'
    or w == 'basic_zstring'
    or w:match '^[cwu0-9]*zstring$' ~= nil
    or w:match '^%u*[ZF]String$' ~= nil
end

-- Split a (caret-free) type segment so each whole-word string-type token is green
-- (DansString) and the rest keeps `base_hl`: a nested `std::string` / `string_view`
-- / `const char*` inside a template (`vector<string>`, `span<czstring>`) reads as a
-- string just like a standalone one, mirroring the raw-line matchadds. When
-- `base_hl` is already DansString (the whole type IS the string, e.g. `string&`)
-- the segment is returned whole -- splitting would fracture an already-right chunk.
local function string_token_chunks(text, base_hl)
  if base_hl == 'DansString' then
    return { { text, base_hl } }
  end
  -- coalesce runs of non-string text (punctuation + non-string words) into one
  -- base_hl chunk, so e.g. `vector<` stays a single chunk and only the string
  -- token is split out.
  local out, run, i, n = {}, {}, 1, #text
  local function flush()
    if #run > 0 then
      out[#out + 1] = { table.concat(run), base_hl }
      run = {}
    end
  end
  while i <= n do
    local s, e = text:find('[%w_]+', i)
    if not s then
      run[#run + 1] = text:sub(i)
      break
    end
    if s > i then
      run[#run + 1] = text:sub(i, s - 1)
    end
    local word = text:sub(s, e)
    if is_string_type(word) then
      flush()
      out[#out + 1] = { word, 'DansString' }
    else
      run[#run + 1] = word
    end
    i = e + 1
  end
  flush()
  return out
end

-- Render a type string into { text, hl } chunks for virt_text *outside* the
-- overlay (the trailing-return reorder): strip_type cleans it (std::/dans::,
-- optional->?, *->^), semantic optional markers use the selected buffer-local
-- accent, and type_hl colors the rest. A nested whole-word `string` is greened via
-- string_token_chunks (same as the overlay's add_type). Exposed for the pointer
-- module.
function M.type_chunks(t, bufnr)
  local segments, semantic = P.type_segments(t)
  local out = {}
  local function push(text, hl)
    local last = out[#out]
    if last and last[2] == hl then
      last[1] = last[1] .. text
    else
      out[#out + 1] = { text, hl }
    end
  end
  local active_hl = 'DansInlayType'
  local weak_tail
  for _, item in ipairs(segments) do
    if item.role == 'type' then
      active_hl = type_hl(item.source or item.text)
      for _, chunk in ipairs(string_token_chunks(P.strip_glfw(item.text), active_hl)) do
        push(chunk[1], chunk[2])
      end
    elseif item.role == 'const' then
      push(item.text, 'DansConst')
    elseif item.role == 'unique_marker' then
      push(item.text, 'DansMarkerMut')
    elseif item.role == 'shared_marker' then
      push(item.text, 'DansMarkerCpy')
    elseif item.role == 'weak_marker' then
      local head, tail = style.weak_pointer_parts(bufnr)
      push(head, 'DansConst')
      weak_tail = tail
    elseif item.role == 'optional_marker' then
      push(weak_tail or item.text, style.optional_marker_hl(bufnr, active_hl))
      weak_tail = nil
    elseif item.role == 'pointer' then
      out[#out + 1] = { item.text, active_hl }
    elseif item.role == 'reference' then
      push(item.text, active_hl)
    else
      push(item.text, active_hl)
    end
  end
  return out, semantic
end

-- Whether `cond` references `name` as a whole identifier (so the condition
-- tests the binding: `res`, `res.has_value()`, `res != end()`, `res == 0`).
local function checks_binding(cond, name)
  local from = 1
  while true do
    local a, b = cond:find(name, from, true)
    if not a then
      return false
    end
    local before = a > 1 and cond:sub(a - 1, a - 1) or ''
    local after = cond:sub(b + 1, b + 1)
    if not before:match '[%w_]' and not after:match '[%w_]' then
      return true
    end
    from = b + 1
  end
end

-- Whether `cond` has a top-level boolean operator (`&&` / `||` / `and` / `or`
-- outside any parens). Such a condition welds the binding check to another term
-- -- `res.has_value() && ready` -- one operand of which may be independent of
-- the binding, so the if-let render keeps it visible rather than dropping it.
local function compound_cond(cond)
  local depth = 0
  local i, n = 1, #cond
  while i <= n do
    local c = cond:sub(i, i)
    if c == '(' or c == '[' or c == '{' then
      depth = depth + 1
      i = i + 1
    elseif c == ')' or c == ']' or c == '}' then
      depth = depth - 1
      i = i + 1
    elseif depth == 0 and (cond:sub(i, i + 1) == '&&' or cond:sub(i, i + 1) == '||') then
      return true
    elseif c:match '[%a_]' then
      local s, e = cond:find('^[%w_]+', i)
      if depth == 0 and (cond:sub(s, e) == 'and' or cond:sub(s, e) == 'or') then
        return true
      end
      i = e + 1
    else
      i = i + 1
    end
  end
  return false
end

-- Build the virt_text chunk list for a parsed declaration, or nil if `core`
-- isn't a recognized declaration form. `align` (optional) is { nw, tw } column
-- widths to pad the name/type to. `was_const` + (bufnr,row0) drive the inferred
-- `mut` on non-const locals.
-- DEFER([cap] { body }); / DANS_DEFER(...) -> Odin-style `defer`. Both macro
-- spellings represent the same lambda-backed facility in the owner's projects.
-- A single statement renders inline (`defer body;`); a multi-statement body keeps
-- braces. A multi-line invocation is handled per line so the line count is
-- preserved: its opener becomes `defer {`, and the matching `});` becomes `}`
-- after Tree-sitter confirms the call owner. `defer` is green like `lambda`.
local DEFER_MACROS = { 'DANS_DEFER', 'DEFER' }
local function defer_chunks(core, had_semi, bufnr, row0)
  local brace
  for _, macro in ipairs(DEFER_MACROS) do
    brace = core:match('^' .. macro .. '%s*%(%s*%b[]%s*(%b{})%s*%)%s*$')
    if brace then
      break
    end
  end
  if brace and had_semi then
    local inner = vim.trim(brace:sub(2, -2))
    local chunks = { { 'defer ', 'DansLambda' } }
    local function addv(text)
      for _, c in ipairs(colorize(text, bufnr)) do
        chunks[#chunks + 1] = c
      end
    end
    if inner:gsub(';%s*$', ''):find ';' then
      chunks[#chunks + 1] = { '{ ', 'Normal' }
      addv(inner)
      chunks[#chunks + 1] = { ' }', 'Normal' }
    else
      addv(inner)
    end
    return chunks
  end
  for _, macro in ipairs(DEFER_MACROS) do
    if core:match('^' .. macro .. '%s*%(%s*%b[]%s*{%s*$') then
      return { { 'defer ', 'DansLambda' }, { '{', 'Normal' } }
    end
  end
  if had_semi and core:match '^}%s*%)%s*$' and P.defer_close(bufnr, row0) then
    return { { '}', 'Normal' } }
  end
  return nil
end

-- Top-level comma split (depth-aware over <> () [] {}) for lambda capture / param
-- lists.
local function split_commas(s)
  local out, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '<' or c == '(' or c == '[' or c == '{' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' or c == '}' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      out[#out + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  out[#out + 1] = s:sub(start)
  return out
end

-- Render a lambda capture list (the text inside `[...]`) to chunks. A by-ref
-- capture of a simple name flips the `&` to a suffix (`&bs` -> `bs&`), matching the
-- param ref style; everything else (by-value name, `=`, `&`, `this`, an init
-- capture) is colorized verbatim.
local function lambda_capture_chunks(cap, bufnr)
  local out = {}
  if not cap or vim.trim(cap) == '' then
    return out
  end
  local first = true
  for _, c in ipairs(split_commas(cap)) do
    local t = vim.trim(c)
    if t ~= '' then
      if not first then
        out[#out + 1] = { ', ', 'Normal' }
      end
      first = false
      local refname = t:match '^&%s*([%w_]+)$'
      if refname then
        out[#out + 1] = { refname, 'Normal' }
        out[#out + 1] = { '&', 'Normal' }
      else
        for _, cc in ipairs(colorize(t, bufnr)) do
          out[#out + 1] = cc
        end
      end
    end
  end
  return out
end

-- Render a lambda param list (inside `(...)`) to chunks, one per param via the
-- shared function-param flip (aliases.flip_param) so lambda and function args read
-- identically: `int x` -> `x: int`, `const auto& a` -> `a&`, `auto& a` -> `mut a&`.
-- An unparseable param is colorized verbatim.
local function lambda_param_chunks(params, bufnr)
  local out = {}
  if not params or vim.trim(params) == '' then
    return out
  end
  local ok, A = pcall(require, 'custom.dans_frontend_cpp.aliases')
  local first = true
  for _, p in ipairs(split_commas(params)) do
    local t = vim.trim(p)
    if t ~= '' then
      if not first then
        out[#out + 1] = { ', ', 'Normal' }
      end
      first = false
      local pc = ok and A.flip_param(t, bufnr) or nil
      if pc then
        for _, c in ipairs(pc) do
          out[#out + 1] = c
        end
      else
        for _, c in ipairs(colorize(t, bufnr)) do
          out[#out + 1] = c
        end
      end
    end
  end
  return out
end

local function build_chunks(prefix, core, had_semi, type_hint, align, was_const, is_constexpr, bufnr, row0)
  local dc = defer_chunks(core, had_semi, bufnr, row0)
  if dc then
    return dc
  end
  -- Function-declaration-shaped lines (`bool f(args)`, and the most-vexing-parse
  -- `vector<T> v(n)` the grammar reads the same way) render raw -- bail so they
  -- aren't mangled into a `name: T(args)` paren-init variable.
  if P.classic_function(bufnr, row0) then
    return nil
  end
  local semi = had_semi and ';' or ''
  -- Lazy (treesitter): only the branches that infer mut pay for it, and only on
  -- lines that actually render (non-decls return before reaching a branch).
  local _local
  local function is_local()
    if _local == nil then
      _local = P.decl_kind(bufnr, row0) == 'local'
    end
    return _local
  end

  local forp = P.parse_for(core)
  local iflet = P.parse_if_let(core)

  -- structured binding: auto [a, b] = expr  ->  a, b := expr (no per-element
  -- type hints; clangd's binding hints aren't reliable enough).
  local sb_sigil, sb_binds, sb_expr = core:match '^auto([&*]?)%s*%[(.-)%]%s*=%s*(.+)$'

  local sigil, name, expr = core:match '^auto([&*]?)%s+([%w_]+)%s*=%s*(.+)$'
  -- `auto operator==(...)` / `auto operator=(...)` are operator declarations, not
  -- an `auto operator = ...` binding -- the `==`/`=` in the operator name fooled
  -- the match. Drop it so they fall through and render raw (trailing functions).
  if name == 'operator' then
    name = nil
  end
  local typ, nm, init, paren, no_init
  if not forp and not iflet and not sb_binds and not name then
    typ, nm, init = core:match '^(.-)%s+([%w_]+)%s*{(.*)}$'
    -- A brace-init declaration is a terminated statement; require the `;`.
    -- Without it this is a continuation / constructor temporary in an argument
    -- list (e.g. `local_ray, Aabb{.min = a}`), where `local_ray,` is not a type.
    if not (nm and had_semi and P.looks_like_type(typ)) then
      -- copy-list-init `T name = {init}` (incl. CTAD `std::array x = {a, b}`):
      -- the braces are kept, rendering `name: T = {init}`.
      local btyp, bnm, binit = core:match '^(.-)%s+([%w_]+)%s*=%s*({.*})$'
      if btyp and bnm and had_semi and P.looks_like_type(btyp) then
        typ, nm, init = btyp, bnm, binit
      else
        -- Copy-initialized explicit declaration: `T name = expr`. This is the
        -- explicit-type counterpart of the auto-binding path and is especially
        -- common for CUDA pointers (`cuFloatComplex* a = byte_offset<...>()`).
        local etyp, enm, einit = core:match '^(.-)%s+([%w_]+)%s*=%s*(.+)$'
        local _, semantic_type = P.type_segments(etyp or '')
        if etyp
          and enm ~= 'operator'
          and had_semi
          and not etyp:match '^auto[&*]'
          and P.looks_like_type(etyp)
          and P.decl_kind(bufnr, row0) ~= nil
          and (etyp:match '[&*]%s*$' or semantic_type)
          and not einit:match ',%s*[%w_]+%s*='
        then
          typ, nm, init = etyp, enm, einit
        else
        -- paren-init `T name(args)` (ctor call), kept as `name: T(args)` since paren
        -- and brace init differ in meaning. The most-vexing-parse (function decl vs
        -- variable) is semantic, so only accept args that look like a value.
        local ptyp, pnm, pargs = core:match '^(.-)%s+([%w_]+)%s*%((.+)%)$'
        if ptyp and pnm and had_semi and P.looks_like_type(ptyp) and (pargs:find('[%.%d(]') or pargs:find('::')) then
          typ, nm, init, paren = ptyp, pnm, nil, pargs
        else
          -- No-brace reference/pointer member: `T& name` / `T* name` (a struct
          -- reference can't be brace-defaulted). The sigil must touch the type, so
          -- bitwise/multiply statements like `a & b;` aren't grabbed.
          typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
          init = ''
          if typ and nm and had_semi and P.looks_like_type(typ) then
            -- a pointer member with no initializer holds garbage -> flag no_init
            -- (even `const T*`: the const is on the pointee, the pointer is still
            -- uninitialized). A reference member is bound in the ctor init-list, so
            -- it's never flagged.
            local sigil = typ:match '([&*]+)%s*$'
            if sigil and sigil:sub(-1) == '*' then
              no_init = true
            end
          else
            -- bare value decl with no initializer (`Type name;`): the value is
            -- indeterminate (no `{}` default-init), so render `name: T` plus a red
            -- `no_init` marker. Array types additionally take the Odin `[N]T` form.
            -- decl_kind gates to a real declaration (member/global), so a statement
            -- like `return x;` is never grabbed. const decls aren't "garbage" -- a
            -- const member is ctor-initialized -- so those stay raw. A bare LOCAL
            -- stays raw too (the deferred-init idiom: declare, then fill in a
            -- branch); only arrays render at every scope.
            local vtyp, vnm = core:match '^(.-)%s+([%w_]+)$'
            if vtyp and vnm and had_semi and P.looks_like_type(vtyp) then
              local is_array = P.strip_type(vtyp):match '^%[' ~= nil
              local kind = P.decl_kind(bufnr, row0)
              if is_array or ((kind == 'member' or kind == 'global') and not was_const) then
                typ, nm, no_init = vtyp, vnm, not was_const
              else
                return nil
              end
            else
              return nil
            end
          end
        end
        end
      end
    end
  end

  local chunks = {}
  local function add(text, hl)
    if text ~= '' then
      chunks[#chunks + 1] = { text, hl or 'Normal' }
    end
  end
  -- Append value text, coloring marker keywords inside it.
  local function add_value(text)
    for _, c in ipairs(colorize(text, bufnr)) do
      chunks[#chunks + 1] = c
    end
  end
  local function add_type(t)
    for _, chunk in ipairs(M.type_chunks(t, bufnr)) do
      add(chunk[1], chunk[2])
    end
  end

  if prefix ~= '' then
    add(prefix, MARKER_HL[prefix:match '^(%S+)'] or 'Normal')
  end

  if iflet then
    -- if (auto x = e; COND)  ->  if let x := e. Drop COND only when it's a
    -- *simple* check on the binding -- it names x and has no top-level && / ||
    -- (`x`, `x.has_value()`, `x != end()`, `x == 0`). A compound COND
    -- (`x.has_value() && ready`) or one that never names x is kept after `;`.
    add 'if let '
    add(iflet.name)
    add ' := '
    add_value(iflet.rhs)
    local simple_check = checks_binding(iflet.cond, iflet.name) and not compound_cond(iflet.cond)
    if not simple_check then
      add '; '
      add_value(iflet.cond)
    end
    if iflet.tail ~= '' then
      add(' ' .. iflet.tail)
    end
  elseif forp then
    add 'for ('
    if not forp.is_const then
      add('mut ', 'DansMarkerMut')
    end
    if FOR_REF_SUFFIX then
      add(forp.name)
      add(P.ptr(forp.sigil))
    else
      add(P.ptr(forp.sigil))
      add(forp.name)
    end
    add ' : '
    add_value(forp.iter)
    add ')'
    if forp.tail ~= '' then
      add(' ' .. forp.tail)
    end
  elseif sb_binds then
    if not P.is_balanced(sb_expr) then
      return nil
    end
    if is_local() and not was_const then
      add('mut ', 'DansMarkerMut')
    end
    if sb_sigil == '&' then
      -- ref structured binding: every name binds a reference, so suffix each
      -- (`[a, b]` -> `a&, b&`), not just the last.
      local first = true
      for nm in sb_binds:gmatch '[^,]+' do
        if not first then
          add ', '
        end
        add(vim.trim(nm))
        add '&'
        first = false
      end
    else
      add(sb_binds)
    end
    add(' := ')
    add_value(sb_expr)
    add(semi)
  elseif name then
    local cap, params, rest = P.parse_lambda(expr)
    if lambda_render and cap ~= nil and P.is_iife(bufnr, row0) then
      -- IIFE: `auto x = [&]() -> T {...}()`. x is the *result* (type T), not a
      -- lambda. Render the multi-line intro as `x: T =` (body + }(); stay raw).
      -- Single-line/deduced-return IIFEs have their body on this line, so leave
      -- them raw rather than truncate.
      local rettype = rest and rest:match '^%->%s*(.+)$'
      if not rettype then
        return nil
      end
      if is_local() and not was_const then
        add('mut ', 'DansMarkerMut')
      end
      add(name .. ': ')
      add_type(rettype)
      add ' ='
    elseif lambda_render and cap ~= nil then
      add(LAMBDA_KEYWORD .. ' ', 'DansLambda')
      add(name)
      add '('
      local cap_chunks = lambda_capture_chunks(cap, bufnr)
      local param_chunks = lambda_param_chunks(params, bufnr)
      local has_params = #param_chunks > 0
      if #cap_chunks > 0 then
        -- Captures present: render them, the `|` boundary (the marker of closure
        -- state), then the params. A non-capturing lambda emits no `|` and reads as
        -- a plain nested function `lambda f(x: int)`.
        for _, c in ipairs(cap_chunks) do
          add(c[1], c[2])
        end
        -- ` | ` between captures and params; capture-only gets a tight `|` (nothing
        -- follows, so no surrounding space): `(a& | x: int)` vs `(&|)`.
        add(has_params and (' ' .. LAMBDA_CAP_SEP .. ' ') or LAMBDA_CAP_SEP)
      end
      for _, c in ipairs(param_chunks) do
        add(c[1], c[2])
      end
      add ')'
      if rest ~= nil and rest ~= '' then
        add ' '
        add_value(rest)
      end
      add(semi)
    elseif not P.is_balanced(expr) then
      return nil -- incomplete RHS (multi-line opener), leave raw
    else
      -- non-const local -> inferred mut. A run of consecutive auto bindings aligns
      -- its `:=` (compute_align): the binding's mut sits in a left column, blank-
      -- reserved on a const line when a sibling is mut, and the name is padded to the
      -- run's widest.
      if is_local() and not was_const then
        add('mut ', 'DansMarkerMut')
      elseif align and align.auto and align.has_mut then
        add '    ' -- blank mut column, so names align under their mut siblings
      end
      if type_hint and name ~= '_' then
        add(name .. ': ')
        add_type(P.ptr(type_hint))
        add ' = '
        add_value(expr)
        add(semi)
      else
        -- Ref/pointer binding: a sigil suffix on the name (`&` for a reference,
        -- `^` for `auto*` -- P.ptr maps `*`->`^`), matching the range-for `v&` /
        -- `p^` style rather than a `ref` keyword or gluing it to the value. A
        -- plain `auto` value binding has no sigil.
        add(name)
        if sigil ~= '' then
          add(P.ptr(sigil))
        end
        if align and align.auto then
          add(string.rep(' ', math.max(0, align.nw - (vim.fn.strwidth(name) + (sigil ~= '' and 1 or 0)))))
        end
        add(' := ')
        add_value(expr)
        add(semi)
      end
    end
  else
    -- Explicit type: colored the same blue as the deduced hints (DansInlayType);
    -- written and deduced types are treated alike. std:: stripped. `constexpr`
    -- becomes Odin's constant binding -- `name: T : value` (a `:` in place of the
    -- `=`), since `::` / `: T :` is how frontend spells a compile-time constant.
    local shown_typ = P.strip_type(typ)
    -- `const char*` is an immutable C string: render it as a single green
    -- `CString` token, dropping the const, the `^` caret, and any mut marker.
    -- split_markers already peeled the leading const (was_const) so the type
    -- arrives here as `char^` (strip_type mapped `*`->`^`).
    -- `const char*` -> CString; `const char**` -> CString^ (inner level becomes
    -- CString, outer pointer level(s) stay as caret(s)).
    local cstring_carets = was_const and shown_typ:match '^char(%^+)$' or nil
    local is_cstring = cstring_carets ~= nil
    local _, smart_kind = P.smart_ptr(typ)
    local disp_typ
    if is_cstring then
      disp_typ = 'CString' .. cstring_carets:sub(2)
    else
      disp_typ = shown_typ
    end
    -- The binding's own mutability sits in a left `mut` column, before the name --
    -- a non-const local value, a non-const reference anywhere, or a non-const
    -- pointer OUTSIDE a struct is `mut`; a pointer MEMBER is plain data, so it
    -- stays unmarked. An uninitialized one is `no_init`; in an aligned block the
    -- others get a blank column so names line up. The pointee/referent const
    -- (`const T^`) is part of the TYPE, so it stays after the colon with the type.
    local tl_caret, tl_amp = top_level_sigils(shown_typ)
    local is_mut = not is_cstring
      and not smart_kind
      and not was_const
      and not is_constexpr
      and not no_init
      and (tl_amp or (tl_caret and P.decl_kind(bufnr, row0) ~= 'member') or is_local())
    if no_init then
      add('no_init ', 'DansMarkerMut')
    elseif is_mut then
      add('mut ', 'DansMarkerMut')
    elseif align and align.has_mut then
      add '    ' -- blank mut column, so names align under their mut siblings
    end
    add(nm)
    if align then
      add(string.rep(' ', math.max(0, align.nw - vim.fn.strwidth(nm))))
    end
    add ': '
    if is_cstring then
      add('CString', 'DansString')
      if #cstring_carets > 1 then
        add(cstring_carets:sub(2), 'Normal') -- outer pointer level(s)
      end
    else
      -- pointee/referent const is part of the type (`const T^`), colored like it.
      if top_level_ptr_ref(shown_typ) and was_const then
        add('const ', type_hl(shown_typ))
      end
      add_type(typ)
    end
    if paren then
      -- paren-init `T name(args)`: keep the parens (ctor call, not assignment).
      add '('
      add_value(paren)
      add ')'
    elseif init ~= '' then
      -- Pad the type only when there's an initializer, so the `=` aligns across
      -- the block; a no-init line's `;` stays at its natural end position.
      if align then
        add(string.rep(' ', math.max(0, align.tw - vim.fn.strwidth(disp_typ))))
      end
      add(is_constexpr and ' : ' or ' = ')
      local dpairs = P.designated_pairs(init)
      if dpairs then
        -- aggregate designated init: fold each `.field = value` like cpp_designated
        -- does on raw lines -- `field=value`, or just `field` when the value's last
        -- access already matches the field (`.center = cfg.center` -> `center`).
        for i, p in ipairs(dpairs) do
          if i > 1 then
            add ', '
          end
          add(p.field, 'DansHint')
          if not P.field_eq(P.access_tail(p.value), p.field) then
            add '='
            add_value(p.value)
          end
        end
      else
        add_value(init)
      end
    end
    add(semi)
  end

  return chunks
end

-- Returns (start_col, chunks) for the overlay, or nil if the line isn't a
-- transformable declaration. `type_hint` is the deduced type for this line.
function M.render_line(line, type_hint, align, bufnr, row0)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  -- A line ending in a line-continuation `\` is a macro body, not a standalone
  -- declaration; the overlay can't represent the continuation, so leave it to
  -- macro_def (which unwraps the do/while(0) block and owns those rows).
  if body:match '\\%s*$' then
    return nil
  end
  -- Peel a trailing line comment so it doesn't defeat the `;` / `}` end anchors
  -- in build_chunks; it's re-appended to the overlay so it stays visible.
  local code, cws, comment = body:match '^(.-)(%s*)(//.*)$'
  if not code then
    code, cws, comment = body, '', ''
  end
  local had_semi = code:match ';%s*$' ~= nil
  local core_in = (code:gsub(';%s*$', ''))
  -- split_markers peels and reports const/constexpr (both hidden; const-ness
  -- suppresses the inferred mut, constexpr also renders as a `:` constant binding).
  local prefix, core, was_const, is_constexpr = P.split_markers(core_in)
  local chunks = build_chunks(prefix, core, had_semi, type_hint, align, was_const, is_constexpr, bufnr, row0)
  if not chunks then
    return nil
  end
  if comment ~= '' then
    chunks[#chunks + 1] = { cws .. comment, 'Comment' }
  end
  return #indent, chunks
end

-- Flip the lambda-as-function rendering; returns the new state. view owns
-- the user command and re-renders open buffers.
function M.toggle_lambda()
  lambda_render = not lambda_render
  return lambda_render
end

function M.lambda_enabled()
  return lambda_render
end

-- LCS alignment of two strings: 0-based map from an index in `a` to the index in
-- `b` it aligns to (nil where `a`'s char has no match). Used to find where a raw
-- buffer column landed in the overlay's rendered text, so the scope highlighter can
-- color the bracket you SEE (the overlay's) rather than the concealed raw one. The
-- two strings are one screen line each, so the O(n*m) table is small.
local function align_lcs(a, b)
  local n, m = #a, #b
  if n == 0 or m == 0 then
    return {}
  end
  local dp = {}
  for i = 0, n do
    dp[i] = {}
    dp[i][0] = 0
  end
  for j = 0, m do
    dp[0][j] = 0
  end
  for i = 1, n do
    local ai = a:sub(i, i)
    for j = 1, m do
      if ai == b:sub(j, j) then
        dp[i][j] = dp[i - 1][j - 1] + 1
      elseif dp[i - 1][j] >= dp[i][j - 1] then
        dp[i][j] = dp[i - 1][j]
      else
        dp[i][j] = dp[i][j - 1]
      end
    end
  end
  local map, i, j = {}, n, m
  while i > 0 and j > 0 do
    if a:sub(i, i) == b:sub(j, j) and dp[i][j] == dp[i - 1][j - 1] + 1 then
      map[i - 1] = j - 1
      i, j = i - 1, j - 1
    elseif dp[i - 1][j] >= dp[i][j - 1] then
      i = i - 1
    else
      j = j - 1
    end
  end
  return map
end

-- Recolor the rendered `chunks` so each scope mark lands on the displayed bracket.
-- `marks` = { { col = raw 0-based buffer column, hl = group } }. Aligns the raw code
-- (after the indent) to the displayed text, maps each mark's column to a display
-- position, and -- only when that position is actually a bracket -- splits the
-- covering chunk to recolor that one character. Returns the (possibly new) chunks;
-- a mark whose bracket was transformed away by the overlay simply doesn't apply.
function M.recolor(chunks, line, start_col, marks)
  if not chunks or not marks or #marks == 0 then
    return chunks
  end
  local parts = {}
  for _, c in ipairs(chunks) do
    parts[#parts + 1] = c[1]
  end
  local disp = table.concat(parts)
  local raw = line:sub(start_col + 1)
  local map = align_lcs(raw, disp)
  local targets = {} -- 0-based display index -> hl
  for _, mk in ipairs(marks) do
    local di = map[mk.col - start_col]
    if di and disp:sub(di + 1, di + 1):match '[%(%)%[%]{}]' then
      targets[di] = mk.hl
    end
  end
  if not next(targets) then
    return chunks
  end
  local out, pos = {}, 0
  for _, c in ipairs(chunks) do
    local text, hl, len = c[1], c[2], #c[1]
    local hit = false
    for di in pairs(targets) do
      if di >= pos and di < pos + len then
        hit = true
        break
      end
    end
    if not hit then
      out[#out + 1] = c
    else
      local seg = 1
      for k = 1, len do
        local g = targets[pos + (k - 1)]
        if g then
          if k > seg then
            out[#out + 1] = { text:sub(seg, k - 1), hl }
          end
          out[#out + 1] = { text:sub(k, k), g }
          seg = k + 1
        end
      end
      if seg <= len then
        out[#out + 1] = { text:sub(seg), hl }
      end
    end
    pos = pos + len
  end
  return out
end

-- Like recolor, but for column RANGES (a yank flash, an LSP reference highlight):
-- map each raw range to its displayed span and APPEND `hl` to the covered chunks
-- (the chunk's group becomes a list, so the original fg shows under the highlight's
-- bg). ranges = { { from, to, hl } }, 0-based inclusive raw buffer columns.
function M.recolor_ranges(chunks, line, start_col, ranges)
  if not chunks or not ranges or #ranges == 0 then
    return chunks
  end
  local parts = {}
  for _, c in ipairs(chunks) do
    parts[#parts + 1] = c[1]
  end
  local disp = table.concat(parts)
  local raw = line:sub(start_col + 1)
  local map = align_lcs(raw, disp)
  local add = {} -- 0-based display col -> hl
  for _, rg in ipairs(ranges) do
    if rg.from <= start_col and rg.to >= #line - 1 then
      -- Whole code line: flash the entire rendered text, including the injected and
      -- reordered tokens (the flipped type, the `mut`/`:` markers, the `=` alignment
      -- padding) that have no raw column to align to.
      for d = 0, #disp - 1 do
        add[d] = rg.hl
      end
    else
      local df, dt
      for c = rg.from, rg.to do
        local d = map[c - start_col]
        if d then
          df = df and math.min(df, d) or d
          dt = dt and math.max(dt, d) or d
        end
      end
      if df then
        for d = df, dt do
          add[d] = rg.hl
        end
      end
    end
  end
  if not next(add) then
    return chunks
  end
  local function combine(hl, g)
    if type(hl) == 'table' then
      return vim.list_extend(vim.deepcopy(hl), { g })
    end
    return { hl, g }
  end
  local out, pos = {}, 0
  for _, c in ipairs(chunks) do
    local text, hl, len = c[1], c[2], #c[1]
    if len == 0 then
      out[#out + 1] = c
    else
      local seg_start, seg_g = 1, add[pos]
      for k = 2, len do
        local g = add[pos + (k - 1)]
        if g ~= seg_g then
          local seg = text:sub(seg_start, k - 1)
          out[#out + 1] = seg_g and { seg, combine(hl, seg_g) } or { seg, hl }
          seg_start, seg_g = k, g
        end
      end
      local tail = text:sub(seg_start)
      out[#out + 1] = seg_g and { tail, combine(hl, seg_g) } or { tail, hl }
      pos = pos + len
    end
  end
  return out
end

return M
