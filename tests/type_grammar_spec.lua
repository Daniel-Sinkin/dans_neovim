-- Exhaustive smart/optional type grammar regression. The matrix is deliberately
-- guideline-shaped: one declaration per line, brace initialization, trailing
-- returns, multiline constructor parameters, and descriptive snake_case names.

local H = dofile 'tests/support/frontend_harness.lua'
local P = require 'custom.dans_frontend_cpp.parse'
local R = require 'custom.dans_frontend_cpp.render'

local pass, fail, failures = 0, 0, {}
local function check(description, condition, detail)
  if condition then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = 'FAIL  ' .. description .. (detail and ('\n      ' .. detail) or '')
  end
end

local function eq(description, actual, expected)
  check(description, actual == expected, string.format('expected: %s\n      actual:   %s', expected, actual))
end

local grammar_cases = {
  { 'unique', 'std::unique_ptr<T>', 'T^' },
  { 'shared', 'std::shared_ptr<T>', 'T^' },
  { 'weak', 'std::weak_ptr<T>', 'T^?' },
  { 'optional', 'std::optional<T>', 'T?' },
  { 'expected', 'std::expected<T, E>', 'T?E' },
  { 'custom deleter', 'std::unique_ptr<T, Del>', 'T^, Del~' },
  { 'nested deleter comma', 'std::unique_ptr<std::pair<A, B>, Del<std::pair<C, D>>>', 'pair<A, B>^, Del<pair<C, D>>~' },
  { 'const pointee', 'std::unique_ptr<const T>', 'const T^' },
  { 'const owner reference', 'const std::unique_ptr<T>&', 'const T^&' },
  { 'mutable owner reference', 'std::unique_ptr<T>&', 'T^&' },
  { 'owner pointer', 'std::unique_ptr<T>*', 'T^^' },
  { 'weak reference', 'std::weak_ptr<T>&', 'T^?&' },
  { 'unique optional', 'std::unique_ptr<std::optional<T>>', 'T?^' },
  { 'optional unique', 'std::optional<std::unique_ptr<T>>', '(T^)?' },
  { 'shared optional', 'std::shared_ptr<std::optional<T>>', 'T?^' },
  { 'optional shared', 'std::optional<std::shared_ptr<T>>', '(T^)?' },
  { 'weak optional', 'std::weak_ptr<std::optional<T>>', 'T?^?' },
  { 'optional weak', 'std::optional<std::weak_ptr<T>>', '(T^?)?' },
  { 'expected unique', 'std::expected<std::unique_ptr<T>, E>', 'T^?E' },
  { 'expected optional', 'std::expected<std::optional<T>, E>', '(T?)?E' },
  { 'expected weak', 'std::expected<std::weak_ptr<T>, E>', '(T^?)?E' },
  { 'optional expected', 'std::optional<std::expected<T, E>>', '(T?E)?' },
  { 'unique expected', 'std::unique_ptr<std::expected<T, E>>', '(T?E)^' },
  { 'weak expected', 'std::weak_ptr<std::expected<T, E>>', '(T?E)^?' },
  { 'expected optional error', 'std::expected<T, std::optional<E>>', 'T?(E?)' },
  { 'array unique', 'std::array<std::unique_ptr<T>, 4>', '[4]T^' },
  { 'array weak', 'std::array<std::weak_ptr<T>, 4>', '[4]T^?' },
  { 'vector unique', 'std::vector<std::unique_ptr<T>>', 'vector<T^>' },
  { 'vector expected', 'std::vector<std::expected<T, E>>', 'vector<T?E>' },
  { 'unique array', 'std::unique_ptr<std::array<T, 3>>', '([3]T)^' },
  { 'array optional', 'std::array<std::optional<T>, 4>', '[4]T?' },
  { 'optional array', 'std::optional<std::array<T, 4>>', '([4]T)?' },
  { 'pointer to optional', 'std::optional<T>*', 'T?^' },
  { 'optional pointer', 'std::optional<T*>', '(T^)?' },
  { 'optional vector', 'std::optional<std::vector<T>>', 'vector<T>?' },
  { 'nested array', 'std::array<std::array<std::optional<T>, 2>, 3>', '[3][2]T?' },
  { 'cstring nesting', 'std::vector<const char*>', 'vector<CString>' },
  { 'fixed width nesting', 'std::expected<std::uint32_t, std::int64_t>', 'u32?i64' },
  { 'exact mystd namespace', 'mystd::optional<T>', 'mystd::optional<T>' },
  { 'exact other namespace', 'foo::optional<T>', 'foo::optional<T>' },
  { 'exact longer identifier', 'my_optional<T>', 'my_optional<T>' },
  { 'exact smart identifier', 'myunique_ptr<T>', 'myunique_ptr<T>' },
  { 'unknown container recurses', 'Box<std::unique_ptr<T>, foo::optional<E>>', 'Box<T^, foo::optional<E>>' },
}

for _, case in ipairs(grammar_cases) do
  eq('grammar: ' .. case[1], P.strip_type(case[2]), case[3])
end

-- Every pair of semantic wrappers is represented in the generated source
-- corpus. Explicit expected spellings above pin the ambiguous/grouped cases;
-- this loop guarantees additions cannot accidentally reduce the 5x5 coverage.
local wrappers = {
  unique = function(inner) return 'std::unique_ptr<' .. inner .. '>' end,
  shared = function(inner) return 'std::shared_ptr<' .. inner .. '>' end,
  weak = function(inner) return 'std::weak_ptr<' .. inner .. '>' end,
  optional = function(inner) return 'std::optional<' .. inner .. '>' end,
  expected = function(inner) return 'std::expected<' .. inner .. ', Error>' end,
}
local generated = {}
for outer_name, outer in pairs(wrappers) do
  for inner_name, inner in pairs(wrappers) do
    generated[#generated + 1] = {
      name = outer_name .. '_' .. inner_name,
      source = outer(inner('Widget')),
    }
  end
end
eq('generated wrapper-pair matrix size', #generated, 25)
for _, case in ipairs(generated) do
  local shown = P.strip_type(case.source)
  check('generated wrapper pair is compact: ' .. case.name, not shown:find('_ptr', 1, true), shown)
  check('generated wrapper pair removes optional/expected words: ' .. case.name, not shown:find('optional', 1, true) and not shown:find('expected', 1, true), shown)
end

-- Preserve the large generated validation pass as an actual rendered corpus,
-- not a disposable log. Each wrapper pair appears as a brace-initialized
-- declaration, trailing return, parameter, array element, and container value.
-- These shapes follow the owner's C++ guide (one declaration per line,
-- descriptive snake_case names, braces, and trailing returns).
local corpus_entries = {}
local function corpus_line(label, source)
  corpus_entries[#corpus_entries + 1] = { label = label, source = source }
end
for index, case in ipairs(generated) do
  local stem = string.format('grammar_case_%02d', index)
  corpus_line(stem .. ' declaration', case.source .. ' ' .. stem .. '_value{};')
  corpus_line(stem .. ' return', 'auto make_' .. stem .. '() -> ' .. case.source .. ';')
  corpus_line(stem .. ' parameter', 'auto consume_' .. stem .. '(' .. case.source .. ' value) -> void;')
  corpus_line(stem .. ' array', 'std::array<' .. case.source .. ', 3> ' .. stem .. '_items{};')
  corpus_line(stem .. ' container', 'std::vector<' .. case.source .. '> ' .. stem .. '_values{};')
end
eq('generated real-render corpus size', #corpus_entries, 125)
local page_size = 30
for page_start = 1, #corpus_entries, page_size do
  local page_lines = { '// cursor parking row' }
  local page_end = math.min(page_start + page_size - 1, #corpus_entries)
  for index = page_start, page_end do
    page_lines[#page_lines + 1] = corpus_entries[index].source
  end
  local corpus = H.open { lines = page_lines, cursor = 1 }
  eq('generated corpus page preserves row count', vim.api.nvim_buf_line_count(corpus.buf), #page_lines)
  check('generated corpus page preserves every source byte', corpus:assert_source_unchanged())
  for index = page_start, page_end do
    local item = corpus_entries[index]
    local shown = corpus:display(index - page_start + 2)
    check(
      'generated corpus removes wrapper words: ' .. item.label,
      not shown:find('unique_ptr', 1, true)
        and not shown:find('shared_ptr', 1, true)
        and not shown:find('weak_ptr', 1, true)
        and not shown:find('optional', 1, true)
        and not shown:find('expected', 1, true),
      shown
    )
    check(
      'generated corpus has no legacy smart aliases: ' .. item.label,
      not shown:find('$up', 1, true) and not shown:find('$sp', 1, true),
      shown
    )
  end
end

-- Marker roles remain independent even after recursive composition. In
-- particular, a CUDA value arm keeps CUDA provenance while Error returns to the
-- ordinary type color instead of inheriting seafoam from the first arm.
local function chunks_for(source, profile)
  local session = H.open {
    lines = { '// park' },
    style_profile = profile,
  }
  return R.type_chunks(source, session.buf)
end

local function has_chunk(chunks, text, highlight)
  for _, chunk in ipairs(chunks) do
    if chunk[1] == text and chunk[2] == highlight then
      return true
    end
  end
  return false
end

check('unique caret owns mutation color', has_chunk(chunks_for('std::unique_ptr<T>'), '^', 'DansMarkerMut'))
check('shared caret owns copy color', has_chunk(chunks_for('std::shared_ptr<T>'), '^', 'DansMarkerCpy'))
local weak_chunks = chunks_for('std::weak_ptr<T>')
check('weak caret is non-owning gray', has_chunk(weak_chunks, '^', 'DansConst'))
check('weak expiration marker uses selected gold', has_chunk(weak_chunks, '?', 'DansOptionalGold'))
local expected_cuda = chunks_for('std::expected<cuDoubleComplex, Error>')
check('expected CUDA value keeps CUDA color', has_chunk(expected_cuda, 'cf64', 'DansCUDA'))
check('expected error arm has independent type color', has_chunk(expected_cuda, 'Error', 'DansInlayType'))
check('expected separator uses selected gold', has_chunk(expected_cuda, '?', 'DansOptionalGold'))

-- Real rendering sites: the user-reported constructor, members, returns,
-- copy-initialization, exact namespace negatives, and a trailing block comment.
local constructor_source = {
  '// cursor parking row',
  'struct ctx',
  '{',
  '    ctx(',
  '        QnpepsConfig config,',
  '        cudaStream_t stream_handle,',
  '        bool own_stream,',
  '        std::unique_ptr<Linalg> linalg,',
  '        std::shared_ptr<State> shared,',
  '        std::weak_ptr<Cache> weak,',
  '        std::optional<Tag> maybe,',
  '        std::expected<Value, Error> result',
  '    );',
  '',
  '    std::array<std::unique_ptr<Widget>, 2> owners{};',
  '    std::optional<std::unique_ptr<Widget>> maybe_owner{};',
  '    std::unique_ptr<std::optional<Widget>> owner_maybe{};',
  '};',
  'auto make() -> std::expected<std::optional<Widget>, Error>;',
  'auto observe() -> std::weak_ptr<Widget>;',
  'auto exact_a() -> mystd::optional<Widget>;',
  'auto exact_b() -> foo::optional<Widget>;',
  'auto values() -> void',
  '{',
  '    std::optional<Widget> empty = std::nullopt;',
  '    auto unrelated = custom::nullopt;',
  '    consume(); /* std::nullopt */',
  '    auto global_empty = ::std::nullopt;',
  '    auto foreign_empty = foo::std::nullopt;',
  '}',
}
local session = H.open { lines = constructor_source, cursor = 1 }
local expected_parameters = {
  [5] = '        config       : Config,',
  [6] = '        stream_handle: Stream,',
  [7] = '        own_stream   : bool,',
  [8] = '        linalg       : Linalg^,',
  [9] = '        shared       : State^,',
  [10] = '        weak         : Cache^?,',
  [11] = '        maybe        : Tag?,',
  [12] = '        result       : Value?Error',
}
for line_number, expected in pairs(expected_parameters) do
  eq('constructor parameter line ' .. line_number, session:display(line_number), expected)
end
check('constructor has no legacy unique alias', not session:display(8):find('$up', 1, true), session:display(8))
check('constructor has no legacy shared alias', not session:display(9):find('$sp', 1, true), session:display(9))
eq('nested array owner member', session:display(15), '    owners     : [2]Widget^;')
eq('optional owner member', session:display(16), '    maybe_owner: (Widget^)?;')
eq('owner of optional member', session:display(17), '    owner_maybe: Widget?^;')
eq('nested expected return groups optional arm', session:display(19), 'def make() -> (Widget?)?Error;')
eq('weak return is compact', session:display(20), 'def observe() -> Widget^?;')
check('mystd optional remains exact', session:display(21):find('mystd::optional<Widget>', 1, true) ~= nil, session:display(21))
check('foreign optional remains exact', session:display(22):find('foo::optional<Widget>', 1, true) ~= nil, session:display(22))
eq('copy-init optional uses declaration grammar and readable sentinel', session:display(25), '    mut empty: Widget? = nullopt;')
check('unrelated nullopt remains a word', session:display(26):find('custom::nullopt', 1, true) ~= nil, session:display(26))
eq('nullopt in trailing block comment remains source text', session:display(27), constructor_source[27])
check('global standard nullopt retains word', session:display(28):find('nullopt', 1, true) ~= nil, session:display(28))
check(
  'nested foreign std namespace remains a word',
  session:display(29):find('nullopt', 1, true) ~= nil and not session:display(29):find('∅', 1, true),
  session:display(29)
)

-- All rows in a Visual range reveal source, not merely the anchor. Escape must
-- restore every row except the current cursor row, which intentionally remains
-- raw until the cursor leaves it.
session:select('line', 8, 12)
for line_number = 8, 12 do
  eq('Visual reveals constructor row ' .. line_number, session:display(line_number), constructor_source[line_number])
end
session:escape()
for line_number = 8, 11 do
  eq('Visual escape restores constructor row ' .. line_number, session:display(line_number), expected_parameters[line_number])
end
eq('Visual escape keeps cursor row raw', session:display(12), constructor_source[12])
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd 'doautocmd CursorMoved'
vim.wait(30)
eq('leaving selection endpoint restores its spelling', session:display(12), expected_parameters[12])
check('constructor interaction preserves every source byte', session:assert_source_unchanged())
eq('constructor interaction preserves row count', vim.api.nvim_buf_line_count(session.buf), #constructor_source)

-- The pointer module depends on whether aliases owns whole parameter ranges.
-- Cycling the compatibility toggles must never leave doubled markers or legacy
-- aliases, and turning aliases back on restores the original display.
vim.api.nvim_set_current_buf(session.buf)
vim.cmd 'DansFrontend aliases'
local aliases_off_unique = session:display(8)
local aliases_off_optional = session:display(11)
check('aliases-off unique remains one compact type', aliases_off_unique:find('Linalg%^') ~= nil and not aliases_off_unique:find('unique_ptr', 1, true), aliases_off_unique)
check('aliases-off optional has one marker', select(2, aliases_off_optional:gsub('%?', '')) == 1, aliases_off_optional)
vim.cmd 'DansFrontend aliases'
eq('aliases-on unique restores parameter flip', session:display(8), expected_parameters[8])
eq('aliases-on optional restores one parameter marker', session:display(11), expected_parameters[11])

-- TextChanged must transfer the same row cleanly between ownership kinds, then
-- return byte-for-byte to the original constructor without stale decorations.
vim.api.nvim_buf_set_lines(session.buf, 7, 8, false, { '        std::weak_ptr<Linalg> linalg,' })
vim.cmd 'doautocmd TextChanged'
vim.wait(30)
eq('edit cycle unique to weak', session:display(8), '        linalg       : Linalg^?,')
vim.api.nvim_buf_set_lines(session.buf, 7, 8, false, { constructor_source[8] })
vim.cmd 'doautocmd TextChanged'
vim.wait(30)
eq('edit cycle weak to unique', session:display(8), expected_parameters[8])
check('edit round trip restores every source byte', session:assert_source_unchanged())
eq('edit round trip preserves row count', vim.api.nvim_buf_line_count(session.buf), #constructor_source)

local report = { string.format('type_grammar_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
