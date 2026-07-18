-- Per-buffer presentation profiles for decisions that are deliberately still
-- under evaluation.  The production/default profile is immutable here: tools
-- such as the browser style lab may attach a small override table to a scratch
-- buffer, but opening ordinary source always receives these defaults.
--
-- This module is intentionally boring.  Renderers ask it for a typed option at
-- the point where spelling is chosen; experiments never monkey-patch renderer
-- functions or mutate process-global state.  That keeps simultaneous real and
-- experimental buffers independent and makes every candidate reproducible in
-- the headless harness.

local M = {}

local DEFAULTS = {
  -- Concrete lvalue references use the same const-default rule as deduced
  -- references: absence of `mut` means read-only. Pointer parameters remain
  -- explicit because pointee and pointer-object constness are independent axes.
  concrete_reference_const = 'const_default',
  -- The selected semantic accent is shared by optional/expected question marks.
  -- The owner's font rendered ∅ poorly, so std::nullopt retains its word spelling
  -- in production while the empty-set candidate remains buffer-local (DEC-015).
  optional_marker_accent = 'gold',
  nullopt_spelling = 'word',
  -- Weak pointers are non-owning pointer-like handles whose lock may fail. The
  -- compact default shows both facts; the style lab can compare equal-width
  -- marker variants without disturbing alignment.
  weak_pointer_marker = 'caret_optional',
}

local VALID = {
  concrete_reference_const = {
    explicit = true,
    const_default = true,
  },
  optional_marker_accent = {
    neutral = true,
    cyan = true,
    gold = true,
    violet = true,
  },
  nullopt_spelling = {
    word = true,
    empty_set = true,
  },
  weak_pointer_marker = {
    caret_optional = true,
    tilde_optional = true,
    caret_weak = true,
  },
}

local OPTIONAL_HL = {
  cyan = 'DansOptionalCyan',
  gold = 'DansOptionalGold',
  violet = 'DansOptionalViolet',
}

M.DEFAULTS = vim.deepcopy(DEFAULTS)

local function overrides(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local value = vim.b[bufnr].dans_frontend_style_profile
  return type(value) == 'table' and value or nil
end

function M.get(bufnr, key)
  assert(DEFAULTS[key] ~= nil, 'unknown frontend style option: ' .. tostring(key))
  local profile = overrides(bufnr)
  local value = profile and profile[key] or DEFAULTS[key]
  assert(VALID[key][value], string.format('invalid frontend style option %s=%s', key, vim.inspect(value)))
  return value
end

-- Validate and install overrides before FileType/autocmd rendering begins.
-- Intended for scratch buffers owned by deterministic tests and the style lab.
function M.set_buffer_profile(bufnr, profile)
  assert(vim.api.nvim_buf_is_valid(bufnr), 'invalid buffer for frontend style profile')
  assert(type(profile) == 'table', 'frontend style profile must be a table')
  local clean = {}
  for key, value in pairs(profile) do
    assert(DEFAULTS[key] ~= nil, 'unknown frontend style option: ' .. tostring(key))
    assert(VALID[key][value], string.format('invalid frontend style option %s=%s', key, vim.inspect(value)))
    clean[key] = value
  end
  vim.b[bufnr].dans_frontend_style_profile = clean
end

function M.profile(bufnr)
  local out = vim.deepcopy(DEFAULTS)
  for key, value in pairs(overrides(bufnr) or {}) do
    out[key] = value
  end
  return out
end

function M.optional_marker_hl(bufnr, fallback)
  return OPTIONAL_HL[M.get(bufnr, 'optional_marker_accent')] or fallback or 'Normal'
end

function M.weak_pointer_parts(bufnr)
  local value = M.get(bufnr, 'weak_pointer_marker')
  if value == 'tilde_optional' then
    return '~', '?'
  elseif value == 'caret_weak' then
    return '^', 'w'
  end
  return '^', '?'
end

return M
