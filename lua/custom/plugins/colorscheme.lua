-- Tokyo Night. Follows the macOS system appearance:
--   dark mode  -> tokyonight-night
--   light mode -> tokyonight-day
-- Terminal nvim: probe AppleInterfaceStyle once on startup.
-- Neovide: `vim.g.neovide_theme = 'auto'` (set in config/options.lua) also
-- updates &background live when the system switches, so the colorscheme
-- follows without restart.

local function macos_is_dark()
  if vim.fn.has 'mac' ~= 1 then
    return true
  end
  local out = vim.fn.system 'defaults read -g AppleInterfaceStyle 2>/dev/null'
  -- "Dark\n" when dark; non-zero exit + empty when light.
  return vim.v.shell_error == 0 and vim.trim(out) == 'Dark'
end

return {
  'folke/tokyonight.nvim',
  lazy = false,
  priority = 1000,
  opts = {
    style = 'night',     -- used when background=dark
    light_style = 'day', -- used when background=light
  },
  config = function(_, opts)
    vim.opt.termguicolors = true
    vim.o.background = macos_is_dark() and 'dark' or 'light'
    require('tokyonight').setup(opts)
    vim.cmd.colorscheme 'tokyonight'

    -- Re-pick the colorscheme whenever &background changes (Neovide flips it
    -- on system appearance change with neovide_theme = 'auto').
    vim.api.nvim_create_autocmd('OptionSet', {
      pattern = 'background',
      group = vim.api.nvim_create_augroup('ds_tokyonight_bg', { clear = true }),
      callback = function()
        vim.cmd.colorscheme 'tokyonight'
      end,
    })
  end,
}
