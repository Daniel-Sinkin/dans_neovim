-- Tokenizer coloring view: treat the buffer as plain text, run it through a
-- bundled byte-level BPE tokenizer (tokenize.mjs + tokenizer.json), and
-- tint each token with a cycling background so the token boundaries are visible
-- (the tokenizer-playground look). While on, every other coloring source for the
-- buffer is suppressed -- the cpp frontend, treesitter, classic syntax, LSP
-- semantic tokens / reference highlights, and diagnostics -- so only the token
-- tints show. Toggle with `:DansFrontend tokens`.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_tokenizer'
local ns_info = vim.api.nvim_create_namespace 'ds_tokenizer_info'

-- Cycling background tints. Muted enough that the (light) Normal foreground stays
-- readable; adjacent tokens always differ because the palette is walked by token
-- sequence index.
local PALETTE = { '#33304d', '#1f414d', '#473327', '#26432f', '#45273c' }

local function define_groups()
  for i, bg in ipairs(PALETTE) do
    vim.api.nvim_set_hl(0, 'DansTok' .. i, { bg = bg })
  end
  vim.api.nvim_set_hl(0, 'DansTokInfo', { fg = '#9aa5ce', bg = '#1b1d29' })
  vim.api.nvim_set_hl(0, 'DansTokInfoLabel', { fg = '#7dcfff', bg = '#1b1d29', bold = true })
end

-- buf -> { tick, S, L, ID, line_start, count, nbytes, aug, inflight, dirty,
--          debounce, last_top, last_bot, saved }
local state = {}

local SCRIPT_DIR = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local SCRIPT = SCRIPT_DIR .. '/tokenize.mjs'
local DATA = SCRIPT_DIR .. '/tokenizer.json'

local function node_cmd()
  return vim.g.dans_tokenizer_node or 'node'
end

-- Whole-buffer tokenize cost (node RSS, the result JSON, and the resident
-- S/L/ID arrays) is linear in size, so cap it. 30k lines / ~1 MB is ~28 ms and
-- ~11 MB resident; the default 4 MB keeps a pathological file from spiking node
-- past ~0.5 GB. Override with vim.g.dans_tokenizer_max_bytes.
local function max_bytes()
  return vim.g.dans_tokenizer_max_bytes or (4 * 1024 * 1024)
end

local function buf_bytes(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  local off = vim.api.nvim_buf_get_offset(buf, n)
  return off >= 0 and off or 0
end

-- greatest index r (1-based) with arr[r] <= b, over the ascending line_start.
local function row_of_byte(line_start, b)
  local lo, hi = 1, #line_start
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if line_start[mid] <= b then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

-- (row0, col) for a global byte offset.
local function map_byte(st, b)
  local r = row_of_byte(st.line_start, b)
  return r - 1, b - st.line_start[r]
end

-- first token index whose end byte is past `b` (lower bound on overlap).
local function first_token_from(st, b)
  local lo, hi = 1, st.count + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if st.S[mid] + st.L[mid] > b then
      hi = mid
    else
      lo = mid + 1
    end
  end
  return lo
end

local function line_len(st, row0)
  return st.line_start[row0 + 2] and (st.line_start[row0 + 2] - st.line_start[row0 + 1] - 1) or 0
end

local function emit_token(buf, st, idx, group)
  local s = st.S[idx]
  local e = s + st.L[idx]
  local srow, scol = map_byte(st, s)
  local erow, ecol = map_byte(st, e)
  local function mark(row, col, opts)
    opts.hl_group = group
    opts.priority = 220
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
  end
  if srow == erow then
    mark(srow, scol, { end_col = ecol })
    return
  end
  -- Multi-line token (a whitespace run crossing newlines): tint each row to its
  -- end, carrying the tint over the newline cell, then the tail on the last row.
  mark(srow, scol, { end_row = srow, end_col = line_len(st, srow), hl_eol = true })
  for row = srow + 1, erow - 1 do
    mark(row, 0, { end_row = row, end_col = line_len(st, row), hl_eol = true })
  end
  if ecol > 0 then
    mark(erow, 0, { end_col = ecol })
  end
end

local function paint(buf, force)
  local st = state[buf]
  if not st or not st.S then return end
  if st.tick ~= vim.api.nvim_buf_get_changedtick(buf) then return end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then return end

  local wi = vim.fn.getwininfo(win)[1]
  local top = math.max(0, wi.topline - 1)
  local bot = math.min(st.count > 0 and (#st.line_start - 2) or 0, wi.botline - 1)
  if not force and st.last_top == top and st.last_bot == bot then return end
  st.last_top, st.last_bot = top, bot

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if st.count == 0 then return end

  local bstart = st.line_start[top + 1]
  local bend = st.line_start[bot + 2] or st.nbytes
  local i = first_token_from(st, bstart)
  while i <= st.count and st.S[i] < bend do
    emit_token(buf, st, i, 'DansTok' .. ((i - 1) % #PALETTE + 1))
    i = i + 1
  end
end

-- count tokens overlapping the byte range [b0, b1).
local function count_overlap(st, b0, b1)
  if not st.S or b1 <= b0 then return 0 end
  local i = first_token_from(st, b0)
  local c = 0
  while i <= st.count and st.S[i] < b1 do
    c = c + 1
    i = i + 1
  end
  return c
end

-- Byte range of the live visual selection, or nil when not in visual mode.
-- Linewise spans whole lines; char/blockwise use the two corners (block is a
-- bounding-range approximation -- fine for a counter). Columns are clamped to
-- the line so `v$` can't spill the count onto following lines.
local function selection_bytes(st)
  local m = vim.fn.mode()
  if m ~= 'v' and m ~= 'V' and m ~= '\22' then return nil end
  local ls = st.line_start
  local a, b = vim.fn.getpos 'v', vim.fn.getpos '.'
  local l1, c1, l2, c2 = a[2], a[3], b[2], b[3]
  if l1 > l2 or (l1 == l2 and c1 > c2) then
    l1, c1, l2, c2 = l2, c2, l1, c1
  end
  if l1 < 1 or not ls[l1] then return nil end
  if m == 'V' then
    return ls[l1], ls[l2 + 1] or (st.nbytes + 1)
  end
  local b0 = ls[l1] + (c1 - 1)
  local lend = ls[l2 + 1] or (st.nbytes + 1)
  local b1 = math.min(ls[l2] + c2, lend)
  if b1 <= b0 then b1 = b0 + 1 end
  return b0, b1
end

-- The bottom bar: tokens in file / on the cursor line / in the selection.
local function update_info(buf)
  local st = state[buf]
  if not st or not st.info_buf or not vim.api.nvim_buf_is_valid(st.info_buf) then return end
  local file = st.count or 0
  local line_c, sel_c = 0, 0
  if st.S and st.line_start then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
      win = (st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win) == buf) and st.code_win or nil
    end
    if win then
      local row0 = vim.api.nvim_win_get_cursor(win)[1] - 1
      local b0 = st.line_start[row0 + 1]
      if b0 then
        line_c = count_overlap(st, b0, st.line_start[row0 + 2] or (st.nbytes + 1))
      end
    end
    local sb0, sb1 = selection_bytes(st)
    if sb0 then sel_c = count_overlap(st, sb0, sb1) end
  end

  local s = '  '
  local spans = {}
  for _, p in ipairs { { 'file', file }, { 'line', line_c }, { 'sel', sel_c } } do
    spans[#spans + 1] = { #s, #s + #p[1] }
    s = s .. p[1] .. ' ' .. tostring(p[2]) .. '    '
  end
  vim.bo[st.info_buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.info_buf, 0, -1, false, { s })
  vim.bo[st.info_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(st.info_buf, ns_info, 0, -1)
  for _, sp in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, st.info_buf, ns_info, 0, sp[1], { end_col = sp[2], hl_group = 'DansTokInfoLabel' })
  end
end

-- A one-line scratch window directly below the code window.
local function open_info(buf)
  local code_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(code_win) ~= buf then
    code_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        code_win = w
        break
      end
    end
    if not code_win then return end
  end
  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype = 'nofile'
  vim.bo[ibuf].bufhidden = 'wipe'
  vim.bo[ibuf].swapfile = false
  vim.bo[ibuf].filetype = 'danstokens'
  vim.bo[ibuf].modifiable = false

  local prev = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(code_win)
  vim.cmd 'belowright 1split'
  local iwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(iwin, ibuf)
  local wo = vim.wo[iwin]
  wo.number, wo.relativenumber, wo.cursorline = false, false, false
  wo.signcolumn, wo.foldcolumn, wo.list = 'no', '0', false
  wo.winfixheight, wo.statuscolumn, wo.colorcolumn = true, '', ''
  wo.winhighlight = 'Normal:DansTokInfo,EndOfBuffer:DansTokInfo'
  pcall(vim.api.nvim_win_set_height, iwin, 1)
  if vim.api.nvim_win_is_valid(prev) then vim.api.nvim_set_current_win(prev) end
  return ibuf, iwin, code_win
end

local function close_info(st)
  if st.info_win and vim.api.nvim_win_is_valid(st.info_win) then
    pcall(vim.api.nvim_win_close, st.info_win, true)
  end
  if st.info_buf and vim.api.nvim_buf_is_valid(st.info_buf) then
    pcall(vim.api.nvim_buf_delete, st.info_buf, { force = true })
  end
  st.info_win, st.info_buf, st.code_win = nil, nil, nil
end

local function on_tokens(buf, tick, lines, flat)
  local st = state[buf]
  if not st then return end
  local count = math.floor(#flat / 3)
  local S, L, ID = {}, {}, {}
  for k = 1, count do
    local o = (k - 1) * 3
    S[k] = flat[o + 1]
    L[k] = flat[o + 2]
    ID[k] = flat[o + 3]
  end
  local line_start = { [1] = 0 }
  for r = 1, #lines do
    line_start[r + 1] = line_start[r] + #lines[r] + 1
  end
  st.S, st.L, st.ID = S, L, ID
  st.count = count
  st.line_start = line_start
  st.nbytes = line_start[#lines + 1]
  st.tick = tick
  st.last_top, st.last_bot = nil, nil
  paint(buf, true)
  update_info(buf)
end

local function run_tokenize(buf)
  local st = state[buf]
  if not st then return end
  if st.inflight then
    st.dirty = true
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  if #text > max_bytes() then
    vim.notify_once(string.format('dans-tokenizer: buffer over the %.0f MB cap, not tokenizing (vim.g.dans_tokenizer_max_bytes to raise)', max_bytes() / 1048576), vim.log.levels.WARN)
    return
  end
  st.inflight = true
  vim.system({ node_cmd(), SCRIPT, DATA }, { stdin = text, text = true }, function(res)
    vim.schedule(function()
      local cur = state[buf]
      if cur then
        cur.inflight = false
      end
      if not cur then return end
      if res.code ~= 0 then
        vim.notify('dans-tokenizer: node failed: ' .. (res.stderr or '?'), vim.log.levels.ERROR)
        return
      end
      local ok, flat = pcall(vim.json.decode, res.stdout)
      if ok and type(flat) == 'table' then
        on_tokens(buf, tick, lines, flat)
      end
      if cur.dirty then
        cur.dirty = false
        run_tokenize(buf)
      end
    end)
  end)
end

local DEBOUNCE_MS = 250

local function schedule_tokenize(buf)
  local st = state[buf]
  if not st then return end
  if st.debounce then
    st.debounce:stop()
  else
    st.debounce = (vim.uv or vim.loop).new_timer()
  end
  st.debounce:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if state[buf] then run_tokenize(buf) end
  end))
end

-- Silence every other coloring source for the buffer, remembering prior state so
-- disable() can put it all back.
local function suppress_others(buf)
  local saved = {}

  local ok, fe = pcall(require, 'custom.dans_frontend_cpp')
  if ok and fe.TOGGLEABLE then
    saved.fe = {}
    for _, name in ipairs(fe.TOGGLEABLE) do
      local on = fe.module_is_on(name, buf)
      saved.fe[name] = on
      if on then pcall(fe.module_set, name, buf, false) end
    end
  end

  saved.ts = vim.treesitter.highlighter ~= nil and vim.treesitter.highlighter.active[buf] ~= nil
  pcall(vim.treesitter.stop, buf)

  saved.syntax = vim.bo[buf].syntax
  vim.bo[buf].syntax = ''

  saved.clients = {}
  for _, c in ipairs(vim.lsp.get_clients { bufnr = buf }) do
    if c.server_capabilities and c.server_capabilities.semanticTokensProvider then
      saved.clients[#saved.clients + 1] = c.id
      pcall(vim.lsp.semantic_tokens.stop, buf, c.id)
    end
  end

  vim.b[buf].dans_token_mode = true
  pcall(vim.lsp.buf.clear_references)
  local rns = vim.api.nvim_get_namespaces()['nvim.lsp.references']
  if rns then pcall(vim.api.nvim_buf_clear_namespace, buf, rns, 0, -1) end

  saved.diag = not (vim.diagnostic.is_enabled and vim.diagnostic.is_enabled { bufnr = buf } == false)
  pcall(vim.diagnostic.enable, false, { bufnr = buf })

  return saved
end

local function restore_others(buf, saved)
  if not saved then return end
  pcall(function() vim.b[buf].dans_token_mode = nil end)

  if saved.diag then pcall(vim.diagnostic.enable, true, { bufnr = buf }) end

  for _, id in ipairs(saved.clients or {}) do
    pcall(vim.lsp.semantic_tokens.start, buf, id)
  end

  if saved.syntax ~= nil then vim.bo[buf].syntax = saved.syntax end
  if saved.ts then pcall(vim.treesitter.start, buf) end

  if saved.fe then
    local ok, fe = pcall(require, 'custom.dans_frontend_cpp')
    if ok then
      for name, was_on in pairs(saved.fe) do
        if was_on then pcall(fe.module_set, name, buf, true) end
      end
    end
  end
end

function M.is_enabled(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return state[buf] ~= nil
end

function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if state[buf] then return end
  if vim.fn.filereadable(DATA) == 0 then
    vim.notify('dans-tokenizer: missing ' .. DATA, vim.log.levels.ERROR)
    return
  end
  -- Refuse over-cap buffers up front, otherwise enabling would suppress every
  -- other coloring source and then leave the buffer blank (no tokens painted).
  local bytes = buf_bytes(buf)
  if bytes > max_bytes() then
    vim.notify(string.format('dans-tokenizer: buffer is %.1f MB, over the %.0f MB cap (vim.g.dans_tokenizer_max_bytes to raise)', bytes / 1048576, max_bytes() / 1048576), vim.log.levels.WARN)
    return
  end
  define_groups()

  local st = { saved = suppress_others(buf), count = 0 }
  state[buf] = st

  local aug = vim.api.nvim_create_augroup('ds_tokenizer_' .. buf, { clear = true })
  st.aug = aug
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = aug,
    buffer = buf,
    callback = function() schedule_tokenize(buf) end,
  })
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'CursorMoved', 'CursorMovedI' }, {
    group = aug,
    buffer = buf,
    callback = function()
      paint(buf, false)
      update_info(buf)
    end,
  })
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = aug,
    buffer = buf,
    callback = function() update_info(buf) end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = aug,
    buffer = buf,
    callback = function() paint(buf, true) end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = aug,
    callback = function() define_groups() end,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = aug,
    buffer = buf,
    callback = function() M.disable(buf) end,
  })

  st.info_buf, st.info_win, st.code_win = open_info(buf)
  update_info(buf)

  run_tokenize(buf)
  vim.notify('dans-tokenizer on', vim.log.levels.INFO)
end

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state[buf]
  if not st then return end
  if st.debounce then pcall(function() st.debounce:stop() end) end
  if st.aug then pcall(vim.api.nvim_del_augroup_by_id, st.aug) end
  close_info(st)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    restore_others(buf, st.saved)
  end
  state[buf] = nil
  vim.notify('dans-tokenizer off', vim.log.levels.INFO)
end

function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if state[buf] then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

return M
