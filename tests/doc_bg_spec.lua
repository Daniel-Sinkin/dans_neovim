-- Headless spec: doc-markdown backgrounds. Reconstructs the effective bg of each
-- real-text cell from the ds_cpp_doc_md extmarks (highest-priority hl with a bg)
-- and asserts a fenced ```cpp line is ALL code_bg (treesitter tokens contribute fg
-- only, the block bg dominates) and a prose line is ALL block_bg.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/doc_bg_spec.lua" -c "qa!"

local pass, fail, fails = 0, 0, {}
local function ok(desc, cond)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. desc
  end
end

local dm = require 'custom.cpp_doc_markdown'
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(b, 'E:/repos/neovim-cfg/tests/_docbg.hpp')
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  '/// prose with a sentence',
  '/// ```cpp',
  '/// int value = 42;',
  '/// ```',
})
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor on row 0; code/prose-below rendered
dm.refresh(b)

local ns = vim.api.nvim_get_namespaces()['ds_cpp_doc_md']
local function gbg(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  return h and h.bg or nil
end
local CODE, BLOCK = gbg 'DansDocCodeBlock', gbg 'DansDocBlock'

-- effective bg of byte col on row0 (highest-priority ds_cpp_doc_md hl with a bg)
local function byte_bg(row0, col)
  local bp, bg = -1, nil
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, { row0, 0 }, { row0, -1 }, { details = true })) do
    local d = m[4]
    if d.hl_group and d.end_col and col >= m[3] and col < d.end_col and (d.priority or 0) >= bp then
      local x = gbg(d.hl_group)
      if x then
        bp, bg = d.priority or 0, x
      end
    end
  end
  return bg
end

-- all non-leader cells of a row share `want` bg
local function row_all(row0, want, label)
  local line = vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1]
  local lead = #(line:match '^%s*///%s?' or '')
  local bad = 0
  for c = lead, #line - 1 do
    if byte_bg(row0, c) ~= want then
      bad = bad + 1
    end
  end
  ok(label .. ' (' .. bad .. ' stray cells)', bad == 0)
end

ok('code_bg and block_bg differ', CODE ~= nil and BLOCK ~= nil and CODE ~= BLOCK)
row_all(0, BLOCK, 'prose line all block_bg')
row_all(2, CODE, 'code line all code_bg') -- 42 (an @number) must not punch a hole

local report = { string.format('doc_bg_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
