-- Compatibility facade for the retired one-dimensional "vanilla" toggle.
-- New code uses custom.dans_mode and the :Dans menu.  Vanilla now means the
-- useful old endpoint: frontend off plus normal (non-monochrome) highlighting.

local M = {}

local function mode()
  return require 'custom.dans_mode'
end

function M.is_enabled()
  return not mode().frontend_enabled() and not mode().monochrome_effective()
end

function M.enable()
  mode().set_frontend(false, { silent = true })
  mode().set_monochrome(false, { silent = true })
  vim.notify('dans normal source view on', vim.log.levels.INFO)
end

function M.disable()
  mode().set_monochrome(true, { silent = true })
  mode().set_frontend(true, { silent = true })
  vim.notify('dans frontend view on', vim.log.levels.INFO)
end

function M.toggle()
  if M.is_enabled() then
    M.disable()
  else
    M.enable()
  end
end

return M
