-- Rainbow brackets. Currently disabled; left in place because the C/C++
-- enclosing-brace highlighter in treesitter.lua covers the same need.
return {
  'HiPhish/rainbow-delimiters.nvim',
  enabled = false,
  event = 'BufReadPost',
  config = function()
    local rd = require 'rainbow-delimiters'

    vim.g.rainbow_delimiters = {
      strategy = {
        [''] = rd.strategy.global,
        c = rd.strategy['local'],
        cpp = rd.strategy['local'],
      },
      query = { [''] = 'rainbow-delimiters' },
      highlight = {
        'RainbowDelimiterRed',
        'RainbowDelimiterYellow',
        'RainbowDelimiterBlue',
        'RainbowDelimiterOrange',
        'RainbowDelimiterGreen',
        'RainbowDelimiterViolet',
        'RainbowDelimiterCyan',
      },
    }

    vim.api.nvim_set_hl(0, 'RainbowDelimiterRed', { link = 'DiagnosticError' })
    vim.api.nvim_set_hl(0, 'RainbowDelimiterYellow', { link = 'DiagnosticWarn' })
    vim.api.nvim_set_hl(0, 'RainbowDelimiterBlue', { link = 'DiagnosticInfo' })
    vim.api.nvim_set_hl(0, 'RainbowDelimiterOrange', { link = 'DiagnosticWarn' })
    vim.api.nvim_set_hl(0, 'RainbowDelimiterGreen', { link = 'DiagnosticHint' })
    vim.api.nvim_set_hl(0, 'RainbowDelimiterViolet', { link = 'DiagnosticInfo' })
    vim.api.nvim_set_hl(0, 'RainbowDelimiterCyan', { link = 'DiagnosticHint' })
  end,
}
