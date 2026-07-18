-- Platform-aware preprocessor conditionals. A `#if defined(_GLFW_WIN32)` block is
-- dead code on a Mac and live code on Windows; rather than coloring every `#if`
-- the same gray, evaluate the condition against THIS machine's platform and:
--   - active branch   -> left normal
--   - inactive branch -> grayed (DansInactive) and folded
--
-- Only platform / windowing-system / vulkan-platform macros are known (see KNOWN),
-- and only single-term conditions (`defined(X)`, `!defined(X)`, `#ifdef`, bare
-- known macro, integer literal) are evaluated. If ANY branch of a group is
-- undecidable (an unknown macro, a `&&`/`||` expression) the whole group is left
-- normal -- never gray code that might be live. Folding is wired in fold.lua; this
-- module owns the graying extmarks. Gated like the rest of the frontend.

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'
local ns = vim.api.nvim_create_namespace 'ds_ppif'

-- macro -> set of platforms on which it is considered defined. Kept to OS /
-- windowing-system / vulkan-platform macros; compiler macros (_MSC_VER, __GNUC__)
-- are intentionally absent -- they're toolchain, not platform.
local KNOWN = {
  _WIN32 = { win = true },
  _WIN64 = { win = true },
  WIN32 = { win = true },
  __WIN32__ = { win = true },
  _GLFW_WIN32 = { win = true },
  VK_USE_PLATFORM_WIN32_KHR = { win = true },
  __APPLE__ = { mac = true },
  __MACH__ = { mac = true },
  _GLFW_COCOA = { mac = true },
  VK_USE_PLATFORM_MACOS_MVK = { mac = true },
  VK_USE_PLATFORM_METAL_EXT = { mac = true },
  __linux__ = { linux = true },
  __linux = { linux = true },
  _GLFW_X11 = { linux = true },
  _GLFW_WAYLAND = { linux = true },
  VK_USE_PLATFORM_XCB_KHR = { linux = true },
  VK_USE_PLATFORM_XLIB_KHR = { linux = true },
  VK_USE_PLATFORM_WAYLAND_KHR = { linux = true },
  __unix__ = { mac = true, linux = true },
  __unix = { mac = true, linux = true },
}

-- Compiler axis. Conditions on the toolchain (`_MSC_VER`, `__GNUC__`, ...) and the
-- `__has_cpp_attribute(...)` feature test are evaluated against THIS toolchain --
-- clang, the compiler you build with. Flip COMPILER if you switch. clang defines
-- `__GNUC__`/`__GNUG__` for compatibility, so those are true here too.
local COMPILER = 'clang'
local COMPILER_MACROS = {
  __clang__ = { clang = true },
  __llvm__ = { clang = true },
  __GNUC__ = { clang = true, gcc = true },
  __GNUG__ = { clang = true, gcc = true },
  _MSC_VER = { msvc = true },
  _MSC_FULL_VER = { msvc = true },
  _MSVC_LANG = { msvc = true },
  __MINGW32__ = { mingw = true },
  __MINGW64__ = { mingw = true },
  __INTEL_COMPILER = { intel = true },
}

-- Standard C++ attributes clang supports, so `__has_cpp_attribute(X)` is non-zero
-- (active). An attribute NOT here is left undecided (nil), never assumed dead.
local HAS_CPP_ATTR = {}
for _, a in ipairs {
  'noreturn', 'carries_dependency', 'deprecated', 'fallthrough', 'nodiscard',
  'maybe_unused', 'likely', 'unlikely', 'no_unique_address', 'assume',
} do
  HAS_CPP_ATTR[a] = true
end

local _plat
function M.platform()
  if _plat then
    return _plat
  end
  -- mac is also unix, so test it first.
  if vim.fn.has 'mac' == 1 or vim.fn.has 'macunix' == 1 then
    _plat = 'mac'
  elseif vim.fn.has 'win32' == 1 or vim.fn.has 'win64' == 1 then
    _plat = 'win'
  elseif vim.fn.has 'unix' == 1 then
    _plat = 'linux'
  else
    _plat = 'unknown'
  end
  return _plat
end

-- true / false / nil(=unknown) for whether `macro` is defined on `plat`.
local function eval_defined(macro, plat)
  local k = KNOWN[macro]
  if k then
    return k[plat] == true
  end
  local c = COMPILER_MACROS[macro]
  if c then
    return c[COMPILER] == true
  end
  return nil
end

-- Evaluate a `#if`/`#elif` expression to true/false/nil. Handles a single term
-- with an optional leading `!`: `defined(X)`, `defined X`, a bare macro, or an
-- integer literal. Anything with operators is nil (don't guess).
local function eval_expr(expr, plat)
  expr = vim.trim(expr)
  local neg = false
  local inner = expr:match '^!%s*(.+)$'
  if inner then
    neg, expr = true, vim.trim(inner)
  end
  local v
  local attr = expr:match '^__has_cpp_attribute%s*%(%s*([%w_:]+)%s*%)$'
  local m = expr:match '^defined%s*%(%s*([%w_]+)%s*%)$' or expr:match '^defined%s+([%w_]+)$'
  if attr then
    -- a vendor-namespaced check (msvc::no_unique_address) tests the bare name.
    v = HAS_CPP_ATTR[attr:gsub('^.*::', '')] and true or nil
  elseif m then
    v = eval_defined(m, plat)
  elseif expr:match '^%d+$' then
    v = tonumber(expr) ~= 0
  elseif expr:match '^[%w_]+$' then
    v = eval_defined(expr, plat) -- bare macro: only decidable if it's a known one
  else
    v = nil -- compound expression: leave undecided
  end
  if v == nil then
    return nil
  end
  if neg then
    return not v
  end
  return v
end

local function eval_directive(dir, rest, plat)
  if dir == 'ifdef' then
    return eval_expr('defined(' .. vim.trim(rest) .. ')', plat)
  elseif dir == 'ifndef' then
    return eval_expr('!defined(' .. vim.trim(rest) .. ')', plat)
  end
  return eval_expr(rest, plat) -- if / elif
end

-- Inactive {s, e} ranges (1-based inclusive), each an `#if`/`#elif`/`#else` branch
-- known to be dead on `plat`. Pure -- the spec drives this directly.
function M.inactive_ranges(lines, plat)
  plat = plat or M.platform()
  local top, stack = {}, {}
  local function cur_children()
    if #stack == 0 then
      return top
    end
    local f = stack[#stack]
    return f.branches[#f.branches].children
  end
  for i, line in ipairs(lines) do
    local dir, rest = line:match '^%s*#%s*(%a+)%s*(.-)%s*$'
    if dir == 'if' or dir == 'ifdef' or dir == 'ifndef' then
      local g = { if_line = i, branches = {} }
      g.branches[1] = { open = i, cond = eval_directive(dir, rest, plat), is_else = false, children = {} }
      table.insert(cur_children(), g)
      stack[#stack + 1] = g
    elseif dir == 'elif' or dir == 'else' then
      if #stack > 0 then
        local g = stack[#stack]
        g.branches[#g.branches].content_to = i - 1
        if dir == 'elif' then
          g.branches[#g.branches + 1] = { open = i, cond = eval_directive('elif', rest, plat), is_else = false, children = {} }
        else
          g.branches[#g.branches + 1] = { open = i, cond = true, is_else = true, children = {} }
        end
      end
    elseif dir == 'endif' then
      if #stack > 0 then
        local g = table.remove(stack)
        g.branches[#g.branches].content_to = i - 1
        g.endif_line = i
      end
    end
  end

  local out = {}
  local function decidable(g)
    for _, b in ipairs(g.branches) do
      if not b.is_else and b.cond == nil then
        return false
      end
    end
    return true
  end
  local function walk(groups)
    for _, g in ipairs(groups) do
      if g.endif_line and decidable(g) then
        local active
        for idx, b in ipairs(g.branches) do
          local is_active = b.is_else and (active == nil) or (active == nil and b.cond == true)
          if is_active and active == nil then
            active = idx
          end
        end
        for idx, b in ipairs(g.branches) do
          if idx ~= active then
            if b.content_to and b.content_to >= b.open then
              out[#out + 1] = { b.open, b.content_to }
            end
          else
            walk(b.children) -- only descend into the live branch
          end
        end
      end
    end
  end
  walk(top)
  return out
end

-- inactive_ranges over the buffer, cached per changedtick. Both this module's
-- refresh and the foldexpr (fold.lua) consume the ranges on the same tick, so
-- the whole-buffer directive scan runs once per edit instead of twice.
local range_cache = {}
function M.buf_inactive_ranges(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = range_cache[bufnr]
  if not (c and c.tick == tick) then
    c = { tick = tick, ranges = M.inactive_ranges(vu.buf_lines(bufnr)) }
    range_cache[bufnr] = c
  end
  return c.ranges
end

local function refresh(bufnr)
  if not (vim.api.nvim_buf_is_valid(bufnr) and vu.is_cpp(vim.bo[bufnr].filetype)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'ppif') then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  for _, r in ipairs(M.buf_inactive_ranges(bufnr)) do
    -- one multi-line highlight over the dead branch; high priority so it overrides
    -- syntax / treesitter and reads as one uniform gray.
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, r[1] - 1, 0, {
      end_row = r[2],
      end_col = 0,
      hl_group = 'DansInactive',
      hl_eol = true,
      priority = 1000,
    })
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_ppif', { clear = true })
  vu.on_decorate(group, { 'FileType', 'BufEnter', 'TextChanged', 'TextChangedI' }, refresh)
end

return M
