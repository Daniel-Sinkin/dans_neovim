-- Global presentation-mode controller for C/C++/CUDA plus the shared
-- monochrome preference used by conventional language buffers.
--
-- There are deliberately two independent owner-facing choices:
--   * frontend: the Odin/Jai-like presentation layer and its supporting views;
--   * monochrome: flattened syntax highlighting for source-faithful display.
--
-- The frontend requires monochrome so its provenance colors remain the only
-- semantic colors.  Therefore effective monochrome is:
--
--     frontend_enabled OR requested_monochrome
--
-- `requested_monochrome` is remembered while the frontend forces the effective
-- value on for buffers where that frontend can actually render. C#, Python, and
-- other non-frontend buffers follow the remembered monochrome preference
-- directly, so the menu can restore their ordinary language colors even while
-- the C++ frontend remains enabled elsewhere.

local M = {}

local CPP_FT = { c = true, cpp = true, cuda = true }
local FRONTEND_MENU_EXT = {
  c = true,
  cc = true,
  cpp = true,
  cu = true,
  cuh = true,
  h = true,
  hh = true,
  hpp = true,
}
local setup_done = false

local function bool_default(value, default)
  if value == nil then
    return default
  end
  return value == true
end

function M.frontend_enabled()
  return bool_default(vim.g.dans_frontend_enabled, true)
end

function M.monochrome_requested()
  return bool_default(vim.g.dans_monochrome_requested, true)
end

local function normalized_bufnr(bufnr)
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function is_cpp(bufnr)
  bufnr = normalized_bufnr(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and CPP_FT[vim.bo[bufnr].filetype] == true
end

function M.frontend_menu_available(bufnr)
  bufnr = normalized_bufnr(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local extension = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':e'):lower()
  return FRONTEND_MENU_EXT[extension] == true
end

function M.monochrome_effective(bufnr)
  if bufnr ~= nil then
    return (is_cpp(bufnr) and M.frontend_enabled()) or M.monochrome_requested()
  end
  return M.frontend_enabled() or M.monochrome_requested()
end

function M.monochrome_locked(bufnr)
  if bufnr ~= nil then
    return is_cpp(bufnr) and M.frontend_enabled()
  end
  return M.frontend_enabled()
end

local function in_buffer_window(bufnr, callback)
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_call(winid, callback)
  else
    vim.api.nvim_buf_call(bufnr, callback)
  end
end

local function set_frontend_modules(bufnr, on)
  if not is_cpp(bufnr) then
    return
  end
  -- Token mode suppresses and later restores the frontend itself.  End it before
  -- applying the global state so that restoration cannot overwrite this choice.
  local tokenizer = require 'custom.dans_tokenizer'
  if tokenizer.is_enabled(bufnr) then
    tokenizer.disable(bufnr)
  end

  in_buffer_window(bufnr, function()
    local frontend = require 'custom.dans_frontend_cpp'
    for _, name in ipairs(frontend.TOGGLEABLE) do
      frontend.module_set(name, bufnr, on)
    end
    require('custom.cpp_doc_markdown').set_enabled(bufnr, on)
    require('custom.dans_macros').set_enabled(bufnr, on)
    require('custom.dans_frontend_cpp.scope').set_enabled(bufnr, on)
  end)
end

local function set_highlighter(bufnr, monochrome)
  if not is_cpp(bufnr) then
    return
  end
  if monochrome then
    -- Stop only the highlighter. Parsers remain available to the frontend.
    pcall(vim.treesitter.stop, bufnr)
  else
    pcall(vim.treesitter.start, bufnr)
  end
end

local function apply_buffer(bufnr)
  if not is_cpp(bufnr) then
    return
  end
  set_frontend_modules(bufnr, M.frontend_enabled())
  set_highlighter(bufnr, M.monochrome_effective(bufnr))
end
M.apply_buffer = apply_buffer

local function apply_loaded_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(apply_buffer, bufnr)
    end
  end
end

-- Re-source the active colorscheme.  Its ColorScheme callbacks either flatten
-- after the event settles or deliberately no-op when normal color is effective.
local function repick_colorscheme()
  local name = vim.g.colors_name
  if not name or name == '' or name == 'cp-monochrome' then
    name = 'tokyonight'
  end
  pcall(vim.cmd.colorscheme, name)
end

local function apply_global(previous_monochrome, repick_required)
  local effective = M.monochrome_effective()
  -- Compatibility for older callbacks/config fragments while the old vanilla
  -- module is retired: true now means normal source colors are effective.
  vim.g.dans_vanilla = not effective
  if previous_monochrome ~= effective or repick_required then
    repick_colorscheme()
  end
  apply_loaded_buffers()
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'DansDisplayModeChanged' })
end

function M.set_frontend(on, options)
  options = options or {}
  on = on == true
  local previous_monochrome = M.monochrome_effective()
  vim.g.dans_frontend_enabled = on
  apply_global(previous_monochrome)
  if not options.silent then
    vim.notify('dans frontend ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
  end
  return on
end

function M.toggle_frontend(options)
  return M.set_frontend(not M.frontend_enabled(), options)
end

function M.set_monochrome(on, options)
  options = options or {}
  if M.monochrome_locked(options.bufnr) then
    if not options.silent then
      vim.notify('monochrome is required while the dans frontend is on', vim.log.levels.INFO)
    end
    return false, 'locked'
  end
  on = on == true
  local changed = M.monochrome_requested() ~= on
  local previous_monochrome = M.monochrome_effective()
  vim.g.dans_monochrome_requested = on
  -- A non-frontend language can change the requested palette while the C++
  -- frontend keeps the process-wide effective value true. Re-source the theme
  -- anyway so language-qualified normal colors can be reconstructed.
  apply_global(previous_monochrome, changed)
  if not options.silent then
    vim.notify('dans monochrome ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
  end
  return true
end

function M.toggle_monochrome(options)
  return M.set_monochrome(not M.monochrome_requested(), options)
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  if vim.g.dans_frontend_enabled == nil then
    vim.g.dans_frontend_enabled = true
  end
  if vim.g.dans_monochrome_requested == nil then
    vim.g.dans_monochrome_requested = true
  end
  vim.g.dans_vanilla = not M.monochrome_effective()

  local group = vim.api.nvim_create_augroup('ds_display_mode', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(event)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(event.buf) then
          apply_buffer(event.buf)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    pattern = { '*.c', '*.cc', '*.cpp', '*.cxx', '*.h', '*.hh', '*.hpp', '*.hxx', '*.cu', '*.cuh' },
    callback = function(event)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(event.buf) then
          apply_buffer(event.buf)
        end
      end)
    end,
  })
  apply_loaded_buffers()
end

return M
