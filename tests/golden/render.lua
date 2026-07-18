-- Headless renderer for golden regression: load a C/C++ fixture, apply the full
-- frontend (every module via its real autocmds), and reconstruct the per-line
-- *displayed* text -- conceals, inline/overlay virt_text, and the window-local
-- `Conceal` matchadds (std::/inline/...) all applied. Text only; highlight
-- groups are intentionally not captured (they'd make the golden brittle and the
-- structural transform is what a refactor must preserve).
--
-- The visible-range cap (cursor +/- 40) is overridden to the whole buffer so a
-- long file renders end to end in one pass. Shared by the golden cases in the
-- spec (compare + update modes).

local M = {}

-- Every extmark namespace this config owns is named `ds_*`; collect them all so
-- a new module's marks are captured without editing this list. Color-only marks
-- (no conceal/virt_text) are ignored by the reconstruction below, so including
-- them is harmless.
local function ds_namespaces()
  local out = {}
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:match '^ds_' then
      out[#out + 1] = id
    end
  end
  return out
end

-- Reconstruct what column-by-column would render for one line.
local function displayed_line(buf, ns_ids, row0, line)
  local conceals, inline, overlay = {}, {}, nil
  for _, ns in ipairs(ns_ids) do
    for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row0, 0 }, { row0, -1 }, { details = true })) do
      local sc, d = mk[3], mk[4]
      if d.conceal ~= nil and d.end_col then
        conceals[#conceals + 1] = { s = sc, e = d.end_col, cc = d.conceal }
      end
      if d.virt_text and #d.virt_text > 0 then
        local t = {}
        for _, c in ipairs(d.virt_text) do
          t[#t + 1] = c[1]
        end
        t = table.concat(t)
        if d.virt_text_pos == 'overlay' then
          if not overlay or sc < overlay.s then
            overlay = { s = sc, text = t }
          end
        elseif d.virt_text_pos == 'inline' then
          inline[sc] = (inline[sc] or '') .. t
        end
      end
    end
  end
  -- Window `Conceal` matchadds (std::/dans::/inline/dans_): hide, no cchar.
  for _, mt in ipairs(vim.fn.getmatches()) do
    if mt.group == 'Conceal' and mt.pattern then
      local ok, re = pcall(vim.regex, mt.pattern)
      if ok then
        local base, s = 0, line
        while true do
          local ms, me = re:match_str(s)
          if not ms or me <= ms then
            break
          end
          conceals[#conceals + 1] = { s = base + ms, e = base + me, cc = '' }
          s = s:sub(me + 1)
          base = base + me
        end
      end
    end
  end
  local hide, cstart = {}, {}
  for _, r in ipairs(conceals) do
    for c = r.s, r.e - 1 do
      hide[c] = true
    end
    if r.cc ~= '' then
      cstart[r.s] = { e = r.e, cc = r.cc }
    end
  end
  local out, c, n = {}, 0, #line
  while c < n do
    if overlay and c == overlay.s then
      out[#out + 1] = overlay.text
      c = n
      break
    end
    if inline[c] then
      out[#out + 1] = inline[c]
    end
    if cstart[c] then
      out[#out + 1] = cstart[c].cc
      c = cstart[c].e
    elseif hide[c] then
      c = c + 1
    else
      out[#out + 1] = line:sub(c + 1, c + 1)
      c = c + 1
    end
  end
  if overlay and overlay.s == n then
    out[#out + 1] = overlay.text
  end
  if inline[n] then
    out[#out + 1] = inline[n]
  end
  return table.concat(out)
end

-- Render `path` end to end; returns a list of displayed lines.
function M.render_file(path)
  local f = assert(io.open(path, 'r'))
  local src = f:read '*a'
  f:close()
  src = src:gsub('\r\n', '\n'):gsub('\r', '\n')
  local lines = vim.split(src, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_name, buf, path)
  vim.bo[buf].filetype = 'cpp'
  vim.api.nvim_set_current_buf(buf)
  pcall(function()
    vim.treesitter.get_parser(buf, 'cpp'):parse()
  end)

  local vu = require 'custom.dans_frontend_cpp.util'
  local saved = vu.visible_range
  vu.visible_range = function()
    return 0, vim.api.nvim_buf_line_count(buf)
  end

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  vim.cmd 'doautocmd CursorMoved'

  local ns_ids = ds_namespaces()
  local out = {}
  for i = 1, #lines do
    out[i] = displayed_line(buf, ns_ids, i - 1, lines[i])
  end

  vu.visible_range = saved
  return out
end

return M
