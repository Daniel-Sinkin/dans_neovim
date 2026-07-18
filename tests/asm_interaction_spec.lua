-- End-to-end asynchronous assembly interaction: compile a real source file,
-- open the reusable split, verify persistent color pairing and active sync, and
-- toggle generated-buffer noise without changing source rows or bytes.

local A = require 'custom.dans_asm'
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
A.show('0', true)

local asm_buf
vim.wait(10000, function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):find 'dans%-asm://' then
      asm_buf = bufnr
      return true
    end
  end
  return false
end, 10)

eq('assembly split opened', asm_buf ~= nil, true)
if asm_buf then
  local namespaces = vim.api.nvim_get_namespaces()
  local map_ns = namespaces.ds_asm_source_map
  local sync_ns = namespaces.ds_asm_sync
  local source_marks = vim.api.nvim_buf_get_extmarks(source_buf, map_ns, 0, -1, { details = true })
  local asm_marks = vim.api.nvim_buf_get_extmarks(asm_buf, map_ns, 0, -1, { details = true })
  eq('source has persistent color marks', #source_marks > 0, true)
  eq('assembly has matching color marks', #asm_marks > 0, true)

  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_win_set_cursor(0, { 5, 8 })
  vim.cmd 'doautocmd CursorMoved'
  local active = vim.api.nvim_buf_get_extmarks(asm_buf, sync_ns, 0, -1, {})
  eq('source cursor activates mapped assembly', #active > 0, true)

  local filtered_count = vim.api.nvim_buf_line_count(asm_buf)
  local asm_window = vim.fn.bufwinid(asm_buf)
  vim.api.nvim_set_current_win(asm_window)
  vim.api.nvim_feedkeys('n', 'x', false)
  local full_count = vim.api.nvim_buf_line_count(asm_buf)
  eq('noise toggle reveals compiler rows', full_count > filtered_count, true)
end

eq('assembly interaction preserves source rows and bytes', vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), original)

local report = { string.format('asm_interaction_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
