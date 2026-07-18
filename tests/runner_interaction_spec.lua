-- End-to-end lifecycle for the function probe result window and its edit/rerun
-- action.  The source buffer is asserted byte-for-byte unchanged.

local R = require 'custom.cpp_runner'
local pass, fail, failures = 0, 0, {}

local function eq(description, actual, expected)
  if vim.deep_equal(actual, expected) then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', description, vim.inspect(expected), vim.inspect(actual))
  end
end

local source_path = vim.fn.getcwd() .. '/tests/fixtures/probe_sample.cpp'
vim.cmd('edit ' .. vim.fn.fnameescape(source_path))
local source_buf = vim.api.nvim_get_current_buf()
vim.bo[source_buf].filetype = 'cpp'
local original = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
vim.api.nvim_win_set_cursor(0, { 5, 8 })
R.run { expression = 'probe_sample::add(4, 8)' }

local result_buf
local function result_contains(needle)
  if not result_buf or not vim.api.nvim_buf_is_valid(result_buf) then
    return false
  end
  local content = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), '\n')
  return content:find(needle, 1, true) ~= nil
end

vim.wait(10000, function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):find 'dans://function%-probe/' then
      result_buf = bufnr
      return result_contains '  12'
    end
  end
  return false
end, 10)
eq('probe result opens and prints value', result_contains '  12', true)

if result_buf and vim.api.nvim_buf_is_valid(result_buf) then
  local result_window = vim.fn.bufwinid(result_buf)
  vim.api.nvim_set_current_win(result_window)
  local previous_input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback 'probe_sample::add(10, 5)'
  end
  vim.api.nvim_feedkeys('e', 'x', false)
  vim.ui.input = previous_input
  vim.wait(10000, function()
    return result_contains '  15'
  end, 10)
  eq('edit-expression action recompiles and reruns', result_contains '  15', true)

  vim.api.nvim_set_current_win(vim.fn.bufwinid(result_buf))
  vim.api.nvim_feedkeys('h', 'x', false)
  local harness_found = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == 'dans://function-probe-harness' then
      harness_found = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n'):find('probe_sample::add(10, 5)', 1, true) ~= nil
    end
  end
  eq('harness inspection shows current invocation', harness_found, true)
end

eq('probe lifecycle preserves source rows and bytes', vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), original)

local report = { string.format('runner_interaction_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
