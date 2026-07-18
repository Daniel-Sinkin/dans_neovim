-- mini.nvim: textobjects, surround, statusline.
return {
  'echasnovski/mini.nvim',
  config = function()
    require('mini.ai').setup { n_lines = 500 }
    require('mini.surround').setup()

    local statusline = require 'mini.statusline'
    -- The filename section is replaced by the jumplist trail (the chain of
    -- files <C-o> walks back through, current file last, library-colored);
    -- everything else is mini's stock active layout. Active window only --
    -- inactive windows keep mini's plain filename line.
    statusline.setup {
      use_icons = vim.g.have_nerd_font,
      content = {
        active = function()
          local mode, mode_hl = statusline.section_mode { trunc_width = 120 }
          local git = statusline.section_git { trunc_width = 40 }
          local diff = statusline.section_diff and statusline.section_diff { trunc_width = 75 } or ''
          local diagnostics = statusline.section_diagnostics { trunc_width = 75 }
          local lsp = statusline.section_lsp and statusline.section_lsp { trunc_width = 75 } or ''
          local trail = require('custom.dans_jumptrail').statusline()
          local fileinfo = statusline.section_fileinfo { trunc_width = 120 }
          return statusline.combine_groups {
            { hl = mode_hl, strings = { mode } },
            { hl = 'MiniStatuslineDevinfo', strings = { git, diff, diagnostics, lsp } },
            '%<',
            { hl = 'MiniStatuslineFilename', strings = { trail } },
            '%=',
            { hl = 'MiniStatuslineFileinfo', strings = { fileinfo } },
            { hl = mode_hl, strings = { '%2l:%-2v' } },
          }
        end,
      },
    }

    require('custom.dans_jumptrail').setup()

    ---@diagnostic disable-next-line: duplicate-set-field
    statusline.section_location = function()
      return '%2l:%-2v'
    end
  end,
}
