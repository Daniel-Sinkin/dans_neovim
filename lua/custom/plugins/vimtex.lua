-- LaTeX project editing, compilation and PDF synchronization.
--
-- VimTeX explicitly must not be lazy-loaded by the plugin manager: its global
-- inverse-search command has to exist before a PDF viewer calls back into a
-- fresh Neovim process.  VimTeX still does its substantive work through its own
-- filetype/autoload gates.
return {
  'lervag/vimtex',
  lazy = false,
  init = function()
    -- LaTeX stays literal source: no \alpha -> α replacement, hidden command,
    -- or concealed delimiter.  Syntax highlighting remains enabled.
    vim.g.vimtex_syntax_conceal_disable = 1
    vim.g.vimtex_fold_enabled = 0

    -- latexmk is VimTeX's recommended/default backend. Continuous compilation
    -- starts only when requested with <localleader>ll and stops with the same
    -- toggle or <localleader>lk; merely opening/saving a document does not start
    -- a compiler from this configuration.
    vim.g.vimtex_compiler_method = 'latexmk'

    -- Prefer viewers with useful SyncTeX support. This Fedora host has Okular;
    -- the remaining branches keep the config usable on macOS and leaner hosts.
    if vim.fn.has 'mac' == 1 and vim.fn.executable 'skim' == 1 then
      vim.g.vimtex_view_method = 'skim'
    elseif vim.fn.executable 'zathura' == 1 then
      vim.g.vimtex_view_method = 'zathura'
    elseif vim.fn.executable 'okular' == 1 then
      vim.g.vimtex_view_method = 'general'
      vim.g.vimtex_view_general_viewer = 'okular'
      vim.g.vimtex_view_general_options = '--unique file:@pdf\\#src:@line@tex'
    elseif vim.fn.executable 'mupdf' == 1 then
      vim.g.vimtex_view_method = 'mupdf'
    else
      vim.g.vimtex_view_method = 'general'
    end
  end,
  config = function()
    -- VimTeX supplies these mappings itself; restating the core set as buffer
    -- mappings adds discoverable descriptions for which-key without changing
    -- the plugin's <Plug> behavior.
    local group = vim.api.nvim_create_augroup('dans-vimtex-maps', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = { 'tex', 'plaintex' },
      callback = function(event)
        local function map(lhs, rhs, description)
          vim.keymap.set('n', lhs, rhs, {
            buffer = event.buf,
            remap = true,
            silent = true,
            desc = description,
          })
        end
        map('<localleader>ll', '<Plug>(vimtex-compile)', 'LaTeX compile toggle')
        map('<localleader>lv', '<Plug>(vimtex-view)', 'LaTeX PDF view / forward search')
        map('<localleader>lk', '<Plug>(vimtex-stop)', 'LaTeX stop compiler')
        map('<localleader>le', '<Plug>(vimtex-errors)', 'LaTeX compilation errors')
        map('<localleader>lt', '<Plug>(vimtex-toc-open)', 'LaTeX table of contents')
        map('<localleader>lc', '<Plug>(vimtex-clean)', 'LaTeX clean auxiliary files')
      end,
    })
  end,
}
