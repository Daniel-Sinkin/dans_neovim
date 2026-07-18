-- Headless spec for dans_asm pure helpers (parse_asm / pick_block / clean_args /
-- split_command). Run against real clang -S output for both x86 ELF and arm64
-- Mach-O so the format-agnostic parsing is exercised on both.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/asm_spec.lua" -c "qa!"

local A = require 'custom.dans_asm'
local TEST_DIR = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local pass, fail, fails = 0, 0, {}
local function ok(desc, cond)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. desc
  end
end
local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end
local function read(p)
  local f = assert(io.open(p, 'r'))
  local s = f:read '*a'
  f:close()
  return s
end

-- t.cpp: add(int,int) spans source lines 1-5 (body 3-4), mul(int,int) is line 7.
for _, fx in ipairs { 'linux', 'macos', 'windows' } do
  local parsed = A.parse_asm(read(TEST_DIR .. '/asm/' .. fx .. '.s'), 't.cpp')
  ok(fx .. ': two function blocks', #parsed.blocks == 2)

  local add = A.pick_block(parsed, 1, 5)
  local mul = A.pick_block(parsed, 7, 7)
  ok(fx .. ': add block found', add ~= nil and add.label ~= nil and add.label:find 'add' ~= nil)
  ok(fx .. ': mul block found', mul ~= nil and mul.label ~= nil and mul.label:find 'mul' ~= nil)
  ok(fx .. ': add != mul', add ~= nil and mul ~= nil and add.label ~= mul.label)

  -- add's source coverage includes lines 3 and 4, not 7; mul covers 7, not 3.
  ok(fx .. ': add covers src 3', add and add.srcs[3] == true)
  ok(fx .. ': add covers src 4', add and add.srcs[4] == true)
  ok(fx .. ': add excludes src 7', add and add.srcs[7] == nil)
  ok(fx .. ': mul covers src 7', mul and mul.srcs[7] == true)

  -- line_src maps at least one asm line to a source line inside add.
  local mapped3 = false
  for _, s in pairs(parsed.line_src) do
    if s == 3 then
      mapped3 = true
    end
  end
  ok(fx .. ': some asm line -> src 3', mapped3)
end

-- clean_args: strip -c / -o X / dep-gen / the input file; force opt; append tail.
do
  local argv = { 'clang++', '-std=c++23', '-I', 'inc', '-O0', '-c', '-o', 'build/t.o', '-MD', '-MF', 'build/t.d', 'src/t.cpp' }
  local out = A.clean_args(argv, 'src/t.cpp', '2')
  ok('clean: keeps compiler', out[1] == 'clang++')
  ok('clean: keeps -std', has(out, '-std=c++23'))
  ok('clean: keeps -I inc', has(out, '-I') and has(out, 'inc'))
  ok('clean: drops -c', not has(out, '-c'))
  ok('clean: drops old -O0', not has(out, '-O0'))
  ok('clean: drops -MD', not has(out, '-MD'))
  ok('clean: drops dep file', not has(out, 'build/t.d') and not has(out, 'build/t.o'))
  ok('clean: forces -O2', has(out, '-O2'))
  ok('clean: emits -S -g', has(out, '-S') and has(out, '-g'))
  -- tail is `-o - src/t.cpp`
  ok('clean: stdout output', out[#out - 2] == '-o' and out[#out - 1] == '-' and out[#out] == 'src/t.cpp')
  -- input file appears exactly once (only the re-added tail copy)
  local nin = 0
  for _, a in ipairs(out) do
    if a == 'src/t.cpp' then
      nin = nin + 1
    end
  end
  ok('clean: input once', nin == 1)
end

-- split_command: quote handling.
do
  local out = A.split_command [[clang++ -DFOO="a b" -I /x y.cpp]]
  ok('split: token count', #out == 5)
  ok('split: define with space', out[2] == '-DFOO=a b')
  ok('split: path', out[3] == '-I' and out[4] == '/x' and out[5] == 'y.cpp')
end

-- Godbolt-style display construction may remove compiler bookkeeping from the
-- generated scratch buffer, but keeps exact source maps for every instruction.
do
  local parsed = A.parse_asm(read(TEST_DIR .. '/asm/linux.s'), 't.cpp')
  local block = assert(A.pick_block(parsed, 1, 5))
  local full = A.display_block(parsed, block, false)
  local filtered, _, source_to_display = A.display_block(parsed, block, true)
  ok('display: noise filter removes rows', #filtered < #full)
  ok('display: source line 3 remains mapped', source_to_display[3] and #source_to_display[3] > 0)
  local palette = A.source_palette(source_to_display, 3)
  local source_lines = vim.tbl_keys(palette)
  table.sort(source_lines)
  ok('display: palette starts at one', palette[source_lines[1]] == 1)
  if #source_lines >= 4 then
    ok('display: palette cycles deterministically', palette[source_lines[4]] == 1)
  end
end

-- Header/inlined locations are deliberately unpaired instead of inheriting the
-- previous translation-unit line's color.
do
  local parsed = A.parse_asm(
    table.concat({
      '.file 1 "t.cpp"',
      '.file 2 "header.hpp"',
      '_Z1fv:',
      '.Lfunc_begin0:',
      '.loc 1 3 1',
      '  addl $1, %eax',
      '.loc 2 9 2',
      '  callq _Z6helperv',
      '.loc 1 4 1',
      '  retq',
      '.Lfunc_end0:',
    }, '\n'),
    't.cpp'
  )
  ok('inline header instruction is unpaired', parsed.line_src[8] == nil)
  ok('source mapping resumes after header', parsed.line_src[10] == 4)
end

-- GCC uses .LFB/.LFE rather than Clang's .Lfunc_begin/.Lfunc_end markers.
do
  local parsed = A.parse_asm(
    table.concat({
      '.file 1 "t.cpp"',
      '_Z3addii:',
      '.LFB0:',
      '.loc 1 3 1',
      '  leal (%rdi,%rsi), %eax',
      '  ret',
      '.LFE0:',
    }, '\n'),
    't.cpp'
  )
  ok('gcc: LFB/LFE block found', #parsed.blocks == 1 and parsed.blocks[1].label == '_Z3addii')
  ok('gcc: instruction source mapped', parsed.line_src[5] == 3)
end

local report = { string.format('asm_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
