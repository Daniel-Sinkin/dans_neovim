-- Read-mode that re-renders C/C++/CUDA variable declarations in a Odin-like
-- syntax. View-only (extmark conceal + inline virt_text). ON by default for
-- c/cpp/cuda buffers; toggle per-buffer with :DansFrontend.
--
--   int x{7}        ->  x: int = 7
--   int x{}         ->  x: int
--   T name{init}    ->  name: T = init
--   auto x = e      ->  x := e          (or x: <deduced> = e when clangd has it)
--   auto& x = e     ->  mut x& := e
--   const auto& x=e ->  x& := e
--   auto* x = e     ->  x^ := e         (the pointer deduction constraint stays visible)
--
-- This is the orchestration layer: per-buffer state, the visible-range refresh,
-- clangd inlay-hint fetching, and the user commands / autocmds. The parsing
-- lives in parse, the chunk building in render.
--
-- Reveal is cursor-line driven: the line the cursor sits on shows the real C++
-- (no overlay, no type hint); every other line shows the overlay. Moving
-- the cursor flips the line you leave back to the overlay and reveals the one you land
-- on. Mode-agnostic (insert mode has no special effect).

local vu = require 'custom.dans_frontend_cpp.util'
local P = require 'custom.dans_frontend_cpp.parse'
local R = require 'custom.dans_frontend_cpp.render'

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_frontend_view'
local enabled = {}
local hint_type = {} -- bufnr -> { [row0] = "int *" } from clangd Type inlay hints
local show_hints = false -- deduced-type hints off by default (toggle with :InlineHints)

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function type_for(bufnr, row0)
  if not show_hints then
    return nil
  end
  local m = hint_type[bufnr]
  return m and m[row0] or nil
end

-- Field alignment is computed over the whole visible window; cache it per buffer
-- per (changedtick, window) so the incremental per-row repaint on a cursor move
-- reuses it instead of rescanning, and the full refresh below shares the lines it
-- fetched. Invalidated by any edit (tick) or scroll (window) -- the only things
-- that change alignment.
local align_cache = {}
local function align_for(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local c = align_cache[bufnr]
  if not (c and c.tick == tick and c.s0 == s0 and c.e0 == e0) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
    c = { tick = tick, s0 = s0, e0 = e0, lines = lines, align = P.compute_align(lines, s0, bufnr) }
    align_cache[bufnr] = c
  end
  return c
end

-- Render the overlay for one row (or leave it raw if revealed / a
-- clang-format-off line). Diagnosed lines render like any other: the
-- diagnostic shows as a first-cell mark (custom.dans_diagmark) plus
-- cursor-line virtual text, neither of which the overlay collides with.
-- The row's namespace must already be cleared by the caller. Shared by the
-- full refresh and the per-row incremental path.
local function render_one(bufnr, row0, line, set, cfoff, cmt, align)
  -- a comment line that happens to parse like a decl (e.g. a `void (*PFN)(...)`
  -- inside a /* */ block) must stay raw -- comments are prose, never overlaid.
  if set[row0] or cfoff[row0] or cmt[row0] then
    return
  end
  local start_col, chunks = R.render_line(line, type_for(bufnr, row0), align[row0], bufnr, row0)
  if start_col then
    -- Scope highlighter coloring: the raw bracket chars it marks are concealed under
    -- this overlay, so recolor the matching displayed brackets in our own chunks.
    local sok, scope = pcall(require, 'custom.dans_frontend_cpp.scope')
    if sok then
      local sm = scope.row_marks(bufnr, row0)
      if sm then
        chunks = R.recolor(chunks, line, start_col, sm)
      end
    end
    -- Mirror transient highlights (yank flash, LSP reference) onto the chunks too.
    local ook, ohl = pcall(require, 'custom.dans_frontend_cpp.overlay_hl')
    if ook then
      local rr = ohl.ranges_for(bufnr, row0)
      if rr then
        chunks = R.recolor_ranges(chunks, line, start_col, rr)
      end
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, start_col, {
      end_col = #line,
      conceal = '',
      virt_text = chunks,
      virt_text_pos = 'overlay',
    })
  end
end

local function refresh(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: the deferred first pass paints everything at once
  end
  clear(bufnr)
  if vu.is_recording() then
    return -- macro recording: show raw text so recorded motions use real columns
  end
  -- reveal_set (cursor + visual selection) and clang-format-off both stay raw.
  local set = vu.reveal_set(bufnr)
  local cfoff = vu.clang_format_off(bufnr)
  local cmt = vu.comment_lines(bufnr)
  local c = align_for(bufnr)
  for idx, line in ipairs(c.lines) do
    render_one(bufnr, c.s0 + idx - 1, line, set, cfoff, cmt, c.align)
  end
end

-- Repaint just one row (the two flipped rows on a cursor move go through here).
-- Same render_one as the full pass, so the result is identical for that row.
function M.render_row(bufnr, row0)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, row0, row0 + 1)
  if vu.is_recording() then
    return
  end
  local c = align_for(bufnr)
  if row0 < c.s0 or row0 >= c.e0 then
    return -- off-screen; the next scroll/full refresh covers it
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  if line then
    render_one(bufnr, row0, line, vu.reveal_set(bufnr), vu.clang_format_off(bufnr), vu.comment_lines(bufnr), c.align)
  end
end

-- Request Type inlay hints from clangd directly (not the built-in renderer, so
-- nothing renders at end-of-line), cache the deduced type per row, re-render.
local function fetch_hints(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local clients = vim.lsp.get_clients { bufnr = bufnr, method = 'textDocument/inlayHint' }
  if #clients == 0 then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = 0, character = 0 },
      ['end'] = { line = math.max(0, n - 1), character = 0 },
    },
  }
  vim.lsp.buf_request_all(bufnr, 'textDocument/inlayHint', params, function(results)
    if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    -- Keep only the leftmost Type hint per line: that's the declarator's type,
    -- not e.g. a lambda's return-type hint placed further right on the line.
    local per_line = {}
    for _, res in pairs(results or {}) do
      for _, hint in ipairs((res or {}).result or {}) do
        if hint.kind == 1 and hint.position then -- 1 = Type
          local label = hint.label
          if type(label) == 'table' then
            local s = ''
            for _, part in ipairs(label) do
              s = s .. (part.value or '')
            end
            label = s
          end
          local t = tostring(label or ''):gsub('^%s*:%s*', ''):gsub('%s+$', '')
          local line = hint.position.line
          local char = hint.position.character
          if per_line[line] == nil or char < per_line[line].char then
            per_line[line] = { char = char, type = t }
          end
        end
      end
    end
    local map = {}
    for line, info in pairs(per_line) do
      -- const is the hidden default and std::/dans:: are hidden everywhere; drop
      -- them from the deduced type so it matches the rest of the view.
      local t = info.type:gsub('^const%s+', ''):gsub('std::', ''):gsub('dans::', '')
      -- Lambdas render as "(lambda at ...)" — useless noise; the lambda is
      -- written inline, so show no type (matches how functions read).
      if t ~= '' and not t:find('lambda', 1, true) then
        map[line] = t
      end
    end
    hint_type[bufnr] = map
    refresh(bufnr)
  end)
end

-- Render one line as the frontend displays it (no align padding, ignoring the
-- cursor reveal), for the frontend-copy operator. A non-declaration line has no
-- overlay, so it comes back raw -- the closest frontend view of a statement.
local function rendered_line(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local start_col, chunks = R.render_line(line, nil, nil, bufnr, row)
  if not start_col then
    return line
  end
  local t = { line:sub(1, start_col) }
  for _, c in ipairs(chunks) do
    t[#t + 1] = c[1]
  end
  return table.concat(t)
end

-- The frontend view of rows [r0, r1] as a linewise string. Read-only.
function M.rendered_text(bufnr, r0, r1)
  local out = {}
  for row = r0, r1 do
    out[#out + 1] = rendered_line(bufnr, row)
  end
  return table.concat(out, '\n') .. '\n'
end

-- Put `text` on the unnamed register and `y` (the paste-split's yank side, so a
-- later `p` pastes it), linewise.
local function set_yank(text)
  vim.fn.setreg('"', text, 'V')
  vim.fn.setreg('y', text, 'V')
end

-- operatorfunc for `<leader>y{motion/textobj}`: yank the rendered view of the lines
-- the motion spanned (the `[`..`]` marks). `<leader>yib` copies the scope's lines.
function _G._dans_frontend_yank(_)
  local bufnr = vim.api.nvim_get_current_buf()
  local r0, r1 = vim.fn.line "'[" - 1, vim.fn.line "']" - 1
  if r1 >= r0 then
    set_yank(M.rendered_text(bufnr, r0, r1))
  end
end

local function frontend_yank_keymaps(bufnr)
  local o = { buffer = bufnr, silent = true }
  -- operator: `<F2>` + a motion / text object (e.g. `<F2>ib` for the scope).
  vim.keymap.set('n', '<F2>', function()
    vim.o.operatorfunc = 'v:lua._dans_frontend_yank'
    return 'g@'
  end, vim.tbl_extend('force', o, { expr = true, desc = 'Frontend-copy (operator)' }))
  -- `<F2><F2>` (+count): the rendered view of N lines, like 3yy on the raw text.
  vim.keymap.set('n', '<F2><F2>', function()
    local r0 = vim.fn.line '.' - 1
    set_yank(M.rendered_text(vim.api.nvim_get_current_buf(), r0, r0 + vim.v.count1 - 1))
  end, vim.tbl_extend('force', o, { desc = 'Frontend-copy N lines' }))
  -- visual: the rendered view of the selected lines.
  vim.keymap.set('x', '<F2>', function()
    local r0, r1 = vim.fn.line 'v' - 1, vim.fn.line '.' - 1
    if r1 < r0 then
      r0, r1 = r1, r0
    end
    set_yank(M.rendered_text(vim.api.nvim_get_current_buf(), r0, r1))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end, vim.tbl_extend('force', o, { desc = 'Frontend-copy selection' }))
end

local function enable(bufnr)
  enabled[bufnr] = true
  vim.opt_local.conceallevel = 2
  -- Empty: cursor line is raw WYSIWYG, driven by cursor position not mode.
  vim.opt_local.concealcursor = ''
  frontend_yank_keymaps(bufnr)
  refresh(bufnr)
  fetch_hints(bufnr)
end

local function disable(bufnr)
  enabled[bufnr] = nil
  hint_type[bufnr] = nil
  clear(bufnr)
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if enabled[bufnr] then
    disable(bufnr)
  else
    enable(bufnr)
  end
end

-- Enable/disable the overlay for a buffer explicitly (the umbrella's
-- :DansFrontend per-module + master toggles drive this).
function M.set_enabled(bufnr, on)
  if on then
    enable(bufnr)
  else
    disable(bufnr)
  end
end

-- Toggle the deduced-type inlay hints (global) while keeping the overlay.
function M.toggle_hints()
  show_hints = not show_hints
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('frontend type hints ' .. (show_hints and 'on' or 'off'), vim.log.levels.INFO)
end

-- Toggle the experimental lambda-as-function rendering (global). The flag lives
-- in render; flip it there, then re-render every open overlay.
function M.toggle_lambda()
  local on = R.toggle_lambda()
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('frontend lambda view ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
end

-- Whether the overlay is currently active for this buffer.
function M.is_enabled(bufnr)
  return enabled[bufnr] == true and not vu.is_recording()
end

-- State getters for the config menu.
function M.hints_enabled()
  return show_hints
end
function M.lambda_enabled()
  return R.lambda_enabled()
end

-- Whether a line is one the overlay rewrites. Lets other view modules
-- (aliases / pointer / designated / ...) defer so they don't double-render on top
-- of the full-line overlay (which orphans their inline virt_text to the end).
--
-- This is the hottest call in the stack: every decoration module's skipper asks it
-- for every visible line, and the answer needs the full (treesitter-heavy)
-- render_line pipeline. Cache it per buffer per changedtick -- coverage depends
-- only on the line's content (align / type-hint don't change whether a line is a
-- decl), so a cursor move (no edit, same tick) is all cache hits, and within one
-- refresh the N skippers compute each row's render_line once, not N times.
local coverage = {} -- bufnr -> { tick, set = { [row0] = bool } }
function M.covers(line, bufnr, row0)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = coverage[bufnr]
  if not c or c.tick ~= tick then
    c = { tick = tick, set = {} }
    coverage[bufnr] = c
  end
  local v = c.set[row0]
  if v == nil then
    v = (R.render_line(line, nil, nil, bufnr, row0)) ~= nil
    c.set[row0] = v
  end
  return v
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_frontend_view', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      enable(ev.buf)
    end,
  })
  -- One visible-range refresh for everything: edits and the cursor/selection
  -- reveal (CursorMoved / ModeChanged recompute reveal_set). Scrolling is driven
  -- by the debounced VIEWPORT_SETTLED event, not WinScrolled, so a scroll burst
  -- repaints once instead of per notch. Cheap: it only touches on-screen lines.
  -- (DiagnosticChanged used to be here: diagnosed lines were skipped, so a new
  -- diagnostic forced a repaint. They render normally now.)
  vu.on_decorate(
    group,
    { 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI', 'ModeChanged' },
    refresh,
    M.render_row -- a plain cursor move repaints only the two reveal-flipped rows
  )
  -- Refresh deduced types: BufEnter/InsertLeave plus CursorHold (a natural
  -- debounce for the async clangd response after edits).
  vim.api.nvim_create_autocmd({ 'BufEnter', 'InsertLeave', 'CursorHold' }, {
    group = group,
    callback = function(ev)
      fetch_hints(ev.buf)
    end,
  })
end

return M
