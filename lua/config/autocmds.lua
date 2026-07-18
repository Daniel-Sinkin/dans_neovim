-- Autocommands that aren't tied to a plugin.

-- Disable automatic comment continuation on newline / o / O.
vim.api.nvim_create_autocmd('FileType', {
  pattern = '*',
  callback = function()
    vim.opt_local.formatoptions:remove { 'r', 'o', 'c' }
  end,
})

-- Markdown and LaTeX are edited as literal source.  FileType establishes the
-- buffer's initial window state; BufWinEnter is also required because
-- conceallevel is window-local and a window previously showing the C++
-- frontend may otherwise carry conceallevel=2 into an existing markup buffer.
local markup_group = vim.api.nvim_create_augroup('dans-source-faithful-markup', { clear = true })
local function reveal_markup_source()
  vim.opt_local.conceallevel = 0
  vim.opt_local.concealcursor = ''
end
vim.api.nvim_create_autocmd('FileType', {
  group = markup_group,
  pattern = { 'markdown', 'markdown.mdx', 'tex', 'plaintex', 'bib' },
  callback = reveal_markup_source,
})
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = markup_group,
  pattern = { '*.md', '*.markdown', '*.mdx', '*.tex', '*.ltx', '*.bib' },
  callback = reveal_markup_source,
})

-- Open Neo-tree on startup when launched in a directory or empty buffer.
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function(data)
    local buf = data.buf
    local name = vim.api.nvim_buf_get_name(buf)

    local stat = (vim.uv or vim.loop).fs_stat(name)
    if stat and stat.type == 'directory' then
      vim.cmd.cd(name)
      vim.cmd 'Neotree show left'
      return
    end

    if name == '' then
      vim.cmd 'Neotree show left'
    end
  end,
})

-- Clear diagnostics for buffers being wiped out. Without this, closing a file
-- with errors leaves them cached in vim.diagnostic forever and Neo-tree keeps
-- showing it as orange.
vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = vim.api.nvim_create_augroup('ds-diagnostic-cleanup', { clear = true }),
  callback = function(ev)
    vim.diagnostic.reset(nil, ev.buf)
  end,
})

local yank_flash_group = vim.api.nvim_create_augroup('dans-highlight-yank', { clear = true })
local function flash_yanked_text()
  vim.highlight.on_yank { higroup = 'IncSearch' }
  -- Mirror the flash onto the frontend overlay (the raw flash is concealed there).
  pcall(function()
    require('custom.dans_frontend_cpp.overlay_hl').flash_yank(vim.api.nvim_get_current_buf())
  end)
end

vim.api.nvim_create_autocmd({ 'TextYankPost' }, {
  desc = 'Flash freshly yanked text in source and frontend views',
  group = yank_flash_group,
  callback = flash_yanked_text,
})

-- Split paste registers: a yank goes to register `y`, every change/delete/x goes
-- to register `z` (TextYankPost fires for y, c and d). Paired with the p/P remaps
-- in keymaps.lua, `p` pastes the last yank and `P` pastes the last change/delete,
-- so cutting text never clobbers what you copied. d/x/s all count as the "cut"
-- side (operator d or c) and land in z.
vim.api.nvim_create_autocmd({ 'TextYankPost' }, {
  desc = 'Route yank -> reg y, change/delete -> reg z',
  group = vim.api.nvim_create_augroup('dans-paste-registers', { clear = true }),
  callback = function()
    local ev = vim.v.event
    local reg = ev.operator == 'y' and 'y' or 'z'
    vim.fn.setreg(reg, ev.regcontents, ev.regtype)
  end,
})

-- Write duration in the "written" message. The autoformatter runs in BufWritePre
-- (conform; clang-format/LSP for c/cpp), so a big file can take a noticeable beat
-- and the built-in line doesn't say how long. Time pre->post and re-echo Neovim's
-- message with the duration appended. This autocmd is created at startup, before
-- conform lazy-loads, so its BufWritePre fires first and the timer spans the
-- format. (Progress *during* a slow format would need to hook the formatter, so
-- it's intentionally left out.)
local write_start = {}
local hrtime = (vim.uv or vim.loop).hrtime
local wgroup = vim.api.nvim_create_augroup('dans-write-time', { clear = true })
vim.api.nvim_create_autocmd('BufWritePre', {
  group = wgroup,
  callback = function(ev)
    write_start[ev.buf] = hrtime()
  end,
})
vim.api.nvim_create_autocmd('BufWritePost', {
  group = wgroup,
  callback = function(ev)
    local t0 = write_start[ev.buf]
    write_start[ev.buf] = nil
    if not t0 or vim.bo[ev.buf].buftype ~= '' then
      return
    end
    local ms = (hrtime() - t0) / 1e6
    local name = vim.fn.fnamemodify(ev.file, ':.')
    local lines = vim.api.nvim_buf_line_count(ev.buf)
    local bytes = vim.fn.getfsize(ev.file)
    -- scheduled so it lands after Neovim's own "written" line (which prints when
    -- the :w command finishes, just after this autocmd).
    vim.schedule(function()
      vim.api.nvim_echo({ { string.format('"%s" %dL, %dB written in %dms', name, lines, bytes, ms) } }, false, {})
    end)
  end,
})

-- C/C++/CUDA: 4-space tabs and the built-in `cindent`. Treesitter indent is
-- disabled for these in custom/plugins/treesitter.lua because the frozen master
-- module goes stale mid-edit and drops the Enter indent to column 0; cindent is
-- deterministic.
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'cpp', 'c', 'h', 'hpp', 'cuda' },
  callback = function()
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.expandtab = true
    vim.opt_local.cindent = true
  end,
})
