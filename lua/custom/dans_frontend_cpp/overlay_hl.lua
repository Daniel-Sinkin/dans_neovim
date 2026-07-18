-- Mirror transient buffer highlights onto the frontend overlay. The yank flash and
-- the LSP reference/hover highlight are placed on the raw buffer text, which the
-- overlay conceals on every non-cursor line -- so on a rewritten line they vanish.
-- Each source registers per-row column ranges here; view.render_one paints them onto
-- its own chunks via render.recolor_ranges, so the highlight shows on what you SEE.
-- The raw highlight still covers the cursor line and other non-overlaid lines.

local M = {}

-- bufnr -> { [source] = { [row] = { {from,to,hl} } } }  (0-based inclusive cols)
local store = {}

-- Every range registered for a row, across sources. Read by the overlay.
function M.ranges_for(bufnr, row)
  local b = store[bufnr]
  if not b then
    return nil
  end
  local out
  for _, by_row in pairs(b) do
    local rs = by_row[row]
    if rs then
      out = out or {}
      for _, rg in ipairs(rs) do
        out[#out + 1] = rg
      end
    end
  end
  return out
end

-- Replace `source`'s ranges and repaint the overlay rows that changed (left ∪
-- entered). No-op for the overlay when it's off -- the raw highlight is all there is.
local function set(bufnr, source, by_row)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local b = store[bufnr] or {}
  store[bufnr] = b
  local old = b[source] or {}
  b[source] = by_row or {}
  local vok, view = pcall(require, 'custom.dans_frontend_cpp.view')
  if not (vok and view.is_enabled and view.is_enabled(bufnr)) then
    return
  end
  local changed = {}
  for row in pairs(old) do
    changed[row] = true
  end
  for row in pairs(by_row or {}) do
    changed[row] = true
  end
  for row in pairs(changed) do
    pcall(view.render_row, bufnr, row)
  end
end

-- ----------------------------------------------------------------- yank flash ----
local YANK_HL = 'IncSearch'
local YANK_MS = 150

-- Build per-row ranges for the just-yanked region (the `[` .. `]` marks) and flash
-- them on the overlay for YANK_MS, mirroring vim.hl.on_yank on the raw lines.
function M.flash_yank(bufnr)
  if (vim.v.event.regtype or ''):byte(1) == 22 then
    return -- block-wise: skip (rare; the raw flash still shows)
  end
  local linewise = vim.v.event.regtype == 'V'
  local a = vim.api.nvim_buf_get_mark(bufnr, '[')
  local z = vim.api.nvim_buf_get_mark(bufnr, ']')
  local r0, c0, r1, c1 = a[1] - 1, a[2], z[1] - 1, z[2]
  if r0 < 0 or r1 < r0 then
    return
  end
  -- The flash is visual: clamp to the on-screen rows so a whole-file yank
  -- doesn't build (and 150ms later clear) one range + repaint per buffer line.
  -- The original endpoints still decide which rows are partial (charwise cols).
  local or0, or1 = r0, r1
  local s0, e0 = require('custom.dans_frontend_cpp.util').visible_range(bufnr)
  r0, r1 = math.max(r0, s0), math.min(r1, e0 - 1)
  if r1 < r0 then
    return -- yanked region is entirely off-screen
  end
  local by_row = {}
  for row = r0, r1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local last = math.max(0, #line - 1)
    local from = (linewise or row > or0) and 0 or c0
    local to = (linewise or row < or1) and last or math.min(c1, last)
    by_row[row] = { { from = from, to = to, hl = YANK_HL } }
  end
  set(bufnr, 'yank', by_row)
  vim.defer_fn(function()
    set(bufnr, 'yank', {})
  end, YANK_MS)
end

-- ------------------------------------------------------- LSP reference / hover ----
-- Request documentHighlight ourselves and register single-line occurrences as
-- ranges, so the symbol-under-cursor highlight shows on rewritten lines too. The
-- builtin vim.lsp.buf.document_highlight still handles the raw (non-overlay) lines.
function M.update_references(bufnr)
  local vok, view = pcall(require, 'custom.dans_frontend_cpp.view')
  if not (vok and view.is_enabled and view.is_enabled(bufnr)) then
    return
  end
  local clients = vim.lsp.get_clients { bufnr = bufnr, method = 'textDocument/documentHighlight' }
  if #clients == 0 then
    return
  end
  local enc = clients[1].offset_encoding or 'utf-16'
  local params = vim.lsp.util.make_position_params(0, enc)
  vim.lsp.buf_request_all(bufnr, 'textDocument/documentHighlight', params, function(results)
    -- Overlay rows only exist on screen; keep the mirror set clamped so a
    -- symbol with hundreds of references doesn't trigger off-screen repaints.
    local s0, e0 = require('custom.dans_frontend_cpp.util').visible_range(bufnr)
    local by_row = {}
    for _, res in pairs(results or {}) do
      for _, h in ipairs((res or {}).result or {}) do
        local rng = h.range
        if rng and rng.start.line == rng['end'].line and rng['end'].character > rng.start.character then
          local row = rng.start.line
          if row >= s0 and row < e0 then
            by_row[row] = by_row[row] or {}
            by_row[row][#by_row[row] + 1] = { from = rng.start.character, to = rng['end'].character - 1, hl = 'LspReferenceText' }
          end
        end
      end
    end
    set(bufnr, 'reference', by_row)
  end)
end

function M.clear_references(bufnr)
  set(bufnr, 'reference', {})
end

return M
