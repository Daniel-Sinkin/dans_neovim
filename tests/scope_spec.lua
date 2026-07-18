-- Headless spec for the C/C++ scope bracket-matcher (custom.dans_frontend_cpp.scope).
-- Validates the worked example end to end: the innermost any-bracket pair at each
-- cursor position, the $5 line-start case that must resolve to the lambda body
-- (not the span braces), the in-string parens that must be skipped, and the
-- ancestor chain used for the blue depth coloring.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/scope_spec.lua" -c "qa!"

local S = require 'custom.dans_frontend_cpp.scope'
local pass, fail, fails = 0, 0, {}

local function ok(d, cond, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d .. (extra and ('  (' .. extra .. ')') or '')
  end
end

-- The worked example. $-markers removed; the $5 `return` is intentionally at
-- column 0 (the reported bug: yib there grabbed the span, not the lambda body).
local lines = {
  '{', -- 0   $1 outermost
  '        auto const glfw_extensions = []', -- 1   $2 in the []
  '        {', -- 2   $3 lambda body open
  '            u32 glfw_count{0};', -- 3
  '            CZString* raw_glfw_extensions = glfwGetRequiredInstanceExtensions(&glfw_count);', -- 4
  '            if (not raw_glfw_extensions) DANS_PANIC("Got no GLFW Extensions (no Vulkan loader?)");', -- 5   $4 in if-parens
  'return std::span{raw_glfw_extensions, static_cast<usize>(glfw_count)};', -- 6   $5 col 0, $6 at static_cast
  '        }();', -- 7   lambda body close
  '}', -- 8
}

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)

-- 0-based col of the first occurrence of a literal substring on `row`.
local function colof(row, sub)
  local s = lines[row + 1]:find(sub, 1, true)
  return s and (s - 1) or -1
end

-- { desc, row, col, open_row, close_row, char }
local cases = {
  { '$1 outermost braces', 1, 0, 0, 8, '{' },
  { '$2 lambda capture [] (cursor on ])', 1, #lines[2] - 1, 1, 1, '[' },
  { '$3 lambda body braces', 3, 12, 2, 7, '{' },
  { '$4 if-condition parens', 5, colof(5, 'raw_glfw_extensions'), 5, 5, '(' },
  { '$5 line-start resolves to lambda body, NOT span', 6, 0, 2, 7, '{' },
  { '$6 span initializer braces', 6, colof(6, 'static_cast'), 6, 6, '{' },
}

for _, c in ipairs(cases) do
  local p = S.innermost(b, c[2], c[3])
  if not p then
    ok(c[1], false, 'no pair found')
  else
    local got = string.format('open r%d close r%d %q', p.or_, p.cr, p.ch)
    local want = string.format('open r%d close r%d %q', c[4], c[5], c[6])
    ok(c[1], p.or_ == c[4] and p.cr == c[5] and p.ch == c[6], 'want ' .. want .. ' got ' .. got)
  end
end

-- Ancestor chain at $4 (in the if-parens): active = the parens, parent = the
-- lambda body ($3), grandparent = the outermost ($1). Drives the blue depth knob.
do
  local chain = S.pair_chain(b, 5, colof(5, 'raw_glfw_extensions'), 3)
  ok('chain[1] active = if-parens', chain[1] and chain[1].ch == '(' and chain[1].or_ == 5, chain[1] and chain[1].ch or 'nil')
  ok('chain[2] parent = lambda body', chain[2] and chain[2].or_ == 2 and chain[2].cr == 7, chain[2] and ('open r' .. chain[2].or_) or 'nil')
  ok('chain[3] grandparent = outermost', chain[3] and chain[3].or_ == 0 and chain[3].cr == 8, chain[3] and ('open r' .. chain[3].or_) or 'nil')
end

-- Depth knob: pair_chain caps at `want`, so depth 0 -> 1 pair, depth 1 -> 2.
do
  local one = S.pair_chain(b, 5, colof(5, 'raw_glfw_extensions'), 1)
  ok('depth 0 yields only the active pair', #one == 1, '#=' .. #one)
end

-- Coloring model: the enclosing brace is always orange, the paren/bracket region
-- the cursor is in is also orange, and every other in-scope delimiter is blue.
do
  local cl = { '{', '  if (  ())', '}' } -- outer( c5, inner( c8, inner) c9, outer) c10
  local cb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(cb)
  vim.api.nvim_buf_set_lines(cb, 0, -1, false, cl)
  vim.bo[cb].filetype = 'cpp'
  pcall(function()
    vim.treesitter.get_parser(cb, 'cpp'):parse()
  end)
  local cns = vim.api.nvim_get_namespaces()['ds_cpp_scope']
  local function at(r, c)
    vim.api.nvim_win_set_cursor(0, { r, c })
    S.refresh(cb)
    local out = {}
    for _, e in ipairs(vim.api.nvim_buf_get_extmarks(cb, cns, 0, -1, { details = true })) do
      out[e[2] .. ',' .. e[3]] = e[4].hl_group == 'DansScopeActive' and 'O' or 'B'
    end
    return out
  end
  local function chk(desc, k, expect)
    local all = true
    for pos, want in pairs(expect) do
      all = all and (k[pos] or '-') == want
    end
    ok(desc, all, vim.inspect(k):gsub('%s+', ' '))
  end
  chk('in-brace: brace orange, all parens blue', at(2, 0), { ['0,0'] = 'O', ['1,5'] = 'B', ['1,8'] = 'B', ['1,9'] = 'B', ['1,10'] = 'B' })
  chk('outer paren: brace+outer orange, inner blue', at(2, 6), { ['0,0'] = 'O', ['1,5'] = 'O', ['1,10'] = 'O', ['1,8'] = 'B', ['1,9'] = 'B' })
  chk('inner paren: brace+inner orange, outer blue', at(2, 9), { ['0,0'] = 'O', ['1,8'] = 'O', ['1,9'] = 'O', ['1,5'] = 'B', ['1,10'] = 'B' })
end

local report = { string.format('scope_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
