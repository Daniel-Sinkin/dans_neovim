-- A single, persistent bottom-right widget for julials startup progress.
--
-- julials runs several $/progress cycles on startup and sends spurious `end`s
-- mid-load, which makes fidget flicker open/closed and show misleading
-- "complete"s. This collapses all of it into one status line: the live
-- message plus elapsed time. The widget opens the instant a Julia file starts
-- a fresh julials (not 9s later when the first report arrives), and simply
-- vanishes once julials is genuinely idle - it never shows a "ready"/"done"
-- text, so it can't claim to be finished while work continues. fidget is told
-- to ignore julials (see init.lua) so only this widget renders it.

local M = {}

local GRACE_MS = 5000 -- linger after `end`; a follow-up report cancels the close
local CAP_MS = 120000 -- safety: dismiss if a final `end` never arrives

local state = {
  buf = nil,
  win = nil,
  tick = nil, -- repeating redraw timer (elapsed counter)
  closer = nil, -- one-shot grace-close timer
  start = 0, -- uv.now() ms the widget is counting from
  frozen = nil, -- elapsed ms frozen while idle (between `end` and next report)
  msg = '',
}

local function fmt_elapsed(ms)
  local s = math.floor(ms / 1000)
  if s >= 60 then
    return string.format('%dm %02ds', math.floor(s / 60), s % 60)
  end
  return s .. 's'
end

local function stop_timer(t)
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
  end
end

local function destroy()
  stop_timer(state.tick)
  stop_timer(state.closer)
  state.tick, state.closer = nil, nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.start = 0
  state.frozen = nil
  state.msg = ''
end

local function render()
  if state.start == 0 then
    return
  end
  local ms = state.frozen or (vim.uv.now() - state.start)
  local text = string.format('  julials   %s   %s  ', state.msg ~= '' and state.msg or 'starting...', fmt_elapsed(ms))

  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { text })

  local cfg = {
    relative = 'editor',
    anchor = 'SE',
    row = vim.o.lines - 1,
    col = vim.o.columns,
    width = vim.fn.strdisplaywidth(text),
    height = 1,
    style = 'minimal',
    focusable = false,
    zindex = 60,
  }
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_config(state.win, cfg)
  else
    state.win = vim.api.nvim_open_win(state.buf, false, cfg)
    vim.api.nvim_set_option_value('winhighlight', 'Normal:JuliaProgress', { win = state.win })
  end
end

local function tick()
  if state.start ~= 0 and not state.frozen and (vim.uv.now() - state.start) > CAP_MS then
    destroy()
  else
    render()
  end
end

local tick_scheduled = vim.schedule_wrap(tick)

---Open the widget (if not already) and keep it alive.
local function activity()
  if state.start == 0 then
    state.start = vim.uv.now()
  end
  state.frozen = nil
  if state.closer then
    stop_timer(state.closer)
    state.closer = nil
  end
  if not state.tick then
    state.tick = vim.uv.new_timer()
    state.tick:start(0, 1000, tick_scheduled)
  end
  tick_scheduled()
end

---A terminal `end`: freeze the counter and linger, so a follow-up report can
---cancel the close (julials sends `end` then keeps reporting). If nothing
---follows within the grace window, the widget vanishes.
local function finish()
  if state.start == 0 then
    return
  end
  state.frozen = vim.uv.now() - state.start
  tick_scheduled()
  if state.closer then
    stop_timer(state.closer)
  end
  state.closer = vim.uv.new_timer()
  state.closer:start(GRACE_MS, 0, vim.schedule_wrap(destroy))
end

local function on_progress(value)
  if value.kind == 'begin' or value.kind == 'report' then
    if value.message and value.message ~= '' then
      state.msg = value.message
    elseif value.kind == 'begin' and value.title and value.title ~= '' then
      state.msg = value.title
    end
    activity()
  elseif value.kind == 'end' then
    finish()
  end
end

local function is_julials(client_id)
  local client = client_id and vim.lsp.get_client_by_id(client_id)
  return client ~= nil and client.name == 'julials'
end

function M.setup()
  vim.api.nvim_set_hl(0, 'JuliaProgress', { link = 'NormalFloat', default = true })

  local group = vim.api.nvim_create_augroup('ds-julia-progress', { clear = true })

  -- Open the widget the instant a Julia file triggers a fresh julials, so it
  -- is visible for the whole startup. Skip when julials is already running
  -- (this is just another buffer) or the widget is already up.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'julia',
    callback = function()
      if state.start ~= 0 or #vim.lsp.get_clients { name = 'julials' } > 0 then
        return
      end
      state.msg = ''
      activity()
    end,
  })

  vim.api.nvim_create_autocmd('LspProgress', {
    group = group,
    callback = function(ev)
      if not is_julials(ev.data and ev.data.client_id) then
        return
      end
      local value = ev.data.params and ev.data.params.value
      if value then
        on_progress(value)
      end
    end,
  })

  vim.api.nvim_create_autocmd('LspDetach', {
    group = group,
    callback = function(ev)
      if is_julials(ev.data.client_id) then
        destroy()
      end
    end,
  })
end

return M
