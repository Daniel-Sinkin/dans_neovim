-- Fuzzy finder (files, lsp, etc). On master rather than the stale 0.1.x branch
-- so the LSP pickers use the Neovim 0.11 APIs without deprecation warnings.
return {
  'nvim-telescope/telescope.nvim',
  event = 'VimEnter',
  dependencies = {
    'nvim-lua/plenary.nvim',
    {
      'nvim-telescope/telescope-fzf-native.nvim',
      -- Windows has no make/gcc by default; build the native lib with CMake
      -- (clang/MSVC) instead. Other platforms keep the make build.
      build = vim.fn.has 'win32' == 1
          and 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build'
        or 'make',
      cond = function()
        if vim.fn.has 'win32' == 1 then
          return vim.fn.executable 'cmake' == 1
        end
        return vim.fn.executable 'make' == 1
      end,
    },
    { 'nvim-telescope/telescope-ui-select.nvim' },
    { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
  },
  config = function()
    require('telescope').setup {
      defaults = {
        file_ignore_patterns = { '[/\\]build[/\\]', '^build[/\\]' },
      },
      extensions = {
        ['ui-select'] = {
          require('telescope.themes').get_dropdown(),
        },
      },
    }

    pcall(require('telescope').load_extension, 'fzf')
    pcall(require('telescope').load_extension, 'ui-select')

    local builtin = require 'telescope.builtin'

    -- A ripgrep jump should land on a visible line: after the default select,
    -- open every fold in the file jumped into (the C++ view opens files folded).
    local function grep_unfold(opts)
      opts = opts or {}
      opts.attach_mappings = function(prompt_bufnr, map)
        map({ 'i', 'n' }, '<CR>', function()
          require('telescope.actions').select_default(prompt_bufnr)
          vim.schedule(function()
            pcall(function()
              require('custom.dans_frontend_cpp.fold').open_all()
            end)
          end)
        end)
        return true
      end
      return opts
    end

    vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
    vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
    vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
    vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = '[F]ind [F]iles' })
    vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
    vim.keymap.set('n', '<leader>sw', function()
      builtin.grep_string(grep_unfold())
    end, { desc = '[S]earch current [W]ord' })
    vim.keymap.set('n', '<leader>sg', function()
      builtin.live_grep(grep_unfold())
    end, { desc = '[S]earch by [G]rep' })
    vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
    -- The inlay error text is virtual (extmarks), so ripgrep can't see it; the
    -- diagnostics picker is the greppable list of everything currently flagged.
    -- `se` = this file, `sE` = every diagnosed file (clangd only reports for
    -- files that have been opened, which matches "what I'd actually see").
    vim.keymap.set('n', '<leader>se', function()
      builtin.diagnostics(grep_unfold { bufnr = 0, prompt_title = 'Errors/warnings (this file)' })
    end, { desc = '[S]earch [E]rrors in current file' })
    vim.keymap.set('n', '<leader>sE', function()
      builtin.diagnostics(grep_unfold { prompt_title = 'Errors/warnings (all files)' })
    end, { desc = '[S]earch [E]rrors in all files' })
    vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
    vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
    vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

    vim.keymap.set('n', '<leader>/', function()
      -- ripgrep the current file only (live regex search). An unnamed/scratch
      -- buffer has nothing on disk to grep, so fall back to the in-buffer fuzzy
      -- finder there.
      local file = vim.api.nvim_buf_get_name(0)
      if file == '' then
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
        return
      end
      builtin.live_grep(grep_unfold {
        search_dirs = { file },
        prompt_title = 'Grep current file',
      })
    end, { desc = '[/] Grep current file (ripgrep)' })

    vim.keymap.set('n', '<leader>s/', function()
      builtin.live_grep(grep_unfold {
        grep_open_files = true,
        prompt_title = 'Live Grep in Open Files',
      })
    end, { desc = '[S]earch [/] in Open Files' })

    vim.keymap.set('n', '<leader>sn', function()
      builtin.find_files { cwd = vim.fn.stdpath 'config' }
    end, { desc = '[S]earch [N]eovim files' })
  end,
}
