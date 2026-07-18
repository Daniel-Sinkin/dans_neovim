-- View-only markdown rendering of `///` doc-comment blocks in .hpp headers.
-- Conceal + virt_text only; source bytes are never touched. `///` (not plain
-- `//`) marks a doc block, so ordinary comments are left as comments. The block
-- gets a distinct background so it reads as a block; shared reveal rows show the
-- raw `///` text, like the other dans view modules.
--
-- Per `///` line in a run of `///` lines:
--   /// # Heading   ->  Heading        (bold, the `#`s hidden)
--   /// - item       ->  • item         (the `-` shown as a bullet)
--   /// `code`       ->  code           (code-colored, backticks hidden)
-- and the `/// ` leader is concealed so the prose reads as prose.
--
-- Fenced code: a ``` line opens a region rendered verbatim (no markdown) on a
-- separate code-block background until the closing ```; the fence lines are
-- hidden. With vim.g.dans_doc_md_inline_frontend set, fenced code additionally
-- gets the cpp frontend's text transforms (alias collapse + std:: strip) so
-- examples read in the dans dialect -- a load-time setting, off by default.
-- Scope: heading / bullet / inline-code / fenced code / leader / block
-- background. Not yet: **bold** / *italic* inline, numbered lists. On by default
-- for .hpp; toggle per buffer with :DansDocMarkdown.

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'

local ns = vim.api.nvim_create_namespace 'ds_cpp_doc_md'
local enabled = {} -- bufnr -> bool; nil means "default", which is ON for .hpp

local BLOCK_WIDTH = 120 -- doc / code blocks render as a fixed-width band, not full-window
local dw = vim.fn.strdisplaywidth

local function is_hpp(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):sub(-4) == '.hpp'
end

-- On by default (like the other view modules); :DansDocMarkdown sets an explicit
-- false to turn it off for a buffer.
local function is_on(bufnr)
  if vu.is_recording() then
    return false -- suspended while a macro records (raw columns for motions)
  end
  local v = enabled[bufnr]
  if v == nil then
    return true
  end
  return v
end

-- Multiply an 0xRRGGBB color toward black; used to derive the fenced-code
-- background as a darker shade of the doc-block background.
local function darken(rgb, f)
  if type(rgb) ~= 'number' then
    return rgb
  end
  local r = math.floor((math.floor(rgb / 65536) % 256) * f + 0.5)
  local g = math.floor((math.floor(rgb / 256) % 256) * f + 0.5)
  local b = math.floor((rgb % 256) * f + 0.5)
  return r * 65536 + g * 256 + b
end

-- Mix 0xRRGGBB `a` toward `b` by weight t (0 = a, 1 = b); used to mute the inline
-- code green by pulling it toward the comment gray.
local function blend(a, b, t)
  if type(a) ~= 'number' or type(b) ~= 'number' then
    return a
  end
  local ch = function(x, sh)
    return math.floor(x / sh) % 256
  end
  local mix = function(x, y)
    return math.floor(x * (1 - t) + y * t + 0.5)
  end
  local r = mix(ch(a, 65536), ch(b, 65536))
  local g = mix(ch(a, 256), ch(b, 256))
  local bl = mix(ch(a, 1), ch(b, 1))
  return r * 65536 + g * 256 + bl
end

-- Prose reads as comment text (gray, italic) so the doc block separates cleanly
-- from real code rather than competing with it; a distinct block background (the
-- float bg, which adapts day/night) sits behind it. The text groups carry that bg
-- so it shows BEHIND the prose -- a fg-only group would let Normal's bg through
-- The fenced-code background, and a cache of fence-token groups that carry a
-- captured group's fg ON the code-block bg (so the bg dominates -- a raw treesitter
-- group like @number can have its own bg that would otherwise punch a lighter hole
-- in the block). Both (re)set in set_hl.
local code_bg
local cpp_tok = {}

-- A fg-only-over-code_bg variant of a treesitter highlight group, for fenced code.
local function cpp_token_group(name)
  local cached = cpp_tok[name]
  if cached then
    return cached
  end
  local src = vim.api.nvim_get_hl(0, { name = name, link = false })
  local derived = 'DansDocCpp_' .. name:gsub('%W', '_')
  vim.api.nvim_set_hl(0, derived, {
    fg = src.fg,
    bg = code_bg, -- the block bg dominates; only the fg comes from the token
    bold = src.bold,
    italic = src.italic,
    underline = src.underline,
    undercurl = src.undercurl,
    sp = src.sp,
  })
  cpp_tok[name] = derived
  return derived
end

-- and the block would only tint the margins. Re-asserted on ColorScheme.
local function set_hl()
  local get = function(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  local normal = get 'Normal'
  local block_bg = (get 'NormalFloat').bg or normal.bg
  vim.api.nvim_set_hl(0, 'DansDocBlock', { bg = block_bg })
  local comment = get 'Comment'
  local comment_fg = comment.fg or normal.fg
  vim.api.nvim_set_hl(0, 'DansDocText', { fg = comment_fg, bg = block_bg, italic = comment.italic })
  vim.api.nvim_set_hl(0, 'DansDocHeading', { fg = comment_fg, bg = block_bg, bold = true })
  vim.api.nvim_set_hl(0, 'DansDocBullet', { fg = comment_fg, bg = block_bg, italic = comment.italic })
  -- inline `code`: a muted green -- the config's green (0x9ece6a, hardcoded the
  -- same way throughout treesitter.lua; the treesitter @string/@markup.raw groups
  -- are flattened away in cpp buffers, so they can't be read here) pulled toward
  -- the comment gray so it reads as code without the loud full-saturation green.
  vim.api.nvim_set_hl(0, 'DansDocCode', { fg = blend(0x9ece6a, comment_fg, 0.4), bg = block_bg })
  -- fenced ``` code: an even darker background (the doc-block bg darkened) so the
  -- code reads as a nested block. cpp fences get real treesitter highlighting on
  -- top, so this fg is only the neutral fallback for chars no capture colors.
  code_bg = darken(block_bg, 0.65) or (get '@markup.raw').bg or block_bg
  vim.api.nvim_set_hl(0, 'DansDocCodeBlock', { fg = normal.fg, bg = code_bg })
  cpp_tok = {} -- rebuild fence-token variants against the new code_bg
end

local function conceal(bufnr, row0, s, e, cchar)
  if e > s then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s, { end_col = e, conceal = cchar or '' })
  end
end

local function hl(bufnr, row0, s, e, group, priority)
  if e > s then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s, { end_col = e, hl_group = group, priority = priority })
  end
end

-- Opt-in "inline frontend" over fenced code (set vim.g.dans_doc_md_inline_frontend
-- in your config; load-time, reload to change). Applies the cheap text transforms
-- of the cpp frontend -- the $-alias collapse (reusing the SAME aliases.ALIASES
-- table, so there is one source of truth) and the std::/dans:: strip -- so code
-- examples read in the dans dialect. The declaration overlay (x: T, carets) is
-- deliberately NOT applied: examples are rarely declarations, and that would need
-- treesitter over comment-embedded code.
local function inline_frontend_on()
  return vim.g.dans_doc_md_inline_frontend == true
end

local function is_word(c)
  return c ~= '' and c:match '[%w_]' ~= nil
end

local function apply_inline_frontend(bufnr, row0, content, base_col)
  -- alias collapse first, so std::runtime_error -> $re before the std:: strip.
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      local kw, rep = a[1], a[2]
      local from = 1
      while true do
        local s, e = content:find(kw, from, true)
        if not s then
          break
        end
        local before = s > 1 and content:sub(s - 1, s - 1) or ''
        if not is_word(before) and not is_word(content:sub(e + 1, e + 1)) then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, base_col + s - 1, {
            end_col = base_col + e,
            conceal = '',
            virt_text = { { rep, 'DansDocCodeBlock' } },
            virt_text_pos = 'inline',
          })
        end
        from = e + 1
      end
    end
  end
  for _, q in ipairs { 'std::', 'dans::' } do
    local from = 1
    while true do
      local s, e = content:find(q, from, true)
      if not s then
        break
      end
      if not is_word(s > 1 and content:sub(s - 1, s - 1) or '') then
        conceal(bufnr, row0, base_col + s - 1, base_col + e)
      end
      from = e + 1
    end
  end
end

-- Render one `/// ...` line. row0 is 0-based; content_col is the byte column
-- where the doc text starts (after `///` and one optional space).
local function render_line(bufnr, row0, line)
  local indent, content = line:match '^(%s*)///%s?(.*)$'
  if not content then
    return
  end
  local content_col = #line - #content -- byte col of the first content char

  -- hide the `/// ` leader (also for an empty `///` line, so it reads as a blank
  -- line inside the block rather than a stray `///`).
  conceal(bufnr, row0, #indent, content_col)
  if content == '' then
    return
  end
  -- repaint the whole body as doc text (block bg + tokyonight fg); element spans
  -- below paint over this at a higher priority.
  hl(bufnr, row0, content_col, #line, 'DansDocText', 150)

  local function col_of(idx)
    return content_col + idx - 1
  end

  -- line-level: heading (# ...) or bullet (- / *), mutually exclusive
  local hashes, htext = content:match '^(#+)%s+(.*)$'
  if hashes then
    local text_idx = #content - #htext + 1 -- 1-based index where heading text starts
    conceal(bufnr, row0, content_col, col_of(text_idx)) -- hide `#+ `
    hl(bufnr, row0, col_of(text_idx), #line, 'DansDocHeading', 200)
  else
    local b_indent = content:match '^(%s*)[%-%*]%s+'
    if b_indent then
      local marker = col_of(#b_indent + 1) -- the `-` / `*`
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, marker, {
        end_col = marker + 1,
        conceal = '•',
        hl_group = 'DansDocBullet',
        priority = 200,
      })
    end
  end

  -- inline `code`: hide the backticks, color the inner span
  local i = 1
  while true do
    local s = content:find('`', i, true)
    if not s then
      break
    end
    local e = content:find('`', s + 1, true)
    if not e then
      break
    end
    conceal(bufnr, row0, col_of(s), col_of(s) + 1)
    hl(bufnr, row0, col_of(s + 1), col_of(e), 'DansDocCode', 200)
    conceal(bufnr, row0, col_of(e), col_of(e) + 1)
    i = e + 1
  end
end

-- Paint a fixed-width (BLOCK_WIDTH) background band on one line: bg over the real
-- text, then an eol virt_text of spaces extending it to the target column. `vis`
-- is the line's already-rendered display width (conceals / indent accounted for).
local function band(bufnr, row0, line, group, vis)
  if #line > 0 then
    hl(bufnr, row0, 0, #line, group, 90)
  end
  local pad = BLOCK_WIDTH - vis
  if pad > 0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, #line, {
      virt_text = { { string.rep(' ', pad), group } },
      virt_text_pos = 'eol',
    })
  end
end

-- Rendered display width of a prose `///` line: leader gone, heading `#`s gone,
-- inline-code backticks gone (the bullet `-`->`•` keeps width).
local function prose_vis(indent, content)
  local body = content
  local _, htext = content:match '^(#+)%s+(.*)$'
  if htext then
    body = htext
  end
  body = body:gsub('`', '')
  return dw(indent .. body)
end

local function is_cpp_lang(lang)
  lang = (lang or ''):lower()
  return lang == '' or lang == 'cpp' or lang == 'c' or lang == 'c++' or lang == 'cc' or lang == 'cxx' or lang == 'h' or lang == 'hpp' or lang == 'hxx'
end

-- Real cpp treesitter highlighting for a fenced block. The code text (leaders
-- stripped) is parsed as a standalone cpp string; each capture is mapped back to
-- its buffer row/col and emitted as an hl_group extmark. Every shared reveal row
-- is left raw but still fed to the parser so multi-line captures stay aligned.
local function highlight_cpp(bufnr, code_lines, reveal)
  if #code_lines == 0 then
    return
  end
  local parts = {}
  for _, cl in ipairs(code_lines) do
    parts[#parts + 1] = cl.content
  end
  local src = table.concat(parts, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'cpp')
  if not ok or not parser then
    return
  end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees or not trees[1] then
    return
  end
  local query = vim.treesitter.query.get('cpp', 'highlights')
  if not query then
    return
  end
  for id, node in query:iter_captures(trees[1]:root(), src, 0, -1) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= '_' then
      local sr, sc, er, ec = node:range()
      for r = sr, er do
        local cl = code_lines[r + 1]
        if cl and not reveal[cl.row0] then
          local s = (r == sr) and sc or 0
          local e = (r == er) and ec or #cl.content
          hl(bufnr, cl.row0, cl.content_col + s, cl.content_col + e, cpp_token_group('@' .. name), 160)
        end
      end
    end
  end
end

local function refresh(bufnr)
  if not (vim.api.nvim_buf_is_valid(bufnr) and is_hpp(bufnr)) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass paints everything at once
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not is_on(bufnr) then
    return
  end
  local reveal = vu.reveal_set(bufnr)
  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  -- Scan only the on-screen window (plus a margin), not the whole buffer, so a
  -- large header isn't reprocessed and its fences reparsed on every repaint. `///`
  -- runs are short, so each run intersecting the window is expanded to its true
  -- bounds and processed whole, keeping fence (``` ... ```) state correct.
  local vs, ve = 1, n
  if bufnr == vim.api.nvim_get_current_buf() then
    vs = math.max(1, vim.fn.line 'w0' - vu.VISIBLE_MARGIN)
    ve = math.min(n, vim.fn.line 'w$' + vu.VISIBLE_MARGIN)
  end
  local i = vs
  while i <= ve do
    if lines[i]:match '^%s*///' then
      local s = i
      while s > 1 and lines[s - 1]:match '^%s*///' do
        s = s - 1
      end
      local j = i
      while j <= n and lines[j]:match '^%s*///' do
        j = j + 1
      end
      local in_fence = false -- inside a ``` ... ``` fenced code region
      local fence_lang = nil
      local code_lines = {}
      local function flush_code()
        if is_cpp_lang(fence_lang) then
          highlight_cpp(bufnr, code_lines, reveal)
        end
        code_lines = {}
      end
      for k = s, j - 1 do
        local row0 = k - 1
        local indent, content = lines[k]:match '^(%s*)///%s?(.*)$'
        content = content or ''
        local full = lines[k]
        -- a stray trailing CR (a \r\n file loaded as unix) renders as a `^M` cell
        -- with SpecialKey bg, breaking the band -- conceal it. No-op under `dos`.
        if full:sub(-1) == '\r' then
          conceal(bufnr, row0, #full - 1, #full)
        end
        local is_fence = content:match '^```' ~= nil
        local is_revealed = reveal[row0]

        if is_fence and not in_fence then
          -- opening fence: hidden; code-block bg forms the block's top edge.
          fence_lang = content:match '^```%s*([%w+]+)'
          if is_revealed then
            band(bufnr, row0, full, 'DansDocCodeBlock', dw(full))
          else
            band(bufnr, row0, full, 'DansDocCodeBlock', #indent)
            conceal(bufnr, row0, #indent, #full)
          end
          in_fence = true
        elseif is_fence and in_fence then
          -- closing fence: NO background. It renders empty, so leaving it on the
          -- Normal bg ends the block at the last code line and eases back to code.
          flush_code()
          if not is_revealed then
            conceal(bufnr, row0, #indent, #full)
          end
          in_fence = false
          fence_lang = nil
        elseif in_fence then
          -- code line: code-block bg, leader hidden. cpp gets treesitter
          -- highlighting via flush_code; the cursor row stays raw.
          local content_col = #full - #content
          if is_revealed then
            band(bufnr, row0, full, 'DansDocCodeBlock', dw(full))
          else
            band(bufnr, row0, full, 'DansDocCodeBlock', #indent + dw(content))
            conceal(bufnr, row0, #indent, content_col)
            if inline_frontend_on() then
              apply_inline_frontend(bufnr, row0, content, content_col)
            end
          end
          code_lines[#code_lines + 1] = { row0 = row0, content_col = content_col, content = content }
        else
          -- prose line: doc-block bg + markdown rendering (cursor row stays raw).
          if is_revealed then
            band(bufnr, row0, full, 'DansDocBlock', dw(full))
          else
            band(bufnr, row0, full, 'DansDocBlock', prose_vis(indent, content))
            render_line(bufnr, row0, full)
          end
        end
      end
      flush_code()
      i = j
    else
      i = i + 1
    end
  end
end

M.refresh = refresh

function M.set_enabled(bufnr, on)
  -- `nil` is the enabled/default state. Do not use `on and nil or false`:
  -- Lua falls through when the middle operand is nil, making that expression
  -- disable the module for both values of `on`.
  if on then
    enabled[bufnr] = nil
  else
    enabled[bufnr] = false
  end
  refresh(bufnr)
end

function M.is_enabled(bufnr)
  return is_on(bufnr)
end

function M.setup()
  set_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_doc_md', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = group,
    pattern = '*.hpp',
    callback = function(ev)
      vim.opt_local.conceallevel = 2
      vim.opt_local.concealcursor = ''
      -- re-pick the comment color on buffer enter: treesitter's cpp FileType
      -- handler resets Comment, which runs after this module's setup().
      if ev.event == 'BufReadPost' or ev.event == 'BufEnter' then
        set_hl()
      end
    end,
  })
  -- Use the same cursor/mode/reveal lifecycle as the C++ renderers. Doc blocks
  -- still require a whole-run refresh to preserve fenced-code state, but the
  -- shared gate deduplicates horizontal movement and supplies ModeChanged plus
  -- debounced scroll handling centrally.
  vu.on_decorate(group, { 'BufReadPost', 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI' }, refresh)
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })

  vim.api.nvim_create_user_command('DansDocMarkdown', function()
    local b = vim.api.nvim_get_current_buf()
    enabled[b] = not is_on(b) -- explicit true/false (nil default is on)
    refresh(b)
    vim.notify('doc markdown ' .. (enabled[b] and 'on' or 'off'), vim.log.levels.INFO)
  end, { desc = 'Toggle markdown rendering of /// doc blocks (.hpp)' })
end

return M
