-- Shared helpers for the C/C++/CUDA view-layer modules (aliases,
-- pointer, view). These were copy-pasted in each; centralized here so
-- the visible-range window, cursor row, and filetype guard stay in one place.

local M = {}

-- The filetypes the view modules operate on.
function M.is_cpp(ft)
  return ft == 'c' or ft == 'cpp' or ft == 'cuda'
end

-- 0-based cursor row in `bufnr`, or nil when it isn't the current buffer (so a
-- background buffer's decorations don't track some other window's cursor).
function M.cursor_row0(bufnr)
  if bufnr == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
end

-- Set of 0-based rows carrying a diagnostic (clangd / clang-tidy / etc). The
-- view modules used to skip these to dodge the end-of-line virtual text; that
-- text is now cursor-line-only (diagnosed lines get a first-cell mark from
-- custom.dans_diagmark instead), so nothing skips them anymore. Kept for any
-- caller that wants the set.
function M.diagnostic_lines(bufnr)
  local set = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    set[d.lnum] = true
  end
  return set
end

-- 0-based rows to show raw: the cursor line, or the whole visual selection while
-- in a visual mode. Both the overlay and the decoration modules reveal this set,
-- so a multi-line select shows the original everywhere (otherwise the overlay
-- reveals but a pointer `^` etc. lingers on the non-cursor selected lines).
function M.reveal_set(bufnr)
  local cur = M.cursor_row0(bufnr)
  if cur == nil then
    return {}
  end
  local m = vim.fn.mode():sub(1, 1)
  if m == 'v' or m == 'V' or m == string.char(22) then
    local vstart = vim.fn.getpos('v')[2] - 1
    local lo, hi = math.min(cur, vstart), math.max(cur, vstart)
    local set = {}
    for r = lo, hi do
      set[r] = true
    end
    return set
  end
  return { [cur] = true }
end

-- Whole-buffer line snapshot, one fetch per changedtick. Several per-tick scans
-- (clang-format-off, the fold map, ppif, the scope bracket index) each pulled
-- the full buffer on every edit; sharing one snapshot cuts the API calls and
-- the per-keystroke GC churn on big files.
local lines_cache = {}
function M.buf_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = lines_cache[bufnr]
  if not (c and c.tick == tick) then
    c = { tick = tick, lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) }
    lines_cache[bufnr] = c
  end
  return c.lines
end

-- 0-based rows inside a `// clang-format off` ... `// clang-format on` region.
-- Those are hand-aligned (data encoded in code); the frontend leaves them
-- verbatim so it never fights the manual layout. Cached per changedtick.
local cfoff_cache = {}
function M.clang_format_off(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cfoff_cache[bufnr]
  if c and c.tick == tick then
    return c.set
  end
  local set, off = {}, false
  for i, line in ipairs(M.buf_lines(bufnr)) do
    if line:match '//%s*clang%-format%s+off' then
      off = true
    elseif line:match '//%s*clang%-format%s+on' then
      off = false
    end
    if off then
      set[i - 1] = true
    end
  end
  cfoff_cache[bufnr] = { tick = tick, set = set }
  return set
end

-- Whether (row, col) (0-based) sits inside a string / char literal / comment /
-- include path, via treesitter -- so syntax-blind coloring / conceals never fire
-- inside one. Robust where a text scan isn't: block comments, char literals, raw
-- and multi-line strings.
local SKIP_NODES = {
  string_literal = true,
  raw_string_literal = true,
  char_literal = true,
  comment = true,
  system_lib_string = true,
  string_content = true,
  escape_sequence = true,
}
function M.in_literal(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok or not node then
    return false
  end
  while node do
    if SKIP_NODES[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

-- 0-based rows covered by a `static_assert(...)` declaration. Those are dedicated
-- compile-time checks -- code you skim rarely and want to read with full fidelity
-- when you do -- so the whole frontend leaves them verbatim (no conceals, sugar,
-- prefix-stripping). Cached per changedtick + visible range; every consumer only
-- tests on-screen rows, and the range-limited query keeps the per-edit cost flat
-- as the file grows (iter_captures yields any node intersecting the range).
local sa_cache = {}
function M.static_assert_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local s0, e0 = M.visible_range(bufnr)
  local c = sa_cache[bufnr]
  if c and c.tick == tick and c.s0 == s0 and c.e0 == e0 then
    return c.set
  end
  local set = {}
  pcall(function()
    local parser = vim.treesitter.get_parser(bufnr)
    local tree = parser:parse()[1]
    local q = vim.treesitter.query.parse(parser:lang(), '(static_assert_declaration) @sa')
    for _, node in q:iter_captures(tree:root(), bufnr, s0, e0) do
      local sr, _, er = node:range()
      for r = sr, er do
        set[r] = true
      end
    end
  end)
  sa_cache[bufnr] = { tick = tick, s0 = s0, e0 = e0, set = set }
  return set
end

-- 0-based rows that are wholly inside a comment (block /* */ or a full-line //),
-- so the frontend leaves them untouched -- a comment is prose, not code. A row is
-- included when the comment owns the line's first non-blank char (so `code; //
-- tail` keeps its code, but ` * doc` and `/* ... */` block lines are skipped).
-- Cached per changedtick + visible range; iterating every comment in the buffer
-- per keystroke was the single largest slice of insert-mode latency on big files.
local comment_cache = {}
function M.comment_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local s0, e0 = M.visible_range(bufnr)
  local c = comment_cache[bufnr]
  if c and c.tick == tick and c.s0 == s0 and c.e0 == e0 then
    return c.set
  end
  local set = {}
  pcall(function()
    local parser = vim.treesitter.get_parser(bufnr)
    local tree = parser:parse()[1]
    local q = vim.treesitter.query.parse(parser:lang(), '(comment) @c')
    local lines
    for _, node in q:iter_captures(tree:root(), bufnr, s0, e0) do
      local sr, sc, er = node:range()
      lines = lines or M.buf_lines(bufnr)
      local first = lines[sr + 1] and #(lines[sr + 1]:match '^%s*' or '') or 0
      if sc <= first then
        set[sr] = true -- the comment starts the line (no code before it)
      end
      for r = sr + 1, er do
        set[r] = true -- continuation / closing lines are wholly inside the comment
      end
    end
  end)
  comment_cache[bufnr] = { tick = tick, s0 = s0, e0 = e0, set = set }
  return set
end

-- 0-based rows belonging to `#include` / `#include_next` directives. Includes
-- are source identifiers, not C/C++ expressions: a library-looking token in a
-- header name (for example cuComplex.h) must never enter the alias/prefix
-- pipeline. Track backslash continuations as part of the same directive so an
-- angle-bracket path on the following source row stays verbatim too. This is a
-- lexical fact on purpose; it remains available when Tree-sitter cannot parse a
-- partial or macro-based include.
local include_cache = {}
function M.include_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = include_cache[bufnr]
  if c and c.tick == tick then
    return c.set
  end
  local set, continued = {}, false
  for i, line in ipairs(M.buf_lines(bufnr)) do
    local directive = not continued and line:match '^%s*#%s*([%a_][%w_]*)' or nil
    local include = continued or directive == 'include' or directive == 'include_next'
    if include then
      set[i - 1] = true
    end
    continued = include and line:match '\\%s*$' ~= nil
  end
  include_cache[bufnr] = { tick = tick, set = set }
  return set
end

-- 0-based [start, end) line range to decorate: the on-screen window plus a
-- margin, so a big file isn't re-scanned whole on every edit / scroll / cursor
-- move. Off-screen rows are (re)decorated as they scroll in (WinScrolled). A
-- non-current buffer has no window, so fall back to the whole buffer.
M.VISIBLE_MARGIN = 40
function M.visible_range(bufnr)
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return 0, vim.api.nvim_buf_line_count(bufnr)
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  return math.max(0, vim.fn.line 'w0' - 1 - M.VISIBLE_MARGIN), math.min(n, vim.fn.line 'w$' + M.VISIBLE_MARGIN)
end

-- Per-refresh skip predicate, capturing the reveal set (cursor + visual
-- selection), clang-format-off rows, and view-overlay coverage once (so a
-- module computes them a single time, not per line/capture). Diagnosed rows
-- are NOT skipped: diagnostics render as a first-cell mark + cursor-line text
-- (custom.dans_diagmark), which the decorations don't collide with. A
-- decoration skips any row it returns true for. `line` is optional, fetched only
-- if a coverage check needs it. `.skip` / `.skip_conceal` are kept as distinct
-- names for call-site readability though they now coincide.
function M.make_skipper(bufnr)
  local reveal = M.reveal_set(bufnr)
  local cfoff = M.clang_format_off(bufnr)
  local sa = M.static_assert_lines(bufnr)
  local cmt = M.comment_lines(bufnr)
  local inc = M.include_lines(bufnr)
  local view_ok, view = pcall(require, 'custom.dans_frontend_cpp.view')
  local view_on = view_ok and view.is_enabled(bufnr)
  local function covered(row0, line)
    if not view_on then
      return false
    end
    if line == nil then
      line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
    end
    return line ~= nil and view.covers(line, bufnr, row0)
  end
  local function any(row0, line)
    return reveal[row0] or cfoff[row0] or sa[row0] or cmt[row0] or inc[row0] or covered(row0, line)
  end
  return { skip = any, skip_conceal = any }
end

-- ------------------------------------------------------------- cold open ---
-- First-paint deferral. Opening a never-seen buffer fires the whole decoration
-- stack synchronously (FileType + BufEnter run BEFORE the first paint); on a
-- vk_core-sized file the treesitter cold parse plus a dozen full-file queries
-- block the open for ~500 ms. Every decoration refresh asks cold_gate first:
-- while the buffer is cold it returns true (skip everything -- the raw file
-- paints instantly), and one deferred pass then decorates the whole stack at
-- once. Small buffers never go cold (their first pass costs a few ms, so the
-- decorated view appearing instantly is worth more than the deferral).
-- Re-entering an already-loaded buffer is warm by definition -- the gate arms
-- once per buffer load (re-armed on unload, so :e! defers again).
local COLD_OPEN_MS = 40
local COLD_MIN_LINES = 400
local cold = {}

-- treesitter-context suspension across cold opens: its update autocmds fire
-- inside the open cascade and would pay the synchronous cold parse themselves
-- (measured ~180 ms on a 4.4k-line file), defeating the gate. Counted, since
-- several cold opens can overlap.
local tsc_suspended = 0
local function tsc_suspend()
  if not package.loaded['treesitter-context'] then
    return -- not loaded yet; requiring it HERE would force the lazy plugin
    -- load (and its initial update) into the open cascade we're deferring
  end
  local ok = pcall(function()
    require('treesitter-context').disable()
  end)
  if ok then
    tsc_suspended = tsc_suspended + 1
  end
end
local function tsc_resume()
  if tsc_suspended > 0 then
    tsc_suspended = tsc_suspended - 1
    if tsc_suspended == 0 then
      pcall(function()
        require('treesitter-context').enable()
      end)
    end
  end
end

function M.cold_gate(bufnr)
  local state = cold[bufnr]
  if state ~= nil then
    return state
  end
  if vim.api.nvim_buf_line_count(bufnr) < COLD_MIN_LINES then
    cold[bufnr] = false
    return false
  end
  cold[bufnr] = true
  tsc_suspend()
  -- exactly one resume per arm, whichever path gets there first (the deferred
  -- finish, or an unload racing it).
  local resumed = false
  local function resume_once()
    if not resumed then
      resumed = true
      tsc_resume()
    end
  end
  -- pcall: the first gate ask can come from the foldexpr, whose evaluation
  -- context restricts some API calls; losing the unload re-arm there only
  -- means a reopened buffer decorates eagerly once.
  pcall(vim.api.nvim_create_autocmd, 'BufUnload', {
    buffer = bufnr,
    once = true,
    callback = function()
      cold[bufnr] = nil
      resume_once()
    end,
  })
  local function finish()
    if cold[bufnr] ~= true then
      return -- unloaded (and possibly re-armed) in the meantime
    end
    cold[bufnr] = false
    resume_once()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if vim.api.nvim_get_current_buf() == bufnr then
      -- one repaint of the whole stack: the settled event drives the view and
      -- every on_decorate module; the few that don't listen to it run directly.
      for _, mod in ipairs { 'lint', 'arrow_align', 'fold' } do
        pcall(function()
          require('custom.dans_frontend_cpp.' .. mod).refresh(bufnr)
        end)
      end
      vim.api.nvim_exec_autocmds('User', { pattern = M.VIEWPORT_SETTLED })
    else
      -- the user hopped away before the deferral fired: drop the folded flag
      -- so the return trip's BufEnter folds the (by then computable) outline.
      pcall(vim.api.nvim_buf_del_var, bufnr, 'dans_folded')
    end
  end
  vim.defer_fn(function()
    if cold[bufnr] ~= true then
      return -- unloaded first; that path already resumed
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cold[bufnr] = false
      resume_once()
      return
    end
    -- Warm the tree asynchronously (time-sliced on the main loop) so neither
    -- the repaint below nor any later consumer pays the ~200 ms cold parse in
    -- one synchronous block. Falls back to the sync path on older runtimes.
    local started = false
    pcall(function()
      local parser = vim.treesitter.get_parser(bufnr)
      if parser then
        parser:parse(true, function()
          vim.schedule(finish)
        end)
        started = true
      end
    end)
    if not started then
      finish()
    end
  end, COLD_OPEN_MS)
  return true
end

-- While a macro is recording, every column-shifting view transform is suspended
-- so recorded motions land on real buffer columns, not concealed / virt_text
-- ones. `fold` is exempt -- it hides lines, not columns, so recording in the
-- normal folded view is fine. The umbrella's RecordingEnter/Leave hooks flip this
-- and repaint; the gates below only have to report "off" while it is set.
local recording = false
function M.is_recording()
  return recording
end
function M.set_recording(on)
  recording = on and true or false
end

-- Per-buffer module enable/disable (default enabled). The umbrella's
-- :DansFrontend command flips these; each module's refresh consults
-- M.module_enabled and clears its own decorations when off.
local module_off = {}
function M.module_enabled(bufnr, name)
  if recording and name ~= 'fold' then
    return false
  end
  local off = module_off[bufnr]
  return not (off and off[name])
end
function M.set_module(bufnr, name, on)
  local off = module_off[bufnr] or {}
  off[name] = (not on) or nil
  module_off[bufnr] = off
end

-- Decoration repaint coalescing. The view / decoration refreshes used to run on
-- every WinScrolled, so a mouse-scroll burst reran the whole stack per notch.
-- Instead the umbrella fires this user event once, DECORATE_DEBOUNCE_MS after
-- scrolling stops; decoration modules listen to it (via on_decorate) rather than
-- WinScrolled. Edits stay immediate; cursor moves are immediate too, EXCEPT the
-- per-notch CursorMoved a scroll fires when it drags the cursor at the scrolloff
-- edge -- those are skipped (see is_scrolling) so scroll speed doesn't depend on
-- where the cursor sits, with the settled event doing the one repaint.
M.VIEWPORT_SETTLED = 'DansViewportSettled'
local DECORATE_DEBOUNCE_MS = 100
local last_scroll_ns = 0

-- True for DECORATE_DEBOUNCE_MS after the last scroll. The window equals the
-- debounce, so the settled repaint lands exactly as it closes: a real cursor move
-- within it is still painted by that settled event, and one after it refreshes
-- immediately. hrtime is monotonic ns.
function M.is_scrolling()
  return ((vim.uv or vim.loop).hrtime() - last_scroll_ns) < DECORATE_DEBOUNCE_MS * 1000000
end

-- Diagnostics generation per buffer, bumped on every DiagnosticChanged. Folded
-- into the paint signature below so a diagnostic update repaints while two
-- events with identical diagnostics can dedupe. Registered once, before any
-- module's own DiagnosticChanged handler (the umbrella calls
-- setup_viewport_debounce first), so the bump is visible to the same event.
local diag_gen = {}
local diag_gen_installed = false
local function ensure_diag_gen()
  if diag_gen_installed then
    return
  end
  diag_gen_installed = true
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = vim.api.nvim_create_augroup('ds_decorate_diag_gen', { clear = true }),
    callback = function(ev)
      diag_gen[ev.buf] = (diag_gen[ev.buf] or 0) + 1
    end,
  })
end

-- Everything a decoration pass reads from, as one comparable string: buffer
-- content (tick), the reveal row, the visible window, mode (visual selection),
-- the diagnostics, macro-record suspension, and the cold-open state (a gated
-- pass paints nothing, so the post-cold repaint must not dedupe against it).
-- Two events with the same signature would paint identical extmarks, so the
-- second is skipped -- this collapses the FileType+BufEnter double paint on
-- every file open and repeated BufEnters into one pass per module.
local function paint_sig(buf)
  local s0, e0 = M.visible_range(buf)
  return table.concat({
    vim.api.nvim_buf_get_changedtick(buf),
    M.cursor_row0(buf) or -1,
    s0,
    e0,
    vim.fn.mode():sub(1, 1),
    diag_gen[buf] or 0,
    recording and 1 or 0,
    tostring(cold[buf]),
  }, ':')
end

-- bufnr-keyed dedup state would go stale when a wiped buffer's number is
-- recycled (a colliding signature on the new buffer would skip its paint), so
-- one autocmd clears every registered table's slot on wipe.
local wipe_tables = {}
local wipe_installed = false
local function clear_on_wipe(t)
  wipe_tables[#wipe_tables + 1] = t
  if not wipe_installed then
    wipe_installed = true
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
      group = vim.api.nvim_create_augroup('ds_decorate_buf_wipe', { clear = true }),
      callback = function(ev)
        for _, tbl in ipairs(wipe_tables) do
          tbl[ev.buf] = nil
        end
      end,
    })
  end
  return t
end

-- Register decoration autocmds for `cb` (called with a bufnr): `events` fire it
-- immediately; the debounced VIEWPORT_SETTLED event drives the scroll repaint.
-- Do NOT pass WinScrolled in `events` -- scrolling goes through the settled event.
-- Scroll-dragged CursorMoved is dropped (the settled event covers it).
--
-- ModeChanged is mandatory and is added here even when a caller omits it. Reveal
-- policy belongs to this shared lifecycle gate, not to individual feature
-- modules: entering, extending, or leaving any visual mode changes which rows
-- must be raw, and every decoration using make_skipper must observe that change.
-- Keeping the subscription here prevents the exact failure mode where one module
-- restores after <Esc> while another remains raw until the cursor touches it.
--
-- Cursor/mode handling, since those events usually only change the reveal set:
--   * if neither the changedtick nor the cursor row changed since the last paint,
--     skip entirely -- this kills the CursorMovedI that trails every insert
--     keystroke (TextChangedI already painted) and every horizontal h/l/w move.
--   * if `render_row` is given and text is unchanged, diff the previous/new reveal
--     sets and repaint ONLY rows whose raw/decorated state flipped. This covers
--     normal vertical motion and arbitrary char/line/block visual selections.
--   * otherwise (an edit, first paint, or a module without row rendering) fall
--     back to the full `cb`.
--
-- Every other event runs through the paint signature: identical signature ->
-- identical output -> skip.
function M.on_decorate(group, events, cb, render_row)
  ensure_diag_gen()
  local normalized_events, seen = {}, {}
  for _, event in ipairs(events) do
    if not seen[event] then
      normalized_events[#normalized_events + 1] = event
      seen[event] = true
    end
  end
  if not seen.ModeChanged then
    normalized_events[#normalized_events + 1] = 'ModeChanged'
  end

  local last = clear_on_wipe {} -- buf -> { sig, tick, row, reveal }
  local function state(buf, sig)
    return {
      sig = sig,
      tick = vim.api.nvim_buf_get_changedtick(buf),
      row = M.cursor_row0(buf),
      reveal = M.reveal_set(buf),
    }
  end
  local function reveal_delta(before, after)
    local changed = {}
    for row in pairs(before or {}) do
      if not after[row] then
        changed[#changed + 1] = row
      end
    end
    for row in pairs(after) do
      if not (before and before[row]) then
        changed[#changed + 1] = row
      end
    end
    table.sort(changed)
    return changed
  end
  local function run(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local sig = paint_sig(buf)
    local st = last[buf]
    if st and st.sig == sig then
      return
    end
    cb(buf)
    last[buf] = state(buf, sig)
  end
  vim.api.nvim_create_autocmd(normalized_events, {
    group = group,
    callback = function(ev)
      local buf = ev.buf
      local reveal_event = ev.event == 'CursorMoved' or ev.event == 'CursorMovedI' or ev.event == 'ModeChanged'
      if reveal_event then
        if M.is_scrolling() then
          return
        end
        local st = last[buf]
        if st then
          local tick = vim.api.nvim_buf_get_changedtick(buf)
          local row = M.cursor_row0(buf)
          local reveal = M.reveal_set(buf)
          local changed = reveal_delta(st.reveal, reveal)
          if st.tick == tick and #changed == 0 then
            -- The mode/cursor may have changed, but no row changed presentation.
            -- Preserve the new lifecycle state so a later visual extension diffs
            -- against the correct selection.
            last[buf] = state(buf, false)
            return
          end
          if render_row and st.tick == tick then
            for _, changed_row in ipairs(changed) do
              render_row(buf, changed_row)
            end
            -- sig=false: the incremental paint matches no future signature, so
            -- the next full event repaints rather than wrongly deduping.
            last[buf] = { sig = false, tick = tick, row = row, reveal = reveal }
            return
          end
        end
      end
      run(buf)
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = M.VIEWPORT_SETTLED,
    callback = function(ev)
      run(ev.buf)
    end,
  })
end

-- Install the single WinScrolled debouncer that fires VIEWPORT_SETTLED once
-- scrolling has been quiet for DECORATE_DEBOUNCE_MS. Called once by the umbrella.
local scroll_timer
function M.setup_viewport_debounce()
  ensure_diag_gen() -- registered before any module handler, so the gen bump runs first
  local group = vim.api.nvim_create_augroup('ds_viewport_debounce', { clear = true })
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    callback = function()
      last_scroll_ns = (vim.uv or vim.loop).hrtime()
      if not scroll_timer then
        scroll_timer = (vim.uv or vim.loop).new_timer()
      end
      scroll_timer:stop()
      scroll_timer:start(
        DECORATE_DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
          vim.api.nvim_exec_autocmds('User', { pattern = M.VIEWPORT_SETTLED })
        end)
      )
    end,
  })
end

return M
