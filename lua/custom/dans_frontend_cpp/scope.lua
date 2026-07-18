-- Scope highlighting + a unified bracket text object for C/C++/CUDA.
--
-- The "current scope" is the innermost delimiter pair of ANY kind -- `()`, `[]`
-- or `{}` -- that strictly encloses the cursor (or that the cursor sits on). Its
-- two delimiters are painted orange (DansScopeActive). The cursor's enclosing
-- scopes form a single linear chain outward (parent, grandparent, ...); the
-- nearest `depth` of them are painted blue (DansScopeParent). Siblings and inner
-- descendants are deliberately NOT colored -- coloring a sibling reproduces the
-- parent's inner set, which collapses the in-C vs in-A distinction that the chain
-- exists to show.
--
--   depth = 0   only the active pair (orange), no blue
--   depth = 1   + immediate parent (the default)
--   depth = N   + N ancestors up the chain
--
-- `ib`/`ab` are remapped to that innermost pair, dispatching to the matching
-- native text object (`i(`/`i[`/`i{`), so a yank/change/delete grabs exactly the
-- orange pair -- yib is always what the orange marks, regardless of bracket kind.
--
-- Scope is derived by bracket matching, not indentation: C's grammar nests
-- brackets rigidly, so the innermost unmatched open before the cursor (skipping
-- string / char / comment literals via treesitter) is the scope opener, and its
-- type-matching close is the scope end. The underlying buffer text is the ground
-- truth; this never reads the frontend overlay.
--
--   :DansScopeDepth [n]   set the ancestor (blue) depth; no arg prints it

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'
local ns = vim.api.nvim_create_namespace 'ds_cpp_scope'

local CPP_FT = { c = true, cpp = true, cuda = true }
local disabled = {}
local OPEN = { ['('] = true, ['['] = true, ['{'] = true }
local CLOSE = { [')'] = true, [']'] = true, ['}'] = true }
local MATCH = { ['('] = ')', ['['] = ']', ['{'] = '}' }
local INNER = { ['('] = 'i(', ['['] = 'i[', ['{'] = 'i{' }
local AROUND = { ['('] = 'a(', ['['] = 'a[', ['{'] = 'a{' }

-- Ancestor (blue) depth. 0 = active pair only; 1 = + immediate parent (default).
M.depth = (type(vim.g.dans_scope_depth) == 'number') and vim.g.dans_scope_depth or 1

-- Per-changedtick bracket index: for every row, the ascending {col, ch} list of
-- bracket characters OUTSIDE string/char/comment literals. Built in one pass
-- (a single treesitter query for the literal ranges + one line scan); every
-- chain walk after that is pure table traversal. This replaces the per-character
-- vu.in_literal calls (a treesitter node lookup each) that made a single cursor
-- move cost tens of ms on a large file -- the chain always reaches the
-- file-spanning namespace brace, so every j/k rescanned to EOF through them.
local LITERAL_QUERY = [[
  [(string_literal) (raw_string_literal) (char_literal) (comment) (system_lib_string)] @lit
]]
local index_cache = {} -- bufnr -> { tick, rows = { [row0] = { {col0, ch}, ... } } }

local function bracket_index(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = index_cache[bufnr]
  if c and c.tick == tick then
    return c.rows
  end
  -- literal spans per row; a multi-line literal covers its middle rows whole.
  local lit = {}
  pcall(function()
    local parser = vim.treesitter.get_parser(bufnr)
    local tree = parser:parse()[1]
    local q = vim.treesitter.query.parse(parser:lang(), LITERAL_QUERY)
    for _, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
      local sr, sc, er, ec = node:range()
      for r = sr, er do
        local t = lit[r]
        if not t then
          t = {}
          lit[r] = t
        end
        t[#t + 1] = { r == sr and sc or 0, r == er and ec or math.huge }
      end
    end
  end)
  local rows = {}
  for i, line in ipairs(vu.buf_lines(bufnr)) do
    local r = i - 1
    local lt = lit[r]
    local out
    local from = 1
    while true do
      local s = line:find('[%(%)%[%]{}]', from)
      if not s then
        break
      end
      local col = s - 1
      local in_lit = false
      if lt then
        for _, span in ipairs(lt) do
          if col >= span[1] and col < span[2] then
            in_lit = true
            break
          end
        end
      end
      if not in_lit then
        out = out or {}
        out[#out + 1] = { col, line:sub(s, s) }
      end
      from = s + 1
    end
    rows[r] = out
  end
  index_cache[bufnr] = { tick = tick, rows = rows }
  return rows
end

-- The indexed bracket char at (row, col), or nil -- nil also for a bracket
-- inside a literal (absent from the index), which matches the old in_literal
-- skip.
local function index_at(rows, row, col)
  local br = rows[row]
  if br then
    for i = 1, #br do
      local c = br[i][1]
      if c == col then
        return br[i][2]
      end
      if c > col then
        break
      end
    end
  end
  return nil
end

-- Nearest unmatched OPEN bracket strictly left of (fromr, fromc), i.e. the opener
-- that encloses the gap just before that position. All bracket kinds share one
-- counter (valid C nests cleanly). Returns r, c, char.
local function enclosing_open(rows, fromr, fromc)
  local skip = 0
  for r = fromr, 0, -1 do
    local br = rows[r]
    if br then
      for i = #br, 1, -1 do
        local col, ch = br[i][1], br[i][2]
        if r < fromr or col < fromc then
          if CLOSE[ch] then
            skip = skip + 1
          elseif skip > 0 then
            skip = skip - 1
          else
            return r, col, ch
          end
        end
      end
    end
  end
  return nil
end

-- Type-matching close for the open at (or_, oc). One shared counter: every open
-- deepens, every close unwinds, the depth-0 close is the match.
local function match_close(rows, bufnr, or_, oc)
  local depth = 0
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  for r = or_, last do
    local br = rows[r]
    if br then
      for i = 1, #br do
        local col, ch = br[i][1], br[i][2]
        if r > or_ or col >= oc then
          if OPEN[ch] then
            depth = depth + 1
          else
            depth = depth - 1
            if depth == 0 then
              return r, col, ch
            end
          end
        end
      end
    end
  end
  return nil
end

-- Matching open for a close at (cr, cc) -- the mirror of match_close, scanning back.
local function match_open(rows, cr, cc)
  local depth = 0
  for r = cr, 0, -1 do
    local br = rows[r]
    if br then
      for i = #br, 1, -1 do
        local col, ch = br[i][1], br[i][2]
        if r < cr or col <= cc then
          if CLOSE[ch] then
            depth = depth + 1
          else
            depth = depth - 1
            if depth == 0 then
              return r, col, ch
            end
          end
        end
      end
    end
  end
  return nil
end

-- Innermost pair enclosing (row, col). If the cursor sits on a (non-literal)
-- bracket, that bracket's pair wins (matching native ib/% feel); otherwise the
-- nearest enclosing open and its match. Returns { or_, oc, cr, cc, ch } or nil.
local function innermost_at(rows, bufnr, row, col)
  local cur = index_at(rows, row, col)
  local or_, oc, ch
  if cur and OPEN[cur] then
    or_, oc, ch = row, col, cur
  elseif cur and CLOSE[cur] then
    or_, oc, ch = match_open(rows, row, col)
  else
    or_, oc, ch = enclosing_open(rows, row, col)
  end
  if not or_ then
    return nil
  end
  local cr, cc = match_close(rows, bufnr, or_, oc)
  if not cr then
    return nil
  end
  return { or_ = or_, oc = oc, cr = cr, cc = cc, ch = ch }
end

-- The cursor's scope chain, innermost first: the active pair plus up to `want - 1`
-- ancestors. Each ancestor is the opener enclosing the previous opener.
local function pair_chain(rows, bufnr, row, col, want)
  local out = {}
  local p = innermost_at(rows, bufnr, row, col)
  while p do
    out[#out + 1] = p
    if #out >= want then
      break
    end
    local nor, noc, nch = enclosing_open(rows, p.or_, p.oc)
    if not nor then
      break
    end
    local ncr, ncc = match_close(rows, bufnr, nor, noc)
    if not ncr then
      break
    end
    p = { or_ = nor, oc = noc, cr = ncr, cc = ncc, ch = nch }
  end
  return out
end

-- Public: the innermost pair around (row, col) in `bufnr`, or nil. For tests and
-- the text-object dispatch.
function M.innermost(bufnr, row, col)
  return innermost_at(bracket_index(bufnr), bufnr, row, col)
end

-- Public: the scope chain (innermost first), capped at `want`. For tests.
function M.pair_chain(bufnr, row, col, want)
  return pair_chain(bracket_index(bufnr), bufnr, row, col, want or (M.depth + 1))
end

local function paint(bufnr, p, hl, prio)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, p.or_, p.oc, { end_col = p.oc + 1, hl_group = hl, priority = prio })
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, p.cr, p.cc, { end_col = p.cc + 1, hl_group = hl, priority = prio })
end

local function paint_one(bufnr, row, col, hl, prio)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, { end_col = col + 1, hl_group = hl, priority = prio })
end

-- Per-row marks the overlay recolors (raw col + hl), and last tick's marks so a
-- cursor move can diff and repaint only the rows whose coloring actually changed.
local row_marks_cache = {}
local prev_marks = {}

local function update(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  if not CPP_FT[vim.bo[bufnr].filetype] then
    return
  end
  if disabled[bufnr] then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  -- The index parses internally when stale, so the tree is fresh here.
  local rows = bracket_index(bufnr)

  -- The enclosing bracket chain, innermost out -- generous depth so we find the
  -- enclosing brace and its ancestor braces, not just the innermost pair.
  local chain = pair_chain(rows, bufnr, row, col, 64)
  local region = chain[1] -- innermost enclosing bracket of any kind
  local brace, brace_idx -- innermost enclosing { } scope
  for i, p in ipairs(chain) do
    if p.ch == '{' then
      brace, brace_idx = p, i
      break
    end
  end

  local marks = {}
  local orange = {} -- "row:col" of the orange delimiters, excluded from the blue sweep
  local function add_mark(r, c, hl)
    marks[r] = marks[r] or {}
    marks[r][#marks[r] + 1] = { col = c, hl = hl }
  end
  local function paint_pair(p, hl, prio)
    paint(bufnr, p, hl, prio)
    add_mark(p.or_, p.oc, hl)
    add_mark(p.cr, p.cc, hl)
  end
  local function mark_orange(p)
    paint_pair(p, 'DansScopeActive', 200)
    orange[p.or_ .. ':' .. p.oc] = true
    orange[p.cr .. ':' .. p.cc] = true
  end

  -- Orange: the enclosing brace scope is always active, and so is the paren/bracket
  -- region the cursor sits in (when that isn't the brace itself).
  if brace then
    mark_orange(brace)
  end
  if region and (not brace or region.or_ ~= brace.or_ or region.oc ~= brace.oc) then
    mark_orange(region)
  end

  -- Blue: every other delimiter inside the current brace scope, so its structure
  -- reads at a glance. Visible rows only -- scanning a whole large scope on each
  -- cursor move was the original cost.
  if brace then
    local vtop = math.max(brace.or_, (vim.fn.line 'w0') - 1)
    local vbot = math.min(brace.cr, (vim.fn.line 'w$') - 1)
    for r = vtop, vbot do
      local br = rows[r]
      if br then
        for i = 1, #br do
          local c, ch = br[i][1], br[i][2]
          local after_open = r > brace.or_ or c > brace.oc
          local before_close = r < brace.cr or c < brace.cc
          if after_open and before_close and not orange[r .. ':' .. c] then
            paint_one(bufnr, r, c, 'DansScopeParent', 150)
            add_mark(r, c, 'DansScopeParent')
          end
        end
      end
    end
  end

  -- Blue: the ancestor brace scopes up the chain, capped at the configured depth.
  local anc = 0
  for i = (brace_idx or #chain) + 1, #chain do
    if chain[i].ch == '{' then
      if anc >= M.depth then
        break
      end
      paint_pair(chain[i], 'DansScopeParent', 150)
      anc = anc + 1
    end
  end

  row_marks_cache[bufnr] = marks

  -- Repaint only the overlay rows whose marks changed (the overlay shows the
  -- brackets the raw paint can't reach). Diff per row so moving inside one scope
  -- doesn't repaint its whole height.
  local vok, view = pcall(require, 'custom.dans_frontend_cpp.view')
  if vok and view.is_enabled and view.is_enabled(bufnr) then
    local function sig(rm)
      if not rm then
        return ''
      end
      local t = {}
      for _, m in ipairs(rm) do
        t[#t + 1] = m.col .. m.hl
      end
      table.sort(t)
      return table.concat(t, ',')
    end
    local old = prev_marks[bufnr] or {}
    local rows = {}
    for r in pairs(marks) do
      rows[r] = true
    end
    for r in pairs(old) do
      rows[r] = true
    end
    for r in pairs(rows) do
      if sig(marks[r]) ~= sig(old[r]) then
        pcall(view.render_row, bufnr, r)
      end
    end
    prev_marks[bufnr] = marks
  else
    prev_marks[bufnr] = nil
  end
end

-- The overlay (view.render_one) reads this to recolor displayed brackets on a row.
function M.row_marks(bufnr, row)
  if disabled[bufnr] then
    return nil
  end
  local m = row_marks_cache[bufnr]
  return m and m[row]
end

M.refresh = update

function M.is_enabled(bufnr)
  return disabled[bufnr] ~= true
end

function M.set_enabled(bufnr, on)
  if on then
    disabled[bufnr] = nil
  else
    disabled[bufnr] = true
  end
  if not on then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    row_marks_cache[bufnr] = nil
    prev_marks[bufnr] = nil
  elseif bufnr == vim.api.nvim_get_current_buf() then
    update(bufnr)
  end
end

-- ib/ab -> the innermost pair, by dispatching to the matching native text object
-- so the selection (and thus yib/cib/dib/vib) is exactly the orange pair. expr
-- mapping: in operator-pending `dib` becomes `d` + `i(`/`i[`/`i{`. With the cursor
-- in no pair it returns <Esc>, cancelling the pending operator instead of hanging.
local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
local function dispatch(map)
  return function()
    local bufnr = vim.api.nvim_get_current_buf()
    local pos = vim.api.nvim_win_get_cursor(0)
    local p = M.innermost(bufnr, pos[1] - 1, pos[2])
    return (p and map[p.ch]) or ESC
  end
end

local function set_keymaps(bufnr)
  local opts = { buffer = bufnr, expr = true, silent = true }
  vim.keymap.set({ 'x', 'o' }, 'ib', dispatch(INNER), vim.tbl_extend('force', opts, { desc = 'inner scope (any bracket)' }))
  vim.keymap.set({ 'x', 'o' }, 'ab', dispatch(AROUND), vim.tbl_extend('force', opts, { desc = 'around scope (any bracket)' }))
end

local function set_highlights()
  -- Active pair: the orange the enclosing-brace highlighter has always used.
  vim.api.nvim_set_hl(0, 'DansScopeActive', { link = 'MatchParen' })
  -- Ancestor chain: the muted blue, distinct from the orange.
  vim.api.nvim_set_hl(0, 'DansScopeParent', { link = 'DiagnosticInfo' })
end

function M.setup()
  set_highlights()
  local group = vim.api.nvim_create_augroup('ds_cpp_scope', { clear = true })

  -- Recolor on cursor move / edit / buffer enter. Routed through the frontend's
  -- debounced decorate event so a scroll burst recomputes once.
  vu.on_decorate(group, { 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, update)

  -- Buffer-local text objects on c/cpp/cuda only; other filetypes keep native ib/ab.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      set_keymaps(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })

  vim.api.nvim_create_user_command('DansScopeDepth', function(a)
    local arg = vim.trim(a.args or '')
    if arg == '' then
      vim.notify('scope ancestor depth = ' .. M.depth, vim.log.levels.INFO)
      return
    end
    local n = tonumber(arg)
    if not n or n < 0 or n ~= math.floor(n) then
      vim.notify('DansScopeDepth: need a non-negative integer', vim.log.levels.WARN)
      return
    end
    M.depth = n
    local b = vim.api.nvim_get_current_buf()
    if CPP_FT[vim.bo[b].filetype] then
      update(b)
    end
    vim.notify('scope ancestor depth = ' .. n, vim.log.levels.INFO)
  end, { nargs = '?', desc = 'Set the scope ancestor (blue) coloring depth' })
end

return M
