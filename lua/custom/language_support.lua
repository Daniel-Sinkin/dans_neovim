-- Conventional, source-faithful support for languages outside the custom
-- C/C++/CUDA frontend.
--
-- Tree-sitter still parses the real source, but syntax captures are flattened
-- to Normal except comments/docstrings, which remain dim. LSP semantic tokens
-- are disabled per buffer so attaching a server cannot reintroduce a second
-- syntax palette; navigation, diagnostics, completion, code actions,
-- refactoring, document highlights, and optional inlay hints remain available.

local M = {}

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
local retry_generation = {}
local setup_done = false

local function is_dim_capture(name)
  return name == 'comment' or name:match('^comment%.') ~= nil or name == 'string.documentation'
end

function M.apply_monochrome(filetype)
  local language = M.languages[filetype]
  if not language then
    return false
  end

  local ok, query = pcall(vim.treesitter.query.get, language.query_language, 'highlights')
  if not ok or not query or not query.captures then
    return false
  end

  for _, name in ipairs(query.captures) do
    if not SKIP_CAPTURE[name] and name:sub(1, 1) ~= '_' then
      vim.api.nvim_set_hl(0, '@' .. name .. '.' .. language.query_language, {
        link = is_dim_capture(name) and 'Comment' or 'Normal',
      })
    end
  end
  return true
end

local function apply_all()
  for filetype in pairs(M.languages) do
    M.apply_monochrome(filetype)
  end
end

-- A parser in ensure_installed may still be compiling the first time a new
-- language buffer opens. Retry without blocking the editor so the initial
-- buffer becomes monochrome as soon as nvim-treesitter attaches the parser.
local function apply_with_retry(filetype)
  retry_generation[filetype] = (retry_generation[filetype] or 0) + 1
  local generation = retry_generation[filetype]
  local attempts_left = 120

  local function attempt()
    if retry_generation[filetype] ~= generation or M.apply_monochrome(filetype) then
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

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  apply_all()

  local group = vim.api.nvim_create_augroup('dans-language-support', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = apply_all,
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
        -- Semantic tokens are presentation only. Disabling them leaves every
        -- language-intelligence request and capability intact.
        pcall(vim.lsp.semantic_tokens.enable, false, { bufnr = event.buf })
      end
    end,
  })
end

return M
