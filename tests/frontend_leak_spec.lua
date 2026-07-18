-- Headless spec: the frontend's window-local color matchadds must not leak onto a
-- non-cpp buffer shown in the same window (e.g. `copy` orange in an .xml).
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/frontend_leak_spec.lua" -c "qa!"

local pass, fail, fails = 0, 0, {}
local function ok(d, c)
  if c then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d
  end
end

local function cpp_colors_present()
  for _, m in ipairs(vim.fn.getmatches()) do
    if type(m.group) == 'string' and m.group:match '^Dans%a' and m.group ~= 'DansCommentMask' then
      return true
    end
  end
  return false
end

local cpp = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cpp, 0, -1, false, { 'const int copy = 0;' })
vim.bo[cpp].filetype = 'cpp'

local xml = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(xml, 0, -1, false, { '<a>copy</a>' })
vim.bo[xml].filetype = 'xml'

vim.api.nvim_set_current_buf(cpp)
vim.cmd 'doautocmd FileType'
ok('cpp buffer has frontend colors', cpp_colors_present())

vim.api.nvim_set_current_buf(xml)
vim.cmd 'doautocmd BufEnter'
ok('non-cpp buffer has NO frontend colors', not cpp_colors_present())

vim.api.nvim_set_current_buf(cpp)
vim.cmd 'doautocmd BufEnter'
ok('cpp colors return on re-entry', cpp_colors_present())

local report = { string.format('frontend_leak_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
