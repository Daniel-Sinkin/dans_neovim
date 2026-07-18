-- Treesitter + the C/C++/CUDA enclosing-brace highlighter and monochrome theme.
--
-- For C/C++/CUDA we DISABLE treesitter highlighting and instead:
--   1. Use the bundled classic vim syntax (re-enabled per FileType below).
--   2. Flatten almost every syntax/LSP-semantic group to Normal.
--   3. Keep strings, comments (gray), and PreProc (dim) visible.
--   4. CUDA only: re-color CUDA-specific identifiers so kernels stand out.
-- The treesitter parser still runs so the brace-highlighter has its AST.
local parser_install_policy = { automatic = true }
local regex_layer_languages = { 'ruby' }

return {
  {
    -- VSCode-like sticky scope header. Loaded at idle (VeryLazy), NOT on the
    -- c/cpp FileType: an ft load happens inside the first big-file `:edit`,
    -- where its initial update pays the synchronous cold parse before the
    -- frontend's cold-open gate can suspend it (~180 ms on a vk_core-sized
    -- file). Loaded ahead of time, every cpp open -- including the first --
    -- hits the gate's suspend/resume path instead.
    'nvim-treesitter/nvim-treesitter-context',
    event = 'VeryLazy',
    main = 'treesitter-context',
    opts = {
      enable = true,
      max_lines = 1,
      trim_scope = 'outer',
      mode = 'topline',
      separator = nil,
      zindex = 20,
      on_attach = function(bufnr)
        local ft = vim.bo[bufnr].filetype
        return ft == 'c' or ft == 'cpp' or ft == 'cuda'
      end,
    },
  },
  {
    'nvim-treesitter/nvim-treesitter',
    -- Pin the classic `master` branch: the config uses its API
    -- (nvim-treesitter.configs / ensure_installed), not the `main` rewrite that
    -- is now nvim-treesitter's default branch.
    branch = 'master',
    build = ':TSUpdate',
    opts = {
      ensure_installed = {
        'bash',
        'c',
        'cpp',
        'cuda',
        'diff',
        'html',
        'lua',
        'luadoc',
        'markdown',
        'markdown_inline',
        'query',
        'vim',
        'vimdoc',
      },
      auto_install = parser_install_policy.automatic,
      -- VimTeX owns these languages; do not let the generic FileType auto
      -- installer fetch redundant parsers before module-disable predicates run.
      ignore_install = { 'latex', 'bibtex' },
      highlight = {
        enable = true,
        disable = function(_, bufnr)
          local ft = vim.bo[bufnr].filetype
          -- VimTeX's syntax engine understands multi-file LaTeX semantics and
          -- owns this presentation. Avoid a second highlighter (and an
          -- unnecessary automatic tree-sitter-latex download).
          if ft == 'tex' or ft == 'plaintex' or ft == 'bib' then return true end
          -- Normal-color raw mode wants stock treesitter highlighting; both the
          -- frontend and requested monochrome mode use classic syntax instead.
          local ok, mode = pcall(require, 'custom.dans_mode')
          if ok and not mode.monochrome_effective() then return false end
          return ft == 'c' or ft == 'cpp' or ft == 'cuda'
        end,
        additional_vim_regex_highlighting = regex_layer_languages,
      },
      -- Treesitter indent (frozen master on nvim 0.12) goes stale mid-edit, so
      -- pressing Enter would land at column 0. C/C++/CUDA fall back to the
      -- deterministic built-in `cindent` instead (set in config/autocmds.lua).
      indent = { enable = true, disable = { 'ruby', 'c', 'cpp', 'cuda', 'tex', 'plaintex', 'bib' } },
    },
    config = function(_, opts)
      -- Windows: zig is a hermetic C compiler (ships its own libc headers), so
      -- parser builds don't need the MSVC/Windows SDK INCLUDE paths set.
      if vim.fn.has 'win32' == 1 then
        require('nvim-treesitter.install').compilers = { 'zig' }
      end
      require('nvim-treesitter.configs').setup(opts)

      -- The pinned (frozen) master nvim-treesitter's `set-lang-from-info-string!`
      -- directive reads match[id] as a single node, but Neovim 0.12 makes it a
      -- list, so markdown code-fence injection crashes ("attempt to call method
      -- 'range' (a nil value)"). Re-register the directive, list-aware.
      pcall(function()
        require 'nvim-treesitter.query_predicates'
        vim.treesitter.query.add_directive('set-lang-from-info-string!', function(match, _, bufnr, pred, metadata)
          local node = match[pred[2]]
          if type(node) == 'table' then
            node = node[#node]
          end
          if not node then
            return
          end
          local alias = vim.treesitter.get_node_text(node, bufnr):lower()
          metadata['injection.language'] = vim.treesitter.language.get_lang(alias) or alias
        end, { force = true })
      end)

      -- Scope highlighting (orange innermost any-bracket pair + blue ancestor
      -- chain) and the unified ib/ab text object live in their own module, driven
      -- by bracket matching over the real buffer text.
      require('custom.dans_frontend_cpp.scope').setup()

      -- C/C++/CUDA monochrome theme: flatten nearly every group to Normal so
      -- only strings (+ comments in gray) carry color. The links are GLOBAL
      -- highlight state, so they're applied once here and re-asserted on
      -- ColorScheme -- NOT per FileType, where the old `syntax clear` +
      -- `syntax on` re-sourced the whole syntax runtime on every cpp open
      -- (a measurable slice of the open latency on big files). The classic
      -- syntax itself loads through Neovim's normal FileType machinery, since
      -- treesitter highlighting is disabled for these filetypes above.
      local function flatten_monochrome()
          -- Raw normal-color mode leaves the stock tokyonight theme alone.
          local ok, mode = pcall(require, 'custom.dans_mode')
          if ok and not mode.monochrome_effective() then return end
          local function link(group, target)
            pcall(vim.api.nvim_set_hl, 0, group, { link = target })
          end

          for _, g in ipairs {
            'Comment',
            'Constant',
            'Number',
            'Boolean',
            'Float',
            'Identifier',
            'Function',
            'Statement',
            'Conditional',
            'Repeat',
            'Label',
            'Operator',
            'Keyword',
            'Exception',
            'PreProc',
            'Include',
            'Define',
            'Macro',
            'PreCondit',
            'Type',
            'StorageClass',
            'Structure',
            'Typedef',
            'Special',
            'SpecialChar',
            'Tag',
            'Delimiter',
            'SpecialComment',
            'Debug',
            'Underlined',
            'Ignore',
            'Error',
            'Todo',
          } do
            link(g, 'Normal')
          end

          for _, g in ipairs {
            'cType',
            'cStorageClass',
            'cStructure',
            'cConstant',
            'cOperator',
            'cppType',
            'cppStatement',
            'cppStorageClass',
            'cppStructure',
            'cppConstant',
            'cppOperator',
            'cppAccess',
            'cppModifier',
            'cppExceptions',
            'cppBoolean',
          } do
            link(g, 'Normal')
          end

          for _, g in ipairs {
            '@lsp.type.namespace',
            '@lsp.type.type',
            '@lsp.type.class',
            '@lsp.type.struct',
            '@lsp.type.enum',
            '@lsp.type.interface',
            '@lsp.type.parameter',
            '@lsp.type.variable',
            '@lsp.type.property',
            '@lsp.type.function',
            '@lsp.type.method',
            '@lsp.type.macro',
            '@lsp.type.enumMember',
            '@lsp.type.member',
            '@lsp.typemod.variable.defaultLibrary',
            '@lsp.typemod.function.defaultLibrary',
            '@lsp.typemod.namespace.defaultLibrary',
            '@lsp.mod.defaultLibrary',
            '@lsp.mod.readonly',
            '@lsp.mod.constant',
            '@lsp.mod.static',
          } do
            link(g, 'Normal')
          end

          for _, g in ipairs {
            'LspSemanticNamespace',
            'LspSemanticType',
            'LspSemanticClass',
            'LspSemanticStruct',
            'LspSemanticEnum',
            'LspSemanticInterface',
            'LspSemanticParameter',
            'LspSemanticVariable',
            'LspSemanticProperty',
            'LspSemanticFunction',
            'LspSemanticMethod',
            'LspSemanticMacro',
            'LspSemanticEnumMember',
            'LspSemanticMember',
          } do
            link(g, 'Normal')
          end

          link('String', 'String')
          link('Character', 'String')

          vim.api.nvim_set_hl(0, 'Comment', { fg = '#6b7280', italic = true })

          vim.api.nvim_set_hl(0, 'PreProc', { fg = '#6b7280' })
          vim.api.nvim_set_hl(0, 'cppPreCondit', { fg = '#6b7280' })
          vim.api.nvim_set_hl(0, 'cPreCondit', { fg = '#6b7280' })

          for _, g in ipairs {
            '@comment',
            '@preproc',
            '@conditional',
            '@conditional.inactive',
          } do
            pcall(vim.api.nvim_set_hl, 0, g, { fg = '#6b7280' })
          end

          -- Dim C++ cast expressions. static_cast<T>(x), dynamic_cast<T>(x),
          -- reinterpret_cast<T>(x), const_cast<T>(x) — all gray, no italic.
          -- Distinguishable from comments (which are italic) but visually low
          -- priority so the meaningful code stands out.
          vim.api.nvim_set_hl(0, 'dansCppCast', { fg = '#6b7280' })

          -- CUDA groups (built-in cuda.vim types/constants/variables plus the
          -- __dunder__ and <<<>>> matches below): flatten to Normal so .cu/.cuh
          -- read monochrome like c/cpp. cuda.vim otherwise default-links these to
          -- colored standard groups and a kernel-heavy file lights up everywhere.
          for _, g in ipairs {
            'cudaStorageClass', 'cudaConstant', 'cudaType', 'cudaVariable',
            'cudaKernelBrackets', 'cudaKernelConfig', 'cudaDunder',
          } do
            vim.api.nvim_set_hl(0, g, { link = 'Normal' })
          end
      end

      flatten_monochrome()
      -- Re-flatten after every colorscheme load. Deferred: Neovide's
      -- neovide_theme='auto' flips &background, whose OptionSet handler
      -- (colorscheme.lua) re-picks tokyonight; running the relink nested inside
      -- that chain doesn't stick (the base groups end up re-colored), so it has
      -- to land after the cycle settles. Scheduling also coalesces the direct
      -- :colorscheme path -- it just runs one tick later.
      vim.api.nvim_create_autocmd('ColorScheme', {
        callback = function() vim.schedule(flatten_monochrome) end,
      })

      -- Per-buffer syntax items only (cheap): the gray cast match, and the
      -- CUDA-specific matches for cuda buffers.
      vim.api.nvim_create_autocmd('FileType', {
        pattern = { 'c', 'cpp', 'cuda' },
        callback = function(ev)
          vim.cmd [[syntax match dansCppCast /\<\(static\|dynamic\|reinterpret\|const\)_cast\s*<[^>]*>/]]
          if ev.match == 'cuda' then
            vim.cmd [[syntax match cudaDunder /\<__\w\+__\>/]]
            vim.cmd [[syntax region cudaKernelConfig matchgroup=cudaKernelBrackets start=/<<</ end=/>>>/ oneline keepend contains=NONE]]
          end
        end,
      })
    end,
  },
}
