-- Reusable nofile result windows for authoring tools.

local M = {}
local named = {}

local function lines(value)
  if type(value) == 'table' then
    return value
  end
  return vim.split(value or '', '\n', { plain = true })
end

function M.set_lines(bufnr, content)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines(content))
  vim.bo[bufnr].modifiable = false
end

function M.open(options)
  options = options or {}
  local key = assert(options.key or options.name, 'scratch window needs a key')
  local bufnr = named[key]
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(false, true)
    named[key] = bufnr
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = options.bufhidden or 'wipe'
    vim.bo[bufnr].swapfile = false
    pcall(vim.api.nvim_buf_set_name, bufnr, options.name or ('dans://' .. key))
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = bufnr,
      once = true,
      callback = function()
        named[key] = nil
        if options.on_close then
          options.on_close()
        end
      end,
    })
  end
  M.set_lines(bufnr, options.lines or {})
  vim.bo[bufnr].filetype = options.filetype or 'text'

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    if options.vertical == false then
      vim.cmd 'botright split'
    else
      vim.cmd 'botright vsplit'
    end
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  else
    vim.api.nvim_set_current_win(winid)
  end
  vim.wo[winid].wrap = options.wrap == true
  vim.wo[winid].number = options.number == true
  vim.wo[winid].relativenumber = false

  vim.keymap.set('n', 'q', function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end, { buffer = bufnr, silent = true, desc = 'Close tool result' })
  for lhs, mapping in pairs(options.mappings or {}) do
    local callback = type(mapping) == 'table' and mapping[1] or mapping
    local description = type(mapping) == 'table' and mapping.desc or nil
    vim.keymap.set('n', lhs, callback, { buffer = bufnr, silent = true, desc = description })
  end
  return bufnr, winid
end

function M.find(key)
  local bufnr = named[key]
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil
end

return M
