-- Interaction coverage for the first-party C++ authoring engine.  These tests
-- drive the real insert mappings and Neovim's built-in snippet session rather
-- than asserting catalog strings in isolation.

local A = require 'custom.cpp_authoring'
local pass, fail, failures = 0, 0, {}

local function eq(description, actual, expected)
  if vim.deep_equal(actual, expected) then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', description, vim.inspect(expected), vim.inspect(actual))
  end
end

local function ok(description, condition)
  eq(description, not not condition, true)
end

local function buffer(lines)
  if vim.snippet.active() then
    vim.snippet.stop()
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = 'cpp'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { '' })
  vim.cmd 'doautocmd FileType cpp'
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return bufnr
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

-- The type language still expands through the real Space mapping.
do
  local bufnr = buffer()
  feed 'i$str <Esc>'
  eq('type expression expands on Space', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'std::string ' })
end

-- A typo is non-destructive.  This is the stability contract that replaces the
-- old "unknown $ block is garbage" deletion behavior.
do
  local bufnr = buffer()
  feed 'i$not_a_snippet <Esc>'
  eq('unknown expression is preserved', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { '$not_a_snippet ' })
end

-- Tree-sitter context protects comments and raw strings, including forms the
-- historical line-local quote counter could not classify.
do
  local bufnr = buffer { '// $str' }
  vim.api.nvim_win_set_cursor(0, { 1, #'// $str' })
  feed 'a <Esc>'
  eq('comment text is not expanded', vim.api.nvim_get_current_line(), '// $str ')

  bufnr = buffer { 'auto text = R"tag($str)tag";' }
  local line = vim.api.nvim_get_current_line()
  local col = assert(line:find('$str', 1, true)) - 1 + #'$str'
  vim.api.nvim_win_set_cursor(0, { 1, col })
  feed 'i <Esc>'
  eq('raw string text is not expanded', vim.api.nvim_get_current_line(), 'auto text = R"tag($str )tag";')
end

-- Structured templates and placeholder mirrors are owned by one session.  The
-- selected class-name field is replaced once and every mirror follows.
do
  local bufnr = buffer()
  feed 'i$class3 '
  ok('class template starts a built-in snippet session', vim.snippet.active())
  feed 'Widget'
  -- feedkeys() executes the whole synthetic key batch before Neovim's normal
  -- idle event boundary; fire the same event a real keystroke produces so the
  -- built-in mirror synchronizer runs before the Tab jump.
  vim.cmd 'doautocmd TextChangedI'
  feed '<Tab><Esc>'
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  ok('primary class name replaced', text:find('class Widget', 1, true) ~= nil)
  ok('constructor mirror updated', text:find('Widget()', 1, true) ~= nil)
  ok('copy mirror updated', text:find('Widget(const Widget&)', 1, true) ~= nil)
end

-- Existing dsk_* muscle memory remains available, but it routes into the same
-- first-party catalog and built-in placeholder engine.
do
  local bufnr = buffer()
  feed 'idsk_println<Tab>'
  ok('legacy alias expands on Tab', vim.api.nvim_get_current_line():find('std::println', 1, true) ~= nil)
  if vim.snippet.active() then
    vim.snippet.stop()
  end
end

-- Ambiguous partials use the same displayed lexical order: the first Tab
-- completes to the first candidate without inserting a literal indentation,
-- and the next Tab expands it.
do
  local bufnr = buffer()
  feed 'i$class<Tab>'
  eq('ambiguous template head completes deterministically', vim.api.nvim_get_current_line(), '$class0')
  -- A headless feedkeys batch returns to Normal mode when its queue drains;
  -- re-enter at the end to model the next physical Tab key.
  feed 'a<Tab><Esc>'
  ok('completed template expands on next Tab', vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]:find('class MyClass', 1, true) ~= nil)
end

local report = { string.format('authoring_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
