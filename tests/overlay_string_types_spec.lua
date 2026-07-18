-- Headless spec for two overlay coloring features in render.lua:
--   A) a whole-word `string` nested in a template stays green (DansString), so
--      `vector<string>` shows `string` in string-green while the rest is the blue
--      inlay-type color -- mirroring the raw-line `\<std::string\>` matchadd.
--   B) `const char*` renders as a single green `CString` token (const, caret, and
--      mut marker all dropped); a non-const `char*` is left as `mut char^`.
-- Run from PowerShell (a bash env fails to load the config):
--   nvim --headless --cmd "set noswapfile" -c "luafile E:/repos/neovim-cfg/tests/overlay_string_types_spec.lua" -c "qa!"

local jns = vim.api.nvim_create_namespace 'ds_frontend_view'
local pass, fail, fails = 0, 0, {}

-- Build a buffer wrapping `body` in a struct or function, parse treesitter, put
-- the cursor on line 1 (the wrapper, so body lines render overlaid), and fire the
-- view's autocmds. Returns (bufnr, off) where `off` is the 0-based row of body[1].
local function build(ctx, body)
  local lines, off
  if ctx == 'fn' then
    lines, off = { 'auto fn() -> void', '{' }, 2
  else
    lines, off = { 'struct S', '{' }, 2
  end
  for _, l in ipairs(body) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = ctx == 'fn' and '}' or '};'
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  return b, off
end

-- Concatenated overlay text on `row0` (the displayed frontend line), or nil.
local function overlay(b, row0)
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
  if #m == 0 then
    return nil
  end
  local s = {}
  for _, c in ipairs(m[1][4].virt_text or {}) do
    s[#s + 1] = c[1]
  end
  return table.concat(s, '')
end

-- Highlight group of the overlay chunk on `row0` whose text == `txt`, or nil.
local function chunk_hl(b, row0, txt)
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
  for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
    if c[1] == txt then
      return c[2]
    end
  end
end

-- Whether ANY chunk on `row0` uses highlight `hl` (used to assert string-green is
-- absent for `string_view`, which must NOT be greened).
local function has_hl(b, row0, hl)
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
  for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
    if c[2] == hl then
      return true
    end
  end
  return false
end

local function chk(desc, got, exp)
  if got == exp then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, tostring(exp), tostring(got))
  end
end

-- ===================== A: nested string stays green =====================
do
  local b, off = build('struct', { 'std::vector<std::string> v{};' })
  chk('vector<string> text', overlay(b, off), 'v: vector<string>;')
  chk('vector<string> string green', chunk_hl(b, off, 'string'), 'DansString')
  chk('vector<string> outer blue', chunk_hl(b, off, 'vector<'), 'DansInlayType')
end

do
  local b, off = build('struct', { 'std::pair<std::string, int> p{};' })
  chk('pair<string, int> text', overlay(b, off), 'p: pair<string, int>;')
  chk('pair<string, int> string green', chunk_hl(b, off, 'string'), 'DansString')
end

do
  -- string_view reads as a string, so it IS greened (whole-word, nested in the
  -- template) -- like string / CString / the gsl zstring aliases.
  local b, off = build('struct', { 'std::vector<std::string_view> sv{};' })
  chk('vector<string_view> text', overlay(b, off), 'sv: vector<string_view>;')
  chk('vector<string_view> green', has_hl(b, off, 'DansString'), true)
end

do
  -- gsl czstring (a C-string alias) is greened like CString.
  local b, off = build('struct', { 'gsl::czstring name{};' })
  chk('czstring green', has_hl(b, off, 'DansString'), true)
end

do
  -- first-party CamelCase z-string types are greened like the gsl aliases.
  local b, off = build('struct', { 'ZString name{};' })
  chk('ZString text', overlay(b, off), 'name: ZString;')
  chk('ZString green', chunk_hl(b, off, 'ZString'), 'DansString')
end

do
  local b, off = build('struct', { 'CZString path{};' })
  chk('CZString text', overlay(b, off), 'path: CZString;')
  chk('CZString green', chunk_hl(b, off, 'CZString'), 'DansString')
end

do
  -- Unreal / CoreFoundation FString family is greened too.
  local b, off = build('struct', { 'FString name{};' })
  chk('FString green', chunk_hl(b, off, 'FString'), 'DansString')
  local b2, off2 = build('struct', { 'CFString cf{};' })
  chk('CFString green', chunk_hl(b2, off2, 'CFString'), 'DansString')
end

-- ===================== B: const char* -> CString =====================
do
  local b, off = build('struct', { 'const char* s{};' })
  chk('member CString text', overlay(b, off), 's: CString;')
  chk('member CString green', chunk_hl(b, off, 'CString'), 'DansString')
end

do
  local b, off = build('fn', { 'const char* p{};' })
  chk('local CString text', overlay(b, off), 'p: CString;')
end

do
  local b, off = build('struct', { 'const char* msg{"hi"};' })
  chk('CString with init text', overlay(b, off), 'msg: CString = "hi";')
end

do
  -- non-const `char*` is NOT a CString: stays a char^. A pointer MEMBER is
  -- plain struct data, so no mut marker.
  local b, off = build('struct', { 'char* raw{};' })
  chk('non-const char* stays ptr', overlay(b, off), 'raw: char^;')
end

-- ===================== report =====================
local report = { string.format('overlay_string_types_spec: PASS %d / FAIL %d', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
