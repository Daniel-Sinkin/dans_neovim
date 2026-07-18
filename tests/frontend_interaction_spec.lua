-- Behavioral interaction regression for frontend reveal/repaint transitions.
-- Run through scripts/test.lua or directly with:
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/frontend_interaction_spec.lua" -c "qa!"

local H = dofile 'tests/support/frontend_harness.lua'
local pass, fail, failures = 0, 0, {}

local function check(description, condition, detail)
  if condition then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = 'FAIL  ' .. description .. (detail and ('\n      ' .. detail) or '')
  end
end

local function check_equal(description, actual, expected)
  check(description, actual == expected, string.format('expected: %s\n      actual:   %s', expected, actual))
end

local source = {
  '// cursor parking row',
  'auto contract(',
  '    const DeviceTensor& tensor_a,',
  '    const DeviceTensor& tensor_b,',
  '    DeviceTensor& output',
  ') -> void;',
}

for _, selection_kind in ipairs { 'char', 'line', 'block' } do
  local session = H.open { lines = source, cursor = 1 }
  local expected = '    tensor_a: DeviceTensor&,'
  check_equal(selection_kind .. ': initial multiline parameter flip', session:display(3), expected)

  session:select(selection_kind, 3, 5)
  check(selection_kind .. ': entered visual mode', session:mode():sub(1, 1) ~= 'n', 'mode=' .. session:mode())
  check_equal(selection_kind .. ': selected parameter is raw', session:display(3), source[3])

  session:escape()
  check(selection_kind .. ': escape returned to normal mode', session:mode():sub(1, 1) == 'n', 'mode=' .. session:mode())
  check_equal(selection_kind .. ': parameter flip restored immediately after escape', session:display(3), expected)
  check(selection_kind .. ': interaction never changed source bytes', session:assert_source_unchanged())
end

-- Experimental style profiles are buffer-local and pass through the same real
-- renderer.  Ordinary buffers keep the accepted current spelling; a lab buffer
-- may compare the const-default reference spelling without affecting it.
do
  local lines = {
    '// park',
    'auto compare(const DeviceTensor& input, DeviceTensor& output, const DeviceTensor* pointer, DeviceTensor* const fixed, const DeviceTensor* const fixed_ro) -> void;',
  }
  local selected = H.open { lines = lines, cursor = 1 }
  local explicit = H.open {
    lines = lines,
    cursor = 1,
    style_profile = { concrete_reference_const = 'explicit' },
  }
  check_equal(
    'selected default profile hides concrete reference const',
    selected:display(2),
    'def compare(input: DeviceTensor&, output: mut DeviceTensor&, pointer: const DeviceTensor^, const fixed: DeviceTensor^, const fixed_ro: const DeviceTensor^) -> void;'
  )
  check_equal(
    'explicit comparison profile retains concrete reference const',
    explicit:display(2),
    'def compare(input: const DeviceTensor&, output: mut DeviceTensor&, pointer: const DeviceTensor^, const fixed: DeviceTensor^, const fixed_ro: const DeviceTensor^) -> void;'
  )
  check('style profile does not change source bytes', explicit:assert_source_unchanged())
end

-- A multiline parameter list is one horizontal layout unit even though every
-- source row remains independent. Concrete parameter colons share an absolute
-- display column; the longest binding name determines it. Namespace/prefix
-- compaction affects only the type side and keeps the Qnpeps provenance color.
do
  local lines = {
    '// park',
    'auto build_dlenv_row(',
    '    Linalg& la,',
    '    const QnpepsConfig& cfg,',
    '    int row,',
    '    int maxdim,',
    '    const void* device_peps_row,',
    '    const void* device_env_below,',
    '    void* dlenv_row_out,',
    '    f64* row_log_out',
    ') -> int',
  }
  local session = H.open { lines = lines, cursor = 1 }
  local colon_col
  for line_number = 3, 10 do
    local shown = session:display(line_number)
    local col = shown:find(':', 1, true)
    check('multiline parameter row ' .. line_number .. ' has a flipped colon', col ~= nil, shown)
    colon_col = colon_col or col
    check_equal('multiline parameter row ' .. line_number .. ' shares the colon column', col, colon_col)
  end
  local cfg = session:display(4)
  check('Qnpeps type prefix is hidden in aligned parameter', cfg:find('Config&', 1, true) ~= nil and cfg:find('Qnpeps', 1, true) == nil, cfg)

  local before = session:display(4)
  session:select('block', 4, 6)
  check_equal('aligned parameter becomes raw in Visual block mode', session:display(4), lines[4])
  session:escape()
  check_equal('aligned parameter restores after Visual block exit', session:display(4), before)
  check('aligned parameter interaction preserves source bytes', session:assert_source_unchanged())
end

-- Exact library spelling applies outside declaration overlays too. This pins the
-- raw token path so it cannot silently diverge from parameter/template chunks.
do
  local session = H.open {
    filetype = 'cuda',
    language = 'cpp',
    name = '/tmp/dans_frontend_library_aliases.cu',
    cursor = 1,
    lines = {
      '// park',
      '#include <cuComplex.h>',
      '# include_next <cuFloatComplex/cuConjf/cudaStream_t/cudaGraph_t/cudaGraphExec_t.hpp>',
      '#include \\',
      '    <cuDoubleComplex/detail.h>',
      'void f() {',
      '    consume<cuFloatComplex, cuComplex, cuDoubleComplex, cudaStream_t, cudaGraph_t, cudaGraphExec_t>();',
      '    qnpeps::submit();',
      '    consume(cuCabsf(value), cuConjf(value), cudaStream_t(0));',
      '    cuFloatComplex make_complex();',
      '    cuDoubleComplex make_complex64();',
      '    cudaStream_t make_stream();',
      '}',
    },
  }
  check_equal('CUDA compatibility header is display-verbatim', session:display(2), '#include <cuComplex.h>')
  check_equal(
    'include_next path is display-verbatim',
    session:display(3),
    '# include_next <cuFloatComplex/cuConjf/cudaStream_t/cudaGraph_t/cudaGraphExec_t.hpp>'
  )
  check_equal('continued include opener is display-verbatim', session:display(4), '#include \\')
  check_equal('continued include path is display-verbatim', session:display(5), '    <cuDoubleComplex/detail.h>')
  check_equal(
    'raw CUDA types use semantic spelling',
    session:display(7),
    '    consume<cf32, cf32, cf64, Stream, Graph, GraphExec>();'
  )
  check_equal('raw qnpeps namespace prefix is hidden', session:display(8), '    submit();')
  check_equal('CUDA exact aliases win in call-shaped expressions', session:display(9), '    consume(abs(value), conj(value), Stream(0));')
  local aliases_ns = vim.api.nvim_get_namespaces()['ds_cpp_aliases']
  local colored_function_aliases = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.buf, aliases_ns, { 8, 0 }, { 8, -1 }, { details = true })) do
    local chunk = mark[4].virt_text and mark[4].virt_text[1]
    if chunk and chunk[2] == 'DansCUDA' then
      colored_function_aliases[chunk[1]] = true
    end
  end
  check('cuCabsf compact spelling retains CUDA color', colored_function_aliases.abs)
  check('cuConjf compact spelling retains CUDA color', colored_function_aliases.conj)
  check_equal('moved CUDA cf32 return uses shared type chunks', session:display(10), '    def make_complex() -> cf32;')
  check_equal('moved CUDA cf64 return uses shared type chunks', session:display(11), '    def make_complex64() -> cf64;')
  check_equal('moved CUDA Stream return uses shared type chunks', session:display(12), '    def make_stream() -> Stream;')
  session:select('line', 9, 10)
  check_equal('Visual reveal restores raw CUDA alias spellings', session:display(9), '    consume(cuCabsf(value), cuConjf(value), cudaStream_t(0));')
  session:escape()
  check_equal('Visual exit restores CUDA-colored exact aliases', session:display(9), '    consume(abs(value), conj(value), Stream(0));')
  check('raw library aliasing preserves source bytes', session:assert_source_unchanged())
end

-- Exact CUDA runtime handle spelling in a complete function declaration. This
-- pins the structured parameter path (rather than only the raw template/type
-- path above) and preserves the owner's source spacing around the semicolon.
do
  local lines = {
    '// park',
    'auto set_stream(cudaStream_t new_stream) -> void ;',
    'auto set_graph(cudaGraph_t graph, cudaGraphExec_t exec) -> void;',
    '// reveal parking row',
  }
  local session = H.open {
    filetype = 'cuda',
    language = 'cpp',
    name = '/tmp/dans_frontend_cuda_stream_signature.cu',
    cursor = 1,
    lines = lines,
  }
  check_equal(
    'cudaStream_t parameter uses Stream in a complete signature',
    session:display(2),
    'def set_stream(new_stream: Stream) -> void ;'
  )
  check_equal(
    'CUDA graph parameters use Graph and GraphExec in a complete signature',
    session:display(3),
    'def set_graph(graph: Graph, exec: GraphExec) -> void;'
  )
  session:select('line', 2, 4)
  check_equal('CUDA stream signature reveals exact source', session:display(2), lines[2])
  session:escape()
  check_equal(
    'CUDA stream signature restores after Visual exit',
    session:display(2),
    'def set_stream(new_stream: Stream) -> void ;'
  )
  check('CUDA stream signature preserves source bytes', session:assert_source_unchanged())
end

-- CUDA_CHECK delimiters are derived from the Tree-sitter argument_list, not a
-- same-line parenthesis scan. Both boundary rows must independently survive the
-- reveal/repaint lifecycle.
do
  local lines = {
    '// park',
    'void copy_scales() {',
    '    CUDA_CHECK(',
    '        cudaMemcpy(scales.data(), device_scales, num_cols * sizeof(f64), cudaMemcpyDeviceToHost)',
    '    );',
    '}',
  }
  local session = H.open {
    filetype = 'cuda',
    language = 'cpp',
    name = '/tmp/dans_frontend_cuda_check.cu',
    cursor = 1,
    lines = lines,
  }
  local aliases_ns = vim.api.nvim_get_namespaces()['ds_cpp_aliases']
  local function has_cuda_delimiter(line_number, source_col0)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.buf, aliases_ns, { line_number - 1, 0 }, { line_number - 1, -1 }, { details = true })) do
      if mark[3] == source_col0 and mark[4].hl_group == 'DansCUDA' then
        return true
      end
    end
    return false
  end
  local open_col0 = assert(lines[3]:find('(', 1, true)) - 1
  local close_col0 = assert(lines[5]:find(')', 1, true)) - 1
  check('multiline CUDA_CHECK opening delimiter is CUDA green', has_cuda_delimiter(3, open_col0))
  check('multiline CUDA_CHECK closing delimiter is CUDA green', has_cuda_delimiter(5, close_col0))
  session:select('line', 5, 6)
  check('Visual reveal removes closing CUDA delimiter highlight', not has_cuda_delimiter(5, close_col0))
  session:escape()
  check('Visual exit restores closing CUDA delimiter highlight independently', has_cuda_delimiter(5, close_col0))
  check('CUDA_CHECK interaction preserves source bytes', session:assert_source_unchanged())
end

-- C ABI headers exercise declaration shapes that C++-style fixtures miss:
-- uninitialized scalar fields, several parameters packed onto one continuation
-- row, and a concrete return type whose parameter close is on a later row.
do
  local lines = {
    '// park',
    'typedef struct QnpepsSampleArgs',
    '{',
    '    uint32_t struct_size;',
    '    const qnpeps_device_peps* peps;',
    '    const qnpeps_device_dlenv* dlenv;',
    '    int32_t gpus;',
    '    void* scratch;',
    '    uint64_t scratch_bytes;',
    '    uint8_t* samples_out;',
    '    double* log_prob_config;',
    '    double* log_gauge;',
    '    uint64_t n_samples;',
    '    uint64_t batch_base;',
    '    uint64_t dim_batch;',
    '    void* stream;',
    '} QnpepsSampleArgs;',
    '',
    'qnpeps_status qnpeps_ctx_build_dlenv(',
    '    qnpeps_ctx* ctx, const qnpeps_device_peps* peps, double* cumulative_row_logs',
    ');',
    '// after',
  }
  local session = H.open {
    lines = lines,
    cursor = 1,
    filetype = 'c',
    language = 'c',
    name = '/tmp/dans_frontend_qnpeps_c_api.h',
  }

  local field_colon
  for line_number = 4, 16 do
    local shown = session:display(line_number)
    local colon = shown:find(':', 1, true)
    check('C struct field row ' .. line_number .. ' renders name: type', colon ~= nil, shown)
    field_colon = field_colon or colon
    check_equal('C struct field row ' .. line_number .. ' shares the colon column', colon, field_colon)
  end
  check_equal('multiline C function moves concrete return on opener', session:display(19), 'def ctx_build_dlenv(')
  check_equal(
    'packed continuation row flips every C parameter without vertical padding',
    session:display(20),
    '    ctx: ctx^, peps: const device_peps^, cumulative_row_logs: f64^'
  )
  check_equal('multiline C function moves return to closing row', session:display(21), ') -> status;')

  session:select('line', 19, 20)
  check_equal('multiline C opener reveals its concrete return', session:display(19), lines[19])
  session:escape()
  check_equal('multiline C opener restores def independently', session:display(19), 'def ctx_build_dlenv(')
  session:select('line', 20, 21)
  check_equal('packed C parameter row reveals raw source', session:display(20), lines[20])
  session:escape()
  check_equal(
    'packed C parameter row restores independently of cursor-owned close row',
    session:display(20),
    '    ctx: ctx^, peps: const device_peps^, cumulative_row_logs: f64^'
  )
  session:select('line', 21, 22)
  check_equal('multiline C close row reveals raw source', session:display(21), lines[21])
  session:escape()
  check_equal('multiline C close row restores its own trailing return', session:display(21), ') -> status;')
  check('C ABI interaction preserves source bytes', session:assert_source_unchanged())
end

-- A clang-format overflow row may contain several parameters one line below the
-- opener; a second common layout closes the list on the opener and puts only the
-- trailing return below. Both remain compact and complete.
do
  local lines = {
    '// park',
    'auto permute_axes(',
    '    const DeviceTensor& tensor, const Permutation& perm, bool conj, cuFloatComplex* out',
    ') -> void;',
    'auto permute_axes(Carver& carver, const DeviceTensor& tensor, const Permutation& perm, bool conj)',
    '    -> DeviceTensor;',
  }
  local session = H.open {
    lines = lines,
    cursor = 1,
    filetype = 'cuda',
    language = 'cpp',
    name = '/tmp/dans_frontend_overflow_params.cu',
  }
  check_equal('overflow opener remains a def', session:display(2), 'def permute_axes(')
  check_equal(
    'overflow continuation flips every parameter',
    session:display(3),
    '    tensor: DeviceTensor&, perm: Permutation&, conj: bool, out: cf32^'
  )
  check_equal(
    'single-row list before wrapped arrow stays complete',
    session:display(5),
    'def permute_axes(carver: mut Carver&, tensor: DeviceTensor&, perm: Permutation&, conj: bool)'
  )
  check_equal('wrapped source trailing return remains on its row', session:display(6), '    -> DeviceTensor;')
  check('overflow parameter rendering preserves source bytes', session:assert_source_unchanged())
end

-- Every character-changing renderer must obey the same reveal round-trip. These
-- cases intentionally assert the lifecycle contract rather than duplicating each
-- feature's exact rendering spec: the focused feature tests own spelling, while
-- this matrix proves that a transformed row becomes source-exact in Visual mode
-- and returns byte-for-byte to its prior presentation immediately after Escape.
local roundtrips = {
  {
    name = 'declaration overlay',
    lines = { '// park', 'void f() {', '    int value{3};', '    consume(value);', '}' },
    target = 3,
  },
  {
    name = 'pointer and function aliases',
    lines = { '// park', 'auto pointer_result() -> int*;', 'auto other() -> void;' },
    target = 2,
  },
  {
    name = 'namespace and CUDA prefix conceal',
    filetype = 'cuda',
    extension = 'cu',
    lines = {
      '// park',
      'void f() {',
      '    consume(std::vector<cuFloatComplex>{});',
      '    consume(std::vector<cuDoubleComplex>{});',
      '}',
    },
    target = 3,
  },
  {
    name = 'logical infix',
    lines = { '// park', 'bool f() {', '    return logic::implies(a, b);', '    return false;', '}' },
    target = 3,
  },
  {
    name = 'designated pun',
    lines = { '// park', 'void f() {', '    consume(Config{ .field = field });', '    consume(Config{});', '}' },
    target = 3,
  },
  {
    name = 'enum alignment',
    lines = { '// park', 'enum class E {', '    a = 1,', '    much_longer = 2,', '};' },
    target = 3,
  },
  {
    name = 'special member',
    lines = { '// park', 'struct Widget {', '    Widget(const Widget&) = default;', '    Widget(Widget&&) = default;', '};' },
    target = 3,
  },
  {
    name = 'header arrow alignment',
    filetype = 'cpp',
    extension = 'hpp',
    lines = { '// park', 'auto x() -> int;', 'auto much_longer_name() -> int;' },
    target = 2,
  },
  {
    name = 'header documentation markdown',
    filetype = 'cpp',
    extension = 'hpp',
    lines = { '// park', '/// # Contract', '/// - preserves source rows', 'auto f() -> void;' },
    target = 2,
  },
  {
    name = 'macro wrapper',
    filetype = 'cpp',
    extension = 'hpp',
    lines = {
      '// park',
      '#define CHECK(x) \\',
      '    do \\',
      '    { \\',
      '        consume(x); \\',
      '    } while (0)',
    },
    target = 2,
  },
}

for index, case in ipairs(roundtrips) do
  local session = H.open {
    lines = case.lines,
    cursor = 1,
    filetype = case.filetype or 'cpp',
    name = string.format('/tmp/dans_frontend_interaction_%02d.%s', index, case.extension or 'cpp'),
  }
  local decorated = session:display(case.target)
  local raw = case.lines[case.target]
  check(case.name .. ': fixture is actually transformed', decorated ~= raw, 'both were: ' .. raw)
  session:select('line', case.target, case.target + 1)
  check_equal(case.name .. ': visual selection reveals source', session:display(case.target), raw)
  session:escape()
  check_equal(case.name .. ': escape restores exact prior presentation', session:display(case.target), decorated)
  check(case.name .. ': source bytes remain unchanged', session:assert_source_unchanged())
end

local report = { string.format('frontend_interaction_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
