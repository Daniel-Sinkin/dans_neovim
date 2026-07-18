-- Headless spec for cpp_type_snippets: :DansCppFormat (path line + StdLib group)
-- and the snippet auto-include.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/snippet_format_spec.lua" -c "qa!"

local S = require 'custom.cpp_type_snippets'
require('custom.cpp_authoring').setup()
local pass, fail, fails = 0, 0, {}
local function eq(desc, got, want)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, vim.inspect(want), vim.inspect(got))
  end
end

local function mkbuf(rel, lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, vim.fn.getcwd() .. '/' .. rel)
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- format: adds the path line and gathers std headers under a new // StdLib block,
-- leaving the project/third-party includes alone.
do
  local b = mkbuf('sub/foo.cpp', {
    '#include <vector>',
    '#include "foo.hpp"',
    '#include <dans/util.hpp>',
    '#include <string>',
  })
  S.format()
  eq(
    'format: path + StdLib group',
    table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n'),
    table.concat({
      '// sub/foo.cpp',
      '#include "foo.hpp"',
      '#include <dans/util.hpp>',
      '// StdLib',
      '#include <string>',
      '#include <vector>',
    }, '\n')
  )
end

-- format is idempotent on an already-formatted file.
do
  local formatted = {
    '// a/b.cpp',
    '#include "b.hpp"',
    '// Externals',
    '#include <SDL3/SDL.h>',
    '// StdLib',
    '#include <vector>',
    '//',
  }
  local b = mkbuf('a/b.cpp', vim.deepcopy(formatted))
  S.format()
  eq('format: idempotent', table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n'), table.concat(formatted, '\n'))
end

-- auto-include: a snippet expanding to a std type adds its header to // StdLib.
do
  local b = mkbuf('c.cpp', {
    '// StdLib',
    '#include <vector>',
    '//',
    '',
    'void f()',
    '{',
    '    ',
    '}',
  })
  vim.cmd 'doautocmd FileType'
  vim.api.nvim_win_set_cursor(0, { 7, 4 })
  vim.api.nvim_feedkeys('A$arr$T$N ', 'x', false)
  vim.cmd 'stopinsert'
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq('auto-include: header added', lines[2], '#include <array>')
  eq('auto-include: existing kept', lines[3], '#include <vector>')
  eq('auto-include: expansion landed', vim.trim(lines[#lines - 1]), 'std::array<T, N>')
end

local report = { string.format('snippet_format_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
