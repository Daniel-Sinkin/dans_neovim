-- View-only lint (vim.diagnostic; no source change): flag the C gotcha where one
-- declaration mixes a pointer/reference declarator with a plain one --
-- `int* x, y;` makes x an `int*` but y a plain `int`, because the `*` binds only
-- to the first declarator. clang-tidy's readability-isolate-declaration flags
-- *every* multi-declaration; this is narrower (only the misleading mixed case)
-- and runs live in the editor. Toggle with `:DansFrontend lint`.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_frontend_lint'
local vu = require 'custom.dans_frontend_cpp.util'

local DECL_QUERY = [[
  (declaration) @decl
  (field_declaration) @decl
]]

-- A declarator that carries a `*`/`&` (so the decoration is easy to mistake for
-- applying to the whole declaration): a (possibly init-wrapped) pointer/reference.
local function decorated(node)
  local t = node:type()
  if t == 'pointer_declarator' or t == 'reference_declarator' then
    return true
  end
  if t == 'init_declarator' then
    local inner = node:field('declarator')[1]
    return inner ~= nil and (inner:type() == 'pointer_declarator' or inner:type() == 'reference_declarator')
  end
  return false
end

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vu.is_cpp(vim.bo[bufnr].filetype) or not vu.module_enabled(bufnr, 'lint') then
    vim.diagnostic.reset(ns, bufnr)
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return
  end
  local okq, q = pcall(vim.treesitter.query.parse, parser:lang(), DECL_QUERY)
  if not okq or not q then
    return
  end
  local diags = {}
  for _, node in q:iter_captures(trees[1]:root(), bufnr, 0, -1) do
    local declarators = node:field 'declarator'
    if #declarators > 1 then
      local has_decorated, has_plain = false, false
      for _, d in ipairs(declarators) do
        if decorated(d) then
          has_decorated = true
        else
          has_plain = true
        end
      end
      if has_decorated and has_plain then
        local sr, sc, er, ec = node:range()
        diags[#diags + 1] = {
          lnum = sr,
          col = sc,
          end_lnum = er,
          end_col = ec,
          severity = vim.diagnostic.severity.WARN,
          source = 'dans-frontend',
          message = '`*`/`&` binds only to the first declarator here -- split into one declaration per line',
        }
      end
    end
  end
  vim.diagnostic.set(ns, bufnr, diags)
end

M.refresh = refresh

-- Debounced: the whole-buffer declaration query is too heavy to run per
-- TextChanged during normal-mode churn (dd spam, macro replay); the lint
-- catching up ~200ms after the last change is imperceptible for diagnostics.
local timers = {}
local function schedule(buf)
  local t = timers[buf]
  if t then
    t:stop()
  else
    t = (vim.uv or vim.loop).new_timer()
    timers[buf] = t
  end
  t:start(
    200,
    0,
    vim.schedule_wrap(function()
      refresh(buf)
    end)
  )
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_frontend_lint', { clear = true })
  vim.api.nvim_create_autocmd({ 'FileType', 'BufWritePost', 'InsertLeave', 'TextChanged' }, {
    group = group,
    callback = function(ev)
      schedule(ev.buf)
    end,
  })
end

return M
