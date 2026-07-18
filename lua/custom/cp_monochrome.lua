local M = {}

function M.apply()
  vim.opt.termguicolors = true
  vim.g.colors_name = 'cp-monochrome'

  local fg = '#c0c0c0'
  local bg = '#1a1a1a'
  local dim = '#555555'
  local cursor_line = '#222222'
  local visual = '#333333'
  local accent = '#808080'

  local function hi(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end

  hi('Normal', { fg = fg, bg = bg })
  hi('NormalNC', { fg = fg, bg = bg })
  hi('NormalFloat', { fg = fg, bg = '#1e1e1e' })
  hi('FloatBorder', { fg = dim, bg = '#1e1e1e' })
  hi('CursorLine', { bg = cursor_line })
  hi('CursorLineNr', { fg = fg, bg = cursor_line, bold = true })
  hi('LineNr', { fg = dim })
  hi('Visual', { bg = visual })
  hi('Search', { fg = bg, bg = accent })
  hi('IncSearch', { fg = bg, bg = fg })
  hi('StatusLine', { fg = fg, bg = '#252525' })
  hi('StatusLineNC', { fg = dim, bg = '#1e1e1e' })
  hi('VertSplit', { fg = dim })
  hi('WinSeparator', { fg = dim })
  hi('Pmenu', { fg = fg, bg = '#252525' })
  hi('PmenuSel', { fg = bg, bg = accent })
  hi('WildMenu', { fg = bg, bg = accent })
  hi('MatchParen', { fg = fg, bold = true, underline = true })
  hi('NonText', { fg = dim })
  hi('SpecialKey', { fg = dim })
  hi('Directory', { fg = fg })
  hi('Title', { fg = fg, bold = true })
  hi('ModeMsg', { fg = fg, bold = true })
  hi('MoreMsg', { fg = fg })
  hi('Question', { fg = fg })
  hi('WarningMsg', { fg = fg })
  hi('ErrorMsg', { fg = '#ff5555', bg = bg })
  hi('Error', { fg = '#ff5555' })
  hi('Folded', { fg = dim, bg = '#1e1e1e' })
  hi('FoldColumn', { fg = dim, bg = bg })
  hi('SignColumn', { fg = dim, bg = bg })
  hi('TabLine', { fg = dim, bg = '#1e1e1e' })
  hi('TabLineFill', { bg = '#1e1e1e' })
  hi('TabLineSel', { fg = fg, bg = bg, bold = true })

  local mono_groups = {
    'Comment',
    'Constant',
    'String',
    'Character',
    'Number',
    'Boolean',
    'Float',
    'Identifier',
    'Function',
    'Statement',
    'Conditional',
    'Repeat',
    'Label',
    'Operator',
    'Keyword',
    'Exception',
    'PreProc',
    'Include',
    'Define',
    'Macro',
    'PreCondit',
    'Type',
    'StorageClass',
    'Structure',
    'Typedef',
    'Special',
    'SpecialChar',
    'Tag',
    'Delimiter',
    'SpecialComment',
    'Debug',
  }

  for _, group in ipairs(mono_groups) do
    hi(group, { fg = fg })
  end
  hi('Comment', { fg = dim, italic = true })

  local ts_groups = {
    '@variable',
    '@function',
    '@keyword',
    '@string',
    '@number',
    '@type',
    '@constant',
    '@operator',
    '@punctuation',
    '@comment',
    '@parameter',
    '@field',
    '@property',
    '@constructor',
    '@method',
    '@namespace',
    '@include',
    '@conditional',
    '@repeat',
    '@exception',
    '@boolean',
  }

  for _, group in ipairs(ts_groups) do
    hi(group, { fg = fg })
  end
  hi('@comment', { fg = dim, italic = true })

  hi('DiagnosticError', { fg = dim })
  hi('DiagnosticWarn', { fg = dim })
  hi('DiagnosticInfo', { fg = dim })
  hi('DiagnosticHint', { fg = dim })
end

return M
