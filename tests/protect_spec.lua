-- Headless spec for dans_protect.is_protected.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/protect_spec.lua" -c "qa!"

local P = require 'custom.dans_protect'
local ROOT = vim.fn.getcwd()
local pass, fail, fails = 0, 0, {}
local function ok(d, c)
  if c then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d
  end
end
local function mk(name, ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, name)
  vim.bo[b].filetype = ft
  return b
end

-- a c++ header outside the project (the standard library case) is protected
ok('stdlib cpp outside project', (P.is_protected(mk('/tmp/dans-protect-system/include/cstdint', 'cpp'))))
-- an out-of-project NON-code file you might open on purpose is left editable
ok('outside non-code editable', not (P.is_protected(mk('/tmp/dans-protect-system/notes.md', 'markdown'))))
-- an in-project source is editable
ok('in-project editable', not (P.is_protected(mk(ROOT .. '/lua/custom/dans_protect.lua', 'lua'))))
-- a path matching .dans_protected (vendor/*) is protected, any filetype
ok('vendor/* protected', (P.is_protected(mk(ROOT .. '/vendor/lib/foo.hpp', 'cpp'))))
ok('non-protected subdir editable', not (P.is_protected(mk(ROOT .. '/lua/foo.lua', 'lua'))))

local report = { string.format('protect_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
