-- Conventional, source-faithful support for languages outside the custom
-- C/C++/CUDA frontend.
--
-- Tree-sitter always parses the real source. The shared Dans monochrome
-- preference either flattens language-qualified captures to Normal (with dim
-- comments/docstrings) or restores a snapshot of the colorscheme's ordinary
-- capture palette. LSP semantic tokens remain disabled so a server cannot add a
-- second, independent coloring layer; navigation, diagnostics, completion,
-- code actions, refactoring, document highlights, and inlay hints remain
-- available.

local M = {}
local Mode = require 'custom.dans_mode'

M.languages = {
  cs = {
    query_language = 'c_sharp',
    missing_executable = 'dotnet',
    missing_message = 'C# editing is active, but Roslyn needs the .NET SDK (`dotnet` on PATH) before LSP navigation can attach.',
  },
  python = {
    query_language = 'python',
  },
}

local SKIP_CAPTURE = { spell = true, nospell = true, conceal = true, none = true }
local normal_palettes = {}
local retry_generation = {}
local setup_done = false

local function is_dim_capture(name)
  return name == 'comment' or name:match('^comment%.') ~= nil or name == 'string.documentation'
end

local function highlight_query(filetype)
  local language = M.languages[filetype]
  if not language then
    return nil, nil
  end
  local ok, query = pcall(vim.treesitter.query.get, language.query_language, 'highlights')
  if not ok or not query or not query.captures then
    return language, nil
  end
  return language, query
end

-- Tree-sitter resolves @a.b.language through progressively broader capture
-- names. Snapshot that resolved colorscheme appearance before the C++ frontend's
-- scheduled global flattening runs, then install it on the language-qualified
-- group so normal Python/C# colors can coexist with a monochrome C++ window.
local function normal_capture_attributes(name)
  local parts = vim.split(name, '.', { plain = true })
  while #parts > 0 do
    local attributes = vim.api.nvim_get_hl(0, {
      name = '@' .. table.concat(parts, '.'),
      link = false,
    })
    if next(attributes) ~= nil then
      return attributes
    end
    parts[#parts] = nil
  end
  return vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
end

local function snapshot_normal_palettes()
  for filetype, language in pairs(M.languages) do
    local _, query = highlight_query(filetype)
    if query then
      local palette = {}
      for _, name in ipairs(query.captures) do
        if not SKIP_CAPTURE[name] and name:sub(1, 1) ~= '_' then
          palette[name] = normal_capture_attributes(name)
        end
      end
      normal_palettes[language.query_language] = palette
    end
  end
end

function M.apply_presentation(filetype)
  local language, query = highlight_query(filetype)
  if not language or not query then
    return false
  end

  local monochrome = Mode.monochrome_requested()
  local palette = normal_palettes[language.query_language] or {}
  for _, name in ipairs(query.captures) do
    if not SKIP_CAPTURE[name] and name:sub(1, 1) ~= '_' then
      local attributes
      if monochrome then
        attributes = { link = is_dim_capture(name) and 'Comment' or 'Normal' }
      else
        attributes = palette[name] or normal_capture_attributes(name)
      end
      vim.api.nvim_set_hl(0, '@' .. name .. '.' .. language.query_language, attributes)
    end
  end
  return true
end

local function apply_all()
  for filetype in pairs(M.languages) do
    M.apply_presentation(filetype)
  end
end

-- A parser in ensure_installed may still be compiling the first time a new
-- language buffer opens. Retry without blocking the editor so the initial
-- buffer receives the selected presentation as soon as its query is available.
local function apply_with_retry(filetype)
  retry_generation[filetype] = (retry_generation[filetype] or 0) + 1
  local generation = retry_generation[filetype]
  local attempts_left = 120

  local function attempt()
    if retry_generation[filetype] ~= generation or M.apply_presentation(filetype) then
      return
    end
    attempts_left = attempts_left - 1
    if attempts_left > 0 then
      vim.defer_fn(attempt, 250)
    end
  end
  attempt()
end

local function reveal_source()
  vim.opt_local.conceallevel = 0
  vim.opt_local.concealcursor = ''
end

local function warn_missing_dependency(filetype)
  local language = M.languages[filetype]
  if not language or not language.missing_executable then
    return
  end
  if vim.fn.executable(language.missing_executable) == 1 or #vim.api.nvim_list_uis() == 0 then
    return
  end
  vim.schedule(function()
    vim.notify_once(language.missing_message, vim.log.levels.WARN, { title = 'Language support' })
  end)
end

local function reapply_loaded_languages()
  apply_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and M.languages[vim.bo[bufnr].filetype] then
      -- Semantic tokens are presentation only. Keeping them disabled leaves
      -- every language-intelligence request and capability intact while the
      -- Tree-sitter palette remains the single coloring source in either mode.
      pcall(vim.lsp.semantic_tokens.enable, false, { bufnr = bufnr })
    end
  end
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  apply_all()

  local group = vim.api.nvim_create_augroup('dans-language-support', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      snapshot_normal_palettes()
      -- The C++ palette's global flatten is scheduled from an earlier
      -- ColorScheme callback. Land language-qualified captures after it.
      vim.schedule(apply_all)
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DansDisplayModeChanged',
    callback = function()
      vim.schedule(reapply_loaded_languages)
    end,
  })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = vim.tbl_keys(M.languages),
    callback = function(event)
      apply_with_retry(event.match)
      reveal_source()
      warn_missing_dependency(event.match)
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(event)
      if M.languages[vim.bo[event.buf].filetype] then
        reveal_source()
      end
    end,
  })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(event)
      if M.languages[vim.bo[event.buf].filetype] then
        pcall(vim.lsp.semantic_tokens.enable, false, { bufnr = event.buf })
      end
    end,
  })
end

return M
