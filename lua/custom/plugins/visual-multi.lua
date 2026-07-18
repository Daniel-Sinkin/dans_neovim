-- VSCode-like multi-cursor.
return {
  'mg979/vim-visual-multi',
  branch = 'master',
  init = function()
    -- Match VSCode muscle memory.
    vim.g.VM_maps = {
      ['Find Under'] = '<C-n>',
      ['Find Subword Under'] = '<C-n>',
    }
    vim.g.VM_default_mappings = 1
    vim.g.VM_silent_exit = 1
  end,
}
