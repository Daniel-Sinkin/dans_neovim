-- Headless spec for the dans::logic infix rendering (logic.lua).
-- Run:  nvim --headless --cmd "set noswapfile" -c "luafile tests/logic_spec.lua" -c "qa!"
-- Each body line sits inside a function (so it's a raw statement, not a decl the
-- view overlays) with the cursor parked on line 1, then we reconstruct the
-- visible text from ONLY the ds_cpp_logic namespace's conceals + inline virt_text.

local pass, fail, fails = 0, 0, {}

local function display(buf, row0)
  local id = vim.api.nvim_get_namespaces()['ds_cpp_logic']
  local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ''
  local hidden, ins = {}, {}
  for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, { row0, 0 }, { row0, -1 }, { details = true })) do
    local d = mk[4]
    if d.conceal ~= nil and d.end_col then
      for c = mk[3], d.end_col - 1 do
        hidden[c] = true
      end
    end
    if d.virt_text and d.virt_text_pos == 'inline' then
      local t = ''
      for _, ch in ipairs(d.virt_text) do
        t = t .. ch[1]
      end
      ins[mk[3]] = (ins[mk[3]] or '') .. t
    end
  end
  local s = {}
  for c = 0, #line do
    if ins[c] then
      s[#s + 1] = ins[c]
    end
    if c < #line and not hidden[c] then
      s[#s + 1] = line:sub(c + 1, c + 1)
    end
  end
  return (table.concat(s):gsub('^%s+', ''))
end

-- body[1] lands at buffer row 2 (0-based): rows 0='bool fn()', 1='{'.
local R = 2
local function run(desc, body_line, expect)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'bool fn()', '{', body_line, '}' })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  vim.cmd 'doautocmd CursorMoved'
  local got = display(b, R)
  if got == expect then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, expect, got)
  end
end

run('basic implies', '    return dans::logic::implies(a, b);', 'return (a) => (b);')
run('user example', '    return dans::logic::implies(not err.descr.empty(), err.code.is_error());', 'return (not err.descr.empty()) => (err.code.is_error());')
run('inside assert', '    assert(dans::logic::implies(a, b));', 'assert((a) => (b));')
run('nested implies', '    return dans::logic::implies(dans::logic::implies(a, b), c);', 'return ((a) => (b)) => (c);')
run('one arg untouched', '    return dans::logic::implies(a);', 'return dans::logic::implies(a);')
run('non-logic call untouched', '    foo(a, b);', 'foo(a, b);')

-- color: the inserted operator is grayed (DansAssert) inside an assert, Normal
-- elsewhere, so it matches markers' graying of the assert statement.
do
  local function op_hl(body_line)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'bool fn()', '{', body_line, '}' })
    vim.bo[b].filetype = 'cpp'
    vim.api.nvim_set_current_buf(b)
    pcall(function()
      vim.treesitter.get_parser(b, 'cpp'):parse()
    end)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd 'doautocmd FileType'
    vim.cmd 'doautocmd BufEnter'
    vim.cmd 'doautocmd CursorMoved'
    local id = vim.api.nvim_get_namespaces()['ds_cpp_logic']
    for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(b, id, { R, 0 }, { R, -1 }, { details = true })) do
      for _, ch in ipairs(mk[4].virt_text or {}) do
        if ch[1]:find('=>', 1, true) then
          return ch[2]
        end
      end
    end
  end
  local function chk(desc, got, exp)
    if got == exp then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  ' .. desc .. '  got ' .. tostring(got)
    end
  end
  chk('assert grays the operator', op_hl('    assert(dans::logic::implies(a, b));'), 'DansAssert')
  chk('plain stmt keeps Normal', op_hl('    return dans::logic::implies(a, b);'), 'Normal')
end

local report = { string.format('logic_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
