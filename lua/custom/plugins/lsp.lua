-- LSP configuration. clangd is configured manually (not via mason). julials
-- uses LanguageServer.jl in ~/.julia/environments/nvim-lspconfig with a custom
-- root_dir picking the OUTERMOST Project.toml so nested layouts don't spawn
-- duplicate clients (see private/AGENTS.md).

-- clangd answers documentHighlight on a control-flow keyword with the whole
-- related flow (every return of the function, a loop plus its continues and
-- breaks), which reads as stray syntax coloring on the monochrome buffers.
-- Keywords are never symbols, so the cursor-hold request skips them outright.
local FLOW_KEYWORDS = {
  ['return'] = true,
  ['if'] = true,
  ['else'] = true,
  ['for'] = true,
  ['while'] = true,
  ['do'] = true,
  ['switch'] = true,
  ['case'] = true,
  ['default'] = true,
  ['break'] = true,
  ['continue'] = true,
  ['goto'] = true,
  ['try'] = true,
  ['catch'] = true,
  ['throw'] = true,
  ['co_return'] = true,
  ['co_await'] = true,
  ['co_yield'] = true,
}

return {
  {
    -- Lua LSP for Neovim config / runtime / plugins.
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'WhoIsSethDaniel/mason-tool-installer.nvim' },
      { 'williamboman/mason.nvim', opts = {} },

      -- julials is rendered by custom.julia_progress instead (one stable
      -- widget); fidget still handles every other LSP.
      { 'j-hui/fidget.nvim', opts = { progress = { ignore = { 'julials' } } } },
    },
    config = function()
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('dans-lsp-attach', { clear = true }),
        callback = function(event)
          local function map(keys, action, description, modes)
            vim.keymap.set(modes or 'n', keys, action, {
              buffer = event.buf,
              desc = ('LSP: %s'):format(description),
            })
          end

          -- gd jumps to the definition, but when you're already standing ON a
          -- definition (a function def has no other origin) clangd returns only the
          -- current spot -- fall through to "find all references" there, which is
          -- what you actually want. (Replaces the buggy <leader>D type-definition
          -- jump, which matched a function's return type from its name.)
          local function goto_def_or_refs()
            vim.lsp.buf.definition {
              on_list = function(opts)
                local here = vim.api.nvim_win_get_cursor(0)[1]
                local file = vim.api.nvim_buf_get_name(0)
                local elsewhere = false
                for _, it in ipairs(opts.items or {}) do
                  if it.lnum ~= here or it.filename ~= file then
                    elsewhere = true
                    break
                  end
                end
                if elsewhere then
                  require('telescope.builtin').lsp_definitions()
                else
                  require('telescope.builtin').lsp_references()
                end
              end,
            }
          end
          map('gd', goto_def_or_refs, '[G]oto [D]efinition (or references when on one)')
          local telescope = require('telescope.builtin')
          local telescope_bindings = {
            { 'gr', 'lsp_references', '[G]oto [R]eferences' },
            { 'gI', 'lsp_implementations', '[G]oto [I]mplementation' },
            { '<leader>ds', 'lsp_document_symbols', '[D]ocument [S]ymbols' },
            { '<leader>ws', 'lsp_dynamic_workspace_symbols', '[W]orkspace [S]ymbols' },
          }
          for _, binding in ipairs(telescope_bindings) do
            map(binding[1], telescope[binding[2]], binding[3])
          end
          local builtin_bindings = {
            { '<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame' },
            { '<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction', { 'n', 'x' } },
            { 'gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration' },
          }
          for _, binding in ipairs(builtin_bindings) do
            map(binding[1], binding[2], binding[3], binding[4])
          end

          local attached_client_id = event.data.client_id
          local client = vim.lsp.get_client_by_id(attached_client_id)
          local function supports(method)
            return client and client:supports_method(method, event.buf)
          end
          -- Drop LSP semantic tokens for C/C++/CUDA; the monochrome theme in
          -- treesitter.lua re-introduces color via classic syntax instead.
          -- server_capabilities is shared across all of the client's buffers, so
          -- nilling it isn't enough: a highlighter that already started on
          -- another buffer keeps running and its next delta response indexes the
          -- now-nil provider, throwing in a scheduled callback (a .cu file on
          -- BufWinEnter after a cpp buffer nilled it). Disable per buffer too so
          -- any live highlighter is torn down. cuda must be here, not just c/cpp:
          -- clangd attaches to .cu and shares the same nilled provider.
          local ft = vim.bo[event.buf].filetype
          if client and (ft == 'c' or ft == 'cpp' or ft == 'cuda') then
            client.server_capabilities.semanticTokensProvider = nil
            local bufs = { [event.buf] = true }
            for buf in pairs(client.attached_buffers or {}) do bufs[buf] = true end
            for buf in pairs(bufs) do
              pcall(vim.lsp.semantic_tokens.enable, false, { bufnr = buf })
            end
          end
          -- clangd can't parse CUDA without the toolchain, so its .cu/.cuh
          -- diagnostics are noise -- and every edit re-publishes them, re-rendering
          -- signs/underline/virt-text extmarks. Turn diagnostic display off for
          -- cuda buffers (clangd stays attached for navigation).
          if ft == 'cuda' then
            pcall(vim.diagnostic.enable, false, { bufnr = event.buf })
          end
          if supports(vim.lsp.protocol.Methods.textDocument_documentHighlight) then
            local highlight_augroup = vim.api.nvim_create_augroup('dans-lsp-highlight', { clear = false })
            local overlay_ok, overlay = pcall(require, 'custom.dans_frontend_cpp.overlay_hl')
            local function show_references()
              if vim.b[event.buf].dans_token_mode or FLOW_KEYWORDS[vim.fn.expand('<cword>')] then
                return
              end
              vim.lsp.buf.document_highlight()
              if overlay_ok then
                pcall(overlay.update_references, event.buf)
              end
            end
            local function hide_references()
              vim.lsp.buf.clear_references()
              if overlay_ok then
                pcall(overlay.clear_references, event.buf)
              end
            end

            local reference_events = {
              { events = { 'CursorHold', 'CursorHoldI' }, callback = show_references },
              { events = { 'CursorMoved', 'CursorMovedI' }, callback = hide_references },
            }
            for _, registration in ipairs(reference_events) do
              vim.api.nvim_create_autocmd(registration.events, {
                buffer = event.buf,
                group = highlight_augroup,
                callback = registration.callback,
              })
            end

            vim.api.nvim_create_autocmd('LspDetach', {
              buffer = event.buf,
              group = highlight_augroup,
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds({ group = highlight_augroup, buffer = event2.buf })
              end,
            })
          end

          if supports(vim.lsp.protocol.Methods.textDocument_inlayHint) then
            -- Toggles the *built-in* renderer (end-of-line hints). For C/C++ the
            -- deduced auto types are instead pulled and placed by custom.dans_frontend_cpp.view
            -- (rendered between the `:` and `=`), so leave the built-in off here.
            local function toggle_inlay_hints()
              local active = vim.lsp.inlay_hint.is_enabled({ bufnr = event.buf })
              vim.lsp.inlay_hint.enable(not active, { bufnr = event.buf })
            end
            map('<leader>th', toggle_inlay_hints, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      local sign_text = {}
      if vim.g.have_nerd_font then
        sign_text = {
          [vim.diagnostic.severity.ERROR] = '󰅚 ',
          [vim.diagnostic.severity.WARN] = '󰀪 ',
          [vim.diagnostic.severity.INFO] = '󰋽 ',
          [vim.diagnostic.severity.HINT] = '󰌶 ',
        }
      end
      vim.diagnostic.config({
        severity_sort = true,
        float = { border = 'rounded', source = 'if_many' },
        underline = { severity = vim.diagnostic.severity.ERROR },
        signs = { text = sign_text },
        -- Full message only on the CURSOR line (hover a line to read it);
        -- every other diagnosed line gets a first-cell mark from
        -- custom.dans_diagmark instead of end-of-line text, so diagnostics
        -- never push code around or suppress the frontend overlay.
        virtual_text = {
          current_line = true,
          source = 'if_many',
          spacing = 2,
        },
      })

      local capabilities = vim.tbl_deep_extend(
        'force',
        {},
        vim.lsp.protocol.make_client_capabilities(),
        require('cmp_nvim_lsp').default_capabilities()
      )

      -- `.clang-tidy` is C++-only; strip clang-tidy diagnostics out of plain C
      -- buffers so they don't see modernize-* warnings meant for .cpp/.hpp.
      local function filter_clang_tidy_for_c(err, result, ctx, config)
        if result and result.diagnostics then
          local bufnr = vim.uri_to_bufnr(result.uri)
          if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == 'c' then
            result.diagnostics = vim.tbl_filter(function(d)
              return d.source ~= 'clang-tidy'
            end, result.diagnostics)
          end
        end
        return vim.lsp.handlers['textDocument/publishDiagnostics'](err, result, ctx, config)
      end

      local server_configs = {
        clangd = {
          cmd = {
            -- macOS: Homebrew clang (newer than Apple's). Elsewhere: clangd
            -- from PATH (LLVM install).
            vim.fn.has 'mac' == 1 and '/opt/homebrew/opt/llvm/bin/clangd' or 'clangd',
            '--background-index',
            '--clang-tidy',
          },
          handlers = {
            ['textDocument/publishDiagnostics'] = filter_clang_tidy_for_c,
          },
        },

        lua_ls = {
          settings = {
            Lua = {
              completion = { callSnippet = 'Replace' },
            },
          },
        },

        -- Julia: LanguageServer.jl. Requires LanguageServer, SymbolServer and
        -- StaticLint installed in ~/.julia/environments/nvim-lspconfig.
        julials = {
          -- Disable StaticLint. On a heavy project it publishes a flood of lint
          -- diagnostics (and re-lints on every change), which nvim then churns
          -- into extmarks. Real parse/syntax errors still come through.
          settings = { julia = { lint = { run = false } } },
          -- Root at the OUTERMOST Project.toml so nested package layouts only
          -- spawn one client (one root = one client).
          root_dir = function(bufnr, on_dir)
            local fname = vim.api.nvim_buf_get_name(bufnr)
            if fname == '' then
              return
            end
            local found = vim.fs.find({ 'Project.toml', 'JuliaProject.toml' }, {
              upward = true,
              path = fname,
              limit = math.huge,
            })
            on_dir(#found > 0 and vim.fs.dirname(found[#found]) or vim.fs.dirname(fname))
          end,
        },

        -- LaTeX language intelligence. VimTeX owns compilation/viewing; texlab
        -- supplies completion, navigation, diagnostics, symbols and explicit
        -- formatting without building or rewriting the document on save.
        texlab = {
          root_dir = function(bufnr, on_dir)
            local fname = vim.api.nvim_buf_get_name(bufnr)
            if fname == '' then
              return
            end
            local root = vim.fs.root(fname, {
              '.texlabroot',
              'texlabroot',
              '.latexmkrc',
              'latexmkrc',
              'Tectonic.toml',
              '.git',
            })
            on_dir(root or vim.fs.dirname(fname))
          end,
          settings = {
            texlab = {
              build = {
                executable = 'latexmk',
                args = { '-pdf', '-interaction=nonstopmode', '-synctex=1', '%f' },
                onSave = false,
                forwardSearchAfter = false,
              },
              chktex = {
                onOpenAndSave = vim.fn.executable 'chktex' == 1,
                onEdit = false,
              },
              diagnosticsDelay = 300,
              latexFormatter = 'latexindent',
              latexindent = { modifyLineBreaks = false },
              bibtexFormatter = 'texlab',
            },
          },
        },
      }

      local required_mason_tools = { 'lua_ls', 'stylua', 'texlab' }
      -- Package installation is explicit; LSP activation is handled below.
      require('mason-tool-installer').setup {
        ensure_installed = required_mason_tools,
        integrations = { ['mason-lspconfig'] = false, ['mason-null-ls'] = false, ['mason-nvim-dap'] = false },
      }

      for server_name, server in pairs(server_configs) do
        server.capabilities = vim.tbl_deep_extend('force', {}, capabilities, server.capabilities or {})
        vim.lsp.config(server_name, server)
        vim.lsp.enable(server_name)
      end
    end,
  },
}
