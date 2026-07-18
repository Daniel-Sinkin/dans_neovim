local manager_dir = vim.fs.joinpath(vim.fn.stdpath('data'), 'lazy', 'lazy.nvim')

local function install_plugin_manager()
  local checkout = vim.system({
    'git',
    'clone',
    '--filter=blob:none',
    '--branch=stable',
    'https://github.com/folke/lazy.nvim.git',
    manager_dir,
  }, { text = true }):wait()

  if checkout.code ~= 0 then
    error(('lazy.nvim installation failed:\n%s'):format(checkout.stderr or checkout.stdout or 'unknown git error'))
  end
end

if not vim.uv.fs_stat(manager_dir) then
  install_plugin_manager()
end

vim.opt.runtimepath:prepend(manager_dir)

local plugin_specs = {
  { import = 'custom.plugins' },
}

require('lazy').setup(plugin_specs)
