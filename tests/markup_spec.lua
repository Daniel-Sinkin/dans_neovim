-- Source-faithful Markdown and LaTeX integration contract.

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

local function open(name, filetype, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = filetype
  vim.cmd 'doautocmd BufWinEnter'
  vim.cmd 'redraw'
  return bufnr
end

local function displayed_prefix(line_number, cells)
  vim.cmd 'redraw'
  local position = vim.fn.screenpos(vim.api.nvim_get_current_win(), line_number, 1)
  local out = {}
  for offset = 0, cells - 1 do
    out[#out + 1] = vim.fn.screenstring(position.row, position.col + offset)
  end
  return table.concat(out)
end

local fence = string.rep(string.char(96), 3)
local markdown_lines = {
  '# Literal Markdown',
  '',
  '**bold delimiters stay visible** and [link text](target.md)',
  fence .. 'cpp',
  'auto value = 1;',
  fence,
}

eq('global conceal default is source-faithful', vim.o.conceallevel, 0)
eq('built-in markdown syntax conceal is disabled before syntax loads', vim.g.markdown_syntax_conceal, 0)

-- Simulate opening Markdown in a window that previously carried the C++
-- frontend's conceal setting. BufWinEnter must reset the window-local value.
vim.wo.conceallevel = 2
local markdown = open('/tmp/dans-markup-contract.md', 'markdown', markdown_lines)
eq('markdown resets inherited conceallevel', vim.wo.conceallevel, 0)
eq('markdown leaves concealcursor empty', vim.wo.concealcursor, '')
eq('markdown source including code fences is byte-for-byte unchanged', vim.api.nvim_buf_get_lines(markdown, 0, -1, false), markdown_lines)
eq('markdown opening code fence is visible on the real screen grid', displayed_prefix(4, #(fence .. 'cpp')), fence .. 'cpp')
eq('markdown closing code fence is visible on the real screen grid', displayed_prefix(6, #fence), fence)

local tex_lines = {
  '\\documentclass{article}',
  '\\begin{document}',
  'Literal $\\alpha + \\beta$ source.',
  '\\end{document}',
}
vim.wo.conceallevel = 2
local tex = open('/tmp/dans-latex-contract.tex', 'tex', tex_lines)
vim.wait(100)
eq('latex resets inherited conceallevel', vim.wo.conceallevel, 0)
eq('VimTeX syntax conceal is disabled', vim.g.vimtex_syntax_conceal_disable, 1)
eq('latex source is byte-for-byte unchanged', vim.api.nvim_buf_get_lines(tex, 0, -1, false), tex_lines)
eq('latex command spelling is visible on the real screen grid', displayed_prefix(1, #'\\documentclass'), '\\documentclass')
eq('VimTeX syntax owns LaTeX highlighting', vim.bo[tex].syntax, 'tex')
eq('Tree-sitter highlighter stays detached from LaTeX', vim.treesitter.highlighter.active[tex], nil)
eq('ordinary tex files are treated as LaTeX', vim.g.tex_flavor, 'latex')
eq('VimTeX compile command is available', vim.fn.exists ':VimtexCompile', 2)
eq('VimTeX PDF view command is available', vim.fn.exists ':VimtexView', 2)

local maps = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(tex, 'n')) do
  maps[mapping.lhs] = mapping
end
ok('LaTeX compile mapping is discoverable', maps[' ll'] and maps[' ll'].desc == 'LaTeX compile toggle')
ok('LaTeX PDF mapping is discoverable', maps[' lv'] and maps[' lv'].desc == 'LaTeX PDF view / forward search')

local texlab = vim.lsp.config.texlab
ok('texlab LSP is configured', type(texlab) == 'table' and texlab.cmd and texlab.cmd[1] == 'texlab')
eq('texlab does not build on save', texlab.settings.texlab.build.onSave, false)
eq('texlab formatter preserves line-break policy', texlab.settings.texlab.latexindent.modifyLineBreaks, false)

local report = { string.format('markup_spec: %d passed, %d failed', pass, fail) }
vim.list_extend(report, failures)
print(table.concat(report, '\n'))
