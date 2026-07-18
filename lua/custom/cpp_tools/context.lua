-- Shared C/C++/CUDA source and compilation context.
--
-- Assembly, probes, and code generation must agree about which syntax node is
-- active and how the project compiles a translation unit.  This module is the
-- single implementation of compile_commands discovery/parsing, argv cleanup,
-- compiler fallback, and Tree-sitter ancestry used by those tools.

local M = {}

M.SOURCE_EXTENSIONS = { c = true, cc = true, cpp = true, cxx = true, cu = true }
M.HEADER_EXTENSIONS = { h = true, hh = true, hpp = true, hxx = true, cuh = true }

local database_cache = {}

local function normalize(path)
  if not path or path == '' then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end
M.normalize = normalize

function M.extension(path)
  return ((path or ''):match '%.([%w]+)$' or ''):lower()
end

function M.is_source(path)
  return M.SOURCE_EXTENSIONS[M.extension(path)] == true
end

-- Shell-like splitting for the legacy compile_commands `command` field.  Most
-- generators provide `arguments`; this fallback handles whitespace, quotes,
-- and backslash escaping without invoking a shell.
function M.split_command(command)
  local out, token = {}, {}
  local quote, escaped = nil, false
  local function finish()
    if #token > 0 then
      out[#out + 1] = table.concat(token)
      token = {}
    end
  end
  for index = 1, #command do
    local char = command:sub(index, index)
    if escaped then
      token[#token + 1], escaped = char, false
    elseif char == '\\' and quote ~= "'" then
      escaped = true
    elseif quote then
      if char == quote then
        quote = nil
      else
        token[#token + 1] = char
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char:match '%s' then
      finish()
    else
      token[#token + 1] = char
    end
  end
  if escaped then
    token[#token + 1] = '\\'
  end
  finish()
  return out
end

function M.find_compile_database(file)
  local directory = vim.fn.fnamemodify(file, ':p:h')
  while directory and directory ~= '' do
    for _, relative in ipairs { 'compile_commands.json', 'build/compile_commands.json' } do
      local candidate = directory .. '/' .. relative
      if vim.fn.filereadable(candidate) == 1 then
        return normalize(candidate)
      end
    end
    local parent = vim.fn.fnamemodify(directory, ':h')
    if parent == directory then
      break
    end
    directory = parent
  end
  return nil
end

local function read_database(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  local stamp = stat and string.format('%s:%s:%s', stat.size or 0, stat.mtime.sec or 0, stat.mtime.nsec or 0) or ''
  local cached = database_cache[path]
  if cached and cached.stamp == stamp then
    return cached.data
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  database_cache[path] = { stamp = stamp, data = data }
  return data
end

local function entry_file(entry)
  if not entry.file then
    return nil
  end
  if entry.file:sub(1, 1) == '/' or entry.file:match '^%a:[/\\]' then
    return normalize(entry.file)
  end
  return normalize((entry.directory or '.') .. '/' .. entry.file)
end

function M.compile_entry(file)
  local database = M.find_compile_database(file)
  if not database then
    return nil
  end
  local target = normalize(file)
  for _, entry in ipairs(read_database(database) or {}) do
    if entry_file(entry) == target then
      return entry, database
    end
  end
  return nil
end

local DROP_ONE = {
  ['-c'] = true,
  ['-S'] = true,
  ['-E'] = true,
  ['-M'] = true,
  ['-MM'] = true,
  ['-MD'] = true,
  ['-MMD'] = true,
  ['-MG'] = true,
  ['-MP'] = true,
  ['/c'] = true,
}
local DROP_PAIR = {
  ['-o'] = true,
  ['-MF'] = true,
  ['-MT'] = true,
  ['-MQ'] = true,
  ['-MJ'] = true,
  ['--serialize-diagnostics'] = true,
  ['/Fo'] = true,
  ['/Fd'] = true,
}

local function same_input(argument, original, cwd)
  if not argument or argument:sub(1, 1) == '-' then
    return false
  end
  local candidate = argument
  if not (candidate:sub(1, 1) == '/' or candidate:match '^%a:[/\\]') then
    candidate = (cwd or '.') .. '/' .. candidate
  end
  return normalize(candidate) == normalize(original)
end

-- Remove compile-only/output/dependency flags and the database's original input
-- while retaining the compiler executable and project-specific defines/includes.
-- `options.mode` selects the deterministic tail:
--   assembly: -S -g -O<opt> -o - <input>
--   link:     -g -O<opt> <input> -o <output>, with section GC for probe isolation
function M.sanitize_arguments(argv, original, options)
  options = options or {}
  local out, index = {}, 1
  while index <= #argv do
    local argument = argv[index]
    if DROP_PAIR[argument] then
      index = index + 2
    elseif
      DROP_ONE[argument]
      or argument:match '^%-O'
      or argument:match '^/O[12dx]'
      or argument:match '^%-o.+'
      or argument:match '^%-M[FTQJ].+'
      or argument:match '^%-%-serialize%-diagnostics='
      or same_input(argument, original, options.cwd)
    then
      index = index + 1
    else
      out[#out + 1] = argument
      index = index + 1
    end
  end

  local opt = tostring(options.opt or (options.mode == 'link' and '0' or '2')):gsub('^%-?O', '')
  if options.mode == 'assembly' then
    vim.list_extend(out, { '-S', '-g', '-O' .. opt, '-o', '-', assert(options.input) })
  elseif options.mode == 'link' then
    vim.list_extend(out, { '-g', '-O' .. opt, '-ffunction-sections', '-fdata-sections', assert(options.input) })
    if options.gc_sections ~= false then
      out[#out + 1] = '-Wl,--gc-sections'
    end
    vim.list_extend(out, { '-o', assert(options.output) })
  else
    error('unknown compilation mode: ' .. tostring(options.mode))
  end
  vim.list_extend(out, options.extra or {})
  return out
end

local function fallback_compiler(file)
  local candidates = {}
  local function configured(value)
    if value and value ~= '' then
      candidates[#candidates + 1] = value
    end
  end
  if M.extension(file) == 'cu' then
    configured(vim.g.dans_cuda_compiler)
    vim.list_extend(candidates, { 'nvcc', 'clang++' })
  elseif M.extension(file) == 'c' then
    configured(vim.g.dans_c_compiler)
    vim.list_extend(candidates, { 'clang', 'gcc', 'cc' })
  else
    configured(vim.g.dans_cpp_compiler)
    configured(vim.g.dans_asm_compiler)
    vim.list_extend(candidates, { 'clang++', 'g++', 'c++' })
  end
  for _, compiler in ipairs(candidates) do
    if compiler and vim.fn.executable(compiler) == 1 then
      return compiler
    end
  end
  return nil
end

function M.compile_command(file, options)
  options = vim.tbl_extend('force', {}, options or {})
  local entry, database = M.compile_entry(file)
  if entry then
    local argv = entry.arguments or M.split_command(entry.command or '')
    if argv and #argv > 0 then
      options.cwd = entry.directory or vim.fn.fnamemodify(file, ':p:h')
      return {
        argv = M.sanitize_arguments(vim.deepcopy(argv), entry_file(entry) or file, options),
        cwd = options.cwd,
        database = database,
        source = 'compile_commands',
      }
    end
  end
  local compiler = fallback_compiler(file)
  if not compiler then
    return nil
  end
  local standard = M.extension(file) == 'c' and '-std=c23' or '-std=c++23'
  local argv = { compiler, standard }
  vim.list_extend(argv, options.fallback_flags or {})
  options.cwd = vim.fn.fnamemodify(file, ':p:h')
  return {
    argv = M.sanitize_arguments(argv, file, options),
    cwd = options.cwd,
    database = nil,
    source = 'fallback',
  }
end

local function node_at(bufnr, row0, col0)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  local root = trees[1] and trees[1]:root()
  if not root then
    return nil
  end
  return root:named_descendant_for_range(row0, col0, row0, col0)
end
M.node_at = node_at

function M.ancestor(bufnr, node_types, row0, col0)
  local wanted = type(node_types) == 'table' and node_types or { [node_types] = true }
  local node = node_at(bufnr, row0, col0)
  while node do
    if wanted[node:type()] then
      return node
    end
    node = node:parent()
  end
  return nil
end

local NAME_NODE = {
  identifier = true,
  field_identifier = true,
  operator_name = true,
  destructor_name = true,
  qualified_identifier = true,
  scoped_identifier = true,
  template_function = true,
}

local function declarator_name(node, bufnr)
  if not node then
    return nil
  end
  if NAME_NODE[node:type()] then
    return vim.treesitter.get_node_text(node, bufnr)
  end
  local field = node:field('declarator')[1] or node:field('name')[1]
  if field and field:id() ~= node:id() then
    local nested = declarator_name(field, bufnr)
    if nested then
      return nested
    end
  end
  for child in node:iter_children() do
    local nested = declarator_name(child, bufnr)
    if nested then
      return nested
    end
  end
  return nil
end

local function namespace_prefix(node, bufnr)
  local names = {}
  node = node and node:parent()
  while node do
    if node:type() == 'namespace_definition' then
      local name_node = node:field('name')[1]
      local name = name_node and vim.treesitter.get_node_text(name_node, bufnr)
      if name and name ~= '' then
        table.insert(names, 1, name)
      end
    end
    node = node:parent()
  end
  return table.concat(names, '::')
end

function M.function_at(bufnr, row0, col0)
  bufnr = bufnr or 0
  if row0 == nil then
    local cursor = vim.api.nvim_win_get_cursor(0)
    row0, col0 = cursor[1] - 1, cursor[2]
  end
  local node = M.ancestor(bufnr, { function_definition = true }, row0, col0 or 0)
  if not node then
    return nil
  end
  local declarator = node:field('declarator')[1]
  local name = declarator_name(declarator, bufnr)
  local prefix = namespace_prefix(node, bufnr)
  local qualified_name = name
  if name and prefix ~= '' and not name:find('::', 1, true) then
    qualified_name = prefix .. '::' .. name
  end
  local start_row, start_col, end_row, end_col = node:range()
  return {
    node = node,
    declarator = declarator,
    name = name,
    qualified_name = qualified_name,
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    first_line = start_row + 1,
    last_line = end_row + 1,
  }
end

function M.type_at(bufnr, row0, col0)
  bufnr = bufnr or 0
  if row0 == nil then
    local cursor = vim.api.nvim_win_get_cursor(0)
    row0, col0 = cursor[1] - 1, cursor[2]
  end
  local node = M.ancestor(bufnr, { struct_specifier = true, class_specifier = true }, row0, col0 or 0)
  if not node then
    return nil
  end
  local name_node = node:field('name')[1]
  local start_row, start_col, end_row, end_col = node:range()
  return {
    node = node,
    name = name_node and vim.treesitter.get_node_text(name_node, bufnr) or nil,
    kind = node:type() == 'class_specifier' and 'class' or 'struct',
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
  }
end

function M.enum_at(bufnr, row0, col0)
  bufnr = bufnr or 0
  if row0 == nil then
    local cursor = vim.api.nvim_win_get_cursor(0)
    row0, col0 = cursor[1] - 1, cursor[2]
  end
  local node = M.ancestor(bufnr, { enum_specifier = true }, row0, col0 or 0)
  if not node then
    return nil
  end
  local name_node = node:field('name')[1]
  local start_row, start_col, end_row, end_col = node:range()
  return {
    node = node,
    name = name_node and vim.treesitter.get_node_text(name_node, bufnr) or nil,
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
  }
end

function M.clear_cache()
  database_cache = {}
end

return M
