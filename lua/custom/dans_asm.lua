-- :DansAsm -- compile the current translation unit to assembly and show the
-- function under the cursor in a side split, with source<->asm line sync (move
-- the cursor in either window, the matching line(s) light up in the other).
--
-- Backend is local clang/gcc: the flags come from compile_commands.json when one
-- is found (walking up from the file, plus build/), else a c++23 fallback. The
-- compile streams asm to stdout (`-S -g -O2 -o -`), so nothing is written to disk.
-- Override: vim.g.dans_asm_compiler, vim.g.dans_asm_flags (list), vim.g.dans_asm_opt.
--
-- The parser is format-agnostic across x86 ELF (`#` comments, `_Z..` labels) and
-- arm64 Mach-O (`;` comments, `__Z..` labels): both bracket each function with
-- .cfi_startproc/.cfi_endproc and map asm to source with .file/.loc, which is all
-- it keys off.

local M = {}
local context = require 'custom.cpp_tools.context'
local jobs = require 'custom.cpp_tools.jobs'
local scratch = require 'custom.cpp_tools.scratch'

local function notify(msg, lvl)
  vim.notify(msg, lvl or vim.log.levels.INFO)
end

-- ============================ pure helpers (tested) ============================

-- Strip the flags that conflict with "stream asm to stdout" from a
-- compile_commands argv, drop the input file (re-added), force the opt level, and
-- append `-S -g -O<opt> -o - <infile>`. argv[1] (the compiler) is kept.
function M.clean_args(argv, infile, opt)
  return context.sanitize_arguments(argv, infile, {
    cwd = vim.fn.getcwd(),
    mode = 'assembly',
    input = infile,
    opt = opt,
  })
end

-- Naive shell-split for a compile_commands `command` string (most DBs use the
-- `arguments` array; this is the fallback). Honors "double" and 'single' quotes.
function M.split_command(s)
  return context.split_command(s)
end

-- Parse assembly text into { lines, files, line_src, blocks }. Handles both
-- toolchain dialects:
--   DWARF (clang on linux/macos): `.file N ["dir"] "name"` + `.loc N line`
--   CodeView (clang on windows-msvc): `.cv_file N "path" "csum"` + `.cv_loc fn N line`
-- Functions are bracketed by .Lfunc_beginN:/.Lfunc_endN: in every format (the
-- mach-o variant drops the leading dot), which is more reliable than .cfi_* (those
-- are absent on a windows leaf function with no unwind).
--   files     fileidx -> basename
--   line_src  asm line (1-based) -> source line, for lines inside a function whose
--             current .loc/.cv_loc points at `src_base`
--   blocks    { label, first, last, srcs={set}, lo, hi } per function, `first` at
--             the function label line.
function M.parse_asm(text, src_base)
  local lines = vim.split(text, '\n', { plain = true })
  local files = {}
  for _, ln in ipairs(lines) do
    local idx, rest = ln:match '^%s*%.file%s+(%d+)%s+(.+)$'
    if idx then
      local name -- DWARF: the LAST quoted token is the file (dir, if any, is first)
      for q in rest:gmatch '"([^"]*)"' do
        name = q
      end
      if name then
        files[tonumber(idx)] = name:match '[^/\\]+$'
      end
    end
    local cidx, crest = ln:match '^%s*%.cv_file%s+(%d+)%s+(.+)$'
    if cidx then
      local path = crest:match '"([^"]*)"' -- CodeView: the FIRST quoted token is the path
      if path then
        files[tonumber(cidx)] = path:match '[^/\\]+$'
      end
    end
  end
  local ours = {}
  for idx, base in pairs(files) do
    if base == src_base then
      ours[idx] = true
    end
  end

  local line_src, blocks = {}, {}
  local cur_src, last_label, last_label_line, open = nil, nil, nil, nil
  for i, ln in ipairs(lines) do
    local t = ln:gsub('^%s+', '')
    local fidx, fline = t:match '^%.loc%s+(%d+)%s+(%d+)'
    if not fidx then
      fidx, fline = t:match '^%.cv_loc%s+%d+%s+(%d+)%s+(%d+)' -- funcid, fileidx, line
    end
    if fidx then
      if ours[tonumber(fidx)] then
        cur_src = tonumber(fline)
      else
        -- An inlined header location must not inherit the last translation-unit
        -- row.  Keep its instructions visible, but leave them unpaired.
        cur_src = nil
      end
    elseif t:match '^%.?Lfunc_begin%d+:' or t:match '^%.LFB%d+:' then
      open = { label = last_label, first = last_label_line or i, last = i, srcs = {}, lo = nil, hi = nil }
    elseif t:match '^%.?Lfunc_end%d+:' or t:match '^%.LFE%d+:' then
      if open then
        open.last = i
        blocks[#blocks + 1] = open
        open = nil
      end
    else
      -- a function symbol label; MS-mangled names are "quoted". Skip compiler-local
      -- .L*/L* labels. Reset the running source line so a new function's prologue
      -- isn't tagged with the previous function's last line.
      local q = t:match '^"([^"]*)":'
      local lbl = q or t:match '^([%w_$.@][%w_$.@]*):'
      if lbl and (q or not lbl:match '^%.?L') then
        last_label, last_label_line, cur_src = lbl, i, nil
      end
    end
    if open then
      open.last = i
      if cur_src then
        line_src[i] = cur_src
        open.srcs[cur_src] = true
        open.lo = (not open.lo or cur_src < open.lo) and cur_src or open.lo
        open.hi = (not open.hi or cur_src > open.hi) and cur_src or open.hi
      end
    end
  end
  return { lines = lines, files = files, line_src = line_src, blocks = blocks }
end

-- The block whose source coverage overlaps the cursor function's [fstart, fend]
-- the most (handles overloads and inlined callees without needing to demangle).
function M.pick_block(parsed, fstart, fend)
  local best, bestn = nil, 0
  for _, b in ipairs(parsed.blocks) do
    local n = 0
    for s in pairs(b.srcs) do
      if s >= fstart and s <= fend then
        n = n + 1
      end
    end
    if n > bestn then
      best, bestn = b, n
    end
  end
  return best
end

local function is_noise(line)
  local trimmed = line:gsub('^%s+', '')
  local directive = trimmed:match '^%.([%w_]+)'
  return trimmed == ''
    or (directive ~= nil and trimmed:sub(-1) ~= ':')
    or directive == 'file'
    or directive == 'loc'
    or directive == 'cv_file'
    or directive == 'cv_loc'
    or trimmed:match '^%.cfi_' ~= nil
    or directive == 'section'
    or directive == 'subsections_via_symbols'
    or directive == 'addrsig'
    or directive == 'ident'
end

-- Construct the displayed block and its bidirectional source map.  Noise
-- filtering is presentation-only and never changes the source buffer.
function M.display_block(parsed, block, hide_noise)
  local body, disp_src, src_to_disp = {}, {}, {}
  for source_index = block.first, block.last do
    local line = parsed.lines[source_index]
    if not hide_noise or not is_noise(line) then
      body[#body + 1] = line
      local display_index = #body
      local source_line = parsed.line_src[source_index]
      if source_line then
        disp_src[display_index] = source_line
        src_to_disp[source_line] = src_to_disp[source_line] or {}
        src_to_disp[source_line][#src_to_disp[source_line] + 1] = display_index
      end
    end
  end
  return body, disp_src, src_to_disp
end

-- Stable Godbolt-style color assignment: source lines are ordered, then cycle
-- through a fixed palette.  Recompilation may change instruction count without
-- changing the source/assembly color identity.
function M.source_palette(src_to_disp, palette_size)
  local source_lines = vim.tbl_keys(src_to_disp)
  table.sort(source_lines)
  local out = {}
  palette_size = palette_size or 8
  for index, source_line in ipairs(source_lines) do
    out[source_line] = ((index - 1) % palette_size) + 1
  end
  return out
end

-- ============================ orchestration ============================

local sync_ns = vim.api.nvim_create_namespace 'ds_asm_sync'
local map_ns = vim.api.nvim_create_namespace 'ds_asm_source_map'
local sessions = {} -- asm bufnr -> live rendering/session state
local source_asm = {} -- source bufnr -> one reusable asm buffer
local cache = {} -- source bufnr -> { signature, parsed, block, fn, command, opt }

local PALETTE = {
  { background = '#352f49', foreground = '#b7a6ff' },
  { background = '#263d39', foreground = '#70d6bd' },
  { background = '#443725', foreground = '#edbc72' },
  { background = '#422d3b', foreground = '#ed91bf' },
  { background = '#26394b', foreground = '#75b9ee' },
  { background = '#353d27', foreground = '#b4d273' },
  { background = '#422f28', foreground = '#e59b73' },
  { background = '#2b3b41', foreground = '#88c6d2' },
}

local function define_highlights()
  vim.api.nvim_set_hl(0, 'DansAsmSync', { link = 'Visual' })
  for index, color in ipairs(PALETTE) do
    vim.api.nvim_set_hl(0, 'DansAsmMap' .. index, { bg = color.background })
    vim.api.nvim_set_hl(0, 'DansAsmMarker' .. index, { fg = color.foreground, bold = true })
  end
end

local function demangle(label)
  if label == nil or label == '' then
    return label
  end
  for _, tool in ipairs { 'llvm-cxxfilt', 'c++filt' } do
    if vim.fn.executable(tool) == 1 then
      local out = vim.fn.systemlist { tool, label }
      if vim.v.shell_error == 0 and out[1] and out[1] ~= '' then
        return out[1]
      end
    end
  end
  return label
end

local function style_asm_window(winid)
  vim.api.nvim_win_call(winid, function()
    if vim.w.dans_asm_styled then
      return
    end
    vim.w.dans_asm_styled = true
    vim.fn.matchadd('Comment', [[^\s*\..*$]])
    vim.fn.matchadd('Comment', [[\s*[;#].*$]])
    vim.fn.matchadd('Function', [[^\S\+:]])
  end)
end

local function clear(bufnr, namespace)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

local function highlight_active(bufnr, row0)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, sync_ns, row0, 0, {
    line_hl_group = 'DansAsmSync',
    priority = 200,
  })
end

local function apply_source_map(session)
  clear(session.sbuf, map_ns)
  clear(session.asmbuf, map_ns)
  session.palette = M.source_palette(session.src_to_disp, #PALETTE)
  for source_line, display_lines in pairs(session.src_to_disp) do
    local palette = session.palette[source_line]
    local group = 'DansAsmMap' .. palette
    local marker = 'DansAsmMarker' .. palette
    if source_line >= 1 and source_line <= vim.api.nvim_buf_line_count(session.sbuf) then
      pcall(vim.api.nvim_buf_set_extmark, session.sbuf, map_ns, source_line - 1, 0, {
        line_hl_group = group,
        number_hl_group = marker,
        priority = 20,
      })
    end
    for _, display_line in ipairs(display_lines) do
      pcall(vim.api.nvim_buf_set_extmark, session.asmbuf, map_ns, display_line - 1, 0, {
        line_hl_group = group,
        number_hl_group = marker,
        priority = 20,
      })
    end
  end
end

local function sync_from_source(asmbuf)
  local session = sessions[asmbuf]
  if not session or vim.api.nvim_get_current_buf() ~= session.sbuf then
    return
  end
  clear(asmbuf, sync_ns)
  local source_line = vim.api.nvim_win_get_cursor(0)[1]
  local display_lines = session.src_to_disp[source_line]
  if not display_lines then
    return
  end
  for _, display_line in ipairs(display_lines) do
    highlight_active(asmbuf, display_line - 1)
  end
  local asm_window = vim.fn.bufwinid(asmbuf)
  if asm_window ~= -1 then
    vim.api.nvim_win_set_cursor(asm_window, { display_lines[1], 0 })
  end
end

local function sync_from_asm(asmbuf)
  local session = sessions[asmbuf]
  if not session or not vim.api.nvim_buf_is_valid(session.sbuf) then
    return
  end
  clear(session.sbuf, sync_ns)
  local source_line = session.disp_src[vim.api.nvim_win_get_cursor(0)[1]]
  if source_line then
    highlight_active(session.sbuf, source_line - 1)
  end
end

local function render_session(session)
  local body, disp_src, src_to_disp = M.display_block(session.parsed, session.block, session.hide_noise)
  session.disp_src, session.src_to_disp = disp_src, src_to_disp
  vim.bo[session.asmbuf].modifiable = true
  vim.api.nvim_buf_set_lines(session.asmbuf, 0, -1, false, body)
  vim.bo[session.asmbuf].modifiable = false
  apply_source_map(session)
  local asm_window = vim.fn.bufwinid(session.asmbuf)
  if asm_window ~= -1 then
    style_asm_window(asm_window)
  end
end

local OPTIMIZATIONS = { '0', '1', '2', '3', 's', 'z', 'g' }

local function select_optimization(session)
  vim.ui.select(OPTIMIZATIONS, {
    prompt = 'Assembly optimization:',
    format_item = function(value)
      return '-O' .. value .. (value == session.opt and '  (current)' or '')
    end,
  }, function(value)
    if not value then
      return
    end
    local source_window = vim.fn.bufwinid(session.sbuf)
    if source_window ~= -1 then
      vim.api.nvim_set_current_win(source_window)
      M.show(value, true)
    end
  end)
end

local function open_split(sbuf, parsed, block, fn, command, opt)
  local asmbuf = source_asm[sbuf]
  if not asmbuf or not vim.api.nvim_buf_is_valid(asmbuf) then
    asmbuf = vim.api.nvim_create_buf(false, true)
    source_asm[sbuf] = asmbuf
    vim.bo[asmbuf].filetype = 'asm'
    vim.bo[asmbuf].buftype = 'nofile'
    vim.bo[asmbuf].bufhidden = 'wipe'
    vim.bo[asmbuf].swapfile = false
    local label = demangle(block.label) or fn.qualified_name or fn.name or 'function'
    pcall(vim.api.nvim_buf_set_name, asmbuf, 'dans-asm://' .. label)
  end

  local old = sessions[asmbuf]
  local session = {
    asmbuf = asmbuf,
    sbuf = sbuf,
    parsed = parsed,
    block = block,
    fn = fn,
    command = command,
    opt = opt,
    hide_noise = old and old.hide_noise or vim.g.dans_asm_hide_noise ~= false,
  }
  sessions[asmbuf] = session

  local asm_window = vim.fn.bufwinid(asmbuf)
  if asm_window == -1 then
    vim.cmd 'botright vsplit'
    asm_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(asm_window, asmbuf)
  end
  vim.wo[asm_window].wrap = false
  vim.wo[asm_window].number = true
  vim.wo[asm_window].relativenumber = false
  render_session(session)

  local group = vim.api.nvim_create_augroup('ds_asm_' .. asmbuf, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = function()
      local current = vim.api.nvim_get_current_buf()
      if current == sbuf then
        sync_from_source(asmbuf)
      elseif current == asmbuf then
        sync_from_asm(asmbuf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = asmbuf,
    callback = function()
      clear(sbuf, sync_ns)
      clear(sbuf, map_ns)
      sessions[asmbuf] = nil
      if source_asm[sbuf] == asmbuf then
        source_asm[sbuf] = nil
      end
    end,
  })
  vim.keymap.set('n', 'n', function()
    session.hide_noise = not session.hide_noise
    render_session(session)
    sync_from_asm(asmbuf)
  end, { buffer = asmbuf, desc = 'Toggle compiler-directive noise' })
  vim.keymap.set('n', 'o', function()
    select_optimization(session)
  end, { buffer = asmbuf, desc = 'Choose optimization level' })
  vim.keymap.set('n', 'r', function()
    local source_window = vim.fn.bufwinid(sbuf)
    if source_window ~= -1 then
      vim.api.nvim_set_current_win(source_window)
      M.show(session.opt, true)
    end
  end, { buffer = asmbuf, desc = 'Recompile assembly' })
  vim.keymap.set('n', 'q', function()
    local window = vim.fn.bufwinid(asmbuf)
    if window ~= -1 then
      vim.api.nvim_win_close(window, true)
    end
  end, { buffer = asmbuf, desc = 'Close assembly' })

  local source_group = vim.api.nvim_create_augroup('ds_asm_source_' .. sbuf, { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = source_group,
    buffer = sbuf,
    callback = function()
      if vim.g.dans_asm_auto_refresh ~= false and vim.api.nvim_get_current_buf() == sbuf and sessions[asmbuf] then
        M.show(session.opt, true)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = source_group,
    buffer = sbuf,
    once = true,
    callback = function()
      jobs.cancel('asm:' .. sbuf)
      if vim.api.nvim_buf_is_valid(asmbuf) then
        pcall(vim.api.nvim_buf_delete, asmbuf, { force = true })
      end
      cache[sbuf] = nil
    end,
  })

  local source_window = vim.fn.bufwinid(sbuf)
  if source_window ~= -1 then
    vim.api.nvim_set_current_win(source_window)
  end
  sync_from_source(asmbuf)
end

local function command_text(argv)
  local values = {}
  for _, value in ipairs(argv) do
    values[#values + 1] = vim.fn.shellescape(value)
  end
  return table.concat(values, ' ')
end

local function show_compile_error(sbuf, fn, command, result)
  local stderr, stdout = result.stderr or '', result.stdout or ''
  local output = stderr ~= '' and stderr or stdout
  local content = {
    'Assembly compilation failed for ' .. (fn.qualified_name or fn.name or 'function'),
    '',
    '$ ' .. command_text(command.argv),
    '',
  }
  vim.list_extend(content, vim.split(output ~= '' and output or ('exit ' .. tostring(result.code)), '\n', { plain = true }))
  scratch.open {
    key = 'asm-error-' .. sbuf,
    name = 'dans://assembly-error',
    lines = content,
    filetype = 'text',
    vertical = true,
    wrap = false,
  }
end

function M.show(opt, force)
  local sbuf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(sbuf)
  if file == '' then
    return notify 'DansAsm: buffer has no file'
  end
  if not context.is_source(file) then
    return notify 'DansAsm: needs a C/C++/CUDA translation unit, not a header'
  end
  if vim.bo[sbuf].modified then
    return notify('DansAsm: save the buffer first so compiler output matches the visible source', vim.log.levels.WARN)
  end
  local fn = context.function_at(sbuf)
  if not fn then
    return notify 'DansAsm: put the cursor inside a function body'
  end
  opt = tostring(opt or vim.g.dans_asm_opt or '2'):gsub('^%-?O', '')
  if not vim.list_contains(OPTIMIZATIONS, opt) then
    return notify('DansAsm: unsupported optimization -O' .. opt, vim.log.levels.ERROR)
  end
  local command = context.compile_command(file, {
    mode = 'assembly',
    input = file,
    opt = opt,
    fallback_flags = vim.g.dans_asm_flags or {},
  })
  if not command then
    return notify('DansAsm: no compiler on PATH; set vim.g.dans_cpp_compiler or vim.g.dans_cuda_compiler', vim.log.levels.ERROR)
  end

  local signature = table.concat(command.argv, '\0') .. ':' .. tostring(vim.b[sbuf].changedtick) .. ':' .. fn.first_line .. ':' .. fn.last_line
  local cached = cache[sbuf]
  if not force and cached and cached.signature == signature then
    open_split(sbuf, cached.parsed, cached.block, cached.fn, cached.command, cached.opt)
    return
  end

  local base = file:match '[^/\\]+$'
  notify(string.format('DansAsm: compiling %s at -O%s...', fn.qualified_name or fn.name or base, opt))
  local process, error_message = jobs.start('asm:' .. sbuf, command.argv, { cwd = command.cwd }, function(result)
    if not vim.api.nvim_buf_is_valid(sbuf) then
      return
    end
    local assembly = result.stdout or ''
    if result.code ~= 0 or assembly == '' then
      show_compile_error(sbuf, fn, command, result)
      return
    end
    local parsed = M.parse_asm(assembly, base)
    local block = M.pick_block(parsed, fn.first_line, fn.last_line)
    if not block then
      notify('DansAsm: no assembly for ' .. (fn.qualified_name or fn.name or '?') .. ' (inline-only, uninstantiated, or optimized away)', vim.log.levels.WARN)
      return
    end
    cache[sbuf] = {
      signature = signature,
      parsed = parsed,
      block = block,
      fn = fn,
      command = command,
      opt = opt,
    }
    open_split(sbuf, parsed, block, fn, command, opt)
  end)
  if not process then
    notify('DansAsm: could not start compiler: ' .. tostring(error_message), vim.log.levels.ERROR)
  end
end

function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('ds_asm_highlights', { clear = true }),
    callback = define_highlights,
  })
  vim.api.nvim_create_user_command('DansAsm', function(options)
    M.show(options.args ~= '' and options.args or nil, options.bang)
  end, {
    nargs = '?',
    bang = true,
    complete = function()
      return vim.tbl_map(function(value)
        return 'O' .. value
      end, OPTIMIZATIONS)
    end,
    desc = 'Show color-matched assembly for the function under the cursor (! bypasses cache)',
  })
end

return M
