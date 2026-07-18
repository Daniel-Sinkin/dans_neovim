-- Parsing and treesitter classification for the dans-cpp-frontend declaration view. Pure
-- analysis: from declaration text (and optionally a buffer position) it returns
-- structured data or measurements -- no rendering, no module state. Used by
-- render (chunk building) and view (alignment / reveal).

local M = {}

-- Render pointer *types* with `^` (Pascal/Odin style). Only in type positions
-- the overlay parses; `*` for multiply and deref in expressions is untouched.
local POINTER_CARET = true

local STMT_KEYWORDS = {
  ['return'] = true,
  ['if'] = true,
  ['else'] = true,
  ['for'] = true,
  ['while'] = true,
  ['switch'] = true,
  ['case'] = true,
  ['do'] = true,
  ['throw'] = true,
  ['delete'] = true,
  ['using'] = true,
  ['namespace'] = true,
  ['template'] = true,
  ['struct'] = true,
  ['class'] = true,
  ['enum'] = true,
  ['typedef'] = true,
  ['def'] = true,
  ['co_return'] = true,
  ['co_await'] = true,
  ['co_yield'] = true,
  ['static_assert'] = true,
  ['goto'] = true,
}

local MARKERS = { 'cpy' }

-- Peel leading attributes/markers. `const`/`constexpr`/`inline` are dropped, as
-- is `[[maybe_unused]]` (pure noise -- only its absence matters); `cpy` is kept
-- as a prefix. mut is never a literal in source -- it is inferred from non-const
-- in build_chunks and injected by the view.
-- Returns prefix, rest, is_const, is_constexpr. Leading cv/storage specifiers in
-- ANY order are peeled and hidden: const/constexpr drive the rendering
-- (const-ness hides const + suppresses the inferred mut; constexpr additionally
-- renders as a `:` constant binding); static/inline/thread_local/extern/constinit
-- are pure storage noise. `[[maybe_unused]]` is dropped (only matters when
-- missing); `cpy` is kept as a visible prefix.
-- Attribute-like leading modifiers dropped from the view (pure noise for the data
-- model; only their absence ever matters). A whitelist, not a guess -- a leading
-- macro/attribute NOT listed here stays part of the type, so add new ones here.
local DROPPED_ATTRS = {
  '%[%[maybe_unused%]%]',
  '%[%[no_unique_address%]%]',
  'DANS_NO_UNIQUE_ADDRESS',
}

function M.split_markers(s)
  local prefix = ''
  local rest = s
  local is_const, is_constexpr = false, false
  while true do
    local matched = false

    -- const must be tried before the storage group; constexpr before const so a
    -- bare `const ` (with trailing space) and `constexpr ` don't shadow it (they
    -- can't anyway -- `^const%s+` won't match `constexpr` -- but keep it clear).
    local after = rest:match '^constexpr%s+(.*)$'
    if after then
      rest, is_const, is_constexpr, matched = after, true, true, true
    end

    if not matched then
      after = rest:match '^const%s+(.*)$'
      if after then
        rest, is_const, matched = after, true, true
      end
    end

    if not matched then
      -- OPENBLAS_CONST is OpenBLAS's const macro (cblas.h prototypes). It IS
      -- const, so it's peeled and hidden exactly the same way.
      after = rest:match '^OPENBLAS_CONST%s+(.*)$'
      if after then
        rest, is_const, matched = after, true, true
      end
    end

    if not matched then
      -- thread_local is kept as a shown prefix: rare and notable storage duration.
      after = rest:match '^thread_local%s+(.*)$'
      if after then
        prefix, rest, matched = prefix .. 'thread_local ', after, true
      end
    end
    if not matched then
      -- static / inline / extern / constinit: hidden. static carries linkage /
      -- storage meaning but reads as noise in the view (every file-scope constant
      -- and helper has it); drop it like inline.
      after = rest:match '^static%s+(.*)$'
        or rest:match '^inline%s+(.*)$'
        or rest:match '^extern%s+(.*)$'
        or rest:match '^constinit%s+(.*)$'
      if after then
        rest, matched = after, true
      end
    end

    if not matched then
      -- Drop a whitelisted attribute modifier ([[maybe_unused]], [[no_unique_address]],
      -- DANS_NO_UNIQUE_ADDRESS, ...): the only time they matter is when MISSING.
      for _, attr in ipairs(DROPPED_ATTRS) do
        local a = rest:match('^' .. attr .. '%s+(.*)$')
        if a then
          rest, matched = a, true
          break
        end
      end
    end

    if not matched then
      for _, mk in ipairs(MARKERS) do
        local a = rest:match('^' .. mk .. '%s+(.*)$')
        if a then
          prefix = prefix .. mk .. ' '
          rest, matched = a, true
          break
        end
      end
    end

    if not matched then
      break
    end
  end
  return prefix, rest, is_const, is_constexpr
end

function M.looks_like_type(t)
  if t == '' then
    return false
  end
  if t:match '[%(%)%[%]{}=;]' then
    return false
  end
  if t:find('->', 1, true) then
    return false
  end
  -- `<<` never appears in a C++ type, so a `name` preceded by a `<<` run is an
  -- output-stream statement (`out << a << name;`), not a `name`-typed decl.
  if t:find('<<', 1, true) then
    return false
  end
  -- a TOP-LEVEL comma is never part of one type: `int a, b;` must not read as a
  -- `b` of type `int a,`. Template commas (`pair<int, int>`) are nested in <>.
  local depth = 0
  for i = 1, #t do
    local c = t:sub(i, i)
    if c == '<' then
      depth = depth + 1
    elseif c == '>' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      return false
    end
  end
  local first = t:match '^([%w_]+)'
  if first and STMT_KEYWORDS[first] then
    return false
  end
  return true
end

-- Whether all (), [], {} on the line are closed. An unbalanced line is the
-- opener of a multi-line statement (e.g. `const auto x = foo(`), not a complete
-- declaration, so it must render raw.
function M.is_balanced(s)
  local depth = 0
  for ch in s:gmatch '[%(%)%[%]{}]' do
    if ch == '(' or ch == '[' or ch == '{' then
      depth = depth + 1
    else
      depth = depth - 1
    end
    if depth < 0 then
      return false
    end
  end
  return depth == 0
end

-- Parse a lambda RHS `[cap](params) rest` (rest = "-> R", "{...}", "{", "" with
-- the brace on the next line, "mutable -> R", ...). Returns (cap, params, rest)
-- or nil. The no-params form `[cap]{...}` returns params=nil. Only matches when
-- the expression starts with `[`, which in valid C++ means a lambda.
function M.parse_lambda(expr)
  local cap, params, rest = expr:match '^%[(.-)%]%s*%((.-)%)%s*(.*)$'
  if cap ~= nil then
    return cap, params, rest
  end
  local cap2, rest2 = expr:match '^%[(.-)%]%s*(.*)$'
  if cap2 ~= nil and rest2:match '^{' then
    return cap2, nil, rest2
  end
  return nil
end

-- The lone `:` of a range-based for (skipping `::` qualifiers).
local function for_colon(s)
  local i = 1
  while true do
    local c = s:find(':', i, true)
    if not c then
      return nil
    end
    if s:sub(c - 1, c - 1) ~= ':' and s:sub(c + 1, c + 1) ~= ':' then
      return c
    end
    i = c + 1
  end
end

-- Parse `for (BINDING : ITER) TAIL` where BINDING is `[const] auto[&*]* name`
-- (the sigil run is `&`, `&&` for a forwarding ref, or `*`). Returns a table or
-- nil. const is hidden; a missing const surfaces as `mut`.
-- C-style fors (no `:`) and explicit-type bindings (no `auto`) return nil.
function M.parse_for(core)
  local inside, tail = core:match '^for%s*%((.+)%)%s*(.*)$'
  if not inside then
    return nil
  end
  local c = for_colon(inside)
  if not c then
    return nil
  end
  local binding = vim.trim(inside:sub(1, c - 1))
  local iter = vim.trim(inside:sub(c + 1))
  local is_const = binding:match '^const%f[%A]' ~= nil
  local sigil, name = binding:gsub('^const%s+', ''):match '^auto%s*([&*]*)%s*(.+)$'
  if not name then
    return nil
  end
  name = vim.trim(name):gsub('^%[%s*(.-)%s*%]$', '%1') -- destructured binding -> bare list
  return { is_const = is_const, sigil = sigil, name = name, iter = iter, tail = tail }
end

-- `if (auto NAME = RHS; COND) TAIL` (NAME bound with `[const] auto`) ->
-- { name, rhs, cond, tail } for an `if let` render, else nil. COND is returned
-- raw; the render drops it when it's a validity check on NAME and shows it
-- otherwise.
function M.parse_if_let(core)
  local inside, tail = core:match '^if%s*%((.+)%)%s*(.*)$'
  if not inside then
    return nil
  end
  local semi = inside:find(';', 1, true)
  if not semi then
    return nil
  end
  local init = vim.trim(inside:sub(1, semi - 1))
  local cond = vim.trim(inside:sub(semi + 1))
  local name, rhs = init:match '^const%s+auto%s+([%w_]+)%s*=%s*(.+)$'
  if not name then
    name, rhs = init:match '^auto%s+([%w_]+)%s*=%s*(.+)$'
  end
  if not name then
    return nil
  end
  -- `cond` returned raw; the render decides whether to show it (it drops any
  -- condition that checks the binding -- `res`, `res.has_value()`, ...).
  return { name = name, rhs = rhs, cond = cond, tail = tail }
end

-- Render pointer-type `*` as `^` (type positions only). `&` is left alone.
function M.ptr(s)
  return POINTER_CARET and (s:gsub('%*', '^')) or s
end

-- Strip the parts of a type the view hides: leading constexpr/inline and the
-- std::/dans:: qualifiers, and render pointer `*` as `^`. Shared by build_chunks
-- and the alignment pass (so column widths match).
-- Raw / std fixed-width types -> the dans aliases, so a Vulkan signature spelled
-- in `uint32_t` / `float` reads the same as first-party code that uses u32 / f32.
-- Whole-word only (frontier guards), so `float32_t` and `my_uint32_t` aren't
-- partially rewritten. `std::` is already dropped before these run.
local TYPE_ALIAS = {
  uint8_t = 'u8',
  uint16_t = 'u16',
  uint32_t = 'u32',
  uint64_t = 'u64',
  int8_t = 'i8',
  int16_t = 'i16',
  int32_t = 'i32',
  int64_t = 'i64',
  size_t = 'usize',
  ptrdiff_t = 'isize',
  uintptr_t = 'uptr',
  intptr_t = 'iptr',
  char8_t = 'c8',
  float32_t = 'f32',
  float64_t = 'f64',
  float = 'f32',
  double = 'f64',
}

-- Replace every `optional<BALANCED>` with `BALANCED?`, nested ones included, so
-- `vector<optional<V>>` -> `vector<V?>` and a trailing ref/ptr is kept naturally
-- (it's just the text after the matched `>`). Word-boundary, so `my_optional<` is
-- left alone.
local function collapse_optional(t)
  local from = 1
  while true do
    local s = t:find('optional<', from, true)
    if not s then
      return t
    end
    local before = s > 1 and t:sub(s - 1, s - 1) or ''
    if before:match '[%w_]' then
      from = s + 8
    else
      local depth, close = 0, nil
      for i = s + 8, #t do
        local c = t:sub(i, i)
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
        return t
      end
      t = t:sub(1, s - 1) .. t:sub(s + 9, close - 1) .. '?' .. t:sub(close + 1)
      from = s
    end
  end
end

-- Every `array<T, N>` -> `[N]T` (Odin), at ANY nesting depth -- top level,
-- nested in another array (array<array<Color, k_width>, k_height> ->
-- [k_height][k_width]Color), or buried in some other template
-- (vector<array<f32, 3>> -> vector<[3]f32>). Word-boundary, so `my_array<` is
-- left alone; the element/count split at the top-level comma so a templated
-- element (array<pair<int, int>, 3>) isn't broken on its inner comma. After a
-- rewrite the scan resumes at the same spot, so the element of a collapsed
-- array gets its own pass.
local function collapse_array(t)
  local from = 1
  while true do
    local s = t:find('array<', from, true)
    if not s then
      return t
    end
    local before = s > 1 and t:sub(s - 1, s - 1) or ''
    if before:match '[%w_]' then
      from = s + 6
    else
      local depth, close = 0, nil
      for i = s + 5, #t do
        local c = t:sub(i, i)
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
        return t
      end
      local inner = t:sub(s + 6, close - 1)
      local d2, comma = 0, nil
      for i = 1, #inner do
        local c = inner:sub(i, i)
        if c == '<' or c == '(' or c == '[' then
          d2 = d2 + 1
        elseif c == '>' or c == ')' or c == ']' then
          d2 = d2 - 1
        elseif c == ',' and d2 == 0 then
          comma = i
          break
        end
      end
      if not comma then
        from = s + 6 -- `array<T>` with no count: not the std::array shape
      else
        local elem = vim.trim(inner:sub(1, comma - 1))
        local n = vim.trim(inner:sub(comma + 1))
        t = t:sub(1, s - 1) .. '[' .. n .. ']' .. elem .. t:sub(close + 1)
        from = s
      end
    end
  end
end

function M.strip_type(typ)
  -- OPENBLAS_CONST -> const first (at any position, so a nested
  -- `OPENBLAS_CONST char*` still reads as CString below).
  local t = typ:gsub('%f[%w_]OPENBLAS_CONST%f[%W]', 'const')
  t = t:gsub('^constexpr%s+', ''):gsub('^inline%s+', ''):gsub('std::', ''):gsub('dans::', '')
  for from, to in pairs(TYPE_ALIAS) do
    t = t:gsub('%f[%w_]' .. from .. '%f[^%w_]', to)
  end
  -- std::optional<T> -> T?, at any nesting depth (vector<optional<V>> -> vector<V?>).
  t = collapse_optional(t)
  -- std::expected<T, E> -> T?E (value, then `?`, then the error arm), keeping any
  -- trailing ref/ptr. Split at the top-level comma so a templated arm
  -- (expected<vector<int>, Error>) isn't broken on its inner comma.
  local exp_inner, exp_sig = t:match '^expected<(.+)>%s*([&*]*)$'
  if exp_inner then
    local depth = 0
    for i = 1, #exp_inner do
      local c = exp_inner:sub(i, i)
      if c == '<' or c == '(' or c == '[' then
        depth = depth + 1
      elseif c == '>' or c == ')' or c == ']' then
        depth = depth - 1
      elseif c == ',' and depth == 0 then
        t = vim.trim(exp_inner:sub(1, i - 1)) .. '?' .. vim.trim(exp_inner:sub(i + 1)) .. exp_sig
        break
      end
    end
  end
  t = collapse_array(t)
  -- const char* (an immutable C string) -> CString, wherever it appears -- incl
  -- nested in a template (vector<const char*> -> vector<CString>). A top-level
  -- const-char* member is handled in build_chunks (the const is peeled there, so
  -- it never reaches here with the const attached); this catches the nested ones
  -- the overlay would otherwise leave as `const char^`. Extra pointer levels are
  -- kept (const char** -> CString*, then M.ptr -> CString^). Runs before M.ptr so
  -- it can match the `*` while it is still a star.
  t = t:gsub('const%s+char%s*(%*+)', function(stars)
    return 'CString' .. stars:sub(2)
  end)
  t = M.ptr(t)
  -- the caret binds tight: C-style `double *X` arrives as `f64 ^` -- drop the
  -- gap so every pointer reads `T^` regardless of the source's star placement.
  t = t:gsub('%s+%^', '^')
  -- Reference declarator spacing belongs to the source project's convention,
  -- not the frontend type language. Canonicalize a top-level trailing `&`/`&&`
  -- so `T& x`, `T &x`, and `T & x` all render as `x: T&`.
  t = t:gsub('%s+(&+)%s*$', '%1')
  -- `const char* const` (a const pointer to const char) -> `CString const` after
  -- the rewrites above; move the pointer-const in front, like the leading-const
  -- rule for pointers, so it reads `const CString` (`span<const char* const>` ->
  -- `span<const CString>`).
  t = t:gsub('CString(%^*)%s+const%f[%W]', 'const CString%1')
  return t
end

-- Exact CUDA numeric aliases are deliberately applied before the generic `cu`
-- prefix rule.  CUDA's cuComplex.h defines cuFloatComplex as float2,
-- cuDoubleComplex as double2, and cuComplex as an alias of cuFloatComplex.  The
-- compact names carry the precision directly; the renderer still classifies the
-- ORIGINAL token first, so cf32/cf64 remain CUDA seafoam rather than generic type
-- blue.  Keep this ordered list as the single source used by both overlay and
-- raw-line renderers.
local CUDA_TYPE_ALIASES = {
  { source = 'cuFloatComplex', shown = 'cf32' },
  { source = 'cuComplex', shown = 'cf32' },
  { source = 'cuDoubleComplex', shown = 'cf64' },
  { source = 'cudaStream_t', shown = 'Stream' },
  { source = 'cudaGraph_t', shown = 'Graph' },
  { source = 'cudaGraphExec_t', shown = 'GraphExec' },
}

-- Exact CUDA value/function aliases. These run before the generic `cu` prefix
-- removal so semantic names can replace CUDA's historical spelling instead of
-- merely exposing its remainder (`cuCabsf` -> `abs`, not `Cabsf`).
local CUDA_FUNCTION_ALIASES = {
  { source = 'cuCabsf', shown = 'abs' },
  { source = 'cuConjf', shown = 'conj' },
}

function M.cuda_type_aliases()
  return vim.deepcopy(CUDA_TYPE_ALIASES)
end

function M.cuda_function_aliases()
  return vim.deepcopy(CUDA_FUNCTION_ALIASES)
end

-- Drop or compact a configured library prefix from a displayed token, matching
-- the raw-line transforms in markers.lua/aliases.lua. Only presentation changes;
-- the caller computes the library color BEFORE calling this so provenance
-- survives. `%f[%w_]` anchors to a C/C++ identifier start so embedded prefixes
-- are untouched.
function M.strip_glfw(t)
  -- internal glfw first (leading underscore: _GLFWwindow -> window), so the
  -- GLFW-without-underscore rules below don't strip the GLFW and strand the `_`.
  -- NOT the _GLFW_X build macros (a letter must follow). `[%w_]` frontier so `_`
  -- counts as a word char, matching the raw-line `\<` conceal (where `_` is one).
  t = t:gsub('%f[%w_]_GLFW([A-Za-z])', '%1')
  t = t:gsub('%f[%w_]_glfw([A-Za-z])', '%1')
  t = t:gsub('%f[%w_]GLFW_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w_]GLFW([a-z])', '%1')
  t = t:gsub('%f[%w_]glfw([A-Z])', '%1')
  -- vulkan: longer sub-prefixes (DebugUtils, KHR) first, then generic Vk/VK_/vk.
  t = t:gsub('%f[%w]VK_DEBUG_UTILS_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]VkDebugUtils([A-Z])', '%1')
  t = t:gsub('%f[%w]VK_KHR_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]VK_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]Vk([A-Z])', '%1')
  -- lowercase vk functions (vkCreateInstance -> CreateInstance), like glfw. The
  -- `[%w_]` frontier treats `_` as a word char (matching the raw-line `\<vk`
  -- conceal), so an embedded `PFN_vkCreateX` keeps its vk rather than `PFN_CreateX`.
  t = t:gsub('%f[%w_]vk([A-Z])', '%1')
  -- CUDA numeric types use exact precision-bearing aliases. The trailing
  -- frontier prevents a longer project identifier such as cuComplexBuffer from
  -- being partially rewritten.
  for _, alias in ipairs(CUDA_TYPE_ALIASES) do
    t = t:gsub('%f[%w_]' .. alias.source .. '%f[^%w_]', alias.shown)
  end
  for _, alias in ipairs(CUDA_FUNCTION_ALIASES) do
    t = t:gsub('%f[%w_]' .. alias.source .. '%f[^%w_]', alias.shown)
  end
  -- Remaining CUDA runtime/driver types and calls lose only their prefix.
  -- cu* math-library names such as cublasHandle do not match these case shapes.
  t = t:gsub('%f[%w_]cu([A-Z])', '%1')
  t = t:gsub('%f[%w_]CU([a-z])', '%1')
  -- vulkan memory allocator
  t = t:gsub('%f[%w]VMA_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]Vma([A-Z])', '%1')
  t = t:gsub('%f[%w_]vma([A-Z])', '%1')
  -- opengl: GL_X / glX (after glfw above, so glfw* is consumed first)
  t = t:gsub('%f[%w]GL_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w_]gl([A-Z])', '%1')
  -- dear imgui: ImGui:: / ImGuiX / ImX / IM_X. ImGui before Im so ImGuiContext
  -- isn't left as GuiContext.
  t = t:gsub('%f[%w]ImGui::', '')
  t = t:gsub('%f[%w]ImGui([A-Z])', '%1')
  t = t:gsub('%f[%w]Im([A-Z])', '%1')
  t = t:gsub('%f[%w]IM_([A-Z0-9])', '%1')
  -- Qnpeps namespace and identifier families. Longer forms must run before qn_
  -- so they cannot be partially consumed. As with every hidden prefix, callers
  -- classify the original token first and preserve the orchid provenance color.
  t = t:gsub('%f[%w_]qnpeps::', '')
  t = t:gsub('%f[%w_]qnpeps_([A-Za-z0-9])', '%1')
  t = t:gsub('%f[%w_]QNPEPS_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w_]Qnpeps([A-Za-z0-9])', '%1')
  t = t:gsub('%f[%w_]qn_([A-Za-z0-9])', '%1')
  return t
end

-- Trailing identifier of a *pure* member-access chain (`cfg.center` -> "center",
-- `obj->p` -> "p", `center` -> "center", `&application_info` -> "application_info"),
-- or the type name of an empty default/value construction (`DebugMessengerCfg{}` ->
-- "DebugMessengerCfg"); nil for anything else (a call with args, index, operator,
-- literal). A wrapping `std::move(...)` / `copy(...)` and a leading address-of are
-- peeled off first, so `.field = std::move(field)` and a `p`-prefixed pointer field
-- against `&local` both pun. Drives the designated-init pun: `.center = cfg.center`
-- collapses to `center` because the last access already matches the field name.
function M.access_tail(v)
  local norm = vim.trim(v)
  norm = vim.trim(norm:gsub('^std::move%s*%((.+)%)$', '%1'):gsub('^copy%s*%((.+)%)$', '%1'))
  -- a default/value-constructed temporary (`DebugMessengerCfg{}` / `Foo()`) puns on
  -- its type name: drop an empty trailing `{}` / `()` so the name is what's matched.
  norm = norm:gsub('%s*{%s*}$', ''):gsub('%s*%(%s*%)$', '')
  norm = norm:gsub('^&%s*', ''):gsub('%s*%->%s*', '.'):gsub('%s*%.%s*', '.')
  if norm:match '^[%a_][%w_]*$' or norm:match '^[%a_][%w_]*%.[%w_.]*[%w_]$' then
    return norm:match '([%w_]+)$'
  end
  return nil
end

-- Whether an access-tail matches a field name across naming conventions: drop a
-- leading Hungarian pointer prefix (`p`/`pp` before an uppercase letter, as Vulkan
-- and others use -- pUserData, ppEnabledLayerNames), then strip underscores and
-- lowercase. So .messageSeverity = message_severity and .pUserData = user_data both
-- collapse (messageSeverity/message_severity/MessageSeverity/MESSAGE_SEVERITY, and
-- pUserData/user_data, all compare equal). nil tail never matches.
local function norm_field(s)
  s = s:gsub('^pp(%u)', '%1'):gsub('^p(%u)', '%1')
  return s:gsub('_', ''):lower()
end

-- Split an identifier into lowercased words: break on `_`, on camelCase humps, and
-- drop a leading Hungarian p/pp. `dbg_messenger_cfg` and `DebugMessengerCfg` both
-- give {dbg|debug, messenger, cfg}.
local function words_of(s)
  s = s:gsub('^pp(%u)', '%1'):gsub('^p(%u)', '%1')
  s = s:gsub('(%l)(%u)', '%1_%2'):gsub('(%u)(%u%l)', '%1_%2')
  local out = {}
  for w in s:gmatch '[%a%d]+' do
    out[#out + 1] = w:lower()
  end
  return out
end

-- One word abbreviates the other: equal, or the shorter (>= 3 chars, so a bare
-- loop var `h` is not read as short for `height`) is a same-first-letter
-- subsequence of the longer (dbg<->debug, cfg<->config, msg<->message, idx<->index).
local function word_abbrev(a, b)
  if a == b then
    return true
  end
  local short, long = a, b
  if #short > #long then
    short, long = long, short
  end
  if #short < 3 or short:sub(1, 1) ~= long:sub(1, 1) then
    return false
  end
  local i = 1
  for j = 1, #long do
    if long:sub(j, j) == short:sub(i, i) then
      i = i + 1
      if i > #short then
        return true
      end
    end
  end
  return false
end

function M.field_eq(tail, field)
  if not tail or not field then
    return false
  end
  if norm_field(tail) == norm_field(field) then
    return true
  end
  -- abbreviation-aware fallback: same word count, each word abbreviating its peer,
  -- so .dbg_messenger_cfg = DebugMessengerCfg{} collapses (dbg~Debug, cfg~Cfg).
  local wt, wf = words_of(tail), words_of(field)
  if #wt == 0 or #wt ~= #wf then
    return false
  end
  for i = 1, #wt do
    if not word_abbrev(wt[i], wf[i]) then
      return false
    end
  end
  return true
end

-- Split a designated-init body (`.a = x, .b = y`) into { {field, value}, ... } on
-- top-level commas, or nil if any element isn't `.field = value`. Lets the value
-- renderer fold designated inits the same way cpp_designated does on raw lines.
function M.designated_pairs(body)
  local out = {}
  local depth, start = 0, 1
  local function push(chunk)
    local field, value = chunk:match '^%s*%.([%w_]+)%s*=%s*(.-)%s*$'
    if not field then
      return false
    end
    out[#out + 1] = { field = field, value = value }
    return true
  end
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == '(' or c == '[' or c == '{' or c == '<' then
      depth = depth + 1
    elseif c == ')' or c == ']' or c == '}' or c == '>' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      if not push(body:sub(start, i - 1)) then
        return nil
      end
      start = i + 1
    end
  end
  if not push(body:sub(start)) then
    return nil
  end
  return #out > 0 and out or nil
end

-- Whether `row0` is a single-line function declaration (return type BEFORE the
-- name, e.g. `bool f(args)` -- including the most-vexing-parse `vector<T> v(n)`
-- that the C++ grammar reads as a function). Used only to BAIL: such lines render
-- raw instead of being mangled into a `name: T(args)` paren-init variable. nil for
-- trailing-return functions, constructors/destructors, non-functions, and
-- multi-line decls. A cheap text pre-check gates the treesitter walk.
-- Cached treesitter node at the first non-blank column of `row0`, with that line's
-- text and column. Per buffer/changedtick, so the several per-line facts derived
-- in build_chunks (classic_function / decl_kind / is_iife) share ONE tree descent
-- and one line fetch instead of repeating get_node for each. Each caller walks its
-- own local copy of the node, so sharing is safe. Returns node, line, col.
local node_cache = {}
function M.node_at(bufnr, row0)
  if not bufnr then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = node_cache[bufnr]
  if not c or c.tick ~= tick then
    c = { tick = tick }
    node_cache[bufnr] = c
  end
  local e = c[row0]
  if e == nil then
    local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
    if not line then
      c[row0] = false
      return nil
    end
    local col = #(line:match '^%s*' or '')
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col } })
    e = { node = (ok and node) or nil, line = line, col = col }
    c[row0] = e
  elseif e == false then
    return nil
  end
  return e.node, e.line, e.col
end

function M.classic_function(bufnr, row0)
  local node, line = M.node_at(bufnr, row0)
  if not line or not line:match '[%w_]+%s*%b()' then
    return nil -- no `ident(...)` at all -> can't be a function decl
  end
  if not node then
    return nil
  end
  while node and node:type() ~= 'declaration' and node:type() ~= 'field_declaration' do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local tfield = node:field('type')[1]
  local dtor = node:field('declarator')[1]
  if not tfield or not dtor or tfield:type() == 'placeholder_type_specifier' then
    return nil -- no return type, or `auto` (deduced / trailing-return)
  end
  local fnode = dtor
  if dtor:type() == 'pointer_declarator' then
    fnode = dtor:field('declarator')[1]
  elseif dtor:type() == 'reference_declarator' then
    fnode = dtor:field('declarator')[1]
  end
  if not fnode or fnode:type() ~= 'function_declarator' then
    return nil
  end
  -- The most-vexing-parse cuts both ways: `vector<f64> a(static_cast<usize>(n));`
  -- parses as a function declaration, but a "parameter" that BEGINS with a cast
  -- keyword is provably an ARGUMENT -- report nil so the paren-init branch
  -- renders the variable this line actually declares (and the decoration
  -- modules defer to that overlay instead of garbling the raw line). Only a
  -- cast at a parameter's start counts: a cast in a DEFAULT argument
  -- (`void f(int x = static_cast<int>(y))`) is a real function.
  local params = fnode:field('parameters')[1]
  if params then
    local ptext = vim.treesitter.get_node_text(params, bufnr):gsub('^%(', ''):gsub('%)$', '')
    local depth, start = 0, 1
    local function value_arg(chunk)
      return vim.trim(chunk):match '^[%w_:]*_cast%s*<' ~= nil
    end
    for i = 1, #ptext do
      local c = ptext:sub(i, i)
      if c == '<' or c == '(' or c == '[' or c == '{' then
        depth = depth + 1
      elseif c == '>' or c == ')' or c == ']' or c == '}' then
        depth = depth - 1
      elseif c == ',' and depth == 0 then
        if value_arg(ptext:sub(start, i - 1)) then
          return nil
        end
        start = i + 1
      end
    end
    if value_arg(ptext:sub(start)) then
      return nil
    end
  end
  local _, _, fe_row = fnode:range()
  if fe_row ~= row0 then
    return nil -- single-line declarations only
  end
  return true
end

-- Whether line `row0` is the `});` that closes a `DANS_DEFER(...)` or
-- `DEFER(...)` call -- the nearest call_expression enclosing the line's closing
-- `}` must be one of the supported lambda-backed defer macros.
-- Lets the view render that closer as a bare `}` (its opener became `defer {`).
function M.defer_close(bufnr, row0)
  if not bufnr then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  local bcol = line and line:find('}', 1, true)
  if not bcol then
    return false
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, bcol - 1 } })
  if not ok or not node then
    return false
  end
  while node do
    if node:type() == 'call_expression' then
      local fn = node:field('function')[1]
      if not fn then
        return false
      end
      local name = vim.treesitter.get_node_text(fn, bufnr)
      return name == 'DANS_DEFER' or name == 'DEFER'
    end
    node = node:parent()
  end
  return false
end

-- Split `s` at the first top-level comma (templates/parens/brackets balanced):
-- returns (first, rest) or (s, nil) if there is none. Used to peel a smart
-- pointer's custom deleter off the pointee type without being fooled by the
-- commas inside a nested template like `pair<int, int>`.
local function split_first_arg(s)
  local depth = 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '<' or c == '(' or c == '[' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      return vim.trim(s:sub(1, i - 1)), vim.trim(s:sub(i + 1))
    end
  end
  return s, nil
end

-- A std smart-pointer type (after strip_type already removed std::): returns the
-- pointee type, 'unique'/'shared', and a custom deleter (or nil), else nil. Lets
-- the view render `unique_ptr<T>` as `T^` with an ownership-colored caret, and
-- `unique_ptr<T, Del>` as `T^, Del~` -- the caret on the pointee, a `~` tying the
-- deleter to it (instead of the caret landing on the deleter).
function M.smart_ptr(t)
  local inner = t:match '^unique_ptr<(.+)>$'
  local kind
  if inner then
    kind = 'unique'
  else
    inner = t:match '^shared_ptr<(.+)>$'
    if not inner then
      return nil
    end
    kind = 'shared'
  end
  local pointee, deleter = split_first_arg(inner)
  return pointee, kind, deleter
end

-- For an explicit declaration that build_chunks presents as `name: type`
-- (brace-init, pointer/reference, array, or bare member/global no_init), return
-- the rendered name and type strings plus constexpr-ness. Mirrors the renderer's
-- acceptance gates so alignment never sees less or more than the display path.
function M.field_dims(line, bufnr, row0)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  local code = body:match '^(.-)%s*//.*$' or body
  local had_semi = code:match ';%s*$' ~= nil
  local _, core, was_const, is_constexpr = M.split_markers((code:gsub(';%s*$', '')))
  local typ, nm = core:match '^(.-)%s+([%w_]+)%s*{.*}$'
  if not (nm and had_semi and M.looks_like_type(typ)) then
    -- no-brace reference/pointer member: `T& name` / `T* name`
    typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
    if not (typ and nm and had_semi and M.looks_like_type(typ)) then
      -- Bare explicit member/global declarations are rendered with `no_init` by
      -- build_chunks, but the old width model ignored them completely. That
      -- split a C struct into tiny pointer-only alignment islands. Mirror the
      -- renderer's exact acceptance gate so every displayed `name: type` row can
      -- belong to one contiguous declaration block while deferred-init locals
      -- (which intentionally stay raw) still cannot bridge a block.
      local vtyp, vnm = core:match '^(.-)%s+([%w_]+)$'
      local is_array = vtyp and M.strip_type(vtyp):match '^%[' ~= nil
      local kind = vtyp and bufnr ~= nil and row0 ~= nil and M.decl_kind(bufnr, row0) or nil
      if
        vtyp
        and vnm
        and had_semi
        and M.looks_like_type(vtyp)
        and (is_array or ((kind == 'member' or kind == 'global') and not was_const))
      then
        typ, nm = vtyp, vnm
      else
        return nil
      end
    end
  end
  local disp = M.strip_glfw(M.strip_type(typ))
  local inner, _, deleter = M.smart_ptr(disp)
  if inner then
    disp = deleter and (inner .. '^, ' .. deleter .. '~') or (inner .. '^')
  elseif was_const and disp:match '^char%^+$' then
    -- `const char*`(*) renders as `CString`(^); the alignment width must match
    -- what's shown, not the stripped `char^`.
    disp = 'CString' .. (disp:gsub('^char%^', ''))
  end
  return nm, disp, is_constexpr
end

-- Whether the declaration on `line` would render a `mut ` prefix -- the EXACT
-- condition build_chunks uses, so the reserved mut column never exists without a
-- real mut in the block: non-const, non-constexpr, not a smart pointer (those
-- render `T^` with an ownership caret, no mut), not an uninitialized pointer
-- (those render `no_init`), and either a top-level pointer/reference or a local
-- value. Lets compute_align reserve the left mut column for a block that has any
-- mut binding.
function M.field_is_mut(line, bufnr, row0)
  -- peel the indent first (like field_dims): split_markers anchors at ^, so a
  -- clang-format-indented `    const T x{};` would otherwise hide its const and
  -- read as mut -- the phantom mut column on all-const blocks.
  local body = line:sub(#(line:match '^%s*') + 1)
  local code = body:match '^(.-)%s*//.*$' or body
  if not code:match ';%s*$' then
    return false
  end
  local _, core, was_const, is_constexpr = M.split_markers((code:gsub(';%s*$', '')))
  if was_const or is_constexpr then
    return false
  end
  local typ = core:match '^(.-)%s+[%w_]+%s*{.*}$'
  if not typ or not M.looks_like_type(typ) then
    typ = core:match '^(.-[%w_>][&*]+)%s*[%w_]+$'
    if not typ or not M.looks_like_type(typ) then
      return false
    end
    -- no-brace `T* name;` renders a no_init marker, not mut.
    local sigil = typ:match '([&*]+)%s*$'
    if sigil and sigil:sub(-1) == '*' then
      return false
    end
  end
  local disp = M.strip_type(typ)
  if M.smart_ptr(disp) then
    return false -- renders `T^` with an ownership-colored caret, never mut
  end
  local depth, caret = 0, false
  for i = 1, #disp do
    local c = disp:sub(i, i)
    if c == '<' or c == '(' or c == '[' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' then
      depth = depth - 1
    elseif depth == 0 then
      if c == '&' then
        return true -- a reference is a mutable borrow at any scope
      elseif c == '^' then
        caret = true
      end
    end
  end
  if caret then
    -- a pointer is mut everywhere EXCEPT a struct member (plain data there)
    return bufnr ~= nil and M.decl_kind(bufnr, row0) ~= 'member'
  end
  return bufnr ~= nil and M.decl_kind(bufnr, row0) == 'local'
end

-- Rendered width of the name (plus a `&`/`^` sigil) for a plain `auto name = value`
-- binding the view renders as `name := value`, and whether it renders a leading
-- `mut`; nil if the line isn't such a binding (an explicit-type decl, a lambda, a
-- structured binding, an incomplete multi-line opener, a cpy/thread_local prefix,
-- ...). Mirrors the exact conditions the `name :=` path in build_chunks uses, so a
-- run of them can align the `:=` and the measured width matches what renders. The
-- treesitter decl_kind lookup is last and short-circuited on const, so only a
-- non-const binding pays for it.
function M.auto_bind_dims(line, bufnr, row0)
  local body = line:sub(#(line:match '^%s*') + 1)
  local code = body:match '^(.-)%s*//.*$' or body
  if not code:match ';%s*$' then
    return nil
  end
  local prefix, core, was_const = M.split_markers((code:gsub(';%s*$', '')))
  if prefix ~= '' then
    return nil -- a cpy/thread_local prefix shifts the name; keep the width model exact
  end
  local sigil, name, expr = core:match '^auto([&*]?)%s+([%w_]+)%s*=%s*(.+)$'
  if not name or name == 'operator' then
    return nil
  end
  if M.parse_lambda(expr) or not M.is_balanced(expr) then
    return nil -- a lambda / IIFE and multi-line openers don't render `name := value`
  end
  local nw = vim.fn.strwidth(name) + (sigil ~= '' and 1 or 0)
  local is_mut = not was_const and M.decl_kind(bufnr, row0) == 'local'
  return nw, is_mut
end

-- Map row0 -> an align entry so a run of consecutive declarations lines up. Two
-- kinds: displayed explicit-type declarations -> { nw, tw, has_mut }, aligning the `:`
-- (after the name) and `=`/`;` (after the type); and plain `auto` bindings ->
-- { auto = true, nw, has_mut }, aligning the `:=` by padding the name. Both reserve
-- the left mut column ONLY when a binding in the run actually renders mut. constexpr
-- declarations (`name: T : value` constant bindings) never mix with normal vars: a
-- constexpr-ness flip ends an explicit run, so a constant block aligns among itself
-- and is never shifted right by a neighbor's mut column. Singleton runs get no entry.
function M.compute_align(lines, offset, bufnr)
  offset = offset or 0
  local map = {}
  local i, n = 1, #lines
  while i <= n do
    local first_row0 = offset + i - 1
    if M.field_dims(lines[i], bufnr, first_row0) then
      -- Displayed explicit declarations: a run grouped by constexpr-ness.
      local block, block_cx = {}, nil
      while i <= n do
        local row0 = offset + i - 1
        local nm, ty, cx = M.field_dims(lines[i], bufnr, row0)
        if not nm then
          break
        end
        if block_cx == nil then
          block_cx = cx
        elseif cx ~= block_cx then
          break -- constexpr-ness flipped: this line starts a new block
        end
        block[#block + 1] = { row0 = row0, nw = vim.fn.strwidth(nm), tw = vim.fn.strwidth(ty), mut = M.field_is_mut(lines[i], bufnr, row0) }
        i = i + 1
      end
      if #block >= 2 then
        local nw, tw, has_mut = 0, 0, false
        for _, b in ipairs(block) do
          nw = math.max(nw, b.nw)
          tw = math.max(tw, b.tw)
          has_mut = has_mut or b.mut
        end
        for _, b in ipairs(block) do
          map[b.row0] = { nw = nw, tw = tw, has_mut = has_mut }
        end
      end
    elseif M.auto_bind_dims(lines[i], bufnr, offset + i - 1) then
      -- Plain `auto name = value` bindings (rendered `name := value`): a run pads
      -- each name to the widest so the `:=` lines up.
      local block = {}
      while i <= n do
        local aw, amut = M.auto_bind_dims(lines[i], bufnr, offset + i - 1)
        if not aw then
          break
        end
        block[#block + 1] = { row0 = offset + i - 1, nw = aw, mut = amut }
        i = i + 1
      end
      if #block >= 2 then
        local nw, has_mut = 0, false
        for _, b in ipairs(block) do
          nw = math.max(nw, b.nw)
          has_mut = has_mut or b.mut
        end
        for _, b in ipairs(block) do
          map[b.row0] = { auto = true, nw = nw, has_mut = has_mut }
        end
      end
    else
      i = i + 1
    end
  end
  return map
end

-- Classify the declaration on a line via treesitter: 'member' (struct/class
-- field), 'local' (function-body variable), 'param', 'global' (file/namespace
-- scope), or nil. mut is inferred only on non-const locals; keyed on the
-- enclosing scope (not just `declaration`, which also covers namespace globals).
-- Cheap (node lookup + ancestor walk); guarded since the tree may be mid-parse.
function M.decl_kind(bufnr, row0)
  local node = M.node_at(bufnr, row0)
  if not node then
    return nil
  end
  while node do
    local t = node:type()
    if t == 'field_declaration' then
      return 'member'
    elseif t == 'parameter_declaration' or t == 'optional_parameter_declaration' then
      return 'param'
    elseif t == 'function_definition' or t == 'compound_statement' then
      return 'local' -- inside a function body
    elseif t == 'namespace_definition' or t == 'translation_unit' then
      return 'global' -- file / namespace scope, not a function local
    end
    node = node:parent()
  end
  return nil
end

-- Whether the declaration on this line initializes from an immediately-invoked
-- lambda (IIFE): `auto x = [&]{...}()`. Treesitter sees the init as a
-- call_expression (vs a plain lambda_expression for a binding). The caller has
-- already confirmed the line's RHS is a lambda, so call_expression => IIFE.
function M.is_iife(bufnr, row0)
  local node = M.node_at(bufnr, row0)
  if not node then
    return false
  end
  while node and node:type() ~= 'declaration' do
    node = node:parent()
  end
  if not node then
    return false
  end
  for child in node:iter_children() do
    if child:type() == 'init_declarator' then
      local last
      for c in child:iter_children() do
        last = c
      end
      return last ~= nil and last:type() == 'call_expression'
    end
  end
  return false
end

return M
