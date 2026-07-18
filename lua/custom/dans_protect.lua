-- Open files you shouldn't edit read-only (nomodifiable + readonly), so an
-- accidental edit/:w is blocked. Two sources:
--   * the standard library / system headers / other repos -- detected as "a
--     c/cpp/cuda buffer whose file is OUTSIDE the project root". No per-device
--     stdlib paths to hardcode: anything not under your project is external.
--   * paths matching a glob in `.dans_protected` at the project root (one per
--     line, # comments ok), e.g. `vendor/*`. The same file is read by the
--     pre-commit hook (scripts/dans-protect-precommit.sh), so editor and commit
--     guard agree.
-- Override a single buffer with `:set modifiable` / `:w!`; disable entirely with
-- `vim.g.dans_protect = false`.

local M = {}

local IS_WIN = vim.fn.has 'win32' == 1
local CPP_FT = { c = true, cpp = true, cuda = true }

local function norm(p)
  p = (p or ''):gsub('\\', '/')
  return IS_WIN and p:lower() or p
end

-- git root above `dir`, else cwd.
local function project_root(dir)
  local git = vim.fs.find('.git', { path = dir, upward = true })[1]
  return norm(git and vim.fs.dirname(git) or vim.fn.getcwd())
end

-- Protected globs from <root>/.dans_protected (cached per root + mtime).
local cache = {}
local function patterns(root)
  local file = root .. '/.dans_protected'
  local mtime = vim.fn.getftime(file)
  local c = cache[root]
  if c and c.mtime == mtime then
    return c.pats
  end
  local pats = {}
  if mtime >= 0 then
    for _, line in ipairs(vim.fn.readfile(file)) do
      local g = vim.trim(line)
      if g ~= '' and g:sub(1, 1) ~= '#' then
        -- glob -> lua pattern: escape magic, `*` -> `.*`, anchored at the start.
        local lua = '^' .. norm(g):gsub('[%(%)%.%%%+%-%[%]%^%$]', '%%%1'):gsub('%*', '.*')
        pats[#pats + 1] = lua
      end
    end
  end
  cache[root] = { mtime = mtime, pats = pats }
  return pats
end

-- Returns true + a reason if the buffer's file must not be edited.
function M.is_protected(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return false
  end
  local abs = norm(vim.fn.fnamemodify(name, ':p'))
  local root = project_root(vim.fs.dirname(abs))
  if abs:sub(1, #root + 1) ~= root .. '/' then
    -- outside the project: only guard code files (stdlib/system headers), so an
    -- out-of-tree note/config you open on purpose stays editable.
    if CPP_FT[vim.bo[buf].filetype] then
      return true, 'standard library / outside the project'
    end
    return false
  end
  local rel = abs:sub(#root + 2)
  for _, pat in ipairs(patterns(root)) do
    if rel:match(pat) then
      return true, 'matches .dans_protected'
    end
  end
  return false
end

local function guard(buf)
  if vim.g.dans_protect == false or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local protected, why = M.is_protected(buf)
  if protected then
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.notify('protected (' .. why .. '): read-only. :set ma to override.', vim.log.levels.WARN)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_protect', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group,
    callback = function(ev)
      guard(ev.buf)
    end,
  })
end

return M
