-- Pure generation plus an actual compile/run of a temporary function probe.

local R = require 'custom.cpp_runner'
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

local root = vim.fn.getcwd()
local source = root .. '/tests/fixtures/probe_sample.cpp'
local generated = R.harness_source(source, 'probe_sample::add(2, 5)', false)
eq('harness includes source', generated:find('#include "' .. source .. '"', 1, true) ~= nil, true)
eq('harness embeds invocation', generated:find('probe_sample::add(2, 5)', 1, true) ~= nil, true)
eq('harness supports ADL to_string', generated:find('AdlStringable', 1, true) ~= nil, true)

local directory = vim.fn.tempname() .. '-dans-probe-spec'
vim.fn.mkdir(directory, 'p')
local harness, executable = directory .. '/probe.cpp', directory .. '/probe'
vim.fn.writefile(vim.split(generated, '\n', { plain = true }), harness)
local command = assert(C.compile_command(source, {
  mode = 'link',
  input = harness,
  output = executable,
  opt = '0',
}))
local compiled = vim.system(command.argv, { cwd = command.cwd, text = true }):wait()
eq('generated probe compiles', compiled.code, 0)
if compiled.code == 0 then
  local result = vim.system({ executable }, { text = true }):wait()
  eq('generated probe exits cleanly', result.code, 0)
  eq('generated probe prints return value', result.stdout, '7\n')
else
  failures[#failures + 1] = compiled.stderr or ''
end
vim.fn.delete(directory, 'rf')

-- Void-returning functions take the dependent template branch; both branches
-- remain valid without evaluating the invocation twice.
do
  local void_directory = vim.fn.tempname() .. '-dans-probe-void-spec'
  vim.fn.mkdir(void_directory, 'p')
  local void_harness, void_executable = void_directory .. '/probe.cpp', void_directory .. '/probe'
  local void_source = R.harness_source(source, '([] { int value = 1; probe_sample::touch(value); }())', false)
  vim.fn.writefile(vim.split(void_source, '\n', { plain = true }), void_harness)
  local void_command = assert(C.compile_command(source, {
    mode = 'link',
    input = void_harness,
    output = void_executable,
    opt = '0',
  }))
  local void_compile = vim.system(void_command.argv, { cwd = void_command.cwd, text = true }):wait()
  eq('void probe compiles', void_compile.code, 0)
  if void_compile.code == 0 then
    local void_result = vim.system({ void_executable }, { text = true }):wait()
    eq('void probe reports void', void_result.stdout, '<void>\n')
  else
    failures[#failures + 1] = void_compile.stderr or ''
  end
  vim.fn.delete(void_directory, 'rf')
end

local report = { string.format('runner_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
