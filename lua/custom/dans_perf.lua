-- Perf tooling for the config.
--
--   :DansPerf       toggle a main-thread responsiveness overlay (top-right).
--                   nvim doesn't render (Neovide does, and it doesn't report frame
--                   timing back), so this measures how well the main thread services
--                   a 60Hz libuv tick: when an autocmd/refresh blocks the loop the
--                   tick fires late, so the tick interval IS the main-thread frame
--                   time. Shows fps (1000/p50) + frametime p50/p95/p99/max.
--   :DansProfile    toggle the LuaJIT sampling profiler. Start it, do the slow
--                   thing, run it again to stop and open a sorted hot-spot report
--                   (by file:line). Catches everything Lua-side, not just the
--                   decoration modules.

local M = {}

-- ------------------------------------------------------------------ monitor ---

local TARGET_MS = 1000 / 60
local RING = 256
local mon = { on = false, timer = nil, win = nil, buf = nil, ring = {}, idx = 1, n = 0, last = 0, fires = 0 }

local function pct(sorted, q)
  if #sorted == 0 then
    return 0
  end
  local i = math.max(1, math.min(#sorted, math.ceil(q * #sorted)))
  return sorted[i]
end

local function mon_stats()
  local s = {}
  for i = 1, mon.n do
    s[i] = mon.ring[i]
  end
  table.sort(s)
  local p50 = pct(s, 0.50)
  return {
    fps = p50 > 0 and math.floor(1000 / p50 + 0.5) or 0,
    p50 = p50,
    p95 = pct(s, 0.95),
    p99 = pct(s, 0.99),
    max = #s > 0 and s[#s] or 0,
  }
end

local function mon_render()
  if not (mon.win and vim.api.nvim_win_is_valid(mon.win)) then
    return
  end
  local st = mon_stats()
  local line = string.format(' fps %2d  frame p50 %4.1f  p95 %4.1f  p99 %4.1f  max %5.1f ms ', st.fps, st.p50, st.p95, st.p99, st.max)
  vim.bo[mon.buf].modifiable = true
  vim.api.nvim_buf_set_lines(mon.buf, 0, -1, false, { line })
  vim.bo[mon.buf].modifiable = false
  local hl = st.p99 > TARGET_MS * 2.5 and 'DiagnosticError' or (st.p99 > TARGET_MS * 1.5 and 'DiagnosticWarn' or 'DiagnosticOk')
  vim.api.nvim_buf_clear_namespace(mon.buf, -1, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, mon.buf, vim.api.nvim_create_namespace 'ds_perf_mon', 0, 0, { line_hl_group = hl })
end

local function mon_open_win()
  mon.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[mon.buf].bufhidden = 'wipe'
  local width = 58
  mon.win = vim.api.nvim_open_win(mon.buf, false, {
    relative = 'editor',
    anchor = 'NE',
    width = width,
    height = 1,
    row = 0,
    col = vim.o.columns,
    focusable = false,
    style = 'minimal',
    border = 'none',
    noautocmd = true,
    zindex = 250,
  })
  vim.wo[mon.win].winblend = 10
end

function M.monitor_enabled()
  return mon.on
end

function M.monitor_toggle()
  if mon.on then
    mon.on = false
    if mon.timer then
      mon.timer:stop()
      mon.timer:close()
      mon.timer = nil
    end
    if mon.win and vim.api.nvim_win_is_valid(mon.win) then
      vim.api.nvim_win_close(mon.win, true)
    end
    mon.win, mon.buf = nil, nil
    return false
  end
  mon.on = true
  mon.ring, mon.idx, mon.n, mon.fires = {}, 1, 0, 0
  mon.last = (vim.uv or vim.loop).hrtime()
  mon_open_win()
  mon.timer = (vim.uv or vim.loop).new_timer()
  mon.timer:start(
    16,
    16,
    vim.schedule_wrap(function()
      if not mon.on then
        return
      end
      local now = (vim.uv or vim.loop).hrtime()
      local dt = (now - mon.last) / 1e6
      mon.last = now
      mon.ring[mon.idx] = dt
      mon.idx = mon.idx % RING + 1
      if mon.n < RING then
        mon.n = mon.n + 1
      end
      mon.fires = mon.fires + 1
      if mon.fires % 15 == 0 then
        mon_render()
      end
    end)
  )
  return true
end

-- ----------------------------------------------------------------- profiler ---

local prof = { on = false, counts = {}, total = 0 }

function M.profile_running()
  return prof.on
end

function M.profile_toggle()
  local ok, p = pcall(require, 'jit.profile')
  if not ok then
    vim.notify('jit.profile unavailable', vim.log.levels.ERROR)
    return
  end
  if not prof.on then
    prof.on = true
    prof.counts, prof.total = {}, 0
    -- 'i1' = sample the stack every 1ms; leaf frame as path:line.
    p.start('i1', function(thread)
      local loc = p.dumpstack(thread, 'pl', 1)
      prof.counts[loc] = (prof.counts[loc] or 0) + 1
      prof.total = prof.total + 1
    end)
    vim.notify('DANS profile: recording (run :DansProfile again to stop)', vim.log.levels.INFO)
    return
  end
  prof.on = false
  p.stop()
  local rows = {}
  for loc, c in pairs(prof.counts) do
    rows[#rows + 1] = { loc = loc, c = c }
  end
  table.sort(rows, function(a, b)
    return a.c > b.c
  end)
  local total = math.max(prof.total, 1)
  local lines = { string.format('DANS profile -- %d samples (~%dms), hottest leaf frames:', total, total), '' }
  for i = 1, math.min(40, #rows) do
    local r = rows[i]
    lines[#lines + 1] = string.format('%6.2f%%  %6d  %s', 100 * r.c / total, r.c, (r.loc:gsub('%s+$', '')))
  end
  vim.cmd 'botright 18new'
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].buftype = 'nofile'
  vim.bo[b].bufhidden = 'wipe'
  vim.bo[b].swapfile = false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
end

function M.setup()
  vim.api.nvim_create_user_command('DansPerf', M.monitor_toggle, { desc = 'Toggle the main-thread perf overlay' })
  vim.api.nvim_create_user_command('DansProfile', M.profile_toggle, { desc = 'Toggle the LuaJIT sampling profiler' })
end

return M
