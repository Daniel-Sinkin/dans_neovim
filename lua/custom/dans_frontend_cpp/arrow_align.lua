-- View-only alignment of the trailing-return `->` across consecutive
-- declaration blocks in .hpp headers. Source text is never changed; alignment
-- is inline virt_text spaces inserted before each arrow so the *seen* arrows
-- line up.
--
-- Why a custom width model instead of plain source alignment: const/std::/dans::
-- are concealed (markers.lua) and $nd/$ne/... aliases shrink their
-- keywords (aliases.lua), so arrows aligned in the source render
-- ragged by exactly those deltas. This recomputes each line's *rendered* arrow
-- column and pads up to the block max.
--
-- COUPLING (accepted by the user): the width model below mirrors the conceals
-- in markers.lua / pointer.lua (leading/param `const`, `std::`, `dans::`, `dans_`)
-- and the alias list in aliases.lua (consumed via M.ALIASES). A new
-- conceal/alias that can appear before a `->` and isn't reflected here will
-- skew alignment. Cached by changedtick, .hpp only. Shared reveal rows render
-- raw (no pad), matching the other C++ view modules.

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'

local ns = vim.api.nvim_create_namespace 'ds_hpp_arrow'
local cache = {} -- bufnr -> { tick, pads = { [row0] = { col = byte0, n = pad } } }

local function is_hpp(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):sub(-4) == '.hpp'
end

local function is_word_char(c)
  return c ~= nil and c ~= '' and c:match '[%w_]' ~= nil
end

-- Drop a trailing line comment so a `->` living only inside `// ...` doesn't
-- count as a declaration. (A `//` inside a string in a signature is vanishingly
-- rare in headers; not handled.)
local function code_of(line)
  local cut = line:find('//', 1, true)
  return cut and line:sub(1, cut - 1) or line
end

-- 1-based index of the trailing-return `->`, or nil. Skips `operator->` and a
-- member-access arrow (`platform_->to_string`): a trailing-return arrow follows the
-- param-list `)` or a qualifier (`const`/`noexcept`/...), never an identifier -- so
-- a `->` glued to the end of an identifier is member access, not a return arrow.
local TRAILING_QUAL = { const = true, noexcept = true, override = true, final = true, volatile = true, mutable = true }
local function arrow_pos(code)
  local from = 1
  while true do
    local s = code:find('->', from, true)
    if not s then
      return nil
    end
    local pre = code:sub(1, s - 1)
    if not pre:match 'operator%s*$' then
      if not is_word_char(code:sub(s - 1, s - 1)) then
        return s -- after `)` or whitespace
      end
      local word = pre:match '([%w_]+)$'
      if word and TRAILING_QUAL[word] then
        return s -- after a qualifier written with no space (`noexcept->`)
      end
    end
    from = s + 2
  end
end

-- Width concealed by the leading `const` rule  ^\s*\zsconst\>\s*  (pointer.lua):
-- a whole-word `const` at line start (a const value local). const in params /
-- return types is no longer concealed, so it isn't removed here.
local function const_removed(prefix)
  local removed, i = 0, 1
  while true do
    local s, e = prefix:find('const', i, true)
    if not s then
      break
    end
    i = e + 1
    if not is_word_char(prefix:sub(e + 1, e + 1)) then
      local j = s - 1
      while j >= 1 and prefix:sub(j, j):match '%s' do
        j = j - 1
      end
      if j < 1 then -- only a leading const is concealed now
        local k = e + 1
        while k <= #prefix and prefix:sub(k, k):match '%s' do
          k = k + 1
        end
        removed = removed + (k - s) -- 'const' + trailing whitespace
      end
    end
  end
  return removed
end

-- Width concealed by a literal prefix conceal at a word boundary (\<std::,
-- \<dans::, \<dans_). Only the literal is hidden, not the identifier after it.
local function literal_removed(prefix, lit)
  local removed, i = 0, 1
  while true do
    local s, e = prefix:find(lit, i, true)
    if not s then
      break
    end
    i = e + 1
    if s == 1 or not is_word_char(prefix:sub(s - 1, s - 1)) then
      removed = removed + #lit
    end
  end
  return removed
end

-- Width concealed by a whole-word conceal that also eats trailing whitespace
-- (\<word\>\s*), e.g. `inline ` (markers.lua).
local function word_ws_removed(prefix, word)
  local removed, i = 0, 1
  while true do
    local s, e = prefix:find(word, i, true)
    if not s then
      break
    end
    i = e + 1
    local bounded = (s == 1 or not is_word_char(prefix:sub(s - 1, s - 1)))
      and not is_word_char(prefix:sub(e + 1, e + 1))
    if bounded then
      local k = e + 1
      while k <= #prefix and prefix:sub(k, k):match '%s' do
        k = k + 1
      end
      removed = removed + (k - s)
    end
  end
  return removed
end

-- Width concealed by the GLFW prefix rules (markers.lua): the prefix only, the
-- rest stays visible. `glfw` before [A-Z] (function) and `GLFW` before [a-z]
-- (type) hide 4 cells; `GLFW_` before [A-Z0-9] (macro) hides 5. `glfw_foo`
-- (yours) matches none. Mirrors the \ze conceals so a `->` after a GLFW token
-- stays aligned.
local function glfw_removed(prefix)
  local removed = 0
  local function count(pat, n)
    for pos in prefix:gmatch('()' .. pat) do
      if pos == 1 or not is_word_char(prefix:sub(pos - 1, pos - 1)) then
        removed = removed + n
      end
    end
  end
  count('glfw[A-Z]', 4)
  count('GLFW[a-z]', 4)
  count('GLFW_[A-Z0-9]', 5)
  return removed
end

-- Width removed by Qnpeps identifier prefixes outside the parameter list. The
-- parameter flip reports its own exact rendered width; this mirrors only raw
-- function/qualifier text before a source trailing arrow.
local function qnpeps_removed(prefix)
  local removed = 0
  local function count(pat, n)
    for pos in prefix:gmatch('()' .. pat) do
      if pos == 1 or not is_word_char(prefix:sub(pos - 1, pos - 1)) then
        removed = removed + n
      end
    end
  end
  count('qnpeps_[A-Za-z0-9]', 7)
  count('QNPEPS_[A-Z0-9]', 7)
  count('Qnpeps[A-Za-z0-9]', 6)
  count('qn_[A-Za-z0-9]', 3)
  return removed
end

-- Net width change from aliases: each whole-word keyword is concealed and
-- replaced by its (shorter) virt_text. Returns (removed, added).
local function alias_delta(prefix)
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if not ok or not aliases then
    return 0, 0
  end
  local removed, added = 0, 0
  for _, a in ipairs(aliases) do
    local kw, rep = a[1], a[2]
    local i = 1
    while true do
      local s, e = prefix:find(kw, i, true)
      if not s then
        break
      end
      i = e + 1
      local before = s > 1 and prefix:sub(s - 1, s - 1) or nil
      if not is_word_char(before) and not is_word_char(prefix:sub(e + 1, e + 1)) then
        removed = removed + vim.fn.strwidth(kw)
        added = added + vim.fn.strwidth(rep)
      end
    end
  end
  return removed, added
end

-- Net rendered width of a non-param fragment: strwidth minus the conceals plus
-- the alias deltas. `line_start` controls const_removed -- a leading-const value
-- local is concealed only at the start of the line, not after a `)`.
local function piecemeal(s, line_start)
  local removed = word_ws_removed(s, 'inline')
    + word_ws_removed(s, 'static')
    + literal_removed(s, 'std::')
    + literal_removed(s, 'dans::')
    + literal_removed(s, 'dans_')
    + literal_removed(s, 'qnpeps::')
    + glfw_removed(s)
    + qnpeps_removed(s)
  if line_start then
    removed = removed + const_removed(s)
  end
  local arem, aadd = alias_delta(s)
  return vim.fn.strwidth(s) - removed - arem + aadd
end

-- Rendered display column of the arrow (cells visible before it), and its 1-based
-- source index. nil if no trailing-return arrow. The param list (between `(` and
-- `)`) is measured by the flip itself (M.flip_params.width) so std::/const/mut
-- inside params are counted once and exactly; the rest is the piecemeal model.
-- strwidth (not strdisplaywidth): the latter inflates long trailing-space runs on
-- this build; headers are space-indented so no tab expansion is needed.
local function rendered_arrow_col(line, bufnr, row0)
  local aliases = require 'custom.dans_frontend_cpp.aliases'
  local ap = arrow_pos(code_of(line))
  if not ap then
    -- Injected arrows on C-style declarations are owned wholly by aliases.lua.
    -- Padding at their source injection column can be ordered after that module's
    -- inline virtual text, producing spaces between the arrow/type and semicolon.
    -- Treat them as block boundaries; only source `->` tokens are aligned here.
    return nil
  end
  local fp = aliases.flip_params(line, bufnr, row0)
  local member_mut = 0
  local okm, mcol = pcall(function()
    return aliases.member_mut_col(line, bufnr, row0)
  end)
  if okm and mcol and mcol < ap - 1 then
    member_mut = 4 -- ` mut` injected after `)` of a non-const member function
  end
  local w
  if fp and fp.close <= ap - 1 then
    w = piecemeal(line:sub(1, fp.open - 1), true) + fp.width + piecemeal(line:sub(fp.close + 1, ap - 1), false)
  else
    w = piecemeal(line:sub(1, ap - 1), true)
  end
  -- A leading `auto` return type renders as the 3-cell `def` (aliases.lua), so
  -- shave the 1 cell `auto` (4) -> `def` (3) drops, or the arrow sits a column
  -- right of where `def ...` actually renders.
  local oka, adc = pcall(function()
    return aliases.fn_auto_def_col(line, bufnr, row0)
  end)
  if oka and adc then
    w = w - 1
  end
  return w + member_mut, ap
end

-- Scan the buffer into a row0 -> {col, n} pad map. Blocks are maximal runs of
-- consecutive arrow lines; within a block each arrow pads up to the max.
local function compute(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cfoff = vu.clang_format_off(bufnr)
  -- special_members collapses some `operator= ... -> X&` lines to $copya/$movea;
  -- those are not arrows to align, so they break a block.
  local ok_sm, sm = pcall(require, 'custom.dans_frontend_cpp.special_members')
  local n = #lines
  local result = {}
  local i = 1
  while i <= n do
    local block = {}
    local j = i
    while j <= n do
      local r, ap = rendered_arrow_col(lines[j], bufnr, j - 1)
      if not r or cfoff[j - 1] or (ok_sm and sm.covers(bufnr, j - 1)) then
        break -- clang-format-off and special-member lines are left alone
      end
      block[#block + 1] = { row0 = j - 1, rendered = r, col0 = ap - 1 }
      j = j + 1
    end
    if #block == 0 then
      i = i + 1
    else
      if #block >= 2 then
        local maxr = 0
        for _, b in ipairs(block) do
          maxr = math.max(maxr, b.rendered)
        end
        for _, b in ipairs(block) do
          local pad = maxr - b.rendered
          if pad > 0 then
            result[b.row0] = { col = b.col0, n = pad }
          end
        end
      end
      i = j
    end
  end
  return result
end

local function place(bufnr, row0, p)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, p.col, {
    virt_text = { { string.rep(' ', p.n), 'Normal' } },
    virt_text_pos = 'inline',
  })
end

local function pads_for(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = cache[bufnr]
  if not entry or entry.tick ~= tick then
    entry = { tick = tick, pads = compute(bufnr) }
    cache[bufnr] = entry
  end
  return entry.pads
end

local function refresh(bufnr)
  if not (vim.api.nvim_buf_is_valid(bufnr) and is_hpp(bufnr)) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'arrow_align') then
    cache[bufnr] = nil
    return
  end
  local reveal = vu.reveal_set(bufnr)
  for row0, p in pairs(pads_for(bufnr)) do
    if not reveal[row0] then
      place(bufnr, row0, p)
    end
  end
end

local function render_row(bufnr, row0)
  if not (vim.api.nvim_buf_is_valid(bufnr) and is_hpp(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, row0, row0 + 1)
  if not vu.module_enabled(bufnr, 'arrow_align') or vu.reveal_set(bufnr)[row0] then
    return
  end
  local p = pads_for(bufnr)[row0]
  if p then
    place(bufnr, row0, p)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_hpp_arrow', { clear = true })
  vu.on_decorate(
    group,
    { 'FileType', 'BufReadPost', 'BufWritePost', 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI' },
    refresh,
    render_row
  )
end

M.refresh = refresh

-- Exposed for the headless live-test harness.
M._rendered_arrow_col = rendered_arrow_col
M._compute = compute

return M
