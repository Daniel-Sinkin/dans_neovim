-- Headless spec for the function-param flip colors (ds_cpp_aliases virt_text):
-- types blue/green, mut red, constrained-auto concept-cyan.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/param_flip_spec.lua" -c "qa!"

local pass, fail, fails = 0, 0, {}
local function ok(d, c)
  if c then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  '// top', -- cursor parks here so the signature renders
  'void f(int x, float x32, double x64, Bar& rw, const Foo& ro, std::string_view s, SizeLike auto n, const cuFloatComplex& scale, const cuComplex& scale_alias, cuDoubleComplex& accum64, const cuFloatComplex* input, cudaStream_t stream, cudaGraph_t graph, cudaGraphExec_t exec, const qnpeps::Tensor& tensor);',
})
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd 'doautocmd FileType'
vim.cmd 'doautocmd BufEnter'

local ans = vim.api.nvim_get_namespaces()['ds_cpp_aliases']
local chunks = {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ans, { 1, 0 }, { 1, -1 }, { details = true })) do
  for _, c in ipairs(m[4].virt_text or {}) do
    chunks[#chunks + 1] = c
  end
end
local function has(text, hl)
  for _, c in ipairs(chunks) do
    if c[1] == text and c[2] == hl then
      return true
    end
  end
  return false
end

ok('param name is Normal', has('x', 'Normal'))
ok('colon is Normal', has(': ', 'Normal'))
ok('value type blue (int)', has('int', 'DansInlayType'))
ok('ordinary float uses f32', has('f32', 'DansInlayType'))
ok('ordinary double uses f64', has('f64', 'DansInlayType'))
ok('non-const ref gets mut (red)', has('mut ', 'DansMarkerMut'))
ok('non-const ref type blue (Bar&)', has('Bar&', 'DansInlayType'))
ok('std::string_view green', has('string_view', 'DansString'))
ok('constrained-auto concept-colored', has('~SizeLike', 'DansConcept'))
ok('const-default ref has no separate mut on ro', not has('mut Foo', 'DansMarkerMut'))
ok('cuFloatComplex uses CUDA-green cf32', has('cf32&', 'DansCUDA'))
ok('cuDoubleComplex uses CUDA-green cf64', has('cf64&', 'DansCUDA'))
ok('visible const qualifier remains gray', has('const ', 'DansConst'))
ok('const CUDA pointee keeps provenance color', has('cf32', 'DansCUDA'))
ok('CUDA stream parameter uses CUDA-green Stream', has('Stream', 'DansCUDA'))
ok('CUDA graph parameter uses CUDA-green Graph', has('Graph', 'DansCUDA'))
ok('CUDA graph executable parameter uses CUDA-green GraphExec', has('GraphExec', 'DansCUDA'))
ok('hidden qnpeps namespace keeps orchid type provenance', has('Tensor&', 'DansQnpeps'))

-- OPENBLAS_CONST (OpenBLAS's const macro, all over cblas.h) is const: the
-- flip must render it exactly like the literal keyword.
do
  local A = require 'custom.dans_frontend_cpp.aliases'
  local function text_of(chunks)
    local t = {}
    for _, c in ipairs(chunks or {}) do
      t[#t + 1] = c[1]
    end
    return table.concat(t)
  end
  local oc = text_of(A.flip_param 'OPENBLAS_CONST blasint M')
  ok('OPENBLAS_CONST value param == const param', oc ~= '' and oc == text_of(A.flip_param 'const blasint M'))
  local op = text_of(A.flip_param 'OPENBLAS_CONST double *A')
  ok('OPENBLAS_CONST ptr param == const ptr param', op ~= '' and op == text_of(A.flip_param 'const double *A'))

  local expected_ref = 'value: DebugLoc&'
  ok('T& name canonical spacing', text_of(A.flip_param('const DebugLoc& value', b)) == expected_ref)
  ok('T &name canonical spacing', text_of(A.flip_param('const DebugLoc &value', b)) == expected_ref)
  ok('T & name canonical spacing', text_of(A.flip_param('const DebugLoc & value', b)) == expected_ref)
end

local report = { string.format('param_flip_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
