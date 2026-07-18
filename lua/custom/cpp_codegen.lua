-- Structured C++ generation and source/header projection.
--
-- Every action is preview-first.  The preview is rendered as a real C++ buffer
-- (therefore through the normal frontend) and `a` performs the advertised edit;
-- `y` only copies it.  Generated text is deterministic and parser-derived, but
-- semantic constraints that syntax cannot infer remain explicit comments.

local M = {}
local context = require 'custom.cpp_tools.context'
local scratch = require 'custom.cpp_tools.scratch'
local type_snippets = require 'custom.cpp_type_snippets'

local function text(node, bufnr)
  return node and vim.treesitter.get_node_text(node, bufnr) or ''
end

local function descendants(node, wanted, out)
  out = out or {}
  if wanted[node:type()] then
    out[#out + 1] = node
  end
  for child in node:iter_children() do
    descendants(child, wanted, out)
  end
  return out
end

local NAME_NODES = { field_identifier = true, identifier = true }
local function declarator_identifier(node, bufnr)
  if not node then
    return nil
  end
  if NAME_NODES[node:type()] then
    return text(node, bufnr)
  end
  local nested = node:field('declarator')[1] or node:field('name')[1] or node:field('field')[1]
  if nested and nested:id() ~= node:id() then
    local name = declarator_identifier(nested, bufnr)
    if name then
      return name
    end
  end
  for child in node:iter_children() do
    local name = declarator_identifier(child, bufnr)
    if name then
      return name
    end
  end
  return nil
end

function M.struct_fields(bufnr, type_info)
  bufnr = bufnr or 0
  local body = type_info and type_info.node:field('body')[1]
  if not body then
    return {}
  end
  local fields = {}
  for child in body:iter_children() do
    if child:type() == 'field_declaration' then
      local type_node = child:field('type')[1]
      local type_text = text(type_node, bufnr)
      local declarators = child:field 'declarator'
      for _, declarator in ipairs(declarators) do
        local name = declarator_identifier(declarator, bufnr)
        if name then
          fields[#fields + 1] = {
            name = name,
            type = type_text,
            declaration = text(child, bufnr),
            node = declarator,
          }
        end
      end
    end
  end
  return fields
end

function M.enum_values(bufnr, enum_info)
  bufnr = bufnr or 0
  local values = {}
  for _, enumerator in ipairs(descendants(enum_info.node, { enumerator = true })) do
    local name_node = enumerator:field('name')[1]
    local name = text(name_node, bufnr)
    if name ~= '' then
      values[#values + 1] = name
    end
  end
  return values
end

local function namespace_path(node, bufnr)
  local names = {}
  node = node:parent()
  while node do
    if node:type() == 'namespace_definition' then
      local name = text(node:field('name')[1], bufnr)
      if name ~= '' then
        table.insert(names, 1, name)
      end
    end
    node = node:parent()
  end
  return table.concat(names, '::')
end

local function known_structs(bufnr)
  local parser = vim.treesitter.get_parser(bufnr)
  local root = parser:parse()[1]:root()
  local out = {}
  for _, node in ipairs(descendants(root, { struct_specifier = true, class_specifier = true })) do
    local name = text(node:field('name')[1], bufnr)
    if name ~= '' then
      out[name] = true
    end
  end
  return out
end

local function nested_field(field, known)
  local declaration = field.declaration
  local optional = declaration:match 'std::optional%s*<%s*([%w_:]+)'
  local pointer = declaration:match '([%w_:]+)%s*%*'
  local candidate = optional or pointer or field.type
  local base = candidate and candidate:match '([%a_][%w_]*)%s*$'
  if base and (known[base] or base:match 'Cfg$' or base:match 'Config$') then
    return optional and 'optional' or (pointer and 'pointer' or 'value')
  end
  return nil
end

local function with_name_function(enum_name, argument, values)
  local lines = {
    '[[nodiscard]] inline def to_string(' .. enum_name .. ' ' .. argument .. ', bool include_name = false) -> std::string',
    '{',
    '    const auto body = [&]() -> std::string_view',
    '    {',
    '        using enum ' .. enum_name .. ';',
    '        switch (' .. argument .. ')',
    '        {',
  }
  for _, value in ipairs(values) do
    vim.list_extend(lines, {
      '            case ' .. value .. ':',
      '                return "' .. value .. '";',
    })
  end
  vim.list_extend(lines, {
    '        }',
    '        std::unreachable();',
    '    }();',
    '    return with_name("' .. enum_name .. '", body, include_name);',
    '}',
  })
  return table.concat(lines, '\n')
end

function M.generate_enum_to_string(name, values)
  assert(name and name ~= '', 'enum needs a name')
  assert(#values > 0, 'enum needs at least one enumerator')
  return with_name_function(name, 'value', values)
end

function M.generate_struct_to_string(name, fields)
  local lines = {
    '[[nodiscard]] inline def to_string(const ' .. name .. '& value, bool include_name = false) -> std::string',
    '{',
  }
  if #fields == 0 then
    lines[#lines + 1] = '    const auto body = std::string{};'
  else
    local labels, arguments = {}, {}
    for _, field in ipairs(fields) do
      labels[#labels + 1] = field.name .. '={}'
      arguments[#arguments + 1] = '        value.' .. field.name
    end
    lines[#lines + 1] = '    const auto body = std::format('
    lines[#lines + 1] = '        "' .. table.concat(labels, ',') .. '",'
    lines[#lines + 1] = table.concat(arguments, ',\n')
    lines[#lines + 1] = '    );'
  end
  lines[#lines + 1] = '    return with_name("' .. name .. '", body, include_name);'
  lines[#lines + 1] = '}'
  return table.concat(lines, '\n')
end

function M.generate_validity(name, fields, known)
  local base = name:gsub('Cfg$', ''):gsub('Config$', '')
  local validity_name = base .. 'Validity'
  local nested = {}
  for _, field in ipairs(fields) do
    local kind = nested_field(field, known or {})
    if kind then
      nested[#nested + 1] = { field = field, kind = kind }
    end
  end
  local values = { 'valid' }
  for _, item in ipairs(nested) do
    values[#values + 1] = 'invalid_' .. item.field.name
  end
  local lines = {
    'enum class ' .. validity_name .. ' : u8',
    '{',
    '    valid = 0,',
  }
  for index = 2, #values do
    lines[#lines + 1] = '    ' .. values[index] .. ','
  end
  vim.list_extend(lines, {
    '};',
    '',
    '[[nodiscard]] inline def validity(const ' .. name .. '& value) -> ' .. validity_name,
    '{',
    '    using enum ' .. validity_name .. ';',
  })
  for _, item in ipairs(nested) do
    local access = 'value.' .. item.field.name
    local condition
    if item.kind == 'optional' or item.kind == 'pointer' then
      condition = access .. ' and not is_valid(*' .. access .. ')'
    else
      condition = 'not is_valid(' .. access .. ')'
    end
    lines[#lines + 1] = '    if (' .. condition .. ') return invalid_' .. item.field.name .. ';'
  end
  lines[#lines + 1] = '    // Add scalar/domain-specific invalid cases here; syntax alone cannot infer them.'
  lines[#lines + 1] = '    return valid;'
  lines[#lines + 1] = '}'
  vim.list_extend(lines, {
    '',
    '[[nodiscard]] inline def is_valid(const ' .. name .. '& value) -> bool',
    '{',
    '    return std::to_underlying(validity(value)) == 0;',
    '}',
    '',
    with_name_function(validity_name, 'value', values),
  })
  return table.concat(lines, '\n'), validity_name, nested
end

-- Strip a function_definition's body (and constructor initializer list) while
-- preserving attributes, constraints, trailing return types, and noexcept.
function M.function_declaration(bufnr, function_info)
  bufnr = bufnr or 0
  local node = function_info.node
  local body = node:field('body')[1]
  if not body then
    return nil
  end
  local start_row, start_col = node:range()
  local cut_row, cut_col = body:range()
  for child in node:iter_children() do
    if child:type() == 'field_initializer_list' then
      local row, col = child:range()
      if row < cut_row or (row == cut_row and col < cut_col) then
        cut_row, cut_col = row, col
      end
    end
  end
  local prefix = table.concat(vim.api.nvim_buf_get_text(bufnr, start_row, start_col, cut_row, cut_col, {}), '\n')
  prefix = vim.trim(prefix):gsub('%s+$', '')
  return prefix .. ';'
end

local function corresponding_header(source)
  local stem = source:gsub('%.[%w]+$', '')
  for _, extension in ipairs { 'hpp', 'h', 'hh', 'hxx', 'cuh' } do
    local candidate = stem .. '.' .. extension
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return stem .. '.hpp'
end
M.corresponding_header = corresponding_header

local function function_nodes(bufnr)
  local parser = vim.treesitter.get_parser(bufnr)
  local root = parser:parse()[1]:root()
  return descendants(root, { function_definition = true })
end

local function inside_type(node)
  node = node:parent()
  while node do
    if node:type() == 'class_specifier' or node:type() == 'struct_specifier' then
      return true
    end
    if node:type() == 'namespace_definition' or node:type() == 'translation_unit' then
      return false
    end
    node = node:parent()
  end
  return false
end

local function inside_function(node)
  node = node:parent()
  while node do
    if node:type() == 'function_definition' then
      return true
    end
    if node:type() == 'namespace_definition' or node:type() == 'translation_unit' then
      return false
    end
    node = node:parent()
  end
  return false
end

function M.header_draft(bufnr, source)
  bufnr = bufnr or 0
  source = source or vim.api.nvim_buf_get_name(bufnr)
  local header = corresponding_header(source)
  local header_basename = vim.fn.fnamemodify(header, ':t')
  local includes = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match '^%s*#%s*include' then
      local target = line:match '[<"]([^>"]+)[>"]'
      if not target or vim.fn.fnamemodify(target, ':t') ~= header_basename then
        includes[#includes + 1] = line
      end
    end
  end
  local groups, order = {}, {}
  local function group(namespace)
    if not groups[namespace] then
      groups[namespace] = { types = {}, functions = {} }
      order[#order + 1] = namespace
    end
    return groups[namespace]
  end

  local parser = vim.treesitter.get_parser(bufnr)
  local root = parser:parse()[1]:root()
  for _, node in
    ipairs(descendants(root, {
      class_specifier = true,
      struct_specifier = true,
      enum_specifier = true,
    }))
  do
    if not inside_type(node) and not inside_function(node) then
      local name = text(node:field('name')[1], bufnr)
      if name ~= '' then
        local forward
        if node:type() == 'class_specifier' then
          forward = 'class ' .. name .. ';'
        elseif node:type() == 'struct_specifier' then
          forward = 'struct ' .. name .. ';'
        else
          local spelling = text(node, bufnr)
          local scoped = spelling:match '^enum%s+class' and 'enum class ' or 'enum '
          local underlying = spelling:match '^enum%s+class%s+[%w_]+%s*:%s*([^%s{]+)' or spelling:match '^enum%s+[%w_]+%s*:%s*([^%s{]+)'
          if scoped == 'enum class ' or underlying then
            forward = scoped .. name .. (underlying and (' : ' .. underlying) or '') .. ';'
          end
        end
        if forward then
          local destination = group(namespace_path(node, bufnr)).types
          destination[#destination + 1] = forward
        end
      end
    end
  end

  for _, node in ipairs(function_nodes(bufnr)) do
    if not inside_type(node) then
      local info = { node = node }
      local declaration = M.function_declaration(bufnr, info)
      local name = declaration and declaration:match '([%w_:~]+)%s*%('
      local parent = node:parent()
      local templated = parent and parent:type() == 'template_declaration'
      if
        declaration
        and name ~= 'main'
        and not (name and (name:match '::main$' or name:find('::', 1, true)))
        and not declaration:match '%f[%w]static%f[%W]'
        and not templated
      then
        local namespace = namespace_path(node, bufnr)
        local destination = group(namespace).functions
        destination[#destination + 1] = declaration
      end
    end
  end
  local relative = vim.fn.fnamemodify(header, ':.'):gsub('\\', '/')
  local lines = { '// ' .. relative, '#pragma once' }
  if #includes > 0 then
    lines[#lines + 1] = ''
    vim.list_extend(lines, includes)
  end
  for _, namespace in ipairs(order) do
    lines[#lines + 1] = ''
    if namespace ~= '' then
      lines[#lines + 1] = 'namespace ' .. namespace
      lines[#lines + 1] = '{'
    end
    vim.list_extend(lines, groups[namespace].types)
    if #groups[namespace].types > 0 and #groups[namespace].functions > 0 then
      lines[#lines + 1] = ''
    end
    vim.list_extend(lines, groups[namespace].functions)
    if namespace ~= '' then
      lines[#lines + 1] = '}  // namespace ' .. namespace
    end
  end
  lines[#lines + 1] = ''
  return table.concat(lines, '\n'), header
end

local preview_serial = 0
local function preview(title, generated, apply)
  preview_serial = preview_serial + 1
  local preview_buf
  preview_buf = scratch.open {
    key = 'codegen-' .. preview_serial,
    name = 'dans://codegen/' .. title,
    lines = vim.split(generated, '\n', { plain = true }),
    filetype = 'cpp',
    vertical = true,
    wrap = false,
    mappings = {
      a = {
        function()
          if apply then
            apply()
          end
          if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
            vim.api.nvim_buf_delete(preview_buf, { force = true })
          end
        end,
        desc = 'Apply generated C++',
      },
      y = {
        function()
          vim.fn.setreg('+', generated)
          vim.notify 'Generated C++ copied'
        end,
        desc = 'Copy generated C++',
      },
    },
  }
  return preview_buf
end
M.preview = preview

local function insert_after(source_buf, node, generated)
  local _, _, end_row = node:range()
  local insertion = vim.split('\n' .. generated .. '\n', '\n', { plain = true })
  vim.api.nvim_buf_set_lines(source_buf, end_row + 1, end_row + 1, false, insertion)
  type_snippets.add_std_includes(source_buf, generated)
  local window = vim.fn.bufwinid(source_buf)
  if window ~= -1 then
    vim.api.nvim_set_current_win(window)
    vim.api.nvim_win_set_cursor(window, { end_row + 3, 0 })
  end
end

local function preview_enum()
  local source_buf = vim.api.nvim_get_current_buf()
  local info = context.enum_at(source_buf)
  if not info or not info.name then
    return vim.notify('DansCppEnumToString: put the cursor inside a named enum', vim.log.levels.WARN)
  end
  local values = M.enum_values(source_buf, info)
  if #values == 0 then
    return vim.notify('DansCppEnumToString: enum has no values', vim.log.levels.WARN)
  end
  local generated = M.generate_enum_to_string(info.name, values)
  preview('enum-to-string-' .. info.name, generated, function()
    insert_after(source_buf, info.node, generated)
  end)
end

local function preview_struct(kind)
  local source_buf = vim.api.nvim_get_current_buf()
  local info = context.type_at(source_buf)
  if not info or not info.name then
    return vim.notify('DansCppGenerate: put the cursor inside a named struct/class', vim.log.levels.WARN)
  end
  local fields = M.struct_fields(source_buf, info)
  local generated
  if kind == 'validity' then
    generated = M.generate_validity(info.name, fields, known_structs(source_buf))
  else
    generated = M.generate_struct_to_string(info.name, fields)
  end
  preview(kind .. '-' .. info.name, generated, function()
    insert_after(source_buf, info.node, generated)
  end)
end

local function header_buffer(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].filetype = 'cpp'
  if vim.api.nvim_buf_line_count(bufnr) == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == '' then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '#pragma once', '' })
  end
  return bufnr
end

local function find_named_type(bufnr, name, namespace)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  local root = parser:parse()[1]:root()
  for _, node in ipairs(descendants(root, { class_specifier = true, struct_specifier = true })) do
    if text(node:field('name')[1], bufnr) == name and (not namespace or namespace_path(node, bufnr) == namespace) then
      return node
    end
  end
  return nil
end

local function append_declaration(header, declaration, namespace, access)
  local existing = table.concat(vim.api.nvim_buf_get_lines(header, 0, -1, false), '\n')
  local compact_existing = existing:gsub('%s+', '')

  -- An out-of-class implementation (`Foo::method`) belongs inside Foo's class
  -- body, not at namespace scope.  Locate that type in the target header and
  -- strip exactly the owner qualifier before inserting the declaration.
  local owner, method = declaration:match '([%w_~]+)::([%w_~]+)%s*%('
  local owner_node = owner and find_named_type(header, owner, namespace) or nil
  if owner_node then
    local body = owner_node:field('body')[1]
    if body then
      local _, _, end_row = body:range()
      local member = declaration:gsub(vim.pesc(owner .. '::' .. method), method, 1)
      if compact_existing:find(member:gsub('%s+', ''), 1, true) then
        vim.notify('Declaration already exists in header', vim.log.levels.INFO)
        return false
      end
      local closing = vim.api.nvim_buf_get_lines(header, end_row, end_row + 1, false)[1] or ''
      local section_indent = closing:match '^%s*' or ''
      local indent = section_indent .. string.rep(' ', vim.bo[header].shiftwidth > 0 and vim.bo[header].shiftwidth or 4)
      local lines = vim.split(member, '\n', { plain = true })
      for index, line in ipairs(lines) do
        lines[index] = indent .. vim.trim(line)
      end
      table.insert(lines, 1, section_indent .. (access or 'public') .. ':')
      vim.api.nvim_buf_set_lines(header, end_row, end_row, false, lines)
      return true
    end
  end

  local normalized = declaration:gsub('%s+', '')
  if compact_existing:find(normalized, 1, true) then
    vim.notify('Declaration already exists in header', vim.log.levels.INFO)
    return false
  end

  -- A fully-qualified free function defined outside its namespace is projected
  -- back into that namespace.  For member functions the branch above wins.
  if namespace == '' then
    local qualified = declaration:match '([%w_~:]+)%s*%('
    local prefix, local_name = qualified and qualified:match '^(.*)::([^:]+)$'
    if prefix and local_name then
      namespace = prefix
      declaration = declaration:gsub(vim.pesc(qualified), local_name, 1)
    end
  end
  local lines = { '' }
  if namespace ~= '' then
    vim.list_extend(lines, { 'namespace ' .. namespace, '{' })
  end
  vim.list_extend(lines, vim.split(declaration, '\n', { plain = true }))
  if namespace ~= '' then
    lines[#lines + 1] = '}  // namespace ' .. namespace
  end
  lines[#lines + 1] = ''
  vim.api.nvim_buf_set_lines(header, -1, -1, false, lines)
  return true
end
M.append_declaration = append_declaration

local function preview_declaration()
  local source_buf = vim.api.nvim_get_current_buf()
  local source = vim.api.nvim_buf_get_name(source_buf)
  if not context.is_source(source) then
    return vim.notify('DansCppDeclareFunction: current buffer is not a translation unit', vim.log.levels.WARN)
  end
  local info = context.function_at(source_buf)
  if not info then
    return vim.notify('DansCppDeclareFunction: put the cursor in a function definition', vim.log.levels.WARN)
  end
  local declaration = M.function_declaration(source_buf, info)
  local header = corresponding_header(source)
  local namespace = namespace_path(info.node, source_buf)
  local shown = table.concat({
    '// Target: ' .. header,
    namespace ~= '' and ('namespace ' .. namespace .. '\n{') or '',
    declaration,
    namespace ~= '' and ('}  // namespace ' .. namespace) or '',
  }, '\n')
  preview('declare-' .. (info.name or 'function'), shown, function()
    local target = header_buffer(header)
    local function finish(access)
      if append_declaration(target, declaration, namespace, access) then
        vim.api.nvim_set_current_buf(target)
        vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(target), 0 })
        vim.notify('Declaration added to ' .. header .. ' (buffer left modified for review)')
      end
    end
    local owner = declaration:match '([%w_~]+)::[%w_~]+%s*%('
    if owner and find_named_type(target, owner, namespace) then
      vim.ui.select({ 'public', 'protected', 'private' }, { prompt = owner .. ' member access:' }, function(access)
        if access then
          finish(access)
        end
      end)
    else
      finish()
    end
  end)
end

local function preview_header()
  local source_buf = vim.api.nvim_get_current_buf()
  local source = vim.api.nvim_buf_get_name(source_buf)
  if not context.is_source(source) then
    return vim.notify('DansCppHeaderDraft: current buffer is not a translation unit', vim.log.levels.WARN)
  end
  local generated, header = M.header_draft(source_buf, source)
  preview('header-draft', generated, function()
    local target = header_buffer(header)
    local current = table.concat(vim.api.nvim_buf_get_lines(target, 0, -1, false), '\n')
    if current:gsub('%s+', '') == '#pragmaonce' then
      vim.api.nvim_buf_set_lines(target, 0, -1, false, vim.split(generated, '\n', { plain = true }))
    else
      vim.notify('Header already contains code; draft was not merged. Use DansCppDeclareFunction for safe incremental insertion.', vim.log.levels.WARN)
      return
    end
    vim.api.nvim_set_current_buf(target)
    vim.notify('Header draft applied to ' .. header .. ' (buffer left modified for review)')
  end)
end

function M.choose()
  local actions = {
    {
      label = 'Validity + is_valid + to_string',
      run = function()
        preview_struct 'validity'
      end,
    },
    {
      label = 'struct to_string',
      run = function()
        preview_struct 'struct-to-string'
      end,
    },
    { label = 'enum to_string', run = preview_enum },
    { label = 'declare current function in header', run = preview_declaration },
    { label = 'create/merge header draft', run = preview_header },
  }
  vim.ui.select(actions, {
    prompt = 'C++ generation:',
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      item.run()
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('DansCppGenerate', M.choose, {
    desc = 'Choose a parser-derived C++ generation action',
  })
  vim.api.nvim_create_user_command('DansCppEnumToString', preview_enum, {
    desc = 'Preview/apply to_string for the enum under the cursor',
  })
  vim.api.nvim_create_user_command('DansCppStructToString', function()
    preview_struct 'struct-to-string'
  end, { desc = 'Preview/apply to_string for the struct under the cursor' })
  vim.api.nvim_create_user_command('DansCppValidity', function()
    preview_struct 'validity'
  end, { desc = 'Preview/apply Validity, validity(), is_valid(), and to_string()' })
  vim.api.nvim_create_user_command('DansCppDeclareFunction', preview_declaration, {
    desc = 'Preview/add the current implementation declaration to its sibling header',
  })
  vim.api.nvim_create_user_command('DansCppHeaderDraft', preview_header, {
    desc = 'Preview/apply a sibling header draft derived from the current translation unit',
  })
end

return M
