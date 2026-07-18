-- cp.lua — Minimal competitive programming config for Neovide
-- Launch: neovide -- -u ~/.config/nvim/cp.lua
-- or use the `cpvim` alias from .zshrc

-------------------- Neovide visuals (keep the flashy cursor) --------------------
if vim.g.neovide then
  vim.g.neovide_cursor_animation_length = 0.06
  vim.g.neovide_scroll_animation_length = 0.0
  vim.g.neovide_cursor_trail_size = 0.35
  vim.g.neovide_cursor_vfx_mode = ''
  vim.o.guifont = 'Monaspace Krypton:h18'
end

-------------------- Leader -------------------------------------------------------
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-------------------- Options ------------------------------------------------------
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = 'a'
vim.opt.showmode = true          -- no statusline plugin, so show mode
vim.opt.clipboard = 'unnamedplus'
vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'no'       -- no gutter needed
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
for _, split_option in ipairs { 'splitright', 'splitbelow' } do
  vim.opt[split_option] = true
end
vim.opt.cursorline = true
vim.opt.scrolloff = 10
vim.opt.confirm = true
vim.opt.termguicolors = true

-- 2-space indent, no tabs
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.softtabstop = 2
vim.opt.expandtab = true
vim.opt.smartindent = true

-- No swap / backup clutter
vim.opt.swapfile = false
vim.opt.backup = false

-- Whitespace display
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
vim.opt.inccommand = 'split'

-------------------- Kill all syntax / highlighting --------------------------------
-- Disable built-in syntax highlighting engine entirely
vim.cmd 'syntax off'

-- Disable filetype plugins (no ftplugin overrides)
vim.cmd 'filetype plugin indent off'

-- Nuke treesitter if it somehow loads
vim.api.nvim_create_autocmd('BufEnter', {
  callback = function()
    pcall(function()
      vim.treesitter.stop()
    end)
  end,
})

-------------------- Monochrome colorscheme (inline) --------------------------------
-- Everything is one color: soft white on dark background
local fg = '#c0c0c0'
local bg = '#1a1a1a'
local dim = '#555555'
local cursor_line = '#222222'
local visual = '#333333'
local accent = '#808080'

local function hi(group, opts)
  vim.api.nvim_set_hl(0, group, opts)
end

-- Base
hi('Normal',       { fg = fg, bg = bg })
hi('NormalFloat',  { fg = fg, bg = '#1e1e1e' })
hi('CursorLine',   { bg = cursor_line })
hi('CursorLineNr', { fg = fg, bg = cursor_line, bold = true })
hi('LineNr',       { fg = dim })
hi('Visual',       { bg = visual })
hi('Search',       { fg = bg, bg = accent })
hi('IncSearch',    { fg = bg, bg = fg })
hi('StatusLine',   { fg = fg, bg = '#252525' })
hi('StatusLineNC', { fg = dim, bg = '#1e1e1e' })
hi('VertSplit',    { fg = dim })
hi('Pmenu',        { fg = fg, bg = '#252525' })
hi('PmenuSel',     { fg = bg, bg = accent })
hi('WildMenu',     { fg = bg, bg = accent })
hi('MatchParen',   { fg = fg, bold = true, underline = true })
hi('NonText',      { fg = dim })
hi('SpecialKey',   { fg = dim })
hi('Directory',    { fg = fg })
hi('Title',        { fg = fg, bold = true })
hi('ModeMsg',      { fg = fg, bold = true })
hi('MoreMsg',      { fg = fg })
hi('Question',     { fg = fg })
hi('WarningMsg',   { fg = fg })
hi('ErrorMsg',     { fg = '#ff5555', bg = bg })
hi('Error',        { fg = '#ff5555' })
hi('Folded',       { fg = dim, bg = '#1e1e1e' })
hi('FoldColumn',   { fg = dim, bg = bg })
hi('SignColumn',   { fg = dim, bg = bg })
hi('TabLine',      { fg = dim, bg = '#1e1e1e' })
hi('TabLineFill',  { bg = '#1e1e1e' })
hi('TabLineSel',   { fg = fg, bg = bg, bold = true })

-- Make ALL syntax groups the same foreground (monochrome)
local mono_groups = {
  'Comment', 'Constant', 'String', 'Character', 'Number', 'Boolean', 'Float',
  'Identifier', 'Function', 'Statement', 'Conditional', 'Repeat', 'Label',
  'Operator', 'Keyword', 'Exception', 'PreProc', 'Include', 'Define', 'Macro',
  'PreCondit', 'Type', 'StorageClass', 'Structure', 'Typedef', 'Special',
  'SpecialChar', 'Tag', 'Delimiter', 'SpecialComment', 'Debug',
}
for _, g in ipairs(mono_groups) do
  hi(g, { fg = fg })
end
-- Comments get a slightly dimmer shade so you can still tell them apart
hi('Comment', { fg = dim, italic = true })

-- Treesitter captures (in case any sneak through)
local ts_groups = {
  '@variable', '@function', '@keyword', '@string', '@number', '@type',
  '@constant', '@operator', '@punctuation', '@comment', '@parameter',
  '@field', '@property', '@constructor', '@method', '@namespace',
  '@include', '@conditional', '@repeat', '@exception', '@boolean',
}
for _, g in ipairs(ts_groups) do
  hi(g, { fg = fg })
end
hi('@comment', { fg = dim, italic = true })

-- Diagnostics off visually
hi('DiagnosticError', { fg = dim })
hi('DiagnosticWarn',  { fg = dim })
hi('DiagnosticInfo',  { fg = dim })
hi('DiagnosticHint',  { fg = dim })

-------------------- Keymaps -------------------------------------------------------

-- Clear search highlight
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Split navigation (same as your init.lua)
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus left' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus right' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus down' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus up' })

-- Mousewheel (same as your init.lua)
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelUp>',   '<C-y><C-y><C-y>', { silent = true })
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelDown>', '<C-e><C-e><C-e>', { silent = true })
vim.opt.mousescroll = 'ver:3,hor:0'

-- Yank highlight
vim.api.nvim_create_autocmd('TextYankPost', {
  callback = function() vim.highlight.on_yank() end,
})

-- Terminal escape
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-------------------- Compile & Run -------------------------------------------------
-- Homebrew LLVM clang++ with the same flags as compile_and_run.sh
-- F5: delegates to compile_and_run.sh (keeps flags in one place)
vim.keymap.set('n', '<F5>', function()
  vim.cmd 'write'
  local dir = vim.fn.expand '%:p:h'
  local script = dir .. '/compile_and_run.sh'
  vim.cmd('botright 15split | terminal ' .. vim.fn.shellescape(script))
  vim.cmd 'startinsert'
end, { desc = 'Compile & run C++ with input.csv' })

-- F6: compile + run WITHOUT input redirection (interactive)
vim.keymap.set('n', '<F6>', function()
  vim.cmd 'write'
  local file = vim.fn.expand '%:p'
  local cxx = '/usr/bin/clang++'
  local cmd = string.format(
    '%s -std=c++17 -O2 -Wall -Wextra -o /tmp/cf_a.out %s && /tmp/cf_a.out',
    cxx,
    vim.fn.shellescape(file)
  )
  vim.cmd('botright 15split | terminal ' .. cmd)
  vim.cmd 'startinsert'
end, { desc = 'Compile & run C++ (no input file)' })

-- F7: open/create input.csv in a vertical split
vim.keymap.set('n', '<F7>', function()
  local dir = vim.fn.expand '%:p:h'
  vim.cmd('vsplit ' .. vim.fn.fnameescape(dir .. '/input.csv'))
end, { desc = 'Open input.csv in split' })

-------------------- No plugins — skip lazy.nvim entirely --------------------------
-- This config intentionally loads zero plugins.
-- The separate lazy.nvim data dir from your main config won't be touched.
