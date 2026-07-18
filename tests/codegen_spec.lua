-- Parser-derived C++ generators and preview/apply interaction.

local G = require 'custom.cpp_codegen'
local C = require 'custom.cpp_tools.context'
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

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = 'cpp'
vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. '/widget.cpp')
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  '#include <optional>',
  '#include "widget.hpp"',
  'namespace demo',
  '{',
  'struct ChildCfg',
  '{',
  '    int value;',
  '};',
  'struct WidgetCfg',
  '{',
  '    ChildCfg child;',
  '    std::optional<ChildCfg> optional_child;',
  '    int count;',
  '};',
  'enum class State : u8',
  '{',
  '    ready = 0,',
  '    failed,',
  '};',
  'auto calculate(const WidgetCfg& cfg) -> int',
  '{',
  '    return cfg.count;',
  '}',
  '}  // namespace demo',
})

local widget = C.type_at(bufnr, 10, 10)
eq('struct located', widget and widget.name, 'WidgetCfg')
local fields = G.struct_fields(bufnr, widget)
eq(
  'field names',
  vim.tbl_map(function(field)
    return field.name
  end, fields),
  { 'child', 'optional_child', 'count' }
)

local validity, validity_name, nested = G.generate_validity('WidgetCfg', fields, {
  ChildCfg = true,
  WidgetCfg = true,
})
eq('Cfg suffix becomes Validity', validity_name, 'WidgetValidity')
eq('only nested fields get inferred cases', #nested, 2)
ok('value recursion generated', validity:find('not is_valid(value.child)', 1, true) ~= nil)
ok('optional recursion generated', validity:find('value.optional_child and not is_valid(*value.optional_child)', 1, true) ~= nil)
ok('generic validity zero contract generated', validity:find('valid = 0', 1, true) ~= nil)
ok('is_valid delegates to validity', validity:find('std::to_underlying(validity(value)) == 0', 1, true) ~= nil)

-- The generated dans-style validity artifact is real C++ once the project's
-- conventional `def`, u8, and with_name helpers are present.
do
  local directory = vim.fn.tempname() .. '-dans-codegen-spec'
  vim.fn.mkdir(directory, 'p')
  local source_path = directory .. '/generated.cpp'
  local program = table.concat({
    '#include <cstdint>',
    '#include <optional>',
    '#include <string>',
    '#include <string_view>',
    '#include <utility>',
    '#define def auto',
    'using u8 = std::uint8_t;',
    'auto with_name(std::string_view name, std::string_view body, bool include_name) -> std::string',
    '{ return include_name ? std::string{name} + "{" + std::string{body} + "}" : std::string{body}; }',
    'struct ChildCfg {};',
    'inline auto is_valid(const ChildCfg&) -> bool { return true; }',
    'struct WidgetCfg { ChildCfg child; std::optional<ChildCfg> optional_child; int count; };',
    validity,
    'int main() { return is_valid(WidgetCfg{}) ? 0 : 1; }',
  }, '\n')
  vim.fn.writefile(vim.split(program, '\n', { plain = true }), source_path)
  local compiled = vim.system({ 'clang++', '-std=c++23', '-fsyntax-only', source_path }, { text = true }):wait()
  eq('generated validity compiles with project conventions', compiled.code, 0)
  if compiled.code ~= 0 then
    failures[#failures + 1] = compiled.stderr or ''
  end
  vim.fn.delete(directory, 'rf')
end

local enum = C.enum_at(bufnr, 16, 8)
local values = G.enum_values(bufnr, enum)
eq('enum values', values, { 'ready', 'failed' })
local enum_string = G.generate_enum_to_string(enum.name, values)
ok('enum switch uses every case', enum_string:find('case ready:', 1, true) and enum_string:find('case failed:', 1, true))

local fn = C.function_at(bufnr, 21, 8)
local declaration = G.function_declaration(bufnr, fn)
eq('definition projects to declaration', declaration, 'auto calculate(const WidgetCfg& cfg) -> int;')

local draft, header = G.header_draft(bufnr, vim.api.nvim_buf_get_name(bufnr))
ok('header path uses hpp', header:match 'widget%.hpp$' ~= nil)
ok('header copies include context', draft:find('#include <optional>', 1, true) ~= nil)
eq('header excludes its own include', draft:find('#include "widget.hpp"', 1, true), nil)
ok('header reopens namespace', draft:find('namespace demo', 1, true) ~= nil)
ok('header forwards source-defined struct', draft:find('struct WidgetCfg;', 1, true) ~= nil)
ok('header forwards enum with underlying type', draft:find('enum class State : u8;', 1, true) ~= nil)
ok('header contains function declaration', draft:find(declaration, 1, true) ~= nil)

-- The preview requires an explicit `a`; merely opening it never edits source.
do
  local applied = false
  local preview = G.preview('spec', 'auto generated() -> int;', function()
    applied = true
  end)
  eq('preview does not auto-apply', applied, false)
  vim.api.nvim_feedkeys('a', 'x', false)
  eq('preview apply mapping runs action', applied, true)
  eq('preview closes after apply', vim.api.nvim_buf_is_valid(preview), false)
end

-- Out-of-class method implementations are inserted into the class body rather
-- than appended as an invalid namespace-scope qualified declaration.
do
  local header_buf = vim.api.nvim_create_buf(true, false)
  vim.bo[header_buf].filetype = 'cpp'
  vim.api.nvim_buf_set_lines(header_buf, 0, -1, false, {
    '#pragma once',
    'namespace demo',
    '{',
    'class Widget',
    '{',
    'public:',
    '};',
    '}',
  })
  ok('member declaration applies', G.append_declaration(header_buf, 'auto Widget::size() const -> usize;', 'demo'))
  local header_text = table.concat(vim.api.nvim_buf_get_lines(header_buf, 0, -1, false), '\n')
  ok('member access is explicit', header_text:find('public:', 1, true) ~= nil)
  ok('member qualifier stripped in class', header_text:find('auto size() const -> usize;', 1, true) ~= nil)
  eq('qualified member not appended at namespace scope', header_text:find('Widget::size', 1, true), nil)
  eq('member duplicate is rejected', G.append_declaration(header_buf, 'auto Widget::size() const -> usize;', 'demo'), false)
end

-- Constructor initializer lists belong only to the implementation and are not
-- leaked into the projected header declaration.
do
  local constructor_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(constructor_buf)
  vim.bo[constructor_buf].filetype = 'cpp'
  vim.api.nvim_buf_set_lines(constructor_buf, 0, -1, false, {
    'class Object { Object(); int value; };',
    'Object::Object()',
    '    : value{1}',
    '{',
    '}',
  })
  local constructor = C.function_at(constructor_buf, 3, 0)
  eq('constructor initializer omitted', G.function_declaration(constructor_buf, constructor), 'Object::Object();')
end

local report = { string.format('codegen_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
