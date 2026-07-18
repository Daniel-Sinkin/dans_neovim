-- Headless interaction coverage for the C++ project index and include-provenance view.

local P = require 'custom.cpp_tools.project'
local pass, fail, failures = 0, 0, {}

local function eq(description, actual, expected)
  if vim.deep_equal(actual, expected) then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = string.format(
      'FAIL  %s\n        exp: %s\n        got: %s',
      description,
      vim.inspect(expected),
      vim.inspect(actual)
    )
  end
end

local function ok(description, condition)
  eq(description, not not condition, true)
end

local root = vim.fn.getcwd() .. '/tests/fixtures/project_index'
local cmake_reply = root .. '/cmake-reply'
local source = root .. '/include/ui/widget.hpp'

eq('root discovery reaches fixture config', P.find_root(source), vim.fs.normalize(root))

local index, scan_error
P.scan(root, { cmake_reply = cmake_reply }, function(value, err)
  index, scan_error = value, err
end)
vim.wait(5000, function()
  return index ~= nil or scan_error ~= nil
end, 10)
eq('headless index scan succeeds', scan_error, nil)
eq('headless index reaches six inferred components', index and index.summary.components, 6)

if index then
  local rendered_lines = P.render(index)
  local rendered = table.concat(rendered_lines, '\n')
  ok('summary renders paired component', rendered:find('core/log', 1, true))
  ok('summary renders observed cycle', rendered:find('cycle/a -> cycle/b -> cycle/a', 1, true))

  local why = P.why_lines(index, source, 7)
  local explanation = why and table.concat(why, '\n') or ''
  ok('why view resolves vendored provider', explanation:find('vendor/ext/ext.hpp', 1, true))
  ok('why view preserves conditional provenance', explanation:find('#if PROJECT_FEATURE', 1, true))
  ok('why view labels observation versus permission', explanation:find('not a declared module permission', 1, true))
end

vim.cmd.edit(vim.fn.fnameescape(source))
local source_buf = vim.api.nvim_get_current_buf()
local original = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

P.show { root = root, file = source, cmake_reply = cmake_reply }
local index_buf
vim.wait(5000, function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):find('dans://cpp%-project/') then
      local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      if content:find('Observed component dependencies', 1, true) then
        index_buf = bufnr
        return true
      end
    end
  end
  return false
end, 10)
ok('interactive project summary opens after asynchronous scan', index_buf ~= nil)

vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_win_set_cursor(0, { 7, 0 })
P.why { root = root, file = source, line = 7, cmake_reply = cmake_reply }

local why_buf
vim.wait(5000, function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):find('dans://cpp%-project%-why/') then
      local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      if content:find('vendor/ext/ext.hpp', 1, true) then
        why_buf = bufnr
        return true
      end
    end
  end
  return false
end, 10)
ok('interactive why view opens with resolved provider', why_buf ~= nil)
eq('project inspection preserves source bytes and rows', vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), original)

local report = { string.format('project_index_ui_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
