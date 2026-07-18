-- File explorer (left tree).
return {
  'nvim-neo-tree/neo-tree.nvim',
  branch = 'v3.x',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons',
    'MunifTanjim/nui.nvim',
  },
  cmd = 'Neotree',
  keys = {
    { '<leader>e', '<cmd>Neotree toggle left<CR>', desc = 'Toggle file explorer' },
    { '<leader>o', '<cmd>Neotree focus left<CR>', desc = 'Focus file explorer' },
  },
  opts = {
    close_if_last_window = true,
    popup_border_style = 'rounded',
    enable_git_status = false,
    enable_diagnostics = true,
    filesystem = {
      filtered_items = {
        hide_dotfiles = false,
        hide_gitignored = false,
        -- Hidden by default (toggle with H); `build` is the CMake output dir.
        hide_by_name = { 'build' },
      },
      follow_current_file = { enabled = true },
      hijack_netrw_behavior = 'open_default',
    },
    window = {
      position = 'left',
      width = 32,
      mappings = {
        ['<space>'] = 'toggle_node',
        ['<cr>'] = 'open',
        ['l'] = 'open',
        ['h'] = 'close_node',
      },
    },
  },
}
