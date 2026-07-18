-- Local-only "plugin": runs the dans-tools clang-tidy plugin
-- (dans-dev-marker-tidy) on save in repos with a .dans_dev file whose
-- `marker_tidy=true` flag is set, and surfaces results as diagnostics.
return {
  name = 'dans-dev-marker-tidy-local',
  dir = vim.fn.stdpath 'config',
  lazy = false,
  config = function()
    local script = '/Users/danielsinkin/GitHub_private/dans-tools/scripts/dans-dev-marker-tidy.sh'
    local namespace = vim.api.nvim_create_namespace 'dans-dev-marker-tidy'

    local function dans_dev_root_for(path)
      if path == nil or path == '' then
        return nil
      end

      local stat = vim.uv.fs_stat(path)
      local search_start = path
      if stat == nil or stat.type ~= 'directory' then
        search_start = vim.fs.dirname(path)
      end

      local match = vim.fs.find('.dans_dev', {
        path = search_start,
        upward = true,
        type = 'file',
      })[1]

      if match == nil then
        return nil
      end

      return vim.fs.dirname(match)
    end

    local function dans_dev_config_value(root, key)
      local handle = io.open(root .. '/.dans_dev', 'r')
      if handle == nil then
        return nil
      end

      for line in handle:lines() do
        local clean_line = line:gsub('%s+#.*$', '')
        local parsed_key, value = clean_line:match '^%s*([^=]+)%s*=%s*(.-)%s*$'
        if parsed_key ~= nil and parsed_key:gsub('%s+$', '') == key then
          handle:close()
          return value
        end
      end

      handle:close()
      return nil
    end

    local function dans_dev_truthy(value)
      if value == nil then
        return false
      end
      value = value:lower()
      return value == 'true' or value == '1' or value == 'yes' or value == 'on'
    end

    local function is_buffer_in_root(bufnr, root)
      local name = vim.api.nvim_buf_get_name(bufnr)
      return root ~= nil and name:sub(1, #root) == root
    end

    local function clear_repo_diagnostics(root)
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and is_buffer_in_root(bufnr, root) then
          vim.diagnostic.set(namespace, bufnr, {})
        end
      end
    end

    local function severity_from_text(severity)
      if severity == 'error' then
        return vim.diagnostic.severity.ERROR
      end
      if severity == 'warning' then
        return vim.diagnostic.severity.WARN
      end
      if severity == 'note' then
        return vim.diagnostic.severity.INFO
      end
      return vim.diagnostic.severity.HINT
    end

    local function parse_clang_tidy_output(output)
      local diagnostics_by_file = {}
      for line in output:gmatch '[^\r\n]+' do
        local file, lnum, col, severity, message, check = line:match '^([^:]+):(%d+):(%d+): (%w+): (.-) %[([^,%]]+)'
        if file ~= nil and (check == 'dans-dev-marker-tidy') then
          diagnostics_by_file[file] = diagnostics_by_file[file] or {}
          table.insert(diagnostics_by_file[file], {
            lnum = tonumber(lnum) - 1,
            col = tonumber(col) - 1,
            severity = severity_from_text(severity),
            source = check,
            message = message,
          })
        end
      end
      return diagnostics_by_file
    end

    local function run_dans_dev_marker_tidy()
      local current_file = vim.api.nvim_buf_get_name(0)
      local repo_root = dans_dev_root_for(current_file)
      if repo_root == nil then
        return
      end
      if not dans_dev_truthy(dans_dev_config_value(repo_root, 'marker_tidy')) then
        clear_repo_diagnostics(repo_root)
        return
      end
      if vim.fn.executable(script) ~= 1 then
        return
      end

      vim.system({ script }, { cwd = repo_root, text = true }, function(result)
        local output = table.concat({ result.stdout or '', result.stderr or '' }, '\n')
        local diagnostics_by_file = parse_clang_tidy_output(output)

        vim.schedule(function()
          clear_repo_diagnostics(repo_root)
          for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr) and is_buffer_in_root(bufnr, repo_root) then
              local file = vim.api.nvim_buf_get_name(bufnr)
              vim.diagnostic.set(namespace, bufnr, diagnostics_by_file[file] or {})
            end
          end
        end)
      end)
    end

    vim.api.nvim_create_user_command('DansDevMarkerTidy', run_dans_dev_marker_tidy, {})

    local group = vim.api.nvim_create_augroup('dans-dev-marker-tidy', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      pattern = {
        '*.cc',
        '*.cpp',
        '*.cxx',
        '*.hpp',
      },
      callback = run_dans_dev_marker_tidy,
    })
  end,
}
