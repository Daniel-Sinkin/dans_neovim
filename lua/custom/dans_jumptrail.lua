-- Jumplist trail for the statusline: the chain of files <C-o> would walk back
-- through, oldest on the left, the current file last --
--
--   vk_core.cpp -> camera.hpp -> main.cpp
--
-- Replaces the filename section of mini.statusline (see plugins/mini.lua), so
-- it lives on the bottom line of the active window only. Names are bare
-- filenames (with extension), consecutive jumps inside one file collapse to a
-- single node, and the whole trail is capped at 120 display columns -- older
-- entries fall off the left (marked `..`) so the current file never drifts to
-- the right edge of a wide window. A file that belongs to a known library
-- (SDL/GLFW, Vulkan, VMA, stb, Dear ImGui, BLAS/LAPACK, LLDB) is tinted in
-- that library's color, same prefixes as the in-buffer coloring.

local M = {}

local MAX_COLS = 120

-- filename (lowercased) -> library highlight group, mirroring markers.lua's
-- identifier prefixes. vk_* is first-party (brighter); vulkan*/vk* is the lib.
local function file_hl(name)
  local l = name:lower()
  if l:match '^vk_' then
    return 'DansVulkanMine'
  end
  if l:match '^vulkan' or l:match '^vk' or l:match '^vma' then
    return l:match '^vma' and 'DansVMA' or 'DansVulkan'
  end
  if l:match '^sdl' or l:match '^glfw' or l:match '^_glfw' then
    return 'DansSDL'
  end
  if l:match '^stb' then
    return 'DansSTB'
  end
  if l:match '^imgui' or l:match '^im_' then
    return 'DansImGui'
  end
  if l:match '^cblas' or l:match '^openblas' or l:match '^lapack' or l:match '^blas' then
    return 'DansBLAS'
  end
  if l:match '^lldb' then
    return 'DansLLDB'
  end
  if l:match '^glad' or l:match '^gl3w' or l:match '^glcorearb' then
    return 'DansVulkan'
  end
  return nil
end

-- Statusline-safe variant of a library group: same fg, the statusline body's
-- bg (a bare fg-only group would punch a Normal-bg hole into the bar). Built
-- lazily, rebuilt after a colorscheme change.
local sl_cache = {}
local function sl_group(base)
  local name = base .. 'Sl'
  if sl_cache[name] then
    return name
  end
  local ok, src = pcall(vim.api.nvim_get_hl, 0, { name = base, link = false })
  local okb, body = pcall(vim.api.nvim_get_hl, 0, { name = 'MiniStatuslineFilename', link = false })
  vim.api.nvim_set_hl(0, name, {
    fg = ok and src.fg or nil,
    bg = okb and body.bg or nil,
    bold = base == 'DansTrailCurrent' or nil,
  })
  sl_cache[name] = true
  return name
end

-- The current-file emphasis group (defined from Normal's fg on first use).
local function ensure_current_group()
  if sl_cache.DansTrailCurrent then
    return
  end
  local ok, n = pcall(vim.api.nvim_get_hl, 0, { name = 'Normal', link = false })
  vim.api.nvim_set_hl(0, 'DansTrailCurrent', { fg = ok and n.fg or nil })
  sl_cache.DansTrailCurrent = true
end

-- The trail entries for the current window, current file LAST:
-- { { name, hl|nil }, ... }. Consecutive same-file jumps collapse.
local function entries()
  local jl = vim.fn.getjumplist()
  local jumps, pos = jl[1], jl[2]
  local out = {} -- built newest-first, reversed at the end
  local function push(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    local full = vim.api.nvim_buf_get_name(bufnr)
    if full == '' then
      return
    end
    local name = vim.fn.fnamemodify(full, ':t')
    if name == '' or (out[#out] and out[#out].name == name) then
      return
    end
    out[#out + 1] = { name = name, hl = file_hl(name) }
  end
  push(vim.api.nvim_get_current_buf())
  -- jumps[pos] is where one <C-o> lands, jumps[pos-1] the next, ... (pos ==
  -- #jumps while at the live end of the list).
  for i = math.min(pos, #jumps), 1, -1 do
    push(jumps[i].bufnr)
  end
  -- reverse: oldest first, current last
  local rev = {}
  for i = #out, 1, -1 do
    rev[#rev + 1] = out[i]
  end
  return rev
end

-- Statusline-format trail string ('%#Group#name%#MiniStatuslineFilename# -> ...'),
-- capped at MAX_COLS display columns (older entries fall off, '..' marks the cut).
function M.statusline()
  local es = entries()
  if #es == 0 then
    return '%f%m%r'
  end
  ensure_current_group()
  -- walk from the current file leftwards, budgeting display columns
  local width = vim.fn.strdisplaywidth(es[#es].name)
  local first = #es
  for i = #es - 1, 1, -1 do
    local w = vim.fn.strdisplaywidth(es[i].name) + 4 -- ' -> '
    if width + w > MAX_COLS then
      break
    end
    width = width + w
    first = i
  end
  local parts = {}
  if first > 1 then
    parts[#parts + 1] = '.. -> '
  end
  for i = first, #es do
    if i > first then
      parts[#parts + 1] = ' -> '
    end
    local e = es[i]
    local name = e.name:gsub('%%', '%%%%')
    local grp = e.hl and sl_group(e.hl) or (i == #es and sl_group 'DansTrailCurrent' or nil)
    if grp then
      parts[#parts + 1] = '%#' .. grp .. '#' .. name .. '%#MiniStatuslineFilename#'
    else
      parts[#parts + 1] = name
    end
  end
  parts[#parts + 1] = '%m%r'
  return table.concat(parts)
end

function M.setup()
  -- statusline-variant groups bake in fg+bg pairs; a colorscheme swap changes
  -- both, so drop the cache and let them rebuild on next render.
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('ds_jumptrail', { clear = true }),
    callback = function()
      sl_cache = {}
    end,
  })
end

return M
