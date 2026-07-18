-- dans-cpp-frontend: a view-only re-render of C/C++/CUDA in an Odin/Pascal-like
-- style -- const hidden, mut/cpy surfaced, `T*` -> `T^`, `optional<T>` -> `T?`,
-- declarations shown as `name: T = value`, and so on. Nothing in the buffer is
-- modified; it is all conceal + virt_text.
--
-- This is the umbrella. Each feature lives in its own module under
-- custom.dans_frontend_cpp.* with its own autocmds and `ds_*` namespace, so it
-- can be read, changed, and toggled in isolation. setup() wires them up and owns
-- the :DansFrontend command.
--
--   :DansFrontend            toggle the whole frontend for the buffer
--   :DansFrontend <module>   toggle one module (view/aliases/markers/pointer/
--                            designated/fold/arrow_align) -- tab-completed
--   :DansFrontend hints      toggle clangd deduced-type hints
--   :DansFrontend lambda     toggle the lambda-as-function rendering
--   :DansFrontend tokens     toggle the tokenizer coloring view (plain
--                            text, every other coloring source suppressed)
local M = {}

-- setup() order preserved from the original flat layout (aliases before the
-- view, decorations after) so nothing ordering-dependent shifts.
local SETUP_ORDER = { 'aliases', 'markers', 'ppif', 'view', 'arrow_align', 'enum_align', 'special_members', 'pointer', 'designated', 'logic', 'macro_def', 'fold', 'lint' }

-- Modules :DansFrontend can toggle per buffer. 'view' is the declaration overlay
-- (its own enable/disable); the rest are decoration / lint modules gated by
-- util.module_enabled and re-rendered through their M.refresh.
local TOGGLEABLE = { 'view', 'aliases', 'markers', 'ppif', 'pointer', 'designated', 'logic', 'macro_def', 'fold', 'arrow_align', 'enum_align', 'special_members', 'lint' }

local function mod(name)
  return require('custom.dans_frontend_cpp.' .. name)
end

local function util()
  return require 'custom.dans_frontend_cpp.util'
end

local function is_on(name, buf)
  if name == 'view' then
    return mod('view').is_enabled(buf)
  end
  return util().module_enabled(buf, name)
end

local function set_on(name, buf, on)
  if name == 'view' then
    mod('view').set_enabled(buf, on)
  else
    util().set_module(buf, name, on)
    mod(name).refresh(buf)
  end
end

-- Public surface for the config menu (custom.dans_menu): the toggleable module
-- names and per-buffer get/set, wrapping the same logic :DansFrontend drives.
M.TOGGLEABLE = TOGGLEABLE
function M.module_is_on(name, buf)
  return is_on(name, buf)
end
function M.module_set(name, buf, on)
  set_on(name, buf, on)
end

-- Repaint every decoration source for `buf`: refresh the toggleable modules
-- directly (covers markers / arrow_align / lint, which aren't on the settled
-- event) and fire VIEWPORT_SETTLED for the overlay (view) and doc markdown, both
-- of which listen to it. `view` has no public refresh and `fold` is intentionally
-- left untouched, so both are skipped in the loop. Used by the record-suspend
-- hooks to clear / restore in one shot.
local function repaint_all(buf)
  for _, name in ipairs(TOGGLEABLE) do
    if name ~= 'fold' and name ~= 'view' then
      pcall(function()
        mod(name).refresh(buf)
      end)
    end
  end
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = util().VIEWPORT_SETTLED })
end

local function dispatch(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local sub = vim.trim(cmd.args or '')
  if sub == 'hints' then
    mod('view').toggle_hints()
  elseif sub == 'lambda' then
    mod('view').toggle_lambda()
  elseif sub == 'tokens' then
    require('custom.dans_tokenizer').toggle(buf)
  elseif sub == '' then
    -- The master state is global because monochrome highlight links are global.
    -- Individual subcommands remain for compatibility/experiments, but the
    -- owner-facing control lives in :Dans.
    require('custom.dans_mode').toggle_frontend()
  elseif vim.tbl_contains(TOGGLEABLE, sub) then
    local on = not is_on(sub, buf)
    set_on(sub, buf, on)
    vim.notify('dans-cpp-frontend ' .. sub .. ' ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
  else
    vim.notify('DansFrontend: unknown argument "' .. sub .. '"', vim.log.levels.WARN)
  end
end

local function complete(arglead)
  local opts = vim.list_extend(vim.deepcopy(TOGGLEABLE), { 'hints', 'lambda', 'tokens' })
  return vim.tbl_filter(function(s)
    return s:find(arglead, 1, true) == 1
  end, opts)
end

function M.setup()
  util().setup_viewport_debounce()
  for _, name in ipairs(SETUP_ORDER) do
    require('custom.dans_frontend_cpp.' .. name).setup()
  end
  vim.api.nvim_create_user_command('DansFrontend', dispatch, {
    nargs = '?',
    complete = complete,
    desc = 'Toggle the dans-cpp-frontend view, a single module, or hints / lambda',
  })
  -- Suspend the column-shifting view transforms while a macro records, so recorded
  -- motions operate on real buffer columns instead of concealed / virt_text ones,
  -- then restore on stop. Opt out with `vim.g.dans_suspend_on_record = false`.
  local rec_group = vim.api.nvim_create_augroup('ds_frontend_record', { clear = true })
  vim.api.nvim_create_autocmd({ 'RecordingEnter', 'RecordingLeave' }, {
    group = rec_group,
    callback = function(ev)
      if vim.g.dans_suspend_on_record == false then
        return
      end
      util().set_recording(ev.event == 'RecordingEnter')
      repaint_all(vim.api.nvim_get_current_buf())
    end,
  })
end

return M
