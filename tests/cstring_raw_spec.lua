-- Headless spec for the raw-line `const char*` -> `CString` rewrite in
-- pointer.lua (the ds_cpp_pointer namespace). Run:
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/cstring_raw_spec.lua" -c "qa!"
-- Each line under test sits on its own row with the cursor parked on a leading
-- `// top` line, so no row under test is revealed (the skipper leaves the
-- cursor line raw). We reconstruct the visible string from ONLY the
-- ds_cpp_pointer conceals + inline virt_text and assert it.

local pass, fail, fails = 0, 0, {}

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  '// top',
  'auto name() -> const char*;',
  'auto greet(const char* who) -> void;',
  'const char** argv;',
  'char* raw_ptr();',
  'auto k = "const char*";',
})
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd 'doautocmd FileType'
vim.cmd 'doautocmd BufEnter'
vim.cmd 'doautocmd CursorMoved'

-- pointer renders return-type / member cstrings; the param flip (aliases) renders
-- the parameter ones, so reconstruct from both namespaces.
local pns = vim.api.nvim_get_namespaces()['ds_cpp_pointer']
local ans = vim.api.nvim_get_namespaces()['ds_cpp_aliases']

-- displayed text: apply both namespaces' conceals (hide) and inline virt_text
-- (insert) to the raw line, then return the visible string.
local function display(row0)
  local line = vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1] or ''
  local hidden, inserts = {}, {}
  for _, nsid in ipairs { pns, ans } do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, nsid, { row0, 0 }, { row0, -1 }, { details = true })) do
      local d = m[4]
      if d.conceal ~= nil and d.end_col then
        for c = m[3], d.end_col - 1 do
          hidden[c] = true
        end
      end
      if d.virt_text and d.virt_text_pos == 'inline' then
        local t = ''
        for _, ch in ipairs(d.virt_text) do
          t = t .. ch[1]
        end
        inserts[m[3]] = (inserts[m[3]] or '') .. t
      end
    end
  end
  local s = {}
  for c = 0, #line do
    if inserts[c] then
      s[#s + 1] = inserts[c]
    end
    if c < #line and not hidden[c] then
      s[#s + 1] = line:sub(c + 1, c + 1)
    end
  end
  return table.concat(s)
end

local function chk(desc, got, exp)
  if got == exp then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, tostring(exp), tostring(got))
  end
end

local function chk_true(desc, cond)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s', desc)
  end
end

chk('return type const char*', display(1), 'def name() -> CString;')
-- the param flip owns parameters now: const char* who -> who: CString
chk('parameter const char*', display(2), 'def greet(who: CString) -> void;')

-- double pointer: untouched, and no stray CString
local d_argv = display(3)
chk_true('double pointer has no CString', not d_argv:find('CString', 1, true))

-- char* without const: normal `*`->`^` rendering, no CString
local d_raw = display(4)
chk_true('char* renders char^', d_raw:find('char^', 1, true) ~= nil)
chk_true('char* has no CString', not d_raw:find('CString', 1, true))

-- const char* inside a string literal: untouched
local d_str = display(5)
chk_true('string literal has no CString', not d_str:find('CString', 1, true))

if fail == 0 then
  print(string.format('cstring_raw_spec: PASS %d/%d', pass, pass))
else
  print(string.format('cstring_raw_spec: %d passed, %d FAILED', pass, fail))
  for _, f in ipairs(fails) do
    print(f)
  end
end
