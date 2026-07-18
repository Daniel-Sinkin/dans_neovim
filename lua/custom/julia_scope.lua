-- Scope highlighting + block text objects for Julia.
-- Mirrors the C/C++ enclosing-brace plugin: Julia has no `{ }` scopes, so the
-- "scope" is the keyword..end construct (function/if/struct/module/let/...).
--
-- Block matching counts openers vs `end`, not indentation: a `module` body is
-- conventionally unindented, so indentation cannot tell a module's `end` apart
-- from a nested function's `end`. Opener keywords are detected at bracket
-- depth 0 anywhere on a statement line (not just the first token), so a block
-- keyword used as an expression - `x = let ... end` - still counts; `a[end]`
-- indexing and `[expr for x in ...]` comprehensions sit at depth > 0 and stay
-- harmless.
--
-- Highlights the enclosing opener keyword and its matching `end`, plus the
-- bracket delimiters within that scope. For `if`, only the keyword of the
-- branch the cursor sits in is highlighted (`if`/`elseif`/`else`) with `end`.
-- `ib`/`ab` text objects select that scope - except when the cursor is inside
-- `(...)`, where they select the paren contents instead (like `ib` in C/C++).

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_julia_scope'

local function set_highlights()
  -- current scope keyword..end
  vim.api.nvim_set_hl(0, 'JuliaScopeKeyword', { link = 'MatchParen' })
  -- parent scope keyword..end - the cyan also used for inner delimiters, so a
  -- nested current/parent pair reads apart
  vim.api.nvim_set_hl(0, 'JuliaParentScope', { link = 'DiagnosticInfo' })
  vim.api.nvim_set_hl(0, 'JuliaInnerDelimiter', { link = 'DiagnosticInfo' })
  -- innermost enclosing () or {} - painted constantly so the pair the cursor
  -- is in (and `ib`/`ab` will select) is visible without moving onto a brace
  vim.api.nvim_set_hl(0, 'JuliaEnclosingBracket', { fg = '#ff9e64' })
end

-- Captures that mark regions for spell/conceal rather than coloring.
local SKIP_CAPTURE = { spell = true, nospell = true, conceal = true, none = true }

-- Flatten Julia treesitter highlighting to monochrome, keeping comments and
-- docstrings (`"""..."""`) gray (mirrors the aggressive C/C++ monochrome
-- treatment). Scope and bracket coloring come from extmarks, which draw on
-- top and are unaffected.
local function set_mono()
  local ok, q = pcall(vim.treesitter.query.get, 'julia', 'highlights')
  if not ok or not q or not q.captures then
    return
  end
  for _, name in ipairs(q.captures) do
    if not SKIP_CAPTURE[name] and name:sub(1, 1) ~= '_' then
      local hl = '@' .. name .. '.julia'
      if name == 'comment' or name:match '^comment%.' or name == 'string.documentation' then
        vim.api.nvim_set_hl(0, hl, { link = 'Comment' })
      else
        vim.api.nvim_set_hl(0, hl, { link = 'Normal' })
      end
    end
  end
end

-- Reserved keywords that open a block terminated by `end`. All are reserved
-- words (never identifiers), so detecting them anywhere at bracket depth 0 is
-- safe. `mutable struct` is handled separately (`mutable` is NOT reserved, so
-- it must not be scanned for - only matched as the first token before
-- `struct`).
local OPENER_WORDS = {
  ['function'] = true,
  ['macro'] = true,
  ['if'] = true,
  ['for'] = true,
  ['while'] = true,
  ['let'] = true,
  ['begin'] = true,
  ['quote'] = true,
  ['struct'] = true,
  ['module'] = true,
  ['baremodule'] = true,
  ['try'] = true,
  ['do'] = true,
}

local MAX_SCAN = 5000
local MAX_FILE = 20000

---Scan a line's code (comment stripped) starting at bracket depth
---`start_depth`, tracking brackets and "..." strings. Returns: whether a bare
---`end` word sits at statement level (depth 0); the first opener keyword found
---at depth 0 and its 1-indexed byte position (or nil); the bracket depth at
---line end.
local function scan_code(line, start_depth)
  local hash = line:find('#', 1, true)
  if hash then
    line = line:sub(1, hash - 1)
  end
  local depth = start_depth
  local in_str = false
  local i, n = 1, #line
  local bare_end = false
  local open_kw, open_pos = nil, nil
  while i <= n do
    local c = line:sub(i, i)
    if in_str then
      if c == '\\' then
        i = i + 1
      elseif c == '"' then
        in_str = false
      end
      i = i + 1
    elseif c == '"' then
      in_str = true
      i = i + 1
    elseif c == '(' or c == '[' or c == '{' then
      depth = depth + 1
      i = i + 1
    elseif c == ')' or c == ']' or c == '}' then
      depth = depth > 0 and depth - 1 or 0
      i = i + 1
    elseif c:match '[%a_]' then
      local s = i
      while i <= n and line:sub(i, i):match '[%w_!]' do
        i = i + 1
      end
      if depth == 0 then
        local w = line:sub(s, i - 1)
        if w == 'end' then
          bare_end = true
        elseif not open_kw and OPENER_WORDS[w] and line:sub(s - 1, s - 1) ~= ':' then
          -- the `:` guard skips `:if`, `:let`, ... used as Symbols
          open_kw, open_pos = w, s
        end
      end
    else
      i = i + 1
    end
  end
  return bare_end, open_kw, open_pos, depth
end

---Precompute per (1-indexed) line: indent, first token, whether the line
---starts inside a triple-quoted string, and its block role:
---  kind = 'open'   line opens a block (depth +1)
---         'close'  line is a bare `end` (depth -1)
---         'single' opens and closes on the same line (depth 0, ignored)
---         'plain'  no effect
---For 'open' lines, `okw`/`ocol` give the keyword to highlight and its column.
local function scan_lines(lines)
  local info = {}
  local in_tstring = false
  local depth = 0 -- cumulative bracket depth carried across lines
  for idx, line in ipairs(lines) do
    local started_in_string = in_tstring
    local started_in_bracket = depth > 0

    local quotes = select(2, line:gsub('"""', ''))
    if quotes % 2 == 1 then
      in_tstring = not in_tstring
    end

    if started_in_string then
      -- a line that starts inside a triple string is not code
      info[idx] = { str = true, kind = 'plain', indent = 0 }
    else
      local bare_end, open_kw, open_pos, new_depth = scan_code(line, depth)
      depth = new_depth
      local indent = #(line:match '^%s*' or '')

      if started_in_bracket then
        -- a continuation line inside a multi-line bracketed expression (e.g.
        -- the `for` of a `[expr for x in ...]` comprehension): its tokens are
        -- not statement-level keywords, so do not treat them as block words.
        info[idx] = { str = false, kind = 'plain', indent = indent }
      else
        local first = line:match '^%s*([%a_][%w_]*)'
        local second = first and line:match '^%s*[%a_][%w_]*%s+([%a_][%w_]*)' or nil

        local kind, okw, ocol = 'plain', nil, nil
        if first == 'end' then
          kind = 'close'
        elseif first == 'mutable' and second == 'struct' then
          -- `mutable` is not reserved; only the first-token form is a block
          kind = bare_end and 'single' or 'open'
          okw, ocol = 'mutable', indent
        elseif open_kw then
          kind = bare_end and 'single' or 'open'
          okw, ocol = open_kw, open_pos - 1
        end

        info[idx] = {
          str = false,
          indent = indent,
          first = first,
          kind = kind,
          okw = okw,
          ocol = ocol,
        }
      end
    end
  end
  return info
end

---Matching `end` of the opener at row `r`: count nested openers vs `end`.
local function match_end(info, r)
  local depth = 1
  local last = math.min(#info, r + MAX_SCAN)
  for k = r + 1, last do
    local li = info[k]
    if not li.str then
      if li.kind == 'open' then
        depth = depth + 1
      elseif li.kind == 'close' then
        depth = depth - 1
        if depth == 0 then
          return k
        end
      end
    end
  end
  return nil
end

---Innermost opener..end block containing the cursor (1-indexed rows).
---`module`/`baremodule` are still counted (so the `end` tally stays balanced)
---but never returned as a scope: highlighting a whole module is not useful.
local function find_enclosing(info, cur)
  local stop = math.max(1, cur - MAX_SCAN)
  for r = cur, stop, -1 do
    local li = info[r]
    if li and li.kind == 'open' then
      local e = match_end(info, r)
      if e and e >= cur and li.okw ~= 'module' and li.okw ~= 'baremodule' then
        return r, e, li
      end
    end
  end
  return nil
end

---The scope that immediately encloses the scope opened at row `r` / closed at
---`e` - i.e. the parent. Same module/baremodule skip as find_enclosing.
local function find_parent(info, r, e)
  local stop = math.max(1, r - MAX_SCAN)
  for pr = r - 1, stop, -1 do
    local li = info[pr]
    if li and li.kind == 'open' then
      local pe = match_end(info, pr)
      if pe and pe >= e and li.okw ~= 'module' and li.okw ~= 'baremodule' then
        return pr, pe, li
      end
    end
  end
  return nil
end

---For an `if` block, the bounds of the section (if / elseif / else) that
---contains the cursor. `elseif`/`else` count only when they sit directly
---inside this `if`. Returns (start_row, last_line, is_last):
---  start_row - the row of the section's opening keyword (if / elseif / else)
---  last_line - the last line of the section (the line before the next
---              branch keyword, or `e` for the last section)
---  is_last   - true if this is the last section (its last_line == e)
local function if_section_bounds(info, r, e, cur)
  local start_row = r
  local last_line = e
  local is_last = true
  local depth = 1
  for k = r + 1, e - 1 do
    local li = info[k]
    if not li.str then
      if li.kind == 'open' then
        depth = depth + 1
      elseif li.kind == 'close' then
        depth = depth - 1
      elseif depth == 1 and (li.first == 'elseif' or li.first == 'else') then
        if k <= cur then
          start_row = k
        else
          last_line = k - 1
          is_last = false
          break
        end
      end
    end
  end
  return start_row, last_line, is_last
end

local function hl_keyword(bufnr, row, col, end_col, group)
  vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, col, {
    end_col = end_col,
    hl_group = group,
    priority = 200,
  })
end

---All branch keywords directly inside the `if` block at rows `r`..`e`.
---Returns a list of { row = N, kw = "if"|"elseif"|"else", col = N }.
local function if_all_branches(info, r, e)
  local out = { { row = r, kw = 'if', col = info[r].ocol } }
  local depth = 1
  for k = r + 1, e - 1 do
    local li = info[k]
    if not li.str then
      if li.kind == 'open' then
        depth = depth + 1
      elseif li.kind == 'close' then
        depth = depth - 1
      elseif depth == 1 and (li.first == 'elseif' or li.first == 'else') then
        out[#out + 1] = { row = k, kw = li.first, col = li.indent }
      end
    end
  end
  return out
end

---Highlight a scope's opener keyword and its matching `end` in `group`. For an
---`if`, every branch keyword (`if` / `elseif` / `else`) is highlighted so the
---branches the cursor is *not* in still get colored as part of the same scope.
local function hl_scope(bufnr, info, lines, r, e, li, group)
  if li.okw == 'if' then
    for _, b in ipairs(if_all_branches(info, r, e)) do
      hl_keyword(bufnr, b.row, b.col, b.col + #b.kw, group)
    end
  elseif li.okw == 'mutable' then
    local ss = lines[r]:find('struct', 1, true) or (li.ocol + 1)
    hl_keyword(bufnr, r, li.ocol, ss - 1 + 6, group)
  else
    hl_keyword(bufnr, r, li.ocol, li.ocol + #li.okw, group)
  end
  hl_keyword(bufnr, e, info[e].indent, info[e].indent + 3, group)
end

local CLOSE_OF = { ['('] = ')', ['{'] = '}', ['['] = ']' }
local OPEN_OF = { [')'] = '(', ['}'] = '{', [']'] = '[' }

---Innermost `()`, `{}` or `[]` pair enclosing the cursor (or at the cursor).
---Returns (open_pos, close_pos), each {line, col} 1-indexed, or nil. Manual
---walk over buffer chars - avoids the Vim regex quirks `searchpairpos` hits
---on `{` and `[`, and treats all three bracket types uniformly.
local function enclosing_bracket()
  local bufnr = vim.api.nvim_get_current_buf()
  local cur_row, cur_col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Walk backward from the cursor (cursor position inclusive) to find the
  -- nearest unbalanced opener of any kind. Depth is tracked per bracket type.
  local depths = { ['('] = 0, ['{'] = 0, ['['] = 0 }
  local open_row, open_col, open_ch

  local row = cur_row
  local col = cur_col + 1 -- 1-indexed; the cursor's own column
  local lim_back = math.max(1, cur_row - MAX_SCAN)
  while row >= lim_back do
    local line = lines[row] or ''
    if col > #line then
      col = #line
    end
    while col >= 1 do
      local ch = line:sub(col, col)
      local close_for = OPEN_OF[ch]
      local open_for = CLOSE_OF[ch]
      if close_for then
        depths[close_for] = depths[close_for] + 1
      elseif open_for then
        if depths[ch] > 0 then
          depths[ch] = depths[ch] - 1
        else
          open_row, open_col, open_ch = row, col, ch
          break
        end
      end
      col = col - 1
    end
    if open_row then
      break
    end
    row = row - 1
    if row >= 1 then
      col = #(lines[row] or '')
    end
  end

  if not open_row then
    return nil
  end

  -- Forward search from just after the opener for the matching closer.
  local close_char = CLOSE_OF[open_ch]
  local depth = 1
  row = open_row
  col = open_col + 1
  local lim_fwd = math.min(#lines, cur_row + MAX_SCAN)
  while row <= lim_fwd do
    local line = lines[row] or ''
    while col <= #line do
      local ch = line:sub(col, col)
      if ch == open_ch then
        depth = depth + 1
      elseif ch == close_char then
        depth = depth - 1
        if depth == 0 then
          return { open_row, open_col }, { row, col }
        end
      end
      col = col + 1
    end
    row = row + 1
    col = 1
  end
  return nil
end

local function hl_enclosing_bracket(bufnr, pos)
  local row = pos[1] - 1
  if row < 0 or row >= vim.api.nvim_buf_line_count(bufnr) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1] or ''
  if pos[2] < 1 or pos[2] > #line then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, pos[2] - 1, {
    end_col = pos[2],
    hl_group = 'JuliaEnclosingBracket',
    priority = 250,
  })
end

local function update(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= 'julia' then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- Innermost enclosing () or {} pair: paint both braces orange. Done first
  -- so it applies even on huge files (where the scope work below bails out).
  -- enclosing_bracket() scans the *current* buffer (focused window). Skip if
  -- the debounced update is firing for a buffer that's no longer focused —
  -- otherwise positions from buffer Y get applied as extmarks on buffer X.
  if bufnr == vim.api.nvim_get_current_buf() then
    local bop, bcp = enclosing_bracket()
    if bop then
      hl_enclosing_bracket(bufnr, bop)
      hl_enclosing_bracket(bufnr, bcp)
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines > MAX_FILE then
    return
  end
  local info = scan_lines(lines)
  local cur = vim.api.nvim_win_get_cursor(0)[1]

  local r, e, li = find_enclosing(info, cur)
  if not r then
    return
  end

  -- Current scope: opener keyword + matching `end`.
  hl_scope(bufnr, info, lines, r, e, li, 'JuliaScopeKeyword')

  -- Parent scope, in the dimmer cyan, so two nested levels read apart.
  local pr, pe, pli = find_parent(info, r, e)
  if pr then
    hl_scope(bufnr, info, lines, pr, pe, pli, 'JuliaParentScope')
  end

  -- Bracket delimiters within the scope.
  if (e - r) <= 3000 then
    for k = r, e do
      if not info[k].str then
        local line = lines[k]
        for col = 1, #line do
          local ch = line:sub(col, col)
          if ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}' then
            vim.api.nvim_buf_set_extmark(bufnr, ns, k - 1, col - 1, {
              end_col = col,
              hl_group = 'JuliaInnerDelimiter',
              priority = 150,
            })
          end
        end
      end
    end
  end
end

-- Debounce update across rapid CursorMoved / TextChanged events so heavy
-- typing or scrolling doesn't pay a full rescan per keystroke. The scope
-- catches up ~50ms after the last event - below perception, still coalesces
-- bursts.
local DEBOUNCE_MS = 50
local pending_update = {}

local function schedule_update(bufnr)
  local t = pending_update[bufnr]
  if t then
    t:stop()
  else
    t = vim.uv.new_timer()
    pending_update[bufnr] = t
  end
  t:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      update(bufnr)
    end
  end))
end

local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

---`ib`/`ab` text object. Inside `(...)` it selects the paren contents
---(charwise), like `ib` in C/C++; otherwise it selects the enclosing Julia
---keyword scope (linewise).
function M.select_block(around)
  -- Innermost enclosing `()` or `{}` wins, mirroring C/C++ where `ib` is the
  -- nearest bracket pair.
  local op, cp = enclosing_bracket()
  if op then
    local sl, sc, el, ec
    if around then
      sl, sc, el, ec = op[1], op[2], cp[1], cp[2]
    else
      sl, sc, el, ec = op[1], op[2] + 1, cp[1], cp[2] - 1
      if sl > el or (sl == el and sc > ec) then
        -- empty () : select the parens themselves
        sl, sc, el, ec = op[1], op[2], cp[1], cp[2]
      end
    end
    if vim.fn.mode():match '[vV\22]' then
      vim.api.nvim_feedkeys(esc, 'nx', false)
    end
    vim.cmd(('normal! %dG%d|v%dG%d|'):format(sl, sc, el, ec))
    return
  end

  -- Otherwise: the enclosing keyword scope, selected linewise.
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines > MAX_FILE then
    return
  end
  local info = scan_lines(lines)
  local cur = vim.api.nvim_win_get_cursor(0)[1]

  local r, e, li = find_enclosing(info, cur)
  if not r then
    return
  end

  local sline, eline
  if li.okw == 'if' then
    -- target just the cursor's branch (if / elseif / else), not the whole
    -- if..end - matches what the scope highlight already shows.
    local sr, ll, is_last = if_section_bounds(info, r, e, cur)
    if around then
      sline, eline = sr, ll
    else
      sline, eline = sr + 1, is_last and ll - 1 or ll
      if sline > eline then
        sline, eline = sr, ll
      end
    end
  elseif around then
    sline, eline = r, e
  else
    sline, eline = r + 1, e - 1
    if sline > eline then
      sline, eline = r, e
    end
  end

  if vim.fn.mode():match '[vV\22]' then
    vim.api.nvim_feedkeys(esc, 'nx', false)
  end
  vim.cmd(('normal! %dGV%dG'):format(sline, eline))
end

function M.setup()
  set_highlights()
  set_mono()

  local group = vim.api.nvim_create_augroup('ds-julia-scope', { clear = true })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      -- Julia only. Without this guard the scheduler (timer stop/start churn) ran
      -- on every cursor move / scroll notch in *every* buffer (~8% of a C++ scroll
      -- in the profiler) before update() bailed on the non-julia filetype.
      if vim.bo[ev.buf].filetype == 'julia' then
        schedule_update(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      set_highlights()
      set_mono()
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'julia',
    callback = function(ev)
      set_mono()
      vim.keymap.set({ 'x', 'o' }, 'ib', function()
        M.select_block(false)
      end, { buffer = ev.buf, desc = 'inner Julia scope' })
      vim.keymap.set({ 'x', 'o' }, 'ab', function()
        M.select_block(true)
      end, { buffer = ev.buf, desc = 'around Julia scope' })
    end,
  })
end

return M
