-- A rolling log of the last N keys (mouse included), so when something flashes
-- open you can see exactly what triggered it. `:DansKeylog` (or the DANS menu ->
-- Tools) shows it, newest at the bottom; mouse double-clicks/drags appear as
-- `<2-LeftMouse>` / `<LeftDrag>` / `<LeftRelease>`, which is usually the answer to
-- "why did that menu appear".
--
-- Always-on and cheap: one vim.on_key handler appending to a ring buffer. Mouse
-- *moves* are dropped (they flood); everything else is kept.

local M = {}

local MAX = 80
local log = {} -- ring of { mode = 'n', key = '<2-LeftMouse>' }
local recording = true

local function record(key, typed)
  if not recording then
    return
  end
  local raw = (typed ~= nil and typed ~= '') and typed or key
  if not raw or raw == '' then
    return
  end
  local ok, s = pcall(vim.fn.keytrans, raw)
  if not ok or s == '' or s:find 'MouseMove' or s:find 'ScrollWheel' then
    return -- mouse-move / scroll-wheel flood is noise
  end
  log[#log + 1] = { mode = vim.api.nvim_get_mode().mode, key = s }
  if #log > MAX then
    table.remove(log, 1)
  end
end

function M.show()
  local lines = {}
  for _, e in ipairs(log) do
    lines[#lines + 1] = string.format('[%-3s] %s', e.mode, e.key)
  end
  if #lines == 0 then
    lines = { '(nothing recorded yet)' }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local width = 24
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, math.max(8, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    anchor = 'SE',
    row = vim.o.lines - 2,
    col = vim.o.columns - 1,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' key log (newest below) ',
    title_pos = 'center',
  })
  pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 }) -- scroll to newest

  -- pause recording while the viewer is up so scrolling it doesn't pollute the log
  recording = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    recording = true
  end
  for _, k in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', k, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })
end

function M.setup()
  vim.on_key(record, vim.api.nvim_create_namespace 'ds_keylog')
  vim.api.nvim_create_user_command('DansKeylog', M.show, {
    desc = 'Show the recent key/mouse log (what triggered something)',
  })
end

return M
