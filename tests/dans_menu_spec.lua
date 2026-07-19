-- Interaction contract for the central :Dans command palette and its two-axis
-- frontend/monochrome display state.

local H = dofile 'tests/support/frontend_harness.lua'
local Menu = require 'custom.dans_menu'
local Mode = require 'custom.dans_mode'
local Frontend = require 'custom.dans_frontend_cpp'

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

local source = {
  '// cursor parking row',
  'auto contract(',
  '    const DeviceTensor& tensor_a,',
  '    DeviceTensor& output',
  ') -> void;',
}

Mode.set_monochrome(true, { silent = true })
Mode.set_frontend(true, { silent = true })
local session = H.open { lines = source, cursor = 1, name = '/tmp/dans_menu_mode.cpp' }
local background = H.open { lines = source, cursor = 1, name = '/tmp/dans_menu_background.cpp' }
vim.api.nvim_set_current_buf(session.buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
eq('frontend starts in accepted presentation', session:display(3), '    tensor_a: DeviceTensor&,')
eq('background buffer starts in accepted presentation', background:display(3), '    tensor_a: DeviceTensor&,')
eq(':Dans command is registered', vim.fn.exists ':Dans', 2)

vim.cmd 'Dans'
local menu_buf = vim.api.nvim_get_current_buf()
local menu_win = vim.api.nvim_get_current_win()

local function content()
  return table.concat(vim.api.nvim_buf_get_lines(menu_buf, 0, -1, false), '\n')
end

local function row_for(label)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(menu_buf, 0, -1, false)) do
    if line:find(label, 1, true) then
      return row
    end
  end
  return nil
end

local function row_highlight(label)
  local wanted = assert(row_for(label), 'missing menu row: ' .. label) - 1
  local namespace = vim.api.nvim_get_namespaces().ds_dans_menu
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(menu_buf, namespace, 0, -1, { details = true })) do
    if mark[2] == wanted then
      return mark[4].line_hl_group
    end
  end
end

local function activate(label)
  local row = assert(row_for(label), 'missing menu row: ' .. label)
  vim.api.nvim_set_current_win(menu_win)
  vim.api.nvim_win_set_cursor(menu_win, { row, 0 })
  vim.cmd 'doautocmd CursorMoved'
  vim.api.nvim_feedkeys(vim.keycode '<CR>', 'x', false)
  vim.wait(100)
end

local initial_menu = content()
ok('menu exposes frontend state', initial_menu:find('Frontend presentation', 1, true))
ok('menu exposes locked monochrome state', initial_menu:find('required by frontend — locked', 1, true))
ok('menu keeps font-size control', initial_menu:find('Font size', 1, true))
ok('menu exposes assembly tool', initial_menu:find('Assembly for current function', 1, true))
ok('menu exposes function runner', initial_menu:find('Run current function', 1, true))
ok('menu exposes project intelligence', initial_menu:find('Inspect project structure', 1, true))
ok('menu removes individual aliases toggle', not initial_menu:find('aliases', 1, true))
ok('menu removes individual pointer toggle', not initial_menu:find('pointer', 1, true))
ok('menu removes lambda/tokenizer toggles', not initial_menu:find('lambda view', 1, true) and not initial_menu:find('tokenizer view', 1, true))

-- Every loaded :Dans* command is accounted for by a curated menu action or the
-- aggregate frontend/codegen entries. A new command must update the palette.
do
  local covered = Menu.covered_commands()
  local missing = {}
  for name in pairs(vim.api.nvim_get_commands { builtin = false }) do
    if name:match '^Dans' and not covered[name] then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  eq('every registered Dans command is represented in the menu', missing, {})
end

-- Frontend off means source-faithful text and disables the entire presentation
-- aggregate, not merely the main declaration overlay.
activate 'Frontend presentation'
eq('frontend toggle turns global frontend off', Mode.frontend_enabled(), false)
eq('frontend off reveals exact source spelling', session:display(3), source[3])
eq('frontend off reaches an already loaded background buffer', background:display(3), source[3])
for _, name in ipairs(Frontend.TOGGLEABLE) do
  eq('frontend aggregate disables ' .. name, Frontend.module_is_on(name, session.buf), false)
end
eq('frontend aggregate disables doc markdown', require('custom.cpp_doc_markdown').is_enabled(session.buf), false)
eq('frontend aggregate disables macro coloring', require('custom.dans_macros').is_enabled(session.buf), false)
eq('frontend aggregate disables scope coloring', require('custom.dans_frontend_cpp.scope').is_enabled(session.buf), false)

-- Buffers created after a transition inherit it through the same aggregate path.
local future_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(future_buf, '/tmp/dans_menu_future.cpp')
vim.api.nvim_buf_set_lines(future_buf, 0, -1, false, source)
vim.bo[future_buf].filetype = 'cpp'
vim.wait(100)
for _, name in ipairs(Frontend.TOGGLEABLE) do
  eq('future buffer inherits disabled ' .. name, Frontend.module_is_on(name, future_buf), false)
end
eq('future buffer inherits disabled doc markdown', require('custom.cpp_doc_markdown').is_enabled(future_buf), false)
eq('future buffer inherits disabled macro coloring', require('custom.dans_macros').is_enabled(future_buf), false)
eq('future buffer inherits disabled scope coloring', require('custom.dans_frontend_cpp.scope').is_enabled(future_buf), false)

-- Once raw, monochrome is interactive. Turning it off restores the actual
-- colorscheme groups and treesitter highlighting.
activate 'Monochrome'
eq('raw mode remembers monochrome off', Mode.monochrome_requested(), false)
eq('raw mode makes normal colors effective', Mode.monochrome_effective(), false)
vim.wait(200)
local normal_keyword = vim.api.nvim_get_hl(0, { name = 'Keyword', link = true })
ok('normal colors no longer flatten Keyword to Normal', normal_keyword.link ~= 'Normal')

-- Re-enabling the frontend forces effective monochrome without destroying the
-- remembered raw-mode preference.
activate 'Frontend presentation'
eq('frontend re-enables globally', Mode.frontend_enabled(), true)
eq('frontend forces monochrome effective', Mode.monochrome_effective(), true)
eq('frontend preserves requested normal-color preference', Mode.monochrome_requested(), false)
eq('frontend presentation restores after re-enable', session:display(3), '    tensor_a: DeviceTensor&,')
eq('frontend aggregate re-enables doc markdown', require('custom.cpp_doc_markdown').is_enabled(session.buf), true)
eq('frontend aggregate re-enables macro coloring', require('custom.dans_macros').is_enabled(session.buf), true)
eq('frontend aggregate re-enables scope coloring', require('custom.dans_frontend_cpp.scope').is_enabled(session.buf), true)
for _, name in ipairs(Frontend.TOGGLEABLE) do
  eq('future buffer re-enables ' .. name, Frontend.module_is_on(name, future_buf), true)
end
vim.wait(200)
local forced_keyword = vim.api.nvim_get_hl(0, { name = 'Keyword', link = true })
eq('forced monochrome flattens Keyword', forced_keyword.link, 'Normal')
ok('menu reports monochrome lock after frontend re-enable', content():find('required by frontend — locked', 1, true))

activate 'Monochrome'
eq('locked monochrome activation cannot change preference', Mode.monochrome_requested(), false)
eq('locked monochrome remains effective', Mode.monochrome_effective(), true)

activate 'Frontend presentation'
eq('frontend off restores remembered normal-color choice', Mode.monochrome_effective(), false)
eq('frontend off restores raw source again', session:display(3), source[3])
ok('all display-mode interaction preserves source bytes', session:assert_source_unchanged())

-- Tool activation closes the palette, restores its target window, then launches
-- the selected feature. This is the path that replaces memorizing commands.
do
  local project = require 'custom.cpp_tools.project'
  local original_show = project.show
  local launched = false
  project.show = function()
    launched = vim.api.nvim_get_current_buf() == session.buf
  end
  activate 'Inspect project structure'
  project.show = original_show
  eq('project action launches against original source buffer', launched, true)
  eq('tool activation closes menu', vim.api.nvim_buf_is_valid(menu_buf), false)
end

-- Font size remains available through the menu without relying on :set guifont.
-- Both inclusive boundaries and fractional values inside them are accepted;
-- anything outside the range leaves guifont byte-for-byte unchanged.
do
  local original_font = vim.o.guifont
  local original_input = vim.ui.input
  local function enter_font(value)
    vim.cmd 'Dans'
    menu_buf, menu_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.ui.input = function(_, callback)
      callback(value)
    end
    activate 'Font size'
  end

  enter_font '8'
  ok('font-size menu accepts inclusive lower boundary', vim.o.guifont:find(':h8', 1, true))
  enter_font '7.99'
  ok('font-size menu rejects below-range size', vim.o.guifont:find(':h8', 1, true))

  enter_font '17.5'
  ok('font-size menu retains fractional in-range sizes', vim.o.guifont:find(':h17.5', 1, true))

  enter_font '32'
  ok('font-size menu accepts inclusive upper boundary', vim.o.guifont:find(':h32', 1, true))
  enter_font '32.01'
  ok('font-size menu rejects above-range size', vim.o.guifont:find(':h32', 1, true))

  vim.ui.input = original_input
  vim.o.guifont = original_font
end

-- The frontend row is contextual even though its stored state is global. It is
-- available for the owner's explicit C/C++/CUDA suffix set and visibly disabled
-- everywhere else; monochrome remains independently interactive there.
do
  for _, extension in ipairs { 'c', 'cpp', 'h', 'hpp', 'hh', 'cc', 'cu', 'cuh' } do
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, '/tmp/dans_menu_supported.' .. extension)
    eq('frontend menu accepts .' .. extension, Mode.frontend_menu_available(bufnr), true)
  end
  for _, extension in ipairs { 'cs', 'py', 'lua' } do
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, '/tmp/dans_menu_unsupported.' .. extension)
    eq('frontend menu rejects .' .. extension, Mode.frontend_menu_available(bufnr), false)
  end

  Mode.set_monochrome(true, { silent = true, bufnr = session.buf })
  Mode.set_frontend(true, { silent = true })
  local python = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(python, '/tmp/dans_menu_language.py')
  vim.api.nvim_buf_set_lines(python, 0, -1, false, { 'value = len([1, 2, 3])' })
  vim.api.nvim_set_current_buf(python)
  vim.bo[python].filetype = 'python'
  vim.cmd 'Dans'
  menu_buf, menu_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()

  ok('non-frontend menu explains the unavailable row', content():find('C/C++/CUDA source files only', 1, true))
  eq('non-frontend menu grays the frontend row', row_highlight('Frontend presentation'), 'Comment')
  activate 'Frontend presentation'
  eq('activating a grayed frontend row is a no-op', Mode.frontend_enabled(), true)
  ok('Python monochrome row is not locked by C++ elsewhere', not content():find('required by frontend — locked', 1, true))

  activate 'Monochrome'
  eq('Python menu disables the shared monochrome preference', Mode.monochrome_requested(), false)
  eq('Python menu reports normal highlighting', Mode.monochrome_effective(python), false)
  eq('Python palette change leaves the C++ frontend enabled', Mode.frontend_enabled(), true)
  ok('Python menu rerenders the normal-color state', content():find('normal highlighting', 1, true))
  Menu.close()
end

-- Leave the isolated process in the production default so later teardown
-- callbacks see the same state as startup.
Mode.set_monochrome(true, { silent = true, bufnr = vim.api.nvim_get_current_buf() })
Mode.set_frontend(true, { silent = true })
Menu.close()

local report = { string.format('dans_menu_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
