-- Neovim client for the deterministic headless C++ physical-project index.
--
-- The Python process owns filesystem/build-model observation and returns a
-- stable JSON document.  This module owns only project-root discovery,
-- cancellable process lifecycle, and inspectable scratch-buffer presentation.
-- It never edits the inspected project.

local M = {}

local jobs = require 'custom.cpp_tools.jobs'
local scratch = require 'custom.cpp_tools.scratch'

local last_index = {}

local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

local function directory_of(path)
  if path == nil or path == '' then
    return normalize(vim.fn.getcwd())
  end
  path = normalize(path)
  if vim.fn.isdirectory(path) == 1 then
    return path
  end
  return vim.fn.fnamemodify(path, ':h')
end

local ROOT_MARKERS = {
  '.dans-project.json',
  'compile_commands.json',
  'build/compile_commands.json',
  'CMakeLists.txt',
  '.git',
}

function M.find_root(path)
  local directory = directory_of(path)
  while directory and directory ~= '' do
    for _, marker in ipairs(ROOT_MARKERS) do
      local candidate = directory .. '/' .. marker
      if vim.fn.filereadable(candidate) == 1 or vim.fn.isdirectory(candidate) == 1 then
        return normalize(directory)
      end
    end
    local parent = vim.fn.fnamemodify(directory, ':h')
    if parent == directory then
      break
    end
    directory = parent
  end
  return directory_of(path)
end

local function tool_path()
  return normalize(vim.fn.stdpath('config') .. '/tools/cpp_project_index')
end
M.tool_path = tool_path

local function key_for(root, suffix)
  return 'cpp-project-' .. vim.fn.sha256(root):sub(1, 12) .. (suffix or '')
end

local function relative_file(root, path)
  root, path = normalize(root), normalize(path)
  local prefix = root:gsub('/+$', '') .. '/'
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

function M.scan(root, options, callback)
  options = options or {}
  root = normalize(root)
  local argv = { tool_path(), '--root', root }
  if options.config then
    vim.list_extend(argv, { '--config', options.config })
  end
  if options.compile_commands then
    vim.list_extend(argv, { '--compile-commands', options.compile_commands })
  end
  if options.cmake_reply then
    vim.list_extend(argv, { '--cmake-reply', options.cmake_reply })
  end
  local process, err = jobs.start(key_for(root), argv, { cwd = root }, function(result)
    if result.code ~= 0 then
      local message = result.stderr and result.stderr ~= '' and result.stderr or result.stdout or ''
      callback(nil, vim.trim(message))
      return
    end
    local ok, index = pcall(vim.json.decode, result.stdout)
    if not ok or type(index) ~= 'table' or index.schema_version ~= 1 then
      callback(nil, 'cpp_project_index returned malformed or unsupported JSON')
      return
    end
    last_index[root] = index
    callback(index)
  end)
  if not process then
    callback(nil, 'could not start cpp_project_index: ' .. tostring(err))
  end
  return process
end

local function comma(values)
  return #values > 0 and table.concat(values, ', ') or '-'
end

local function optional(value, fallback)
  if value == nil or value == vim.NIL then
    return fallback or '-'
  end
  return tostring(value)
end

function M.render(index)
  local lines, locations = {}, {}
  local function add(line, path)
    lines[#lines + 1] = line
    if path then
      locations[#lines] = path
    end
  end
  local summary = index.summary
  add 'Dans C++ physical project index'
  add '================================'
  add('root:             ' .. index.root)
  add('configuration:    ' .. optional(index.inputs.configuration.path))
  add('compile database: ' .. optional(index.inputs.compile_database))
  add('CMake codemodel:  ' .. optional(index.inputs.cmake_file_api_reply))
  add ''
  add(string.format(
    'files %d | components %d | profiles %d | targets %d | edges %d | cycles %d',
    summary.files,
    summary.components,
    summary.profiles,
    summary.targets,
    summary.component_edges,
    summary.cycles
  ))
  add ''
  add 'Components'
  add '----------'
  for _, component in ipairs(index.components) do
    local path = component.headers[1] or component.module_interfaces[1] or component.sources[1]
    add(string.format(
      '%-30s %-28s targets=[%s]',
      component.id,
      component.kind,
      comma(component.target_ids)
    ), path)
  end
  add ''
  add 'Observed component dependencies'
  add '-------------------------------'
  if #index.component_dependencies == 0 then
    add '(none)'
  else
    for _, edge in ipairs(index.component_dependencies) do
      local evidence = edge.evidence[1]
      add(string.format(
        '%s -> %s  [%s; %d include%s]',
        edge.from,
        edge.to,
        edge.kind,
        #edge.evidence,
        #edge.evidence == 1 and '' or 's'
      ), evidence and evidence.file)
    end
  end
  if #index.component_cycles > 0 then
    add ''
    add 'Observed cycles'
    add '---------------'
    for _, cycle in ipairs(index.component_cycles) do
      add(table.concat(cycle, ' -> ') .. ' -> ' .. cycle[1])
    end
  end
  add ''
  add 'Diagnostics'
  add '-----------'
  if #index.diagnostics == 0 then
    add '(none)'
  else
    for _, diagnostic in ipairs(index.diagnostics) do
      local source = diagnostic.path and (' ' .. diagnostic.path .. (diagnostic.line and ':' .. diagnostic.line or '')) or ''
      add(string.format('[%s/%s]%s %s', diagnostic.severity, diagnostic.code, source, diagnostic.message), diagnostic.path)
    end
  end
  add ''
  add '<CR> open evidence  |  J raw JSON  |  r rescan  |  q close'
  return lines, locations
end

local function open_raw(index)
  scratch.open {
    key = key_for(index.root, '-json'),
    name = 'dans://cpp-project-json/' .. vim.fn.sha256(index.root):sub(1, 12),
    filetype = 'json',
    lines = vim.split(vim.json.encode(index), '\n', { plain = true }),
    wrap = false,
  }
end

local function open_index(index)
  local lines, locations = M.render(index)
  local bufnr
  bufnr = scratch.open {
    key = key_for(index.root, '-index'),
    name = 'dans://cpp-project/' .. vim.fn.sha256(index.root):sub(1, 12),
    filetype = 'text',
    lines = lines,
    wrap = false,
    mappings = {
      ['<CR>'] = {
        function()
          local row = vim.api.nvim_win_get_cursor(0)[1]
          local path = locations[row]
          if path then
            vim.cmd.edit(vim.fn.fnameescape(index.root .. '/' .. path))
          end
        end,
        desc = 'Open component/include evidence',
      },
      J = { function()
        open_raw(index)
      end, desc = 'Show raw project-index JSON' },
      r = { function()
        M.show { root = index.root }
      end, desc = 'Rescan C++ project' },
    },
  }
  return bufnr
end

local function open_loading(root, suffix, label)
  local view_name = suffix == '-index' and 'cpp-project' or ('cpp-project-' .. suffix:gsub('^-', ''))
  return scratch.open {
    key = key_for(root, suffix),
    name = 'dans://' .. view_name .. '/' .. vim.fn.sha256(root):sub(1, 12),
    filetype = 'text',
    lines = { label, '', root },
    wrap = false,
  }
end

function M.show(options)
  options = options or {}
  local source = options.file or vim.api.nvim_buf_get_name(0)
  local root = normalize(options.root or M.find_root(source))
  local loading = open_loading(root, '-index', 'Indexing C++ project...')
  M.scan(root, options, function(index, err)
    if err then
      scratch.set_lines(loading, { 'C++ project index failed', '', err })
      return
    end
    open_index(index)
  end)
end

function M.why_lines(index, source_path, line)
  local relative = relative_file(index.root, source_path)
  local source
  for _, file in ipairs(index.files) do
    if file.path == relative then
      source = file
      break
    end
  end
  if not source then
    return nil, 'Current file is not part of the physical project index: ' .. relative
  end
  local include
  for _, candidate in ipairs(source.includes) do
    if candidate.line == line then
      include = candidate
      break
    end
  end
  if not include then
    return nil, 'Cursor is not on a directly spelled include.'
  end
  local lines = {
    'Why this include?',
    '=================',
    'source:              ' .. source.path .. ':' .. include.line,
    'spelling:            ' .. include.spelling,
    'delimiter:           ' .. include.delimiter,
    'resolved provider:   ' .. optional(include.resolved),
    'classification:      ' .. include.classification,
    'provider component:  ' .. optional(include.provider_component_id),
    'resolution route:    ' .. include.resolution,
    'search root:         ' .. optional(include.search_root),
    'root provenance:     ' .. optional(include.search_root_provenance),
    'compilation profiles:' .. (#include.profile_ids > 0 and (' ' .. table.concat(include.profile_ids, ', ')) or ' -'),
    'conditional depth:   ' .. include.conditional_depth,
  }
  if #include.conditions > 0 then
    lines[#lines + 1] = 'conditions:'
    for _, condition in ipairs(include.conditions) do
      lines[#lines + 1] = string.format(
        '  line %d: #%s %s',
        condition.line,
        condition.directive,
        condition.expression
      )
    end
  end
  if #include.alternatives > 0 then
    lines[#lines + 1] = 'shadowed alternatives:'
    for _, alternative in ipairs(include.alternatives) do
      lines[#lines + 1] = '  ' .. alternative
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'This is observed compiler/filesystem provenance, not a declared module permission.'
  return lines
end

function M.why(options)
  options = options or {}
  local source_path = options.file or vim.api.nvim_buf_get_name(0)
  local line = options.line or vim.api.nvim_win_get_cursor(0)[1]
  local root = normalize(options.root or M.find_root(source_path))
  local loading = open_loading(root, '-why', 'Resolving include provenance...')
  M.scan(root, options, function(index, err)
    if err then
      scratch.set_lines(loading, { 'Include provenance failed', '', err })
      return
    end
    local lines, why_err = M.why_lines(index, source_path, line)
    scratch.set_lines(loading, lines or { 'No include provenance', '', why_err })
  end)
end

function M.raw(options)
  options = options or {}
  local source = options.file or vim.api.nvim_buf_get_name(0)
  local root = normalize(options.root or M.find_root(source))
  if last_index[root] then
    open_raw(last_index[root])
    return
  end
  M.scan(root, options, function(index, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    else
      open_raw(index)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('DansCppProjectIndex', function()
    M.show()
  end, { desc = 'Inspect deterministic C++ file/component/include/build ownership' })
  vim.api.nvim_create_user_command('DansCppProjectWhy', function()
    M.why()
  end, { desc = 'Explain the direct include under the cursor' })
  vim.api.nvim_create_user_command('DansCppProjectJson', function()
    M.raw()
  end, { desc = 'Show the raw headless C++ project index' })
end

return M
