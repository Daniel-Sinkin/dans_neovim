-- Headless spec for the statusline jumplist trail (custom.dans_jumptrail).
-- Run:  nvim --headless --cmd "set noswapfile" -c "luafile tests/jumptrail_spec.lua" -c "qa!"
-- Jump entries are created the real way: :edit file-to-file transitions.

local J = require 'custom.dans_jumptrail'
local pass, fail, fails = 0, 0, {}

local function chk(desc, ok, detail)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. desc .. (detail and ('\n        ' .. detail) or '')
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local function open(name)
  vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/' .. name))
end

-- chain: vk_core.cpp -> camera.hpp -> main.cpp (current). clearjumps first:
-- config startup leaves entries in the window's jumplist.
open 'vk_core.cpp'
vim.cmd 'clearjumps'
open 'camera.hpp'
open 'main.cpp'

local s = J.statusline()
local plain = s:gsub('%%#[%w_]*#', '')

local a = plain:find('vk_core.cpp', 1, true)
local b = plain:find('camera.hpp', 1, true)
local c = plain:find('main.cpp', 1, true)
chk('all three files present', a and b and c, 'got: ' .. plain)
chk('oldest -> newest order', a and b and c and a < b and b < c, 'got: ' .. plain)
chk('arrow separators', plain:find('vk_core.cpp -> camera.hpp -> main.cpp', 1, true) ~= nil, 'got: ' .. plain)
chk('vk_ file carries the first-party vulkan color', s:find('%%#DansVulkanMineSl#vk_core.cpp') ~= nil, 'got: ' .. s)
chk('current file emphasized', s:find('%%#DansTrailCurrentSl#main.cpp') ~= nil, 'got: ' .. s)

-- consecutive jumps within one file collapse to a single node (the file is
-- written to disk first: buffers outside the project are protect-read-only)
do
  local f = assert(io.open(tmp .. '/solo.cpp', 'w'))
  for i = 1, 200 do
    f:write('// line ' .. i .. '\n')
  end
  f:close()
end
open 'solo.cpp'
vim.cmd 'clearjumps'
vim.cmd 'normal! G'
vim.cmd 'normal! gg'
vim.cmd 'normal! G'
local s2 = J.statusline():gsub('%%#[%w_]*#', '')
local first = s2:find('solo.cpp', 1, true)
local second = first and s2:find('solo.cpp', first + 1, true)
chk('same-file jumps collapse', first ~= nil and second == nil, 'got: ' .. s2)

-- the trail caps at 120 display columns, older entries fall off behind `..`
vim.cmd 'clearjumps'
for i = 1, 12 do
  open(string.format('really_long_translation_unit_name_%02d.cpp', i))
end
local s3 = J.statusline()
local plain3 = s3:gsub('%%#[%w_]*#', ''):gsub('%%[mr<]', '')
chk('long trail is capped', vim.fn.strdisplaywidth(plain3) <= 126, 'width: ' .. vim.fn.strdisplaywidth(plain3) .. ' got: ' .. plain3)
chk('cap marks the cut', plain3:find('^%.%. %-> ') ~= nil, 'got: ' .. plain3)
chk('current file still last', plain3:find('really_long_translation_unit_name_12.cpp', 1, true) ~= nil, 'got: ' .. plain3)

local report = { string.format('jumptrail_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
