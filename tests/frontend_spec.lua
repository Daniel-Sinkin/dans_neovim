-- Headless spec for the C/C++ frontend view layer (view / parse / render).
-- Run:  nvim --headless --cmd "set noswapfile" -c "luafile tests/frontend_spec.lua" -c "qa!"
-- Each case wraps body lines in a function ('fn'), a struct ('struct'), or none
-- ('top'); the cursor sits on line 1 (the wrapper) so body lines aren't revealed.
-- expect[i] is the rendered frontend overlay for body line i, or false for "no overlay"
-- (raw). Prints a PASS/FAIL summary; failures show expected vs actual.

local jns = vim.api.nvim_create_namespace 'ds_frontend_view'
local pass, fail, fails = 0, 0, {}

local function overlay(b, row0)
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
  if #m == 0 then
    return nil
  end
  local s = {}
  for _, c in ipairs(m[1][4].virt_text or {}) do
    s[#s + 1] = c[1]
  end
  return table.concat(s, '')
end

local function run(desc, ctx, body, expect)
  local lines, off = {}, 0
  if ctx == 'fn' then
    lines, off = { 'auto fn() -> void', '{' }, 2
  elseif ctx == 'struct' then
    lines, off = { 'struct S', '{' }, 2
  else
    lines, off = { '// top' }, 1
  end
  for _, l in ipairs(body) do
    lines[#lines + 1] = l
  end
  if ctx == 'fn' then
    lines[#lines + 1] = '}'
  elseif ctx == 'struct' then
    lines[#lines + 1] = '};'
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  for i, exp in pairs(expect) do
    local got = overlay(b, off + i - 1)
    local ok = (exp == false) and (got == nil) or (got == exp)
    if ok then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  %s\n        src: %s\n        exp: %s\n        got: %s', desc, body[i], exp == false and '<raw>' or exp, got == nil and '<raw>' or got)
    end
  end
end

-- ===================== value declarations (locals -> mut) =====================
run('local value int', 'fn', { 'int x{7};' }, { 'mut x: int = 7;' })
run('local value float', 'fn', { 'f32 y{1.0f};' }, { 'mut y: f32 = 1.0f;' })
run('local value empty-init', 'fn', { 'Vec2 p{};' }, { 'mut p: Vec2;' })
run('local const', 'fn', { 'const int x{7};' }, { 'x: int = 7;' })
run('local constexpr', 'fn', { 'constexpr int x{7};' }, { 'x: int : 7;' })
run('local static constexpr', 'fn', { 'static constexpr usize n{4};' }, { 'n: usize : 4;' })
run('local inline constexpr', 'fn', { 'inline constexpr f32 k{2.0f};' }, { 'k: f32 : 2.0f;' })

-- ===================== auto bindings =====================
run('auto local', 'fn', { 'auto a = foo();' }, { 'mut a := foo();' })
run('const auto local', 'fn', { 'const auto a = foo();' }, { 'a := foo();' })
run('auto& ref', 'fn', { 'auto& r = x;' }, { 'mut r& := x;' })
run('const auto& ref', 'fn', { 'const auto& r = x;' }, { 'r& := x;' })
run('auto* ptr', 'fn', { 'auto* p = &x;' }, { 'mut p^ := &x;' })
run('const auto* ptr', 'fn', { 'const auto* s = get();' }, { 's^ := get();' })
run('const auto* glfw', 'fn', { 'const auto* p = glfwGetVersionString();' }, { 'p^ := GetVersionString();' })
run('vk function value', 'fn', { 'const auto r = vkCreateInstance(&info);' }, { 'r := CreateInstance(&info);' })
run('CUDA complex magnitude value', 'fn', { 'const auto magnitude = cuCabsf(value);' }, { 'magnitude := abs(value);' })
run('CUDA complex conjugate value', 'fn', { 'const auto conjugate = cuConjf(value);' }, { 'conjugate := conj(value);' })
run('auto&& fwd (raw)', 'fn', { 'auto&& z = f();' }, { false })

-- ===================== pointers / references =====================
run('local pointer', 'fn', { 'int* p{};' }, { 'mut p: int^;' })
run('local const pointer', 'fn', { 'const char* s{};' }, { 's: CString;' })
run('explicit CUDA pointer copy-init', 'fn', {
  'cuFloatComplex* a_perm = byte_offset<cuFloatComplex>(scratch, 0);',
}, {
  'mut a_perm: cf32^ = byte_offset<cf32>(scratch, 0);',
})
run('CUDA stream value', 'fn', { 'cudaStream_t stream{};' }, { 'mut stream: Stream;' })
run('CUDA graph value', 'fn', { 'cudaGraph_t graph{};' }, { 'mut graph: Graph;' })
run('CUDA graph executable value', 'fn', { 'cudaGraphExec_t exec{};' }, { 'mut exec: GraphExec;' })

-- ===================== casts inside values =====================
run('static_cast value', 'fn', { 'auto v = static_cast<int>(y);' }, { 'mut v := $scast<int>(y);' })

-- ===================== lambdas =====================
-- Captures and params render like a nested function: concrete params flip to
-- `name: type`, auto params collapse to the ref-sigil form (`const auto& a` -> `a&`,
-- `auto& a` -> `mut a&`, `auto&& x` -> `x&&`, `auto x` -> `x`), and `|` divides the
-- capture list from the params -- shown only when the lambda captures, so a
-- non-capturing lambda reads as `lambda f(x: int)`. `&a` captures flip to `a&`.
run('lambda no cap no params', 'fn', { 'auto g = []() { run(); };' }, { 'lambda g() { run(); };' })
run('lambda concrete param', 'fn', { 'const auto f = [](int x) { return x; };' }, { 'lambda f(x: int) { return x; };' })
run('lambda const-ref auto param', 'fn', { 'const auto f = [](const auto& as) { return as; };' }, { 'lambda f(as&) { return as; };' })
run('lambda mut-ref auto param', 'fn', { 'const auto f = [](auto& a) { return a; };' }, { 'lambda f(mut a&) { return a; };' })
run('lambda fwd-ref auto param', 'fn', { 'const auto f = [](auto&& x) { return x; };' }, { 'lambda f(x&&) { return x; };' })
run('lambda value auto param', 'fn', { 'const auto f = [](auto x) { return x; };' }, { 'lambda f(x) { return x; };' })
run('lambda mixed auto+concrete', 'fn', { 'const auto f = [](const auto& as, int x) { return x; };' }, { 'lambda f(as&, x: int) { return x; };' })
run('lambda concrete const ref', 'fn', { 'const auto f = [](const Foo& foo) { return foo; };' }, { 'lambda f(foo: Foo&) { return foo; };' })
run('lambda concrete mut ref', 'fn', { 'const auto f = [](Bar& rw) { return rw; };' }, { 'lambda f(rw: mut Bar&) { return rw; };' })
run('lambda ref capture + param', 'fn', { 'const auto f = [&bs](auto& a) { return a; };' }, { 'lambda f(bs& | mut a&) { return a; };' })
run('lambda two ref captures', 'fn', { 'const auto f = [&a, &b](int x, int y) { return x; };' }, { 'lambda f(a&, b& | x: int, y: int) { return x; };' })
run('lambda value capture', 'fn', { 'const auto f = [count](int x) { return x; };' }, { 'lambda f(count | x: int) { return x; };' })
run('lambda mixed captures', 'fn', { 'const auto f = [a, &b](int x) { return x; };' }, { 'lambda f(a, b& | x: int) { return x; };' })
run('lambda blanket ref capture', 'fn', { 'const auto f = [&](int x) { return x; };' }, { 'lambda f(& | x: int) { return x; };' })
run('lambda blanket copy capture', 'fn', { 'const auto h = [=](int n) { return n; };' }, { 'lambda h(= | n: int) { return n; };' })
run('lambda capture no params', 'fn', { 'const auto f = [&state]() { return state; };' }, { 'lambda f(state&|) { return state; };' })
run('lambda trailing return', 'fn', { 'const auto f = [](int x) -> bool { return x > 0; };' }, { 'lambda f(x: int) -> bool { return x > 0; };' })
run('lambda mutable tail', 'fn', { 'const auto f = [count](u32 n) mutable { return n; };' }, { 'lambda f(count | n: u32) mutable { return n; };' })

-- ===================== structured bindings =====================
run('structured binding', 'fn', { 'auto [a, b] = pair;' }, { 'mut a, b := pair;' })
run('structured ref binding', 'fn', { 'const auto& [k, v] = *it;' }, { 'k&, v& := *it;' })
run('structured mut ref binding', 'fn', { 'auto& [xpos, ypos] = *res;' }, { 'mut xpos&, ypos& := *res;' })

-- ===================== range-for =====================
run('for const ref', 'fn', { 'for (const auto& v : items)' }, { 'for (v& : items)' })
run('for mut ref', 'fn', { 'for (auto& m : items)' }, { 'for (mut m& : items)' })
run('for mut value', 'fn', { 'for (auto x : xs)' }, { 'for (mut x : xs)' })
run('for fwd ref', 'fn', { 'for (auto&& elem : range)' }, { 'for (mut elem&& : range)' })
run('for const value', 'fn', { 'for (const auto x : xs)' }, { 'for (x : xs)' })
run('for c-style (raw)', 'fn', { 'for (int i = 0; i < n; ++i)' }, { false })

-- ===================== defer =====================
run('defer single', 'fn', { 'DANS_DEFER([] { cleanup(); });' }, { 'defer cleanup();' })
run('plain DEFER single ref capture', 'fn', { 'DEFER([&] { free(Z); });' }, { 'defer free(Z);' })
run('defer block', 'fn', { 'DANS_DEFER([] { a(); b(); });' }, { 'defer { a(); b(); }' })
run('defer multiline', 'fn', { 'DANS_DEFER([] {', '    a();', '});' }, { 'defer {', false, '}' })
run('plain DEFER multiline', 'fn', { 'DEFER([&] {', '    free(Z);', '});' }, { 'defer {', false, '}' })

-- ===================== non-declarations (raw) =====================
run('return stmt', 'fn', { 'return x;' }, { false })
run('call stmt', 'fn', { 'foo(a, b);' }, { false })
run('assign stmt', 'fn', { 'x = y + z;' }, { false })
run('if opener', 'fn', { 'if (cond) {' }, { false })
run('multiline opener', 'fn', { 'auto big = compute(' }, { false })

-- ===================== members (no mut on value) =====================
run('member value', 'struct', { 'int x{7};' }, { 'x: int = 7;' })
run('member empty', 'struct', { 'Vec2 pos{};' }, { 'pos: Vec2;' })
-- a pointer MEMBER is plain struct data: no mut (locals/globals keep it)
run('member pointer', 'struct', { 'Foo* ptr{};' }, { 'ptr: Foo^;' })
run('member glfw pointer', 'struct', { 'GLFWwindow* window_{};' }, { 'window_: window^;' })
run('member const pointer', 'struct', { 'const Foo* cptr{};' }, { 'cptr: const Foo^;' })
run('member array', 'struct', { 'std::array<f32, 3> arr{};' }, { 'arr: [3]f32;' })
run('member array no-init', 'struct', { 'std::array<f32, 3> arr;' }, { 'no_init arr: [3]f32;' })
-- nested arrays collapse fully: [outer][inner]Elem, not [outer]array<Elem, inner>
run('member nested array', 'struct', { 'std::array<std::array<Color, k_width>, k_height> framebuffer{};' }, { 'framebuffer: [k_height][k_width]Color;' })
-- uninitialized members get a red no_init marker at the start (vs `x{}` -> clean)
run('member value no-init', 'struct', { 'GLFWbool x;' }, { 'no_init x: bool;' })
run('member value default-init', 'struct', { 'GLFWbool x{};' }, { 'x: bool;' })
run('member int no-init', 'struct', { 'int count;' }, { 'no_init count: int;' })
-- a pointer member is uninitialized garbage too; a reference is ctor-bound, omit
run('member pointer no-init', 'struct', { 'void* userPointer;' }, { 'no_init userPointer: void^;' })
run('member ref no no_init', 'struct', { 'Foo& ref;' }, { 'mut ref: Foo&;' })
-- a bare local stays raw (deferred-init idiom), not flagged
run('local value no-init stays raw', 'fn', { 'int x;' }, { false })

-- an output-stream statement is not a decl: `out << a << k_newline;` must not be
-- read as a `k_newline`-typed local with `out << a <<` as the type. The last line
-- has no char literals, so only the `<<` guard (not a quote check) saves it.
run('stream char literals stays raw', 'fn', { "out << 'P' << '6' << k_newline;" }, { false })
run('stream mixed stays raw', 'fn', { "out << k_width << ' ' << k_height << k_newline;" }, { false })
run('stream no literals stays raw', 'fn', { 'out << k_max_color_u8 << k_newline;' }, { false })

-- raw / std fixed-width types render as the dans aliases (so Vulkan's uint32_t /
-- float read the same as first-party u32 / f32)
run('member raw uint32', 'struct', { 'uint32_t count{};' }, { 'count: u32;' })
run('member raw float', 'struct', { 'float scale{};' }, { 'scale: f32;' })
run('member std int32', 'struct', { 'std::int32_t off{};' }, { 'off: i32;' })
run('member double', 'struct', { 'double ratio{};' }, { 'ratio: f64;' })

-- [[maybe_unused]] is hidden entirely (only its absence matters); on a decl the
-- overlay drops it via split_markers.
run('maybe_unused dropped on decl', 'fn', { '[[maybe_unused]] constexpr int n{4};' }, { 'n: int : 4;' })

-- OPENBLAS_CONST is OpenBLAS's const macro: peeled and hidden exactly like
-- const (no mut, const invisible).
run('OPENBLAS_CONST decl', 'fn', { 'OPENBLAS_CONST blasint lda{8};' }, { 'lda: blasint = 8;' })

-- const char* const (const pointer to const char) -> const CString, not CString const
run('span const cstring', 'struct', { 'std::span<const char* const> layers{};' }, { 'layers: span<const CString>;' })
run('member nested template', 'struct', { 'std::vector<std::pair<int, int>> v{};' }, { 'v: vector<pair<int, int>>;' })
run('member vector cstring', 'struct', { 'std::vector<const char*> v{};' }, { 'v: vector<CString>;' })
run('member const-ref vector cstring', 'struct', { 'const std::vector<const char*>& e{};' }, { 'e: const vector<CString>&;' })
run('member ref-in-template', 'struct', { 'std::pair<int&, int> pr{};' }, { 'pr: pair<int&, int>;' })
run('member unique_ptr', 'struct', { 'std::unique_ptr<Foo> up{};' }, { 'up: Foo^;' })
run('member shared_ptr', 'struct', { 'std::shared_ptr<Foo> sp{};' }, { 'sp: Foo^;' })
run('member unique_ptr deleter', 'struct', { 'std::unique_ptr<Foo, FooDeleter> p{};' }, { 'p: Foo^, FooDeleter~;' })
run('member unique_ptr nested deleter', 'struct', { 'std::unique_ptr<std::pair<int, int>> p{};' }, { 'p: pair<int, int>^;' })
run('member glfw type (overlay strips prefix)', 'struct', { 'GLFWwindow win{};' }, { 'win: window;' })
run('member glfw unique_ptr deleter', 'struct', { 'std::unique_ptr<GLFWwindow, WindowDeleter> w{};' }, { 'w: window^, WindowDeleter~;' })
run('member optional', 'struct', { 'std::optional<int> o{};' }, { 'o: int?;' })
run('member vulkan null', 'struct', { 'VkBuffer buf{VK_NULL_HANDLE};' }, { 'buf: Buffer = nullptr;' })
run('member vk PFN kept', 'struct', { 'PFN_vkCreateInstance fn{};' }, { 'fn: PFN_vkCreateInstance;' })
run('member static constexpr', 'struct', { 'static constexpr usize cap{16};' }, { 'cap: usize : 16;' })

-- ===================== alignment block =====================
-- a pointer member is not mut, so this block reserves no mut column; a local
-- block with a pointer still does (see 'array member block widths' below for
-- the member case and 'smart-ptr beside mut local' for the local case)
run('aligned members', 'struct', {
  'Vec2 position{};',
  'Color fill{white};',
  'Foo* ptr{};',
}, {
  'position: Vec2;',
  'fill    : Color = white;',
  'ptr     : Foo^;',
})

-- constexpr constants never share an alignment block with normal vars: the
-- constexpr-ness flip splits the run, so the constants align among themselves
-- (no mut column, ever) and the vars align separately with their own mut shift.
-- Bodies indented like clang-format output: the const/constexpr detection must
-- see through the indent (it once didn't, shifting all-const blocks).
run('constexpr block split from vars', 'fn', {
  '    constexpr blasint m{2};',
  '    constexpr blasint k{3};',
  '    constexpr blasint n{2};',
  '    f64 alpha{1.0};',
  '    f64 beta{0.0};',
}, {
  'm: blasint : 2;',
  'k: blasint : 3;',
  'n: blasint : 2;',
  'mut alpha: f64 = 1.0;',
  'mut beta : f64 = 0.0;',
})

-- a block with no actual mut binding gets no mut column at all
run('all-const block unshifted', 'fn', {
  '    const int width{800};',
  '    const int height{600};',
}, {
  'width : int = 800;',
  'height: int = 600;',
})

-- smart pointers render `T^` without mut; a block of only those (and consts)
-- must not reserve the mut column
run('smart-ptr block unshifted', 'fn', {
  '    std::unique_ptr<Foo> a{};',
  '    std::unique_ptr<Bar> b{};',
}, {
  'a: Foo^;',
  'b: Bar^;',
})

-- ...but a real mut sibling still shifts the non-mut lines under it
run('smart-ptr beside mut local', 'fn', {
  '    std::unique_ptr<Foo> up{};',
  '    int counter{0};',
}, {
  '    up     : Foo^;',
  'mut counter: int  = 0;',
})

-- mixed const + mut locals, indented: the consts take the blank mut column so
-- names align under their mut sibling; the constexpr neighbors stay unshifted
run('mixed const/mut block', 'fn', {
  '    constexpr f32 k_scale{2.0f};',
  '    constexpr f32 k_bias{0.5f};',
  '    const Vec2 origin{0.0f, 0.0f};',
  '    Vec2 cursor{};',
}, {
  'k_scale: f32 : 2.0f;',
  'k_bias : f32 : 0.5f;',
  '    origin: Vec2 = 0.0f, 0.0f;',
  'mut cursor: Vec2;',
})

-- static constexpr constants inside a struct split from the fields below them
run('struct constants split from fields', 'struct', {
  '    static constexpr u32 k_width{800};',
  '    static constexpr u32 k_height{600};',
  '    Vec2 pos{};',
  '    Vec2 vel{};',
}, {
  'k_width : u32 : 800;',
  'k_height: u32 : 600;',
  'pos: Vec2;',
  'vel: Vec2;',
})

-- a blank line splits alignment blocks: each pair aligns independently
run('blank line splits blocks', 'fn', {
  '    int aa{1};',
  '    int bb{2};',
  '',
  '    f32 c{1.0f};',
  '    f32 dd{2.0f};',
}, {
  [1] = 'mut aa: int = 1;',
  [2] = 'mut bb: int = 2;',
  [4] = 'mut c : f32 = 1.0f;',
  [5] = 'mut dd: f32 = 2.0f;',
})

-- array members in a block: the [N]T display width drives the type column;
-- pointer members carry no mut, so nothing shifts
run('array member block widths', 'struct', {
  '    std::array<f32, 3> a{};',
  '    Foo* p{};',
  '    GLFWwindow* win{};',
}, {
  'a  : [3]f32;',
  'p  : Foo^;',
  'win: window^;',
})

-- a smart pointer with a deleter renders `T^, Del~`; that full width is what
-- the block's type column measures
run('deleter width in block', 'fn', {
  '    std::unique_ptr<Foo, FooDeleter> p{};',
  '    int counter{0};',
}, {
  [1] = '    p      : Foo^, FooDeleter~;',
  [2] = 'mut counter: int' .. (' '):rep(14) .. ' = 0;',
})

-- consecutive `const auto` bindings align their `:=`, padding each name to the
-- run's widest -- the same treatment explicit-type decl blocks give the `:`
run('aligned auto bindings', 'fn', {
  '    const auto sigma = args.sigma;',
  '    const auto chosen_spins = args.chosen_spins;',
  '    const auto dim_phys = args.dim_phys;',
}, {
  'sigma' .. (' '):rep(7) .. ' := args.sigma;',
  'chosen_spins := args.chosen_spins;',
  'dim_phys' .. (' '):rep(4) .. ' := args.dim_phys;',
})

-- a mut auto binding in the run reserves the left mut column, so the const
-- siblings shift under it and the `:=` still lines up (sigils count toward width)
run('auto binding block with mut', 'fn', {
  '    const auto a = foo();',
  '    auto bb = bar();',
  '    const auto& cref = a;',
}, {
  '    a' .. (' '):rep(4) .. ' := foo();',
  'mut bb' .. (' '):rep(3) .. ' := bar();',
  '    cref& := a;',
})

-- a singleton auto binding is untouched (nothing to align against)
run('lone auto binding unpadded', 'fn', { '    const auto only = args.only;' }, { 'only := args.only;' })

-- ===================== nested template rendering =====================
run('array of pairs', 'struct', { 'std::array<std::pair<int, int>, 4> lut{};' }, { 'lut: [4]pair<int, int>;' })
run('array of vectors', 'struct', { 'std::array<std::vector<f32>, 2> buckets{};' }, { 'buckets: [2]vector<f32>;' })
run('triple nested array', 'struct', { 'std::array<std::array<std::array<u8, 2>, 3>, 4> voxels{};' }, { 'voxels: [4][3][2]u8;' })
run('array of optionals', 'struct', { 'std::array<std::optional<int>, 4> os{};' }, { 'os: [4]int?;' })
run('vector of arrays', 'struct', { 'std::vector<std::array<f32, 3>> tris{};' }, { 'tris: vector<[3]f32>;' })
run('array of unique_ptr', 'struct', { 'std::array<std::unique_ptr<Foo>, 2> owners{};' }, { 'owners: [2]unique_ptr<Foo>;' })
run('array of cstrings', 'struct', { 'std::array<const char*, 3> names{};' }, { 'names: [3]CString;' })
run('unordered_map value array', 'struct', { 'std::unordered_map<u32, std::array<f32, 2>> uv{};' }, { 'uv: unordered_map<u32, [2]f32>;' })

-- ===================== top-level (raw) =====================
run('include', 'top', { '#include <vector>' }, { false })
run('using alias (raw)', 'top', { 'using Vec3 = glm::vec3;' }, { false })

-- ===================== diagnostics don't suppress the overlay =====================
-- A diagnosed line renders like any other: the diagnostic shows as a first-cell
-- mark + cursor-line virtual text, so `std::array<int, 5> xs{};` must still
-- read as `[5]int` even while clangd flags something on that line.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'auto fn() -> void', '{', '    std::array<int, 5> xs{};', '}' })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local dns = vim.api.nvim_create_namespace 'spec_diag'
  vim.diagnostic.set(dns, b, { { lnum = 2, col = 0, end_lnum = 2, end_col = 5, severity = vim.diagnostic.severity.ERROR, message = 'boom' } })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local got = overlay(b, 2)
  if got == 'mut xs: [5]int;' then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  overlay on diagnosed line\n        exp: mut xs: [5]int;\n        got: %s', got == nil and '<raw>' or got)
  end
  -- and the diagnostic itself lands as a first-cell mark (red bg on col 0)
  require('custom.dans_diagmark').setup()
  require('custom.dans_diagmark').refresh(b)
  local dm = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace 'ds_diagmark', { 2, 0 }, { 2, -1 }, { details = true })
  if #dm == 1 and dm[1][4].hl_group == 'DansDiagMarkError' and dm[1][4].end_col == 1 then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  diagmark first-cell extmark missing/wrong: ' .. vim.inspect(dm)
  end
  vim.diagnostic.reset(dns, b)
end

-- ===================== more edge cases =====================
run('multi declarator (raw)', 'fn', { 'int a, b;' }, { false })
run('multi init (raw)', 'fn', { 'int a = 1, b = 2;' }, { false })
run('function pointer (raw)', 'fn', { 'void (*fp)(int){};' }, { false })
run('string init', 'fn', { 'std::string s{"hi"};' }, { 'mut s: string = "hi";' })
run('bool init', 'fn', { 'bool ok{true};' }, { 'mut ok: bool = true;' })
run('negative init', 'fn', { 'int x{-1};' }, { 'mut x: int = -1;' })
run('ternary value', 'fn', { 'auto x = a ? b : c;' }, { 'mut x := a ? b : c;' })
run('dans-namespaced type', 'fn', { 'dans::Foo f{};' }, { 'mut f: Foo;' })
run('glm-namespaced type', 'fn', { 'glm::vec3 v{};' }, { 'mut v: glm::vec3;' })
run('ref member', 'struct', { 'Foo& m;' }, { 'mut m: Foo&;' })
run('const ref member', 'struct', { 'const Foo& m;' }, { 'm: const Foo&;' })
run('trailing comment', 'fn', { 'int x{7}; // count' }, { 'mut x: int = 7; // count' })

-- ===================== new features =====================
run('optional local', 'fn', { 'std::optional<Foo> o{};' }, { 'mut o: Foo?;' })
run('optional pointer', 'struct', { 'std::optional<int> o{};' }, { 'o: int?;' })
run('optional ref member', 'struct', { 'std::optional<int>& o;' }, { 'mut o: int?&;' })
run('optional const ref member', 'struct', { 'const std::optional<int>& o;' }, { 'o: const int?&;' })
run('optional ptr member', 'struct', { 'std::optional<int>* o{};' }, { 'o: int?^;' })
run('expected member', 'struct', { 'std::expected<int, Error> r{};' }, { 'r: int?Error;' })
run('expected local', 'fn', { 'std::expected<Foo, Err> r{};' }, { 'mut r: Foo?Err;' })
run('expected const ref member', 'struct', { 'const std::expected<int, Err>& r;' }, { 'r: const int?Err&;' })
run('expected nested arm', 'struct', { 'std::expected<std::vector<int>, Err> r{};' }, { 'r: vector<int>?Err;' })
run('designated decl pun', 'fn', { 'const Ray r{.origin = origin, .direction = direction};' }, { 'r: Ray = origin, direction;' })
run('designated member-access pun', 'fn', { 'const Ray r{.center = cfg.center};' }, { 'r: Ray = center;' })
run('designated non-pun', 'fn', { 'const Cfg c{.width = 800, .height = h};' }, { 'c: Cfg = width=800, height=h;' })
run('ranges value', 'fn', { 'auto a = std::ranges::transform(xs, fn);' }, { 'mut a := transform(xs, fn);' })
run('views value', 'fn', { 'auto a = std::ranges::views::filter(xs, p);' }, { 'mut a := filter(xs, p);' })
run('for destructure', 'fn', { 'for (const auto& [k, v] : items)' }, { 'for (k, v& : items)' })
run('if let bare', 'fn', { 'if (const auto res = find(x); res)' }, { 'if let res := find(x)' })
run('if let with brace', 'fn', { 'if (const auto p = lookup(k); p) {' }, { 'if let p := lookup(k) {' })
run('if let has_value drop', 'fn', { 'if (auto res = from_glfw_get_window_pos(); res.has_value())' }, { 'if let res := from_glfw_get_window_pos()' })
run('if let iterator drop', 'fn', { 'if (auto it = m.find(x); it != m.end())' }, { 'if let it := m.find(x)' })
run('if let value-cmp drop', 'fn', { 'if (const auto res = find(x); res == 0)' }, { 'if let res := find(x)' })
run('if let independent cond kept', 'fn', { 'if (auto res = f(); ready)' }, { 'if let res := f(); ready' })
run('if let compound && kept', 'fn', { 'if (auto res = f(); res.has_value() && ready)' }, { 'if let res := f(); res.has_value() && ready' })
run('if let compound and-keyword kept', 'fn', { 'if (auto res = m.find(k); res != m.end() and res->ok)' }, { 'if let res := m.find(k); res != m.end() and res->ok' })
run('static thread_local', 'fn', { 'static thread_local std::mt19937_64 engine{std::random_device{}()};' }, { 'thread_local mut engine: mt19937_64 = random_device{}();' })
run('if plain (raw)', 'fn', { 'if (ready) {' }, { false })
run('std move value', 'fn', { 'auto y = std::move(x);' }, { 'mut y := move(x);' })
run('std forward value', 'fn', { 'auto y = std::forward<T>(x);' }, { 'mut y := forward<T>(x);' })
run('cast pointer arg', 'fn', { 'auto y = reinterpret_cast<u8*>(p);' }, { 'mut y := $rcast<u8^>(p);' })
run('cast nested pointer', 'fn', { 'auto z = static_cast<std::vector<int*>>(v);' }, { 'mut z := $scast<vector<int^>>(v);' })
run('paren init', 'fn', { 'std::vector<stbtt_bakedchar> out(config.codepoint_count);' }, { 'mut out: vector<stbtt_bakedchar>(config.codepoint_count);' })
run('paren init digit', 'fn', { 'Buffer buf(1024);' }, { 'mut buf: Buffer(1024);' })
run('function decl raw', 'fn', { 'Foo make(Bar);' }, { false })
-- most-vexing-parse with a cast argument: treesitter reads it as a function
-- decl, but a "param" STARTING with a cast keyword is an argument -- the line
-- is the variable it declares (and the decorations defer to this overlay
-- instead of double-rendering the raw line)
run('mvp cast arg is a variable', 'fn', { 'std::vector<f64> a(static_cast<usize>(m * k));' }, { 'mut a: vector<f64>($scast<usize>(m * k));' })
-- ...but a cast in a DEFAULT argument is a real function: stays raw
run('cast default arg stays function', 'fn', { 'void f(int x = static_cast<int>(y));' }, { false })

-- std::move / forward must render red (DansMarkerMut); the text suite can't see hl
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'auto fn() -> void', '{', '    auto y = std::move(x);', '}' })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { 2, 0 }, { 2, -1 }, { details = true })
  local hl
  for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
    if c[1] == 'move' then
      hl = c[2]
    end
  end
  if hl == 'DansMarkerMut' then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  std::move color: move hl = ' .. tostring(hl)
  end
end

-- BLAS/LAPACK identifiers carry the DansBLAS yellow-green in the overlay: the
-- blasint type and a cblas_ call in the value.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'auto fn() -> void', '{', '    constexpr blasint m{2};', '    auto s = cblas_dsdot(n, x, 1, y, 1);', '}' })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local function hl_of(row, text)
    local m = vim.api.nvim_buf_get_extmarks(b, jns, { row, 0 }, { row, -1 }, { details = true })
    for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
      if c[1] == text then
        return c[2]
      end
    end
  end
  local t_hl = hl_of(2, 'blasint')
  local v_hl = hl_of(3, 'cblas_dsdot')
  if t_hl == 'DansBLAS' and v_hl == 'DansBLAS' then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  BLAS colors: blasint=%s cblas_dsdot=%s', tostring(t_hl), tostring(v_hl))
  end
end

-- ===================== designated init (conceal + inline pad) =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'auto fn() -> void', '{',
    '    const auto m = Metrics{',
    '        .x = a,',
    '        .width = b,',
    '        .same = same,',
    '    };',
    '    render({.x = 1, .y = 2});',
    '}',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local dns = vim.api.nvim_create_namespace 'ds_cpp_designated'
  -- displayed text: apply conceals (hide) and inline virt_text (insert), then trim.
  local function display(row0)
    local line = vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1] or ''
    local hidden, inserts, hint = {}, {}, false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, dns, { row0, 0 }, { row0, -1 }, { details = true })) do
      local d = m[4]
      if d.conceal ~= nil and d.end_col then
        for c = m[3], d.end_col - 1 do
          hidden[c] = true
        end
      end
      if d.virt_text and d.virt_text_pos == 'inline' then
        local t = ''
        for _, ch in ipairs(d.virt_text) do
          t = t .. ch[1]
        end
        inserts[m[3]] = (inserts[m[3]] or '') .. t
      end
      if d.hl_group == 'DansHint' then
        hint = true
      end
    end
    local s = {}
    for c = 0, #line do
      if inserts[c] then
        s[#s + 1] = inserts[c]
      end
      if c < #line and not hidden[c] then
        s[#s + 1] = line:sub(c + 1, c + 1)
      end
    end
    return (table.concat(s):gsub('^%s+', '')), hint
  end
  local function chk(desc, got, exp)
    if got == exp then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, tostring(exp), tostring(got))
    end
  end
  local d3, hint3 = display(3)
  chk('designated align narrow', d3, 'x     = a,')
  chk('designated align wide', display(4), 'width = b,')
  chk('designated pun', display(5), 'same,')
  chk('designated single-line tight', display(7), 'render({x=1, y=2});')
  chk('designated field hint color', hint3, true)
end

-- ===================== caret / const colors =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'struct S', '{',
    '    Foo* raw{};',
    '    std::unique_ptr<Foo> uni{};',
    '    std::shared_ptr<Foo> sha{};',
    '    const Foo* cst{};',
    '    std::unique_ptr<Foo, Del> del{};',
    '    VkBuffer* vp{};',
    '};',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local function chunk_hl(row0, txt)
    local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
    for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
      if c[1] == txt then
        return c[2]
      end
    end
  end
  local function chk(d, g, e)
    if g == e then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  ' .. d .. '  got ' .. tostring(g)
    end
  end
  -- a plain pointer's caret + its const take the pointee's type color (Foo ->
  -- DansInlayType); smart-ptr carets keep their ownership colors below.
  chk('raw caret type-colored', chunk_hl(2, '^'), 'DansInlayType')
  chk('unique caret mut', chunk_hl(3, '^'), 'DansMarkerMut')
  chk('shared caret cpy', chunk_hl(4, '^'), 'DansMarkerCpy')
  chk('const ptr type-colored', chunk_hl(5, 'const '), 'DansInlayType')
  chk('vulkan caret orange', chunk_hl(7, '^'), 'DansVulkan')
  chk('deleter caret mut', chunk_hl(6, '^'), 'DansMarkerMut')
  chk('deleter tilde mut', chunk_hl(6, '~'), 'DansMarkerMut')
end

-- ===================== template param name color =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    '// x', -- cursor parks here so the template line renders
    'template <typename V, usize N>',
    'class Span {};',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local ans = vim.api.nvim_get_namespaces()['ds_cpp_aliases']
  local line = 'template <typename V, usize N>'
  local function hl_at(text)
    local col = line:find(text, 1, true) - 1
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ans, { 1, col }, { 1, col + #text }, { details = true })) do
      if m[4].hl_group then
        return m[4].hl_group
      end
    end
  end
  local okp, vhl = pcall(hl_at, 'V')
  local okp2, nhl = pcall(hl_at, ' N') -- the N param name
  if okp and vhl == 'DansConcept' then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  template param V is concept-colored  got ' .. tostring(vhl)
  end
  if okp2 and nhl == 'DansConcept' then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  template param N is concept-colored  got ' .. tostring(nhl)
  end
end

-- ===================== type qualifier not grayed as namespace =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'struct S', '{',
    '    ApiVersion v{ApiVersion::vulkan()};',
    '};',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { 2, 0 }, { 2, -1 }, { details = true })
  local grayed = false
  for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
    if c[1]:find('ApiVersion', 1, true) and c[2] == 'DansNamespace' then
      grayed = true
    end
  end
  if not grayed then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  CamelCase Type:: qualifier grayed as a namespace'
  end
end

-- ===================== string type color =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'struct S', '{',
    '    std::string name{};',
    '    std::string& ref;',
    '};',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local function chunk_hl(row0, txt)
    local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
    for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
      if c[1] == txt then
        return c[2]
      end
    end
  end
  local function chk2(d, g, e)
    if g == e then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  ' .. d .. '  got ' .. tostring(g)
    end
  end
  chk2('std::string type green', chunk_hl(2, 'string'), 'DansString')
  chk2('std::string& ref green', chunk_hl(3, 'string&'), 'DansString')
  local found = false
  for _, m in ipairs(vim.fn.getmatches()) do
    if m.group == 'DansString' and tostring(m.pattern):find('std::string', 1, true) then
      found = true
    end
  end
  chk2('std::string raw matchadd', found, true)
end

-- ===================== fold levels (Expects / Ensures blocks) =====================
do
  local fl = require('custom.dans_frontend_cpp.fold').compute_fold_levels
  local levels = fl({
    'def f() -> void', '{',
    '    {  // Expects', '        assert(a > 0);', '    }',
    '    do_work();',
    '    {  // Ensures', '        assert(b);', '    }',
    '}',
  })
  local exp = { '0', '0', '>1', '1', '<1', '0', '>1', '1', '<1', '0' }
  local ok = true
  for i = 1, #exp do
    if levels[i] ~= exp[i] then
      ok = false
    end
  end
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  fold levels: ' .. table.concat(levels, ',')
  end
end

-- static_assert runs (2+ contiguous) fold; a lone one doesn't; `{ // Asserts }`
-- folds like a contract block.
do
  local fl = require('custom.dans_frontend_cpp.fold').compute_fold_levels
  local levels = fl({
    'static_assert(a);', 'static_assert(b);',
    'do_work();',
    'static_assert(lonely);',
    '{  // Asserts', '    assert(x);', '}',
  })
  local exp = { '>1', '<1', '0', '0', '>1', '1', '<1' }
  local ok = true
  for i = 1, #exp do
    if levels[i] ~= exp[i] then
      ok = false
    end
  end
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  static_assert fold: ' .. table.concat(levels, ',')
  end
end

-- ===================== golden regression (real dans-vk fixtures) =====================
-- Render frozen first-party files end to end and diff against committed snapshots.
-- Regenerate intentionally with tests/golden/update.lua, then review the diff.
do
  local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
  local ok, R = pcall(dofile, here .. 'golden/render.lua')
  if not ok then
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  golden: render.lua failed to load: ' .. tostring(R)
  else
    local gdir = here .. 'golden/'
    for _, name in ipairs(vim.fn.readdir(gdir .. 'fixtures')) do
      local got = R.render_file(gdir .. 'fixtures/' .. name)
      local ef = io.open(gdir .. 'expected/' .. name .. '.txt', 'r')
      if not ef then
        fail = fail + 1
        fails[#fails + 1] = 'FAIL  golden ' .. name .. ': no expected snapshot (run update.lua)'
      else
        local exp_src = ef:read('*a'):gsub('\r\n', '\n'):gsub('\r', '\n')
        ef:close()
        local exp = vim.split(exp_src, '\n', { plain = true })
        if exp[#exp] == '' then
          exp[#exp] = nil
        end
        local bad
        for i = 1, math.max(#got, #exp) do
          if got[i] ~= exp[i] then
            bad = i
            break
          end
        end
        if bad then
          fail = fail + 1
          fails[#fails + 1] = string.format('FAIL  golden %s:%d\n        exp: %s\n        got: %s', name, bad, tostring(exp[bad]), tostring(got[bad]))
        else
          pass = pass + 1
        end
      end
    end
  end
end

-- ===================== module toggles (:DansFrontend <module>) =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'auto gp() -> int*;', -- trailing return remains owned by pointer (`*` -> `^`)
    'void fn()',
    '{',
    '    int x{7};', -- overlaid by the view
    '}',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- cursor off both decorated lines
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  vim.cmd 'doautocmd CursorMoved'

  local function count(nsname)
    local id = vim.api.nvim_get_namespaces()[nsname]
    return id and #vim.api.nvim_buf_get_extmarks(b, id, 0, -1, {}) or 0
  end
  local function chk(desc, cond)
    if cond then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  toggle: ' .. desc
    end
  end

  chk('view on by default', count 'ds_frontend_view' > 0)
  chk('pointer on by default', count 'ds_cpp_pointer' > 0)
  vim.cmd 'DansFrontend pointer'
  chk('pointer off clears its marks', count 'ds_cpp_pointer' == 0)
  chk('toggling pointer leaves view alone', count 'ds_frontend_view' > 0)
  vim.cmd 'DansFrontend pointer'
  chk('pointer back on', count 'ds_cpp_pointer' > 0)
  vim.cmd 'DansFrontend view'
  chk('view off clears its overlay', count 'ds_frontend_view' == 0)
  vim.cmd 'DansFrontend view'
  chk('view back on', count 'ds_frontend_view' > 0)
end

-- ===================== report =====================
local report = { string.format('frontend_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
