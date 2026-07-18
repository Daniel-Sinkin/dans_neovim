-- Macro highlighting driven by the project's actual `#define`s instead of an
-- "all-caps must be a macro" guess. On opening a directory it scans recursively
-- (ripgrep, async) for `#define NAME` and colors exactly those names; a header
-- save merges that file's new defines. With no scan available (rg missing, empty,
-- or a scratch file) it falls back to the old all-caps heuristic so something
-- still reads as a macro.
--
-- Coloring is membership-by-lookup over the on-screen range (reusing the frontend
-- decoration infra: visible range, the debounced settled event, is_scrolling), so
-- the set can be any size without a giant matchadd alternation. Library-prefixed
-- tokens (VK_/SDL_/stb/...) are skipped -- markers.lua already colors those.
--
--   :DansMacros        toggle macro coloring for the buffer
--   :DansMacrosRescan  re-scan the project now

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'
local ns = vim.api.nvim_create_namespace 'ds_macros'

local CPP_FT = { c = true, cpp = true, cuda = true }
local DEFINE_GLOBS = '*.{h,hpp,hxx,hh,c,cc,cpp,cxx,cu,cuh,inl,ipp,ixx}'

-- nil until a scan finishes; then a set of macro name -> true.
M.names = nil
local enabled = {} -- bufnr -> bool; nil = default on

-- `def` is the trailing-return function macro; markers colors it green-bold like
-- lambda/defer, so keep the purple macro coloring off it.
local DENY = { FILE = true, SEEK_SET = true, SEEK_CUR = true, SEEK_END = true, EOF = true, NULL = true, def = true }

-- Common standard-library macros. The rg scan only covers the project, not the
-- stdlib headers, so these would never be found there -- color them as macros via
-- this curated set instead (EXIT_FAILURE etc.). Add more here as you hit them.
local STDLIB = {}
for _, name in ipairs {
  'EXIT_SUCCESS', 'EXIT_FAILURE', 'RAND_MAX', 'BUFSIZ', 'CHAR_BIT', 'MB_LEN_MAX',
  'SCHAR_MIN', 'SCHAR_MAX', 'UCHAR_MAX', 'CHAR_MIN', 'CHAR_MAX',
  'SHRT_MIN', 'SHRT_MAX', 'USHRT_MAX', 'INT_MIN', 'INT_MAX', 'UINT_MAX',
  'LONG_MIN', 'LONG_MAX', 'ULONG_MAX', 'LLONG_MIN', 'LLONG_MAX', 'ULLONG_MAX',
  'INT8_MIN', 'INT8_MAX', 'INT16_MIN', 'INT16_MAX', 'INT32_MIN', 'INT32_MAX',
  'INT64_MIN', 'INT64_MAX', 'UINT8_MAX', 'UINT16_MAX', 'UINT32_MAX', 'UINT64_MAX',
  'INTPTR_MIN', 'INTPTR_MAX', 'UINTPTR_MAX', 'INTMAX_MIN', 'INTMAX_MAX', 'UINTMAX_MAX',
  'SIZE_MAX', 'PTRDIFF_MIN', 'PTRDIFF_MAX', 'WCHAR_MIN', 'WCHAR_MAX', 'WINT_MIN', 'WINT_MAX',
  'FLT_MIN', 'FLT_MAX', 'FLT_EPSILON', 'FLT_DIG', 'FLT_RADIX', 'FLT_MANT_DIG',
  'DBL_MIN', 'DBL_MAX', 'DBL_EPSILON', 'DBL_DIG', 'DBL_MANT_DIG',
  'LDBL_MIN', 'LDBL_MAX', 'LDBL_EPSILON',
  'HUGE_VAL', 'HUGE_VALF', 'INFINITY', 'NAN',
  'M_PI', 'M_E', 'M_SQRT2', 'M_SQRT1_2', 'M_PI_2', 'M_PI_4', 'M_1_PI', 'M_2_PI',
  'M_LN2', 'M_LN10', 'M_LOG2E', 'M_LOG10E',
  'va_start', 'va_arg', 'va_end', 'va_copy', 'offsetof',
} do
  STDLIB[name] = true
end

-- Tokens markers.lua already colors as their own library -- leave them to it.
local function is_library(t)
  return t:match '^VK_' ~= nil
    or t:match '^Vk' ~= nil
    or t:match '^vk%u' ~= nil
    or t:match '^VK%u' ~= nil -- first-party wrapper VKBuffer / lib VKAPI_*
    or t:match '^vk_' ~= nil
    or t:match '^VMA_' ~= nil
    or t:match '^Vma' ~= nil
    or t:match '^vma%u' ~= nil
    or t:match '^GL_' ~= nil
    or t:match '^gl%u' ~= nil
    or t:match '^SDL_' ~= nil
    or t:match '^GLFW' ~= nil
    or t:match '^glfw%u' ~= nil
    or t:match '^_GLFW' ~= nil
    or t:match '^_glfw' ~= nil
    or t:match '^IM_' ~= nil
    or t:match '^Im%u' ~= nil
    or t:match '^stb' ~= nil
    or t:match '^STB' ~= nil
    or t:match '^cblas_' ~= nil
    or t:match '^CBLAS_' ~= nil
    or t:match '^Cblas%u' ~= nil
    or t:match '^openblas_' ~= nil
    or t:match '^OPENBLAS_' ~= nil
    or t:match '^lapacke?_' ~= nil
    or t:match '^LAPACKE?_' ~= nil
    or t == 'blasint'
    or t:match '^LLDB_' ~= nil
    or t:match '^SB%u' ~= nil
    or t == 'StateType'
end

local function is_macro(tok)
  if DENY[tok] or is_library(tok) then
    return false
  end
  if STDLIB[tok] then
    return true -- a known stdlib macro, regardless of the project scan
  end
  if M.names then
    return M.names[tok] == true
  end
  -- no scan yet: fall back to the all-caps heuristic (>=2 chars).
  return #tok >= 2 and tok:match '^[A-Z][A-Z0-9_]*$' ~= nil
end

local function is_on(bufnr)
  return enabled[bufnr] ~= false
end

-- Color macro identifiers on one line, skipping `//` comments and "..." strings.
local function color_line(bufnr, row0, line)
  local i, n = 1, #line
  local in_str = false
  while i <= n do
    local c = line:sub(i, i)
    if in_str then
      if c == '\\' then
        i = i + 2
      else
        if c == '"' then
          in_str = false
        end
        i = i + 1
      end
    elseif c == '"' then
      in_str = true
      i = i + 1
    elseif c == '/' and line:sub(i + 1, i + 1) == '/' then
      break
    elseif c:match '[%a_]' then
      local s = i
      while i <= n and line:sub(i, i):match '[%w_]' do
        i = i + 1
      end
      local tok = line:sub(s, i - 1)
      -- in_literal (treesitter) catches block comments / doc comments the cheap
      -- text scan above misses, so a `#define`d word like `types` in a `/* */`
      -- doc block isn't colored as a macro.
      if is_macro(tok) and not vu.in_literal(bufnr, row0, s - 1) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, { end_col = i - 1, hl_group = 'DansMacro', priority = 120 })
      end
    else
      i = i + 1
    end
  end
end

local function refresh(bufnr)
  if not (vim.api.nvim_buf_is_valid(bufnr) and CPP_FT[vim.bo[bufnr].filetype]) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not is_on(bufnr) then
    return
  end
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  for i, line in ipairs(lines) do
    color_line(bufnr, s0 + i - 1, line)
  end
end

M.refresh = refresh

local function refresh_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      refresh(b)
    end
  end
end

-- Merge `#define` names found in `lines` into the set (used by a header save, and
-- to seed before the async scan returns).
local function harvest(lines)
  M.names = M.names or {}
  for _, line in ipairs(lines) do
    local name = line:match '^%s*#%s*define%s+([%a_][%w_]*)'
    if name then
      M.names[name] = true
    end
  end
end

local scanning = false
local function scan()
  if scanning or vim.fn.executable 'rg' ~= 1 then
    return -- rg missing -> M.names stays nil -> all-caps fallback
  end
  scanning = true
  local cmd = {
    'rg',
    '-N',
    '-o',
    '--no-filename',
    '-r',
    '$1',
    '-g',
    DEFINE_GLOBS,
    [[^\s*#\s*define\s+([A-Za-z_]\w*)]],
    vim.fn.getcwd(),
  }
  local ok = pcall(vim.system, cmd, { text = true }, function(res)
    scanning = false
    if not res or not res.stdout or res.stdout == '' then
      return
    end
    local set = {}
    for name in res.stdout:gmatch '[^\r\n]+' do
      set[name] = true
    end
    vim.schedule(function()
      M.names = set
      refresh_all()
    end)
  end)
  if not ok then
    scanning = false
  end
end

function M.is_enabled(bufnr)
  return is_on(bufnr)
end

function M.set_enabled(bufnr, on)
  if on then
    enabled[bufnr] = nil
  else
    enabled[bufnr] = false
  end
  refresh(bufnr)
end

function M.setup()
  vim.api.nvim_create_autocmd({ 'VimEnter', 'DirChanged' }, {
    group = vim.api.nvim_create_augroup('ds_macros_scan', { clear = true }),
    callback = scan,
  })
  scan() -- in case setup runs after VimEnter

  local group = vim.api.nvim_create_augroup('ds_macros', { clear = true })
  -- a header save can introduce new macros: merge that file's defines, repaint.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { '*.h', '*.hpp', '*.hxx', '*.hh', '*.c', '*.cc', '*.cpp', '*.cxx', '*.cu', '*.cuh', '*.inl', '*.ipp', '*.ixx' },
    callback = function(ev)
      harvest(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false))
      refresh_all()
    end,
  })
  -- repaint on edits and the debounced scroll-settled event. No CursorMoved:
  -- the coloring doesn't reveal on the cursor line (it conceals nothing), so a
  -- pure cursor move changes none of its output.
  vu.on_decorate(group, { 'FileType', 'BufEnter', 'TextChanged', 'TextChangedI' }, refresh)

  vim.api.nvim_create_user_command('DansMacrosRescan', scan, { desc = 'Re-scan the project for #define macros' })
  vim.api.nvim_create_user_command('DansMacros', function()
    local b = vim.api.nvim_get_current_buf()
    M.set_enabled(b, not is_on(b))
    vim.notify('macro coloring ' .. (is_on(b) and 'on' or 'off'), vim.log.levels.INFO)
  end, { desc = 'Toggle #define-driven macro coloring' })
end

return M
