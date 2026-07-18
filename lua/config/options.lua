-- Editor options, globals, and environment setup.
-- Loaded first from init.lua, before any plugin work.

-- Leader keys (must be set before plugins load).
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.g.have_nerd_font = false

-- Markup buffers are source documents, not rendered previews.  Disable the
-- built-in Markdown syntax conceals before any syntax file can be sourced, and
-- make ordinary .tex files unambiguously LaTeX for VimTeX/texlab.
vim.g.markdown_syntax_conceal = 0
vim.g.tex_flavor = 'latex'

-- Treat `.h` headers as C, not C++. Must be set before any filetype detection
-- runs so plain C headers don't get C++ clang-tidy checks.
vim.g.c_syntax_for_h = 1

-- macOS: `cc` resolves to the raw Xcode toolchain compiler without a sysroot,
-- so nvim-treesitter parser builds fail with "'stdlib.h' file not found".
-- Exporting SDKROOT gives clang the SDK.
if vim.fn.has 'mac' == 1 and (vim.env.SDKROOT == nil or vim.env.SDKROOT == '') then
  local sdk = vim.trim(vim.fn.system 'xcrun --show-sdk-path 2>/dev/null')
  if vim.v.shell_error == 0 and sdk ~= '' and vim.fn.isdirectory(sdk) == 1 then
    vim.env.SDKROOT = sdk
  end
end

-- GUI launches (Neovide, dock) don't inherit shell PATH; juliaup's `julia`
-- goes missing and the Julia LSP / DAP can't spawn. Prepend it explicitly.
do
  local juliaup_bin = vim.fn.expand '~/.juliaup/bin'
  if vim.fn.isdirectory(juliaup_bin) == 1 and not (vim.env.PATH or ''):find(juliaup_bin, 1, true) then
    vim.env.PATH = juliaup_bin .. ':' .. (vim.env.PATH or '')
  end
end

-- Neovide-only visuals (ignored in terminal Neovim)
if vim.g.neovide then
  vim.g.neovide_cursor_animation_length = 0.03
  vim.g.neovide_scroll_animation_length = 0.0
  vim.g.neovide_cursor_trail_size = 0.2
  vim.g.neovide_cursor_vfx_mode = ''
  -- Neovide expects a font *family* name, not a file name.
  vim.o.guifont = 'Monaspace Krypton:h12'
  -- Follow macOS system appearance: sets &background and updates it live when
  -- the system switches dark/light. The colorscheme autocmd in
  -- custom/plugins/colorscheme.lua re-picks tokyonight on change.
  vim.g.neovide_theme = 'auto'
end

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = 'a'
-- Touchpad drift must not scroll the view sideways; vertical is handled by
-- the wheel maps in keymaps.lua.
vim.opt.mousescroll = 'ver:3,hor:0'
vim.opt.showmode = false

-- Indentation: 4 spaces, never tabs.
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4

local function enable_system_clipboard()
  vim.opt.clipboard = { 'unnamedplus' }
end
vim.schedule(enable_system_clipboard)

vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'yes'
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
for _, split_option in ipairs { 'splitright', 'splitbelow' } do
  vim.opt[split_option] = true
end
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣', extends = '>', precedes = '<' }
-- Never wrap -- long lines (and frontend overlays wider than the raw text) overflow
-- horizontally instead. `extends` (>) marks a line running off the right edge,
-- `precedes` (<) one scrolled past the left; sidescroll=1 pans a column at a time
-- rather than jumping half the window.
vim.opt.wrap = false
vim.opt.sidescroll = 1
vim.opt.inccommand = 'split'
vim.opt.cursorline = true
vim.opt.scrolloff = 10
vim.opt.confirm = true

-- Source-faithful by default. C/C++ presentation modules opt individual windows
-- into conceallevel=2 when their frontend is active.
vim.opt.conceallevel = 0
