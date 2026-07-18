-- Headless spec for .hpp outline folding: whole-function folds (not body-only)
-- and the frontend-rendered gray signature in the foldtext.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/fold_spec.lua" -c "qa!"

require('custom.dans_frontend_cpp.fold').setup()

local pass, fail, fails = 0, 0, {}
local function ok(d, c)
  if c then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d
  end
end

local src = {
  'namespace dans::app {', -- 1  named non-detail: stays open
  '', -- 2
  'class Camera {', -- 3  whole-class fold
  '    int x_;', -- 4
  '};', -- 5
  '', -- 6
  'inline auto update(const std::string& s) -> void', -- 7  whole-function fold
  '{', -- 8
  '    use(s);', -- 9
  '}', -- 10
  '', -- 11
  'auto make(VkInstance inst) -> _GLFWwindow*', -- 12  prefix-stripped sig
  '{', -- 13
  '    return nullptr;', -- 14
  '}', -- 15
  '', -- 16
  '} // namespace dans::app', -- 17
}

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, src)
vim.api.nvim_buf_set_name(buf, '/tmp/fold_probe.hpp')
vim.bo[buf].filetype = 'cpp'
vim.api.nvim_set_current_buf(buf)
pcall(function()
  vim.treesitter.get_parser(buf, 'cpp'):parse()
end)

local function level(lnum)
  vim.v.lnum = lnum
  return _G.dans_cpp_foldexpr()
end
local function foldtext(s, e)
  vim.v.foldstart = s
  vim.v.foldend = e
  return _G.dans_cpp_foldtext()
end

-- named non-detail namespace: not folded
ok('namespace dans::app open', level(1) == '0')
-- class: whole fold (sig..brace)
ok('class fold starts at opener', level(3) == '>1')
ok('class fold ends at brace', level(5) == '<1')
-- function update: whole fold including the signature line (was body-only before)
ok('fn update folds from signature', level(7) == '>1')
ok('fn update signature inside fold (not visible)', level(8) == '1')
ok('fn update fold ends at brace', level(10) == '<1')
-- function make: whole fold
ok('fn make folds from signature', level(12) == '>1')
ok('fn make fold ends at brace', level(15) == '<1')

-- foldtext: frontend-rendered signature, prefixes/std:: stripped, trailing { gone
ok('class foldtext', foldtext(3, 5) == '+-- 3 lines: class Camera')
ok('update foldtext strips inline + std::', foldtext(7, 10) == '+-- 4 lines: auto update(const string& s) -> void')
ok('make foldtext strips Vk + _GLFW prefixes', foldtext(12, 15) == '+-- 4 lines: auto make(Instance inst) -> window*')

-- sole-member suppression + namespace member counts
local src2 = {
  'namespace detail', -- 1  one multi-line fn -> fn suppressed, ns folds
  '{', -- 2
  'inline void only() -> void', -- 3
  '{', -- 4
  '    work();', -- 5
  '}', -- 6
  '}', -- 7
  '', -- 8
  'namespace detail2', -- 9  two multi-line fns + one struct -> all fold, ns labeled
  '{', -- 10
  'void a()', -- 11
  '{', -- 12
  '    x();', -- 13
  '}', -- 14
  'void b()', -- 15
  '{', -- 16
  '    y();', -- 17
  '}', -- 18
  'struct S', -- 19
  '{', -- 20
  '    int x;', -- 21
  '};', -- 22
  '}', -- 23
}
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, src2)
vim.api.nvim_buf_set_name(b2, '/tmp/fold_probe2.hpp')
vim.bo[b2].filetype = 'cpp'
vim.api.nvim_set_current_buf(b2)
pcall(function()
  vim.treesitter.get_parser(b2, 'cpp'):parse()
end)

-- detail (sole fn): ns folds, the fn does NOT (suppressed)
ok('sole-member ns folds', level(1) == '>1')
ok('sole fn not folded', level(3) == '1')
ok('sole-member ns label', foldtext(1, 7) == '+-- 7 lines: namespace detail : 1 function')
-- detail2 (2 fn + 1 struct): all fold, label lists counts
ok('multi-member ns folds', level(9) == '>1')
ok('member fn a folds', level(11) == '>2')
ok('member fn b folds', level(15) == '>2')
ok('member struct folds', level(19) == '>2')
ok('multi-member ns label', foldtext(9, 23) == '+-- 15 lines: namespace detail2 : 2 function : 1 struct')

-- arrays + switches fold; a lone function next to a data table still folds
local src3 = {
  'namespace dans::vk', -- 1
  '{', -- 2
  'constexpr std::array k_codes = {', -- 3  array -> fold
  '    A,', -- 4
  '    B,', -- 5
  '};', -- 6
  'constexpr def to_string(int res) -> std::string_view', -- 7  sole fn, still folds
  '{', -- 8
  '    switch (res)', -- 9  switch -> fold
  '    {', -- 10
  '    case 0: return "a";', -- 11
  '    default: return "?";', -- 12
  '    }', -- 13
  '}', -- 14
  '}', -- 15
}
local b3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b3, 0, -1, false, src3)
vim.api.nvim_buf_set_name(b3, '/tmp/fold_probe3.hpp')
vim.bo[b3].filetype = 'cpp'
vim.api.nvim_set_current_buf(b3)
pcall(function()
  vim.treesitter.get_parser(b3, 'cpp'):parse()
end)
ok('array folds', level(3) == '>1')
ok('array fold ends', level(6) == '<1')
ok('lone fn next to array still folds', level(7) == '>1')
ok('switch folds', level(9) == '>2')
ok('switch fold ends', level(13) == '<2')

local report = { string.format('fold_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
