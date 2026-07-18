-- Shared compiler/context/job primitives used by assembly and probes.

local C = require 'custom.cpp_tools.context'
local J = require 'custom.cpp_tools.jobs'
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

local function has(values, target)
  return vim.list_contains(values, target)
end

do
  local values = C.split_command [[clang++ '-DNAME=a b' -I "space dir" src/a.cpp]]
  eq('shell split preserves quoted define', values[2], '-DNAME=a b')
  eq('shell split preserves quoted path', values[4], 'space dir')
  eq('shell split token count', #values, 5)
end

do
  local argv = {
    'clang++',
    '-std=c++23',
    '-I',
    'include',
    '-O3',
    '-c',
    '-MD',
    '-MF',
    'build/a.d',
    '-o',
    'build/a.o',
    'src/a.cpp',
  }
  local assembly = C.sanitize_arguments(argv, '/project/src/a.cpp', {
    cwd = '/project',
    mode = 'assembly',
    input = '/project/src/a.cpp',
    opt = '1',
  })
  ok('sanitize keeps project include', has(assembly, '-I') and has(assembly, 'include'))
  ok('sanitize drops compile/dependency flags', not has(assembly, '-c') and not has(assembly, '-MD'))
  ok('sanitize drops old outputs', not has(assembly, 'build/a.o') and not has(assembly, 'build/a.d'))
  eq('assembly deterministic tail', vim.list_slice(assembly, #assembly - 5, #assembly), {
    '-S',
    '-g',
    '-O1',
    '-o',
    '-',
    '/project/src/a.cpp',
  })

  local linked = C.sanitize_arguments(argv, '/project/src/a.cpp', {
    cwd = '/project',
    mode = 'link',
    input = '/tmp/probe.cpp',
    output = '/tmp/probe',
  })
  ok('probe link enables dead-section removal', has(linked, '-ffunction-sections') and has(linked, '-Wl,--gc-sections'))
  eq('probe link output', linked[#linked], '/tmp/probe')
end

-- Tree-sitter context is shared rather than reimplemented by every tool.
do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = 'cpp'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    'namespace demo {',
    'struct Config { int count; };',
    'enum class State : unsigned char { ready, failed };',
    'auto evaluate(const Config& cfg) -> int',
    '{',
    '    return cfg.count;',
    '}',
    '}',
  })
  local fn = C.function_at(bufnr, 5, 8)
  eq('function name', fn and fn.name, 'evaluate')
  eq('qualified function name', fn and fn.qualified_name, 'demo::evaluate')
  eq('function source range', fn and { fn.first_line, fn.last_line }, { 4, 7 })
  local struct = C.type_at(bufnr, 1, 12)
  eq('struct context', struct and struct.name, 'Config')
  local enum = C.enum_at(bufnr, 2, 20)
  eq('enum context', enum and enum.name, 'State')
end

-- Starting a newer keyed process cancels/supersedes the old callback.  This is
-- what prevents a slow O0 assembly compile from overwriting a newer O3 result.
do
  local observed = {}
  J.start('spec', { 'sh', '-c', 'sleep 0.08; printf old' }, {}, function(result)
    observed[#observed + 1] = result.stdout
  end)
  J.start('spec', { 'sh', '-c', 'printf new' }, {}, function(result)
    observed[#observed + 1] = result.stdout
  end)
  vim.wait(1000, function()
    return #observed > 0
  end, 10)
  eq('latest process result wins', observed, { 'new' })
end

local report = { string.format('cpp_tools_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
