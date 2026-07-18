-- Space-triggered, composable C++ type shorthand for c/cpp/cuda. Type a
-- `$`-token and press <Space>: the token before the cursor is expanded to a
-- std:: type. Unlike an automatic text abbreviation it does NOT fire mid-token, so the
-- pieces compose -- `$?$str` waits for the space, then becomes
-- std::optional<std::string>.
--
-- Two call syntaxes for the same templates: prefix sigils `$um$K$V` (outer to
-- inner, so `$<$?$int` reads vector-of-optional-of-int) and explicit parens
-- `$um(K, V)` (whitespace-stripped, clearer arg count). UNDERSPECIFIED tokens
-- still expand: every missing operand becomes a literal `$` -- `$um$K` ->
-- std::unordered_map<K, $> -- so the expansion exists but fails the build until
-- the `$` is filled in. Only OVERspecified tokens (too many operands) are
-- rejected. A segment that isn't a known atom is the literal inner type
-- (`$?$Foo`); a bare unknown `$token` is preserved so a typo is never a
-- destructive edit.
--
--   $str / $sv / $rv / $ra -> std::string / string_view / ranges::views / ranges
--   $?              -> std::nullopt   ($?$ / $?(T) give the optional)
--   $?$int / $?(int) -> std::optional<int>
--   $< / $> / $arr / $um -> the bare template name (std::vector / array / ...)
--   $<$Foo / $>(Foo) -> std::vector<Foo>          (vector is `<`, alias `>`)
--   $^$Foo / $up$Foo / $sp$Foo -> std::unique_ptr<Foo> / shared_ptr<Foo>
--   $um$K$V / $um(K, V) -> std::unordered_map<K, V>
--   $um$K / $um(K)  -> std::unordered_map<K, $>    (missing operand -> `$`)
--   $map$K$V / $arr$T$N -> std::map<K, V> / std::array<T, N>
--   $arr$arr$int$5$4 -> std::array<std::array<int, 5>, 4>  (operands fill the
--                       templates left to right, innermost binding tightest)
--   $[5]int         -> std::array<int, 5>          (Odin array sugar; nests:
--   $[4][5]int      -> std::array<std::array<int, 5>, 4>; `$[5]` / `$[]int`
--                       fill the missing part as `$`; the element may be a
--                       $form: $[5]$<$int -> std::array<std::vector<int>, 5>)
--   $sc$u32$x / $sc(u32, x) -> static_cast<u32>(x)   (also $rc / $cc / $dc casts;
--                              bare $sc$u32 / $sc(u32) -> static_cast<u32>)
--   $<T, S>         -> template <typename T, typename S>  (angle form, closing >)
--   relations (concept ~-notation), prefix or infix:
--   $~> / $~=       -> std::convertible_to / std::same_as
--   $~>$T$S / $T$~>$S / $~>(T, S) -> std::convertible_to<T, S>
--   $~>$T / $T$~> / $~>(T) -> std::convertible_to<T, $>  (missing operand -> `$`)
--   $copy / $copya / $move / $movea
--                   -> the matching special member of the enclosing class, e.g.
--                      $copy -> X(const X&), $copya -> def operator=(const X&) -> X&
--                      (inverse of the special_members view collapse; the default
--                      ctor/dtor are no longer collapsed, so they have no $form)
--   $sdfgfd<Space>  -> (deleted)                    (bare unknown $token isn't a
--                                                    type; unresolved $-blocks go)
-- `$` inside a string is left alone. A block must end at the cursor, so `$sa(`
-- (trailing non-snippet char) does nothing.
--
-- While a `$`-block is being typed, a preview floats at the end of the line:
-- the snippet's brief name plus the expansion as it stands right now (missing
-- parts shown as `$`). A partial head previews its prefix matches ($u -> um /
-- up). See M.preview / the ds_snip_preview autocmds in setup().
--
-- This is the inverse of the dans_frontend_cpp view: type the short form, store
-- real C++, read it back short (the frontend hides std:: and shows optional<T>
-- as T?, unique_ptr<T> as T^, ...).

local M = {}

-- Prefix. Reachable alternatives if you ever want to swap: '§', '%'. Everything
-- keys off this one constant.
local SIGIL = '$'
local SIGIL_PAT = vim.pesc(SIGIL)

local unpack = table.unpack or unpack

-- Templates: `$head` with a fixed arity. 0 operands -> the bare form; exactly
-- `arity` operands -> the `fmt`; FEWER operands fill the missing ones as a
-- literal `$` (`$um$K` -> std::unordered_map<K, $> -- the expansion always
-- works, the `$` fails the build until filled in); only MORE operands reject.
-- Both call syntaxes expand the same entry: prefix sigils `$um$K$V` and parens
-- `$um(K, V)`.
--   tbare: the bare form when a `$` follows but no operand is given -- `$?` is the
--   value std::nullopt, but `$?$` (templated, no arg) is std::optional.
--   fmt2: an optional one-larger form (arity + 1 operands). The casts use it for
--   the wrapped-expression form: `$sc$u32` -> static_cast<u32> (fmt, 1 operand),
--   `$sc$u32$x` -> static_cast<u32>(x) (fmt2, 2 operands). The fold prefers fmt2
--   when the extra operand is available.
local TEMPLATES = {
  ['?'] = { bare = 'std::nullopt', tbare = 'std::optional', arity = 1, fmt = 'std::optional<%s>' },
  ['<'] = { bare = 'std::vector', arity = 1, fmt = 'std::vector<%s>' },
  ['>'] = { bare = 'std::vector', arity = 1, fmt = 'std::vector<%s>' }, -- `$>` alias for vector
  ['^'] = { bare = 'std::unique_ptr', arity = 1, fmt = 'std::unique_ptr<%s>' },
  up = { bare = 'std::unique_ptr', arity = 1, fmt = 'std::unique_ptr<%s>' },
  sp = { bare = 'std::shared_ptr', arity = 1, fmt = 'std::shared_ptr<%s>' },
  um = { bare = 'std::unordered_map', arity = 2, fmt = 'std::unordered_map<%s, %s>' },
  map = { bare = 'std::map', arity = 2, fmt = 'std::map<%s, %s>' },
  arr = { bare = 'std::array', arity = 2, fmt = 'std::array<%s, %s>' },
  sc = { bare = 'static_cast', arity = 1, fmt = 'static_cast<%s>', fmt2 = 'static_cast<%s>(%s)' },
  rc = { bare = 'reinterpret_cast', arity = 1, fmt = 'reinterpret_cast<%s>', fmt2 = 'reinterpret_cast<%s>(%s)' },
  cc = { bare = 'const_cast', arity = 1, fmt = 'const_cast<%s>', fmt2 = 'const_cast<%s>(%s)' },
  dc = { bare = 'dynamic_cast', arity = 1, fmt = 'dynamic_cast<%s>', fmt2 = 'dynamic_cast<%s>(%s)' },
}

-- Binary concept relations, infix-capable: `$~>` -> std::convertible_to. The
-- operand forms are handled in expand_relation and the paren branch.
local RELATIONS = { ['~>'] = 'std::convertible_to', ['~='] = 'std::same_as' }

-- 0-arg atoms: $word -> expansion. Type shorthands below, plus the view-layer
-- alias table (aliases.ALIASES) -- the SAME EXPR<->$A pairs that collapse
-- `noexcept` to `$ne`, etc. -- so collapse and expansion stay one idea. A `_cast`
-- alias becomes a 1-arg template; up/sp/casts already live in TEMPLATES.
local ATOM = {
  str = 'std::string',
  sv = 'std::string_view',
  rv = 'std::ranges::views',
  ra = 'std::ranges',
  -- $mu still types the attribute even though the frontend now hides it (so it's
  -- no longer importable from aliases.ALIASES, where its replacement is '').
  mu = '[[maybe_unused]]',
}
do
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      local key = type(a[2]) == 'string' and a[2]:match '^%$([%w_]+)$'
      if key and ATOM[key] == nil and not TEMPLATES[key] then
        if type(a[1]) == 'string' and a[1]:match '_cast$' then
          TEMPLATES[key] = { bare = a[1], arity = 1, fmt = a[1] .. '<%s>', fmt2 = a[1] .. '<%s>(%s)' }
        else
          ATOM[key] = a[1]
        end
      end
    end
  end
end

-- Split an arg-list body on top-level commas (depth-aware over <>, (), [], {}).
local function split_commas(s)
  local args, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '(' or c == '<' or c == '[' or c == '{' then
      depth = depth + 1
    elseif c == ')' or c == '>' or c == ']' or c == '}' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      args[#args + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  args[#args + 1] = s:sub(start)
  return args
end

-- A relation operand: a single segment that's a known atom or a bare identifier.
local function expand_operand(seg)
  if ATOM[seg] then
    return ATOM[seg]
  end
  if seg:match '^[%w_:]+$' then
    return seg
  end
  return nil
end
local function operands(segs, lo, hi)
  local out = {}
  for i = lo, hi do
    local e = expand_operand(segs[i])
    if not e then
      return nil
    end
    out[#out + 1] = e
  end
  return out
end

-- A relation `~>` / `~=` at segment `idx`. Left/right operand counts pick a form:
--   $~>       convertible_to            $~>$T$S convertible_to<T, S> (prefix)
--   $T$~>$S   convertible_to<T, S> (infix)
--   $~>$T / $T$~>  convertible_to<T, $>  (the missing operand becomes a literal
--                                         `$`, which fails the build until filled
--                                         -- same rule as the templates)
local function expand_relation(segs, idx)
  local name = RELATIONS[segs[idx]]
  local L = operands(segs, 1, idx - 1)
  local R = operands(segs, idx + 1, #segs)
  if not L or not R then
    return nil
  end
  local nl, nr = #L, #R
  if nl == 0 and nr == 0 then
    return name
  elseif nl == 0 and nr == 1 then
    return name .. '<' .. R[1] .. ', $>'
  elseif nl == 0 and nr == 2 then
    return name .. '<' .. R[1] .. ', ' .. R[2] .. '>'
  elseif nl == 1 and nr == 1 then
    return name .. '<' .. L[1] .. ', ' .. R[1] .. '>'
  elseif nl == 1 and nr == 0 then
    return name .. '<' .. L[1] .. ', $>'
  end
  return nil
end

-- Prefix / Polish fold of the segments (right to left), so each template wraps
-- the operand(s) to its right -- the outer-to-inner nesting (`$<$?$int` ->
-- vector(optional(int))), and operands fill the templates left to right
-- ($arr$arr$int$5$4 -> array<array<int, 5>, 4>). A template missing operands
-- fills them as literal `$` ($um$K -> unordered_map<K, $>); zero operands give
-- the bare name; LEFTOVER operands (too many) reject via the final stack check.
-- `templated` (a trailing `$`) turns a bare `$?$` into the template.
local function expand_fold(segs, templated)
  local stack, transformed = {}, false
  for i = #segs, 1, -1 do
    local seg = segs[i]
    local t = TEMPLATES[seg]
    if t then
      local pop = function(count, fmt)
        local args = {}
        for _ = 1, count do
          args[#args + 1] = table.remove(stack) or '$' -- missing operand -> `$`
        end
        stack[#stack + 1] = string.format(fmt, unpack(args))
      end
      if t.fmt2 and #stack >= t.arity + 1 then
        pop(t.arity + 1, t.fmt2) -- the one-larger form (cast type + expression)
      elseif #stack > 0 then
        pop(t.arity, t.fmt) -- underspecified operands fill as `$`
      else
        stack[#stack + 1] = (templated and t.tbare) or t.bare
      end
      transformed = true
    elseif ATOM[seg] then
      stack[#stack + 1] = ATOM[seg]
      transformed = true
    elseif seg:match '^[%w_:]+$' then
      stack[#stack + 1] = seg -- literal inner type
    else
      return nil
    end
  end
  if #stack ~= 1 or not transformed then
    return nil
  end
  return stack[1]
end

-- The paren call form `$head(a, b, ...)`: whitespace-stripped, arity-checked, and
-- each `$`-arg recursively expanded (so `$>($?(int))` nests).
local function expand_paren(head, argstr)
  local t, rel = TEMPLATES[head], RELATIONS[head]
  if not t and not rel then
    return nil
  end
  local args = {}
  for _, a in ipairs(split_commas(argstr)) do
    a = vim.trim(a)
    if a ~= '' then
      if a:sub(1, #SIGIL) == SIGIL then
        local ex = M.expand(a)
        if not ex then
          return nil
        end
        args[#args + 1] = ex
      else
        args[#args + 1] = a
      end
    end
  end
  if rel then
    if #args == 0 then
      return rel
    elseif #args == 1 then
      return rel .. '<' .. args[1] .. ', $>' -- missing operand -> `$`
    elseif #args == 2 then
      return rel .. '<' .. args[1] .. ', ' .. args[2] .. '>'
    end
    return nil
  end
  if #args == 0 then
    return t.bare
  elseif #args == t.arity then
    return string.format(t.fmt, unpack(args))
  elseif t.fmt2 and #args == t.arity + 1 then
    return string.format(t.fmt2, unpack(args))
  elseif #args < t.arity then
    -- underspecified: fill the missing operands as literal `$` (same as the
    -- sigil form), so $um(K) -> std::unordered_map<K, $>.
    local filled = {}
    for i = 1, t.arity do
      filled[i] = args[i] or '$'
    end
    return string.format(t.fmt, unpack(filled))
  end
  return nil
end

-- Evaluate a `$`-token to its C++ expansion, or nil if it isn't a valid DSL
-- token. The paren form `$head(...)` is tried first; otherwise the token is split
-- on the sigil and dispatched to the relation handler (a `~>`/`~=` segment is
-- present) or the Polish fold (templates + atoms). A bare unknown `$Ident` folds
-- to nil and is left untouched by the interactive authoring layer.
function M.expand(token)
  if token:sub(1, #SIGIL) ~= SIGIL then
    return nil
  end
  -- Odin array sugar `$[N]T` -> std::array<T, N>. Dims nest left to right
  -- ($[4][5]int -> std::array<std::array<int, 5>, 4>), a missing dim or element
  -- fills as `$` ($[5] -> std::array<$, 5>, $[]int -> std::array<int, $>), and
  -- the element may itself be a $form ($[5]$<$int -> array<vector<int>, 5>).
  if token:sub(#SIGIL + 1, #SIGIL + 1) == '[' then
    local rest = token:sub(#SIGIL + 1)
    local dims = {}
    while true do
      local d, r = rest:match '^%[([^%[%]]*)%](.*)$'
      if not d then
        break
      end
      dims[#dims + 1] = vim.trim(d)
      rest = r
    end
    if #dims == 0 then
      return nil -- `$[` with no closing `]` isn't a complete block
    end
    local elem
    if rest == '' then
      elem = '$'
    elseif rest:sub(1, #SIGIL) == SIGIL then
      elem = M.expand(rest)
      if not elem then
        return nil
      end
    elseif rest:match '^[%w_:]+$' then
      elem = rest
    else
      return nil
    end
    for i = #dims, 1, -1 do
      elem = string.format('std::array<%s, %s>', elem, dims[i] == '' and '$' or dims[i])
    end
    return elem
  end
  -- angle form `$<T, S>` -> `template <typename T, typename S>`: each bare
  -- identifier becomes a `typename` param, a multi-token arg (e.g. `usize N`) is
  -- kept verbatim. (`$<` without a closing `>` is still the vector wrapper below.)
  local targs = token:match('^' .. SIGIL_PAT .. '<(.-)>$')
  if targs then
    local parts = {}
    for _, a in ipairs(split_commas(targs)) do
      a = vim.trim(a)
      if a ~= '' then
        parts[#parts + 1] = a:match '^[%a_][%w_]*$' and ('typename ' .. a) or a
      end
    end
    if #parts == 0 then
      return nil
    end
    return 'template <' .. table.concat(parts, ', ') .. '>'
  end
  local head, argstr = token:match('^' .. SIGIL_PAT .. '([%w_?<>%^~=]+)%((.*)%)$')
  if head then
    return expand_paren(head, argstr)
  end
  local segs = vim.split(token:sub(#SIGIL + 1), SIGIL, { plain = true })
  -- a trailing empty segment is a dangling `$` (`$?$`) -- "templated, no arg".
  local templated = false
  if segs[#segs] == '' then
    templated = true
    table.remove(segs)
  end
  if #segs == 0 then
    return nil
  end
  for i, seg in ipairs(segs) do
    if RELATIONS[seg] then
      return expand_relation(segs, i)
    end
  end
  return expand_fold(segs, templated)
end

-- Naive "is byte column col0 inside a "..." string on this line": odd count of
-- unescaped quotes before it. `$` is valid C++ only inside a string, so a `$`
-- there is left completely alone.
local function in_string(line, col0)
  local n, i = 0, 1
  while i <= col0 do
    local c = line:sub(i, i)
    if c == '\\' then
      i = i + 2
    elseif c == '"' then
      n, i = n + 1, i + 1
    else
      i = i + 1
    end
  end
  return n % 2 == 1
end

-- Tree-sitter is the authority for the interactive path.  The line-local quote
-- scanner above intentionally remains as the deterministic fallback used by
-- the pure parser tests and while a parser is unavailable.  In particular,
-- Tree-sitter protects raw strings, character literals, and multiline comments
-- which cannot be classified correctly from one source row in isolation.
function M.protected_at(bufnr, row0, col0)
  bufnr = bufnr or 0
  local okp, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not okp or not parser then
    return in_string(vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or '', col0)
  end
  pcall(function()
    parser:parse()
  end)
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = bufnr,
    pos = { row0, math.max(0, col0) },
    ignore_injections = false,
  })
  if not ok then
    return false
  end
  while node do
    local kind = node:type()
    if
      kind:find('comment', 1, true)
      or kind:find('string', 1, true)
      or kind == 'char_literal'
      or kind == 'raw_string_literal'
      or kind == 'system_lib_string'
    then
      return true
    end
    node = node:parent()
  end
  return false
end

-- Special-member shorthands: $copy etc. -> the signature for the enclosing class
-- X (the inverse of dans_frontend_cpp.special_members, which collapses these back
-- to $copy). X is supplied by the caller (treesitter), so these are handled in
-- resolve rather than the pure M.expand.
local SPECIAL = {
  copy = function(x)
    return x .. '(const ' .. x .. '&)'
  end,
  copya = function(x)
    return 'def operator=(const ' .. x .. '&) -> ' .. x .. '&'
  end,
  move = function(x)
    return x .. '(' .. x .. '&&)'
  end,
  movea = function(x)
    return 'def operator=(' .. x .. '&&) -> ' .. x .. '&'
  end,
}

-- Name of the class/struct whose member area the cursor is in, or nil (nil inside
-- a method body, so $copy only fires where special members are declared).
local function enclosing_class_name()
  local okp, parser = pcall(vim.treesitter.get_parser, 0)
  if okp and parser then
    pcall(function()
      parser:parse()
    end)
  end
  local ok, node = pcall(vim.treesitter.get_node)
  if not ok then
    return nil
  end
  while node do
    local nt = node:type()
    if nt == 'compound_statement' or nt == 'function_definition' then
      return nil
    end
    if nt == 'class_specifier' or nt == 'struct_specifier' then
      local nm = node:field('name')[1]
      return nm and vim.treesitter.get_node_text(nm, 0) or nil
    end
    node = node:parent()
  end
  return nil
end
M.enclosing_class_name = enclosing_class_name

-- Decide what pressing <Space> should do at 0-based cursor `col` on `line`. The
-- token is the trailing run of snippet chars ENDING at the cursor (identifiers,
-- the `$` separator, and the sigils `?`/`^`/`<`), taken from its first `$`. `$`
-- is never valid C++ outside a string, so such a block is always a snippet:
--   { 'expand', bs, text } -> replace the block [bs,col) with text + a space
--   { 'unresolved', bs }   -> preserve the block and insert the requested space
--   nil                    -> no `$`-block ends here -> just insert a space
-- A trailing non-snippet char (e.g. `$sa(`) means no block ends at the cursor,
-- so nothing fires. Exposed for headless tests.
function M.resolve(line, col, class_fn)
  local before = line:sub(1, col)
  -- Odin array sugar `$[N]T` ending at the cursor: `[`/`]` are NOT in the
  -- generic run class below (indexing like `m[$i]` must not be grabbed), so a
  -- block that STARTS with `$[` is matched explicitly here.
  local arr = before:match('(' .. SIGIL_PAT .. '%[[%w_$?<>%^~=%[%]:]*)$')
  if arr then
    local abs0 = col - #arr
    if not in_string(line, abs0) then
      local atext = M.expand(arr)
      return { action = atext and 'expand' or 'unresolved', bs = abs0, text = atext }
    end
  end
  -- paren form `$head(...)` ending at the cursor: balanced parens, so it may hold
  -- spaces / commas the run scan below would stop at. Tried first.
  local paren = before:match('(' .. SIGIL_PAT .. '[%w_?<>%^~=]+%b())$')
  if paren then
    local pbs = col - #paren
    if not in_string(line, pbs) then
      local ptext = M.expand(paren)
      return { action = ptext and 'expand' or 'unresolved', bs = pbs, text = ptext }
    end
  end
  -- angle template form `$<T, S>` ending at the cursor (holds commas/spaces too).
  -- Requires a closing `>`, so the bare `$<` vector wrapper still goes to the run
  -- scan below.
  local angle = before:match('(' .. SIGIL_PAT .. '<[^<>]*>)$')
  if angle then
    local abs = col - #angle
    if not in_string(line, abs) then
      local atext = M.expand(angle)
      return { action = atext and 'expand' or 'unresolved', bs = abs, text = atext }
    end
  end
  -- sigil form: the trailing run of snippet chars (incl the relation `~>=` and `>`).
  local run = before:match '([%w_$?<>^~=]*)$'
  if run == '' then
    return nil
  end
  local p = run:find(SIGIL, 1, true)
  if not p then
    return nil
  end
  local bs = col - #run + p - 1 -- 0-based col of the first `$`
  if in_string(line, bs) then
    return nil
  end
  local block = run:sub(p)
  -- class-name-dependent special members ($copy etc.); class_fn (treesitter) is
  -- only called when one matches, so a normal space pays nothing for it.
  local sm = SPECIAL[block:sub(#SIGIL + 1)]
  if sm then
    local x = class_fn and class_fn()
    if x then
      return { action = 'expand', bs = bs, text = sm(x) }
    end
    return { action = 'unresolved', bs = bs }
  end
  local text = M.expand(block)
  if text then
    return { action = 'expand', bs = bs, text = text }
  end
  -- Preserve unresolved input.  Earlier revisions deleted an unknown block on
  -- Space because `$` is not normally valid C++; that made one typo destructive
  -- and was especially surprising while editing a partial template.  The
  -- authoring layer now inserts the requested space and leaves the text for the
  -- user to correct.
  return { action = 'unresolved', bs = bs }
end

-- The live `$`-block ending at 0-based `col` (the token being typed), or nil.
-- Same scanning as resolve, minus the expansion: array sugar, paren form, angle
-- form, then the plain sigil run. Used by the preview.
local function block_at(line, col)
  local before = line:sub(1, col)
  for _, pat in ipairs {
    SIGIL_PAT .. '%[[%w_$?<>%^~=%[%]:]*', -- array sugar `$[N]T`
    SIGIL_PAT .. '[%w_?<>%^~=]+%b()', -- paren form `$head(...)`
    SIGIL_PAT .. '<[^<>]*>', -- angle template form `$<T, S>`
  } do
    local b = before:match('(' .. pat .. ')$')
    if b then
      local bs = col - #b
      if not in_string(line, bs) then
        return b, bs
      end
      return nil
    end
  end
  local run = before:match '([%w_$?<>%^~=]*)$'
  if run and run ~= '' then
    local p = run:find(SIGIL, 1, true)
    if p then
      local bs = col - #run + p - 1
      if not in_string(line, bs) then
        return run:sub(p), bs
      end
    end
  end
  return nil
end
M.block_at = block_at

-- Brief display name for a snippet head: the bare expansion minus std:: --
-- arr -> array, um -> unordered_map, `?` -> optional, `~>` -> convertible_to.
local function head_name(head)
  local t = TEMPLATES[head]
  if t then
    return ((t.tbare or t.bare):gsub('std::', ''))
  end
  if RELATIONS[head] then
    return (RELATIONS[head]:gsub('std::', ''))
  end
  if ATOM[head] then
    return (ATOM[head]:gsub('std::', ''))
  end
  return nil
end

-- The block's leading snippet name, for the preview label.
local function block_name(block)
  if block:sub(#SIGIL + 1, #SIGIL + 1) == '[' then
    return 'array'
  end
  local phead = block:match('^' .. SIGIL_PAT .. '([%w_?<>%^~=]+)%(')
  if phead then
    return head_name(phead) or phead
  end
  if block:match('^' .. SIGIL_PAT .. '<[^<>]*>$') then
    return 'template'
  end
  local segs = vim.split(block:sub(#SIGIL + 1), SIGIL, { plain = true })
  for _, seg in ipairs(segs) do
    if RELATIONS[seg] then
      return head_name(seg)
    end
  end
  return head_name(segs[1]) or segs[1]
end

-- All snippet heads the last partial segment could become, sorted (templates,
-- atoms, relations, special members). Exact matches are excluded -- those
-- expand directly.
local function head_candidates(partial)
  if partial == '' then
    return {}
  end
  local seen, out = {}, {}
  local function collect(tbl)
    for k in pairs(tbl) do
      if type(k) == 'string' and #k > #partial and k:sub(1, #partial) == partial and not seen[k] then
        seen[k] = true
        out[#out + 1] = k
      end
    end
  end
  collect(TEMPLATES)
  collect(ATOM)
  collect(RELATIONS)
  collect(SPECIAL)
  table.sort(out)
  return out
end
M.head_candidates = head_candidates

-- Preview for the `$`-block being typed at 0-based `col`, or nil. Forms:
--   { name, text }   -- the block expands as it stands (missing parts as `$`)
--   { candidates = { { head, name }, ... } } -- the final segment is a partial
--                       head; its prefix matches, briefly named
-- class_fn supplies the enclosing class for $copy/$move previews (falls back
-- to `T` so the shape still shows outside a class).
function M.preview(line, col, class_fn)
  local block = block_at(line, col)
  if not block or block == SIGIL then
    return nil
  end
  local sm = SPECIAL[block:sub(#SIGIL + 1)]
  if sm then
    local x = (class_fn and class_fn()) or 'T'
    return { name = block:sub(#SIGIL + 1), text = sm(x) }
  end
  local text = M.expand(block)
  if text then
    return { name = block_name(block), text = text }
  end
  -- the block doesn't expand yet: if the FINAL segment is a partial head,
  -- preview its prefix matches ($u -> um / up; $arr$ar -> arr).
  local segs = vim.split(block:sub(#SIGIL + 1), SIGIL, { plain = true })
  local partial = segs[#segs]
  if not partial or partial == '' or partial:find '%[' then
    return nil
  end
  local cands = head_candidates(partial)
  if #cands == 0 then
    return nil
  end
  if #cands == 1 then
    -- unique completion: expand the block as if the head were finished
    segs[#segs] = cands[1]
    local full = SIGIL .. table.concat(segs, SIGIL)
    local t = M.expand(full)
    if t then
      return { name = block_name(full), text = t }
    end
    local sm1 = SPECIAL[cands[1]]
    if sm1 and #segs == 1 then
      return { name = cands[1], text = sm1((class_fn and class_fn()) or 'T') }
    end
    return nil
  end
  local out = {}
  for i = 1, math.min(#cands, 4) do
    out[#out + 1] = { head = cands[i], name = head_name(cands[i]) or (SPECIAL[cands[i]] and 'special member') or cands[i] }
  end
  return { candidates = out }
end

-- std symbol (after `std::`) -> the header that provides it. Used to auto-add an
-- include when a snippet expands to a std type, the way LSP auto-import does.
local STD_HEADERS = {
  string = '<string>',
  string_view = '<string_view>',
  vector = '<vector>',
  array = '<array>',
  span = '<span>',
  optional = '<optional>',
  nullopt = '<optional>',
  unordered_map = '<unordered_map>',
  map = '<map>',
  unique_ptr = '<memory>',
  shared_ptr = '<memory>',
  ranges = '<ranges>',
  views = '<ranges>',
  convertible_to = '<concepts>',
  same_as = '<concepts>',
  invocable = '<concepts>',
  invoke_result_t = '<type_traits>',
  runtime_error = '<stdexcept>',
  format = '<format>',
  unreachable = '<utility>',
  to_underlying = '<utility>',
}

-- Add any std headers `text` needs to the file's `// StdLib` block, skipping ones
-- already included. No-op (returns nil) when there is no `// StdLib` demarcation
-- -- the convention is opt-in. Returns (insert_row0, count) for cursor fixup.
local function add_std_includes(bufnr, text)
  local need = {}
  for sym in text:gmatch 'std::([%w_]+)' do
    if STD_HEADERS[sym] then
      need[STD_HEADERS[sym]] = true
    end
  end
  if not next(need) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local stdlib_row, have = nil, {}
  for i, l in ipairs(lines) do
    if l:match '^%s*//%s*StdLib%s*$' then
      stdlib_row = i - 1
    end
    local inc = l:match '^%s*#%s*include%s*(<[^>]+>)'
    if inc then
      have[inc] = true
    end
  end
  if not stdlib_row then
    return -- no StdLib demarcation: skip (clang-format / the user owns layout)
  end
  local add = {}
  for h in pairs(need) do
    if not have[h] then
      add[#add + 1] = '#include ' .. h
    end
  end
  if #add == 0 then
    return
  end
  table.sort(add)
  vim.api.nvim_buf_set_lines(bufnr, stdlib_row + 1, stdlib_row + 1, false, add)
  return stdlib_row + 1, #add
end
M.add_std_includes = add_std_includes

-- :DansCppFormat -- reformat to the dans layout. Two things it does reliably:
--   1. line 1 is `// <relative path>`.
--   2. every std header (`<name>`, no `/` and no `.`) is grouped under a `// StdLib`
--      marker (created after the last include if absent), so clang-format sorts the
--      std group on its own.
-- Internals / Externals classification is project-specific (this project and
-- dans-core both live under <dans/...>), so those groups are left exactly as the
-- user arranged them.
function M.format()
  local buf = 0
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- 1. path comment on line 1
  local rel = vim.fn.fnamemodify(name, ':.'):gsub('\\', '/')
  local pathline = '// ' .. rel
  local l1 = lines[1]
  local is_path = l1 and l1:match '^//%s+%S' and (l1:find('/', 1, true) or l1:match '%.%a+%s*$')
  if is_path then
    lines[1] = pathline
  else
    table.insert(lines, 1, pathline)
  end

  -- 2. gather std headers under // StdLib
  local kept, std, seen, last_inc, stdlib_at = {}, {}, {}, nil, nil
  for _, l in ipairs(lines) do
    local h = l:match '^%s*#%s*include%s*<([%w_]+)>%s*$' -- std: no `/`, no `.`
    if h and not seen['<' .. h .. '>'] then
      seen['<' .. h .. '>'] = true
      std[#std + 1] = '#include <' .. h .. '>'
    elseif not h then
      kept[#kept + 1] = l
      if l:match '^%s*//%s*StdLib%s*$' then
        stdlib_at = #kept
      elseif l:match '^%s*#%s*include' then
        last_inc = #kept
      end
    end
  end
  table.sort(std)
  if #std > 0 then
    if not stdlib_at then
      -- create the block right after the last (non-std) include, else after line 1
      local at = last_inc or 1
      table.insert(kept, at + 1, '// StdLib')
      stdlib_at = at + 1
    end
    for i = #std, 1, -1 do
      table.insert(kept, stdlib_at + 1, std[i])
    end
    lines = kept
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

return M
