-- Integrated terminal as a panel. <leader>tt opens it below the main code
-- window (not under Neo-tree), reusing a dedicated buffer across toggles.
return {
  'akinsho/toggleterm.nvim',
  version = '*',
  opts = {
    size = function(term)
      if term.direction == 'horizontal' then
        return 15
      elseif term.direction == 'vertical' then
        return 80
      end
    end,
    open_mapping = nil,
    shade_terminals = false,
    direction = 'horizontal',
    close_on_exit = false,
    shell = vim.o.shell,
  },
  keys = {
    {
      '<leader>tt',
      function()
        local tab = vim.api.nvim_get_current_tabpage()

        -- Already visible in this tab? Close it.
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].buftype == 'terminal' and vim.b[buf].ds_bottom_term == true then
            vim.api.nvim_win_close(win, true)
            return
          end
        end

        -- Pick the widest non-tree, non-terminal window to split under.
        local target_win = nil
        local best_width = -1
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
          local buf = vim.api.nvim_win_get_buf(win)
          local ft = vim.bo[buf].filetype
          local bt = vim.bo[buf].buftype
          if bt == '' and ft ~= 'neo-tree' then
            local w = vim.api.nvim_win_get_width(win)
            if w > best_width then
              best_width = w
              target_win = win
            end
          end
        end

        if not target_win then
          target_win = vim.api.nvim_get_current_win()
        end

        vim.api.nvim_win_call(target_win, function()
          vim.cmd 'belowright 15split'

          local buf = vim.g.ds_bottom_term_buf
          if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_win_set_buf(0, buf)
            vim.cmd 'startinsert'
            return
          end

          vim.cmd 'terminal'
          buf = vim.api.nvim_get_current_buf()
          vim.b.ds_bottom_term = true
          vim.bo.bufhidden = 'hide'
          vim.g.ds_bottom_term_buf = buf
          vim.cmd 'startinsert'
        end)
      end,
      desc = 'Toggle terminal (bottom of code panel)',
    },
    { '<leader>tb', '<leader>tt', remap = true, desc = 'Toggle terminal (bottom)' },
    { '<leader>tf', '<cmd>ToggleTerm direction=float<CR>', desc = 'Toggle terminal (float)' },
  },
}
