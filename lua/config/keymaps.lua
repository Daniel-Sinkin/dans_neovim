-- Non-plugin keymaps. Plugin-specific keymaps live in each plugin spec under
-- lua/custom/plugins/.

-- Clear highlights on search when pressing <Esc> in normal mode.
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Mousewheel: scroll viewport without smoothing.
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelUp>', '<C-y><C-y><C-y>', { silent = true })
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelDown>', '<C-e><C-e><C-e>', { silent = true })

-- Split paste registers (see the TextYankPost router in autocmds.lua): bare `p`
-- pastes the last yank (register y), bare `P` pastes the last change/delete
-- (register z). An explicit register is honored -- `"ap` still pastes register a;
-- only the default `"` is redirected. Mapped in normal + visual; in visual the
-- replaced selection lands on the cut side, so y survives a paste-over.
vim.keymap.set({ 'n', 'x' }, 'p', function()
  return '"' .. (vim.v.register == '"' and 'y' or vim.v.register) .. 'p'
end, { expr = true, desc = 'Paste last yank (reg y)' })
vim.keymap.set({ 'n', 'x' }, 'P', function()
  return '"' .. (vim.v.register == '"' and 'z' or vim.v.register) .. 'P'
end, { expr = true, desc = 'Paste last change/delete (reg z)' })

-- Central DANS command palette. :Dans is the canonical entry point; keep the
-- historical mnemonic as a convenient alias.
vim.keymap.set('n', '<leader>dan', function()
  require('custom.dans_menu').open()
end, { desc = 'D[AN]S command palette' })

-- Nuke stale diagnostics and refresh Neo-tree's view. Use when a closed file
-- is still marked orange in the tree.
vim.keymap.set('n', '<leader>dc', function()
  vim.diagnostic.reset()
  pcall(vim.cmd, 'Neotree refresh')
end, { desc = '[D]iagnostics [C]lear (reset all, refresh tree)' })

local movement_maps = {
  { mode = 't', lhs = '<Esc><Esc>', rhs = '<C-\\><C-n>', label = 'Exit terminal mode' },
  { mode = 'n', lhs = '<C-h>', rhs = '<C-w>h', label = 'Focus left split' },
  { mode = 'n', lhs = '<C-j>', rhs = '<C-w>j', label = 'Focus lower split' },
  { mode = 'n', lhs = '<C-k>', rhs = '<C-w>k', label = 'Focus upper split' },
  { mode = 'n', lhs = '<C-l>', rhs = '<C-w>l', label = 'Focus right split' },
}

for _, binding in ipairs(movement_maps) do
  vim.keymap.set(binding.mode, binding.lhs, binding.rhs, { desc = binding.label })
end
