-- Headless spec for the $-type-snippet expander (cpp_type_snippets.M.expand).
-- Pure string-in / string-out, so no buffer is needed. Run:
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/type_snippets_spec.lua" -c "qa!"

local S = require 'custom.cpp_type_snippets'
local pass, fail, fails = 0, 0, {}

local function eq(token, expect)
  local got = S.expand(token)
  if got == expect then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', token, tostring(expect), tostring(got))
  end
end

-- atoms
eq('$str', 'std::string')
eq('$sv', 'std::string_view')
eq('$ra', 'std::ranges')
eq('$rv', 'std::ranges::views')

-- bare optional sigil
eq('$?', 'std::nullopt')

-- prefix unary wrappers (outer-to-inner)
eq('$?$int', 'std::optional<int>')
eq('$?$str', 'std::optional<std::string>')
eq('$?$sdfgfd', 'std::optional<sdfgfd>')
eq('$^$Foo', 'std::unique_ptr<Foo>')
eq('$<$str', 'std::vector<std::string>')
eq('$<$Foo', 'std::vector<Foo>')

-- nested wrappers, outer first
eq('$<$?$int', 'std::vector<std::optional<int>>')
eq('$?$<$str', 'std::optional<std::vector<std::string>>')
eq('$<$<$int', 'std::vector<std::vector<int>>')

-- smart pointers: `^`/`up` (unique) and `sp` (shared) -- wrap + bare form
eq('$up', 'std::unique_ptr')
eq('$^', 'std::unique_ptr')
eq('$sp', 'std::shared_ptr')
eq('$up$int', 'std::unique_ptr<int>')
eq('$^$int', 'std::unique_ptr<int>')
eq('$sp$int', 'std::shared_ptr<int>')
eq('$up$str', 'std::unique_ptr<std::string>')
eq('$<$^$int', 'std::vector<std::unique_ptr<int>>')

-- binary combinators (prefix)
eq('$um$K$V', 'std::unordered_map<K, V>')
eq('$map$K$V', 'std::map<K, V>')
eq('$arr$T$N', 'std::array<T, N>')
eq('$um$str$<$int', 'std::unordered_map<std::string, std::vector<int>>')

-- casts: short + long spellings wrap the type; bare form is the keyword
eq('$sc$u32', 'static_cast<u32>')
eq('$rc$int', 'reinterpret_cast<int>')
eq('$cc$Bar', 'const_cast<Bar>')
eq('$dc$Foo', 'dynamic_cast<Foo>')
eq('$scast$u32', 'static_cast<u32>')
eq('$rcast$u8', 'reinterpret_cast<u8>')
eq('$ccast$T', 'const_cast<T>')
eq('$sc', 'static_cast')
eq('$rc', 'reinterpret_cast')
eq('$cc', 'const_cast')
eq('$dc', 'dynamic_cast')
eq('$sc$?$int', 'static_cast<std::optional<int>>')

-- casts with a second operand wrap the expression: type + expr (sigil + paren)
eq('$sc$u32$x', 'static_cast<u32>(x)')
eq('$rc$int$p', 'reinterpret_cast<int>(p)')
eq('$cc$Bar$ref', 'const_cast<Bar>(ref)')
eq('$dc$Foo$base', 'dynamic_cast<Foo>(base)')
eq('$scast$u32$x', 'static_cast<u32>(x)')
eq('$sc(u32, x)', 'static_cast<u32>(x)')
eq('$dc(Foo, base)', 'dynamic_cast<Foo>(base)')
eq('$sc$u32$x$y', nil) -- too many operands
eq('$sc(u32, x, y)', nil) -- too many operands

-- rejected: bare unknown identifier (nonsense)
eq('$sdfgfd', nil)
eq('$Foo', nil)
eq('$int', nil)
eq('$', nil)

-- bare templates expand to the plain template name (like $arr -> std::array)
eq('$<', 'std::vector')
eq('$>', 'std::vector')
eq('$arr', 'std::array')
eq('$um', 'std::unordered_map')

-- underspecified: missing operands become a literal `$` (the expansion always
-- works; the `$` fails the build until filled in)
eq('$um$K', 'std::unordered_map<K, $>')
eq('$arr$T', 'std::array<T, $>')
eq('$arr$int', 'std::array<int, $>')
eq('$map$K', 'std::map<K, $>')

-- nesting: operands fill the templates left to right, innermost binding
-- tightest -- $arr$arr$int$5$4 reads "array of (array of int, 5), 4"
eq('$arr$arr$int$5$4', 'std::array<std::array<int, 5>, 4>')
eq('$arr$arr$int$5', 'std::array<std::array<int, 5>, $>')
eq('$arr$arr$int', 'std::array<std::array<int, $>, $>')
eq('$um$str$arr$int$4', 'std::unordered_map<std::string, std::array<int, 4>>')
eq('$<$arr$int$3', 'std::vector<std::array<int, 3>>')
eq('$arr$<$int$5', 'std::array<std::vector<int>, 5>')

-- overspecified still rejects (leftover operands are never guessed at)
eq('$?$int$float', nil)
eq('$um$K$V$X', nil)

-- Odin array sugar: $[N]T -> std::array<T, N>, dims nest left to right,
-- missing parts fill as `$`, the element may be a $form
eq('$[5]int', 'std::array<int, 5>')
eq('$[4][5]int', 'std::array<std::array<int, 5>, 4>')
eq('$[2][3][4]f32', 'std::array<std::array<std::array<f32, 4>, 3>, 2>')
eq('$[k_max]Foo', 'std::array<Foo, k_max>')
eq('$[5]', 'std::array<$, 5>')
eq('$[]int', 'std::array<int, $>')
eq('$[]', 'std::array<$, $>')
eq('$[5]$<$int', 'std::array<std::vector<int>, 5>')
eq('$[3]$um$K$V', 'std::array<std::unordered_map<K, V>, 3>')
eq('$[5]$str', 'std::array<std::string, 5>')
eq('$[5]x y', nil) -- garbage element

-- $> is a vector alias (prefix + paren)
eq('$>$Foo', 'std::vector<Foo>')

-- paren call form: whitespace-stripped, $-args recurse, missing args fill `$`
eq('$arr(T, N)', 'std::array<T, N>')
eq('$um(K, V)', 'std::unordered_map<K, V>')
eq('$>(T)', 'std::vector<T>')
eq('$?(int)', 'std::optional<int>')
eq('$>($?(int))', 'std::vector<std::optional<int>>')
eq('$sc(u32)', 'static_cast<u32>')
eq('$um(K)', 'std::unordered_map<K, $>') -- underspecified -> fill
eq('$arr(A, B, C)', nil) -- too many args

-- $? value vs template: bare is nullopt, templated/with-arg is optional
eq('$?', 'std::nullopt')
eq('$?$', 'std::optional')
eq('$?$T', 'std::optional<T>')

-- relations: bare / prefix / infix; a missing operand fills as `$` (uniform
-- with the template rule, prefix and postfix alike)
eq('$~>', 'std::convertible_to')
eq('$~=', 'std::same_as')
eq('$~>$T$S', 'std::convertible_to<T, S>')
eq('$T$~>$S', 'std::convertible_to<T, S>')
eq('$T$~=$S', 'std::same_as<T, S>')
eq('$~>$T', 'std::convertible_to<T, $>')
eq('$T$~>', 'std::convertible_to<T, $>')
eq('$~>(A, B)', 'std::convertible_to<A, B>')
eq('$~>(T)', 'std::convertible_to<T, $>')

-- angle template form: $<T, S> -> template <typename T, typename S>
eq('$<T>', 'template <typename T>')
eq('$<T, S>', 'template <typename T, typename S>')
eq('$<T, usize N>', 'template <typename T, usize N>')
-- vector forms unaffected (no closing > = the wrapper)
eq('$<', 'std::vector')
eq('$<$Foo', 'std::vector<Foo>')
eq('$<(Foo)', 'std::vector<Foo>')

-- old postfix forms no longer expand (committed to prefix, no order-guessing)
eq('$str$?', nil)
eq('$Foo<', nil)
eq('$int?', nil)
eq('$K$V$um', nil)

-- ===================== resolve: the space-trigger path =====================
-- The array sugar must be caught by resolve (brackets aren't in the generic
-- run class), and indexing brackets must never be grabbed.
do
  local function res(line, expect_action, expect_text)
    local r = S.resolve(line, #line, nil)
    local got_action = r and r.action or nil
    local got_text = r and r.text or nil
    if got_action == expect_action and got_text == expect_text then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  resolve %q\n        exp: %s / %s\n        got: %s / %s', line, tostring(expect_action), tostring(expect_text), tostring(got_action), tostring(got_text))
    end
  end
  res('$[5]int', 'expand', 'std::array<int, 5>')
  res('    $[4][5]f32', 'expand', 'std::array<std::array<f32, 5>, 4>')
  res('auto x = $[3]$<$int', 'expand', 'std::array<std::vector<int>, 3>')
  res('$arr$arr$int$5$4', 'expand', 'std::array<std::array<int, 5>, 4>')
  res('$um$K', 'expand', 'std::unordered_map<K, $>')
  res('m[$idx]', nil, nil) -- indexing, not a block ending at the cursor
  res('call(arr[i]', nil, nil)
  res('s = "$[5]int', nil, nil) -- inside a string: untouched
end

-- ===================== preview: live $-block feedback =====================
do
  local function prev(line, expect)
    local p = S.preview(line, #line, nil)
    local got
    if p == nil then
      got = nil
    elseif p.candidates then
      local heads = {}
      for _, c in ipairs(p.candidates) do
        heads[#heads + 1] = c.head
      end
      got = 'cands:' .. table.concat(heads, ',')
    else
      got = string.format('[%s] %s', p.name, p.text)
    end
    if got == expect then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  preview %q\n        exp: %s\n        got: %s', line, tostring(expect), tostring(got))
    end
  end
  -- live expansion preview: brief name + how the block stands right now
  prev('$arr$T', '[array] std::array<T, $>')
  prev('$arr$arr$int$5', '[array] std::array<std::array<int, 5>, $>')
  prev('$um$K', '[unordered_map] std::unordered_map<K, $>')
  prev('$[5]', '[array] std::array<$, 5>')
  prev('$[4][5]int', '[array] std::array<std::array<int, 5>, 4>')
  prev('$str', '[string] std::string')
  prev('$?$int', '[optional] std::optional<int>')
  prev('x = $<$str', '[vector] std::vector<std::string>')
  -- partial head: unique prefix completes ($ar -> arr), ambiguous lists
  prev('$ar', '[array] std::array')
  prev('$u', 'cands:um,up')
  -- special members preview with a generic T outside a class
  prev('$copy', '[copy] T(const T&)')
  -- no block, no preview
  prev('plain text', nil)
  prev('$', nil)
  prev('s = "$arr', nil) -- inside a string
end

-- trigger: both <Space> and <S-Space> fire the expansion (Neovide sends a
-- distinct <S-Space>, which a bare <Space> map would miss).
do
  local function expand_via(lhs)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].filetype = 'cpp'
    vim.api.nvim_set_current_buf(b)
    vim.cmd 'doautocmd FileType'
    local keys = vim.api.nvim_replace_termcodes('i$str' .. lhs .. '<Esc>', true, false, true)
    vim.api.nvim_feedkeys(keys, 'x', false)
    return vim.api.nvim_get_current_line()
  end
  local function chk(desc, got)
    if got == 'std::string ' then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  %s\n        got: %q', desc, got)
    end
  end
  chk('<Space> expands $str', expand_via '<Space>')
  chk('<S-Space> expands $str', expand_via '<S-Space>')
end

local report = { string.format('type_snippets_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
