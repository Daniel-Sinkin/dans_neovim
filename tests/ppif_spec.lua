-- Headless spec for platform-aware preprocessor branch evaluation.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/ppif_spec.lua" -c "qa!"

local P = require 'custom.dans_frontend_cpp.ppif'
local pass, fail, fails = 0, 0, {}

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then
      return false
    end
  end
  return true
end

local function eq(desc, lines, plat, expect)
  local got = P.inactive_ranges(lines, plat)
  if same(got, expect) then
    pass = pass + 1
  else
    fail = fail + 1
    local function fmt(r)
      local t = {}
      for _, x in ipairs(r) do
        t[#t + 1] = '{' .. x[1] .. ',' .. x[2] .. '}'
      end
      return '[' .. table.concat(t, ' ') .. ']'
    end
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, fmt(expect), fmt(got))
  end
end

-- simple win-only block
local win_block = { '#if defined(_GLFW_WIN32)', '  win();', '#endif' }
eq('win block on mac -> dead', win_block, 'mac', { { 1, 2 } })
eq('win block on win -> live', win_block, 'win', {})

-- if / elif / else
local three = {
  '#if defined(_GLFW_WIN32)', -- 1
  '  win();', -- 2
  '#elif defined(_GLFW_COCOA)', -- 3
  '  mac();', -- 4
  '#else', -- 5
  '  other();', -- 6
  '#endif', -- 7
}
eq('three-way on mac', three, 'mac', { { 1, 2 }, { 5, 6 } })
eq('three-way on win', three, 'win', { { 3, 4 }, { 5, 6 } })
eq('three-way on linux', three, 'linux', { { 1, 2 }, { 3, 4 } })

-- ifndef
local ifndef = { '#ifndef _WIN32', '  nonwin();', '#endif' }
eq('ifndef _WIN32 on mac -> live', ifndef, 'mac', {})
eq('ifndef _WIN32 on win -> dead', ifndef, 'win', { { 1, 2 } })

-- unknown macro: never touched
eq('unknown macro left normal', { '#if defined(FOO_UNKNOWN)', '  x();', '#endif' }, 'mac', {})
-- compound expression: not evaluated
eq('compound expr left normal', { '#if defined(_GLFW_WIN32) && BUILD', '  x();', '#endif' }, 'mac', {})
-- #if 0 is dead everywhere
eq('#if 0 dead', { '#if 0', '  dead();', '#endif' }, 'mac', { { 1, 2 } })

-- nested: outer live on mac -> evaluate inner; outer dead on win -> whole outer
local nested = {
  '#if defined(_GLFW_COCOA)', -- 1
  '  mac();', -- 2
  '  #if defined(_GLFW_WIN32)', -- 3
  '    never();', -- 4
  '  #endif', -- 5
  '  more();', -- 6
  '#endif', -- 7
}
eq('nested: outer live, inner dead (mac)', nested, 'mac', { { 3, 4 } })
eq('nested: outer dead (win)', nested, 'win', { { 1, 6 } })

local report = { string.format('ppif_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
