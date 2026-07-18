-- Headless spec: frontend coloring must not leak into block comments.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/comment_color_spec.lua" -c "qa!"
-- dans_macros (extmark colors) must skip /* */ and /** */ blocks; the markers
-- DansCommentMask matchadd must span a multi-line block (so matchadd colors like
-- `copy` get neutralized inside one).

local pass, fail, fails = 0, 0, {}
local function ok(desc, cond)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. desc
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  '/** a doxygen block',
  ' * mentions FOO and copy and types here',
  ' */',
  'void f() { int FOO = 0; (void) FOO; }',
})
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)
require('custom.dans_macros').refresh(b)

local ns = vim.api.nvim_get_namespaces()['ds_macros']
local function marks_on(row)
  return #vim.api.nvim_buf_get_extmarks(b, ns, { row, 0 }, { row, -1 }, {})
end
ok('no macro coloring in a /** */ block', marks_on(1) == 0)
ok('macro coloring still applies in code', marks_on(3) >= 1)

-- the markers comment masks: a MULTI-LINE matchadd (`\_.`) for precise inline
-- `/* */` spans, plus per-line anchored masks (`^\s*/\*` / `^\s*\*`) so a block
-- comment scrolled past its `/*` still grays without the multiline lag. Trigger
-- markers, then inspect the window's matches.
vim.cmd 'doautocmd FileType'
local patterns = {}
for _, m in ipairs(vim.fn.getmatches()) do
  if m.group == 'DansCommentMask' then
    patterns[#patterns + 1] = m.pattern
  end
end
local has_multiline, has_perline = false, false
for _, p in ipairs(patterns) do
  if p:find('\\_', 1, true) then
    has_multiline = true
  end
  if p:find('^%^') then
    has_perline = true -- a `^...`-anchored per-line mask
  end
end
ok('comment mask matchadd exists', #patterns > 0)
ok('comment mask has a multi-line span (\\_.)', has_multiline)
ok('comment mask has per-line anchored masks', has_perline)

local report = { string.format('comment_color_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
