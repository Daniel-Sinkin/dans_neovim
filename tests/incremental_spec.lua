-- Headless spec: the incremental per-row repaint (view.render_row, used on a plain
-- cursor move) must produce byte-identical overlay extmarks to a full refresh.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/incremental_spec.lua" -c "qa!"

local pass, fail, fails = 0, 0, {}
local view = require 'custom.dans_frontend_cpp.view'

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  'struct S {',
  '    int a{1};',
  '    int b{2};',
  '    int c{3};',
  '};',
})
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)
vim.cmd 'doautocmd FileType' -- enable the view for this buffer

local ns = vim.api.nvim_get_namespaces()['ds_frontend_view']
local function snapshot()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
    local d = m[4]
    local txt = {}
    for _, ch in ipairs(d.virt_text or {}) do
      txt[#txt + 1] = ch[1]
    end
    out[m[2]] = m[3] .. '|' .. table.concat(txt)
  end
  return out
end
local function same(x, y)
  for k, v in pairs(x) do
    if y[k] ~= v then
      return false
    end
  end
  for k, v in pairs(y) do
    if x[k] ~= v then
      return false
    end
  end
  return true
end
local function full_at(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd 'doautocmd BufEnter' -- forces a full refresh at the current cursor
  return snapshot()
end

-- ground truth: a full refresh with the cursor on each member row
local SA = full_at(2) -- reveal row 1 (member a)
local SB = full_at(3) -- reveal row 2 (member b)

-- now reproduce A->B as the on_decorate incremental does: from state A, with the
-- cursor moved to B, repaint only the two flipped rows.
full_at(2) -- back to state A
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- cursor now on row 2 (the move target)
view.render_row(b, 1) -- row we left -> overlay
view.render_row(b, 2) -- row we entered -> raw
local SI = snapshot()

local function ok(d, c)
  if c then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d
  end
end
ok('A and B differ (reveal flips)', not same(SA, SB))
ok('incremental A->B == full refresh at B', same(SI, SB))

local report = { string.format('incremental_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
