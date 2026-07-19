-- Conventional C#/Python support contract: literal monochrome source, no C++
-- frontend decorations, enabled language-server configs, shared navigation
-- mappings, and a real Python cross-file definition request.

local Support = require('custom.language_support')
local Mode = require('custom.dans_mode')

local pass, fail, failures = 0, 0, {}

local function eq(description, actual, expected)
  if vim.deep_equal(actual, expected) then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = string.format(
      'FAIL  %s\n        exp: %s\n        got: %s',
      description,
      vim.inspect(expected),
      vim.inspect(actual)
    )
  end
end

local function ok(description, condition)
  eq(description, not not condition, true)
end

local function highlight_link(name)
  return vim.api.nvim_get_hl(0, { name = name, link = true }).link
end

local function highlight_attributes(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local function open_scratch(name, filetype, lines, query_language)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  vim.wo.conceallevel = 2 -- simulate a window inherited from the C++ frontend
  vim.bo[bufnr].filetype = filetype
  vim.cmd('doautocmd BufWinEnter')

  local parser_ready = vim.wait(30000, function()
    return Support.apply_presentation(filetype)
  end, 100)
  ok(filetype .. ' Tree-sitter query becomes available', parser_ready)
  if parser_ready then
    local parser_ok = pcall(function()
      vim.treesitter.get_parser(bufnr, query_language):parse()
      vim.treesitter.start(bufnr, query_language)
    end)
    ok(filetype .. ' Tree-sitter parser starts', parser_ok)
  end
  return bufnr
end

local csharp_source = {
  'using System;',
  '',
  '/// A literal C# type.',
  'public sealed class Greeter',
  '{',
  '    public static string Message(int count) => $"hello {count}";',
  '}',
}
local csharp = open_scratch('/tmp/dans-language-support.cs', 'cs', csharp_source, 'c_sharp')
eq('C# resets inherited conceallevel', vim.wo.conceallevel, 0)
eq('C# leaves every source byte unchanged', vim.api.nvim_buf_get_lines(csharp, 0, -1, false), csharp_source)
eq('C# keywords are monochrome', highlight_link('@keyword.c_sharp'), 'Normal')
eq('C# strings are monochrome', highlight_link('@string.c_sharp'), 'Normal')
eq('C# documentation comments stay dim', highlight_link('@comment.documentation.c_sharp'), 'Comment')

local frontend_namespaces = {
  'ds_frontend_view',
  'ds_cpp_aliases',
  'ds_cpp_pointer',
  'ds_cpp_doc_md',
  'ds_cpp_scope',
}
for _, name in ipairs(frontend_namespaces) do
  local namespace = vim.api.nvim_get_namespaces()[name]
  eq('C# receives no ' .. name .. ' frontend marks', vim.api.nvim_buf_get_extmarks(csharp, namespace, 0, -1, {}), {})
end

-- The generic LspAttach layer is what supplies gd/gr/gI/rename/code actions to
-- Roslyn. A synthetic attachment is enough to exercise the deterministic local
-- mapping and C# semantic-color opt-out without requiring the host's .NET SDK.
vim.api.nvim_exec_autocmds('LspAttach', { buffer = csharp, data = { client_id = -1 } })
local csharp_maps = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(csharp, 'n')) do
  csharp_maps[mapping.lhs] = mapping
end
ok('C# gets the shared gd definition mapping', csharp_maps.gd and csharp_maps.gd.desc:find('[D]efinition', 1, true))
ok('C# gets the shared references mapping', csharp_maps.gr and csharp_maps.gr.desc:find('[R]eferences', 1, true))
eq('C# semantic-token syntax coloring is disabled', vim.lsp.semantic_tokens.is_enabled { bufnr = csharp }, false)

local roslyn = vim.lsp.config.roslyn_ls
ok('Roslyn LSP config is enabled', vim.lsp.is_enabled('roslyn_ls'))
eq('Roslyn starts through the Mason command', roslyn.cmd, { 'roslyn-language-server', '--stdio' })
eq('Roslyn is scoped to C# buffers', roslyn.filetypes, { 'cs' })

local temp_root = vim.fn.tempname()
vim.fn.mkdir(temp_root, 'p')
local cs_project = temp_root .. '/Example.csproj'
local cs_file = temp_root .. '/Program.cs'
vim.fn.writefile({ '<Project Sdk="Microsoft.NET.Sdk" />' }, cs_project)
vim.fn.writefile(csharp_source, cs_file)
local root_buffer = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(root_buffer, cs_file)
vim.api.nvim_set_current_buf(root_buffer)
local detected_cs_root
roslyn.root_dir(root_buffer, function(root)
  detected_cs_root = root
end)
eq('Roslyn discovers a csproj workspace', detected_cs_root, temp_root)

local python_source = {
  'from definitions import answer',
  '',
  'value = answer()',
  'print(f"answer: {value}")',
}
local definitions_source = {
  'def answer() -> int:',
  '    """Return the answer."""',
  '    return 42',
}
vim.fn.writefile({ '[project]', 'name = "dans-language-support"', 'version = "0.0.0"' }, temp_root .. '/pyproject.toml')
vim.fn.writefile(definitions_source, temp_root .. '/definitions.py')
vim.fn.writefile(python_source, temp_root .. '/main.py')

local python = open_scratch(temp_root .. '/buffer.py', 'python', python_source, 'python')
eq('Python resets inherited conceallevel', vim.wo.conceallevel, 0)
eq('Python leaves every source byte unchanged', vim.api.nvim_buf_get_lines(python, 0, -1, false), python_source)
eq('Python keywords are monochrome', highlight_link('@keyword.python'), 'Normal')
eq('Python strings are monochrome', highlight_link('@string.python'), 'Normal')
eq('Python comments stay dim', highlight_link('@comment.python'), 'Comment')
eq('Python docstrings stay dim', highlight_link('@string.documentation.python'), 'Comment')

-- The owner-facing monochrome preference applies to these conventional
-- languages even while the C++ frontend remains globally enabled elsewhere.
eq(
  'Python can disable monochrome while the C++ frontend remains enabled',
  Mode.set_monochrome(false, { silent = true, bufnr = python }),
  true
)
eq('C++ frontend state is unchanged by the Python palette choice', Mode.frontend_enabled(), true)
eq('Python reports normal highlighting in its own context', Mode.monochrome_effective(python), false)
eq('C# shares the requested normal palette', Mode.monochrome_effective(csharp), false)
local normal_palette_ready = vim.wait(3000, function()
  return not vim.deep_equal(highlight_attributes('@keyword.python'), highlight_attributes('Normal'))
    and not vim.deep_equal(highlight_attributes('@keyword.c_sharp'), highlight_attributes('Normal'))
end, 20)
ok('normal C#/Python Tree-sitter colors are restored after the menu preference changes', normal_palette_ready)
eq('C# semantic tokens remain disabled in normal syntax mode', vim.lsp.semantic_tokens.is_enabled { bufnr = csharp }, false)

eq(
  'Python can restore monochrome through the same preference',
  Mode.set_monochrome(true, { silent = true, bufnr = python }),
  true
)
local monochrome_ready = vim.wait(3000, function()
  return highlight_link('@keyword.python') == 'Normal' and highlight_link('@keyword.c_sharp') == 'Normal'
end, 20)
ok('restored monochrome reaches both conventional languages', monochrome_ready)

local basedpyright = vim.lsp.config.basedpyright
ok('BasedPyright LSP config is enabled', vim.lsp.is_enabled('basedpyright'))
eq('BasedPyright starts through the Mason command', basedpyright.cmd, { 'basedpyright-langserver', '--stdio' })
eq('BasedPyright is scoped to Python buffers', basedpyright.filetypes, { 'python' })

-- Use a real file/project for one end-to-end LSP definition request. Mason owns
-- this executable, so a clean machine may still be installing it at test start.
local server_ready = vim.wait(30000, function()
  return vim.fn.executable('basedpyright-langserver') == 1
end, 100)
ok('Mason provides the BasedPyright executable', server_ready)

if server_ready then
  vim.cmd('edit ' .. vim.fn.fnameescape(temp_root .. '/main.py'))
  local main_buffer = vim.api.nvim_get_current_buf()
  local attached = vim.wait(15000, function()
    return #vim.lsp.get_clients { name = 'basedpyright', bufnr = main_buffer } > 0
  end, 50)
  ok('BasedPyright attaches to a pyproject workspace', attached)

  if attached then
    local call_col = assert(python_source[3]:find('answer', 1, true)) - 1
    vim.api.nvim_win_set_cursor(0, { 3, call_col })
    local definitions
    vim.lsp.buf.definition {
      on_list = function(options)
        definitions = options.items or {}
      end,
    }
    vim.wait(10000, function()
      return definitions ~= nil
    end, 50)
    local found = false
    for _, item in ipairs(definitions or {}) do
      if vim.fs.basename(item.filename) == 'definitions.py' and item.lnum == 1 then
        found = true
        break
      end
    end
    ok('Python definition request resolves across project files', found)

    local python_maps = {}
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(main_buffer, 'n')) do
      python_maps[mapping.lhs] = mapping
    end
    ok(
      'Python gets the shared gd definition mapping',
      python_maps.gd and python_maps.gd.desc:find('[D]efinition', 1, true)
    )
    eq(
      'Python semantic-token syntax coloring is disabled',
      vim.lsp.semantic_tokens.is_enabled { bufnr = main_buffer },
      false
    )
  end
end

for _, client in ipairs(vim.lsp.get_clients { name = 'basedpyright' }) do
  client:stop(true)
end
vim.fn.delete(temp_root, 'rf')

local report = { string.format('language_support_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
