local H = {}

local Session = {}
Session.__index = Session

local function frontend_namespaces()
  local out = {}
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:match '^ds_' then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function displayed_line(buf, row0)
  local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ''
  local conceals, inline, overlay = {}, {}, nil
  for _, ns in ipairs(frontend_namespaces()) do
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row0, 0 }, { row0, -1 }, { details = true })) do
      local col, detail = mark[3], mark[4]
      if detail.conceal ~= nil and detail.end_col then
        conceals[#conceals + 1] = { start_col = col, end_col = detail.end_col, replacement = detail.conceal }
      end
      if detail.virt_text and #detail.virt_text > 0 then
        local parts = {}
        for _, chunk in ipairs(detail.virt_text) do
          parts[#parts + 1] = chunk[1]
        end
        local text = table.concat(parts)
        if detail.virt_text_pos == 'overlay' then
          if not overlay or col < overlay.start_col then
            overlay = { start_col = col, text = text }
          end
        elseif detail.virt_text_pos == 'inline' then
          inline[col] = (inline[col] or '') .. text
        end
      end
    end
  end

  local hidden, replacement_at = {}, {}
  for _, range in ipairs(conceals) do
    for col = range.start_col, range.end_col - 1 do
      hidden[col] = true
    end
    if range.replacement ~= '' then
      replacement_at[range.start_col] = range
    end
  end

  local out, col = {}, 0
  while col < #line do
    if overlay and col == overlay.start_col then
      out[#out + 1] = overlay.text
      col = #line
      break
    end
    if inline[col] then
      out[#out + 1] = inline[col]
    end
    local replacement = replacement_at[col]
    if replacement then
      out[#out + 1] = replacement.replacement
      col = replacement.end_col
    elseif hidden[col] then
      col = col + 1
    else
      out[#out + 1] = line:sub(col + 1, col + 1)
      col = col + 1
    end
  end
  if overlay and overlay.start_col == #line then
    out[#out + 1] = overlay.text
  end
  if inline[#line] then
    out[#out + 1] = inline[#line]
  end
  return table.concat(out)
end

local function settle()
  vim.cmd 'redraw'
  vim.wait(10)
end

function H.open(opts)
  opts = opts or {}
  local lines = vim.deepcopy(opts.lines or {})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if opts.name then
    vim.api.nvim_buf_set_name(buf, opts.name)
  end
  if opts.style_profile then
    require('custom.dans_frontend_cpp.style').set_buffer_profile(buf, opts.style_profile)
  end
  vim.bo[buf].filetype = opts.filetype or 'cpp'
  vim.api.nvim_set_current_buf(buf)
  pcall(function()
    vim.treesitter.get_parser(buf, opts.language or vim.bo[buf].filetype):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { opts.cursor or 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  vim.cmd 'doautocmd CursorMoved'
  settle()
  return setmetatable({ buf = buf, original = lines }, Session)
end

function Session:display(line_number)
  return displayed_line(self.buf, line_number - 1)
end

function Session:source(line_number)
  return vim.api.nvim_buf_get_lines(self.buf, line_number - 1, line_number, false)[1] or ''
end

function Session:mode()
  return vim.fn.mode()
end

function Session:select(kind, first_line, last_line)
  vim.api.nvim_win_set_cursor(0, { first_line, 0 })
  vim.cmd 'doautocmd CursorMoved'
  local key = ({ char = 'v', line = 'V', block = string.char(22) })[kind]
  assert(key, 'unknown selection kind: ' .. tostring(kind))
  local delta = math.max(0, last_line - first_line)
  vim.cmd('normal! ' .. key .. (delta > 0 and (tostring(delta) .. 'j') or ''))
  settle()
  return self
end

function Session:escape()
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  vim.api.nvim_feedkeys(esc, 'x', false)
  settle()
  return self
end

function Session:assert_source_unchanged()
  local current = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  return vim.deep_equal(current, self.original)
end

return H
