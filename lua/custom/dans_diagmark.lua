-- Diagnostics as a first-character mark instead of end-of-line text. The
-- built-in virtual text is restricted to the cursor line (see plugins/lsp.lua:
-- `virtual_text = { current_line = true }`), so hovering a line shows the full
-- message; every other diagnosed line just gets its FIRST cell painted -- red
-- background for an error, orange for a warning -- a quiet left-edge flag that
-- never pushes text around or fights the frontend overlay. The line number is
-- tinted too, so a line whose first cell sits under an overlay still shows it.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_diagmark'

local function set_hl()
  -- background-only groups: the glyph underneath keeps its own fg.
  vim.api.nvim_set_hl(0, 'DansDiagMarkError', { bg = '#9d2f3f' })
  vim.api.nvim_set_hl(0, 'DansDiagMarkWarn', { bg = '#96632a' })
  vim.api.nvim_set_hl(0, 'DansDiagMarkErrorNr', { fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'DansDiagMarkWarnNr', { fg = '#e0af68', bold = true })
end

local SEV = vim.diagnostic.severity
local MARK = {
  [SEV.ERROR] = { hl = 'DansDiagMarkError', nr = 'DansDiagMarkErrorNr' },
  [SEV.WARN] = { hl = 'DansDiagMarkWarn', nr = 'DansDiagMarkWarnNr' },
}

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- worst severity per line (ERROR < WARN in the enum)
  local worst = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if MARK[d.severity] then
      local w = worst[d.lnum]
      if not w or d.severity < w then
        worst[d.lnum] = d.severity
      end
    end
  end
  if not next(worst) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for lnum, sev in pairs(worst) do
    local line = lines[lnum + 1]
    if line then
      local mk = MARK[sev]
      if #line > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum, 0, {
          end_col = 1,
          hl_group = mk.hl,
          number_hl_group = mk.nr,
          priority = 5000,
        })
      else
        -- empty line: no cell to paint, overlay a one-cell block instead
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum, 0, {
          virt_text = { { ' ', mk.hl } },
          virt_text_pos = 'overlay',
          number_hl_group = mk.nr,
          priority = 5000,
        })
      end
    end
  end
end

M.refresh = refresh

function M.setup()
  set_hl()
  local group = vim.api.nvim_create_augroup('ds_diagmark', { clear = true })
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
  -- marks are buffer-local extmarks, but a TextChanged can move/orphan the
  -- col-0 anchor; re-pin on idle so edits don't smear the cell.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'InsertLeave' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
end

return M
