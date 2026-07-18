-- Debug Adapter Protocol. Prefers CodeLLDB on macOS, falls back to lldb-dap.
-- nvim-dap-julia wires DebugAdapter.jl into its own Julia env on build
-- (Pkg.update so it re-resolves for the local Julia version, not the shipped manifest).
--
-- Loaded on first debug keypress / :Dap* command: the eager load (dap + dapui +
-- nio + virtual-text + mason-nvim-dap) cost ~140 ms of every startup, all of it
-- for sessions that never debug.
return {
  'mfussenegger/nvim-dap',
  keys = {
    {
      '<F5>',
      function()
        require('dap').continue()
      end,
      desc = 'DAP: Continue',
    },
    {
      '<F10>',
      function()
        require('dap').step_over()
      end,
      desc = 'DAP: Step over',
    },
    {
      '<F11>',
      function()
        require('dap').step_into()
      end,
      desc = 'DAP: Step into',
    },
    {
      '<F12>',
      function()
        require('dap').step_out()
      end,
      desc = 'DAP: Step out',
    },
    {
      '<leader>db',
      function()
        require('dap').toggle_breakpoint()
      end,
      desc = 'DAP: Toggle breakpoint',
    },
    {
      '<leader>dB',
      function()
        require('dap').set_breakpoint(vim.fn.input 'Breakpoint condition: ')
      end,
      desc = 'DAP: Conditional breakpoint',
    },
    {
      '<leader>dr',
      function()
        require('dap').repl.open()
      end,
      desc = 'DAP: Open REPL',
    },
    {
      '<leader>dl',
      function()
        require('dap').run_last()
      end,
      desc = 'DAP: Run last',
    },
    {
      '<leader>du',
      function()
        require('dapui').toggle()
      end,
      desc = 'DAP: Toggle UI',
    },
  },
  cmd = { 'DapContinue', 'DapToggleBreakpoint', 'DapStepOver', 'DapStepInto', 'DapStepOut', 'DapTerminate' },
  dependencies = {
    {
      'rcarriga/nvim-dap-ui',
      dependencies = { 'nvim-neotest/nvim-nio' },
    },
    {
      'theHamsta/nvim-dap-virtual-text',
      opts = {
        enabled = true,
        enabled_commands = true,
        highlight_changed_variables = false,
        show_stop_reason = false,
        commented = true,
        virt_text_pos = 'eol',
        virt_text_win_col = nil,
        all_frames = false,
        virt_lines = false,
        virt_text_priority = 200,
      },
    },
    {
      'jay-babu/mason-nvim-dap.nvim',
      dependencies = { 'williamboman/mason.nvim' },
      opts = {
        automatic_installation = true,
        handlers = {},
        ensure_installed = { 'codelldb' },
      },
    },
    {
      'kdheepak/nvim-dap-julia',
      build = "julia --project=. -e 'using Pkg; Pkg.update()'",
    },
  },
  config = function()
    local debugger = {
      core = require('dap'),
      ui = require('dapui'),
    }
    local dap, dapui = debugger.core, debugger.ui

    dapui.setup {
      layouts = {
        {
          position = 'left',
          size = 40,
          elements = {
            { id = 'scopes', size = 0.45 },
            { id = 'watches', size = 0.30 },
            { id = 'stacks', size = 0.20 },
            { id = 'breakpoints', size = 0.05 },
          },
        },
        {
          position = 'bottom',
          size = 10,
          elements = {
            { id = 'repl', size = 0.5 },
            { id = 'console', size = 0.5 },
          },
        },
      },
    }

    vim.api.nvim_set_hl(0, 'DapVirtualText', { fg = '#6b7280', italic = false })
    vim.api.nvim_set_hl(0, 'DapVirtualTextChanged', { fg = '#9ca3af', italic = false })
    vim.api.nvim_set_hl(0, 'DapVirtualTextError', { fg = '#9ca3af', italic = false })

    -- Red disc breakpoint signs.
    vim.fn.sign_define('DapBreakpoint', { text = '🔴', texthl = '', linehl = '', numhl = '' })
    vim.fn.sign_define('DapBreakpointCondition', { text = '🔴', texthl = '', linehl = '', numhl = '' })
    vim.fn.sign_define('DapBreakpointRejected', { text = '🔴', texthl = '', linehl = '', numhl = '' })

    dap.listeners.after.event_initialized['dapui_config'] = function()
      dapui.open()
    end
    dap.listeners.before.event_terminated['dapui_config'] = function()
      dapui.close()
    end
    dap.listeners.before.event_exited['dapui_config'] = function()
      dapui.close()
    end

    local mason_data = vim.fn.stdpath 'data'
    local codelldb_adapter = mason_data .. '/mason/packages/codelldb/extension/adapter/codelldb'
    local lldb_dap_mason = mason_data .. '/mason/bin/lldb-dap'
    local lldb_dap_homebrew = '/opt/homebrew/opt/llvm/bin/lldb-dap'

    if vim.fn.executable(codelldb_adapter) == 1 then
      dap.adapters.codelldb = {
        type = 'server',
        port = '${port}',
        executable = {
          command = codelldb_adapter,
          args = { '--port', '${port}' },
        },
      }
    else
      local lldb_dap = (vim.fn.executable(lldb_dap_mason) == 1 and lldb_dap_mason)
        or (vim.fn.executable(lldb_dap_homebrew) == 1 and lldb_dap_homebrew)
        or 'lldb-dap'

      dap.adapters.lldb = {
        type = 'executable',
        command = lldb_dap,
        name = 'lldb',
      }
    end

    local function default_program()
      return vim.fn.getcwd() .. '/build/main'
    end

    local function split_args(s)
      if s == nil or s == '' then
        return {}
      end
      return vim.split(s, '%s+')
    end

    local preferred_type = (dap.adapters.codelldb ~= nil) and 'codelldb' or 'lldb'

    dap.configurations.cpp = {
      {
        name = 'Launch build/main',
        type = preferred_type,
        request = 'launch',
        program = default_program,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
        args = {},
        terminal = 'integrated',
      },
      {
        name = 'Launch (prompt)',
        type = preferred_type,
        request = 'launch',
        program = function()
          return vim.fn.input('Path to executable: ', default_program(), 'file')
        end,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
        args = function()
          return split_args(vim.fn.input 'Args (space-separated): ')
        end,
        terminal = 'integrated',
      },
      {
        name = 'Attach to process',
        type = preferred_type,
        request = 'attach',
        pid = require('dap.utils').pick_process,
        cwd = '${workspaceFolder}',
      },
    }
    dap.configurations.c = dap.configurations.cpp

    pcall(function()
      require('nvim-dap-julia').setup()
    end)
  end,
}
