-- do/while(0) function-like macro rendering (treesitter + text, view-only). The
-- classic `#define NAME(args) do { ... } while (0)` wrapper is rigid boilerplate;
-- unwrap it to read as a plain braced block:
--
--   #define CUDA_NOCHECK(x)  \        Macro CUDA_NOCHECK(x)
--       do                   \        {
--       {                    \        (blank -- the do and { collapse to one brace)
--           (void) (x);      \            (void) (x);
--       } while (0)                   }
--
-- Per line, never merging rows (only fold/collapse may change line counts), so the
-- `do` row becomes the brace and the bare `{` row blanks. Allman: the brace sits
-- on its own line at the macro's column. Conceal + virt_text only; bytes are never
-- touched, so the real do/while(0) still compiles and shared reveal rows show raw.
--
-- Headers only (.h / .hpp / .cuh) -- where these macros live.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_macro_def'
local vu = require 'custom.dans_frontend_cpp.util'

local SHIFT = 4

-- A header buffer (.h / .hpp / .cuh): macros live here, not in .cpp/.cu.
local function is_header(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match '%.h$' or name:match '%.hpp$' or name:match '%.cuh$' or name:match '%.hh$' or name:match '%.hxx$'
end

-- Strip a trailing line-continuation `\` (and the run of spaces before it).
-- Returns the content end column (0-based, exclusive) -- everything from there to
-- EOL is the backslash+padding to conceal -- and the trimmed-for-analysis text.
local function strip_cont(line)
  local bs = line:find '%s*\\%s*$'
  local content_end = bs and (bs - 1) or #line
  return content_end, vim.trim(line:sub(1, content_end))
end

local function conceal(bufnr, row, s, e)
  if e > s then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, s, { end_col = e, conceal = '' })
  end
end

local function inject(bufnr, row, col, text, hl)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, {
    virt_text = { { text, hl or 'Normal' } },
    virt_text_pos = 'inline',
  })
end

-- Head end column (0-based, exclusive) of `#define NAME(params)` on the define
-- row: the right edge of the last name/params child that sits on that row.
local function head_end(node, sr)
  local fin = nil
  for c in node:iter_children() do
    local t = c:type()
    if t == 'identifier' or t == 'preproc_params' then
      local csr, _, cer, cec = c:range()
      if csr == sr and cer == sr then
        fin = math.max(fin or 0, cec)
      end
    end
  end
  return fin
end

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vu.is_cpp(vim.bo[bufnr].filetype) or not is_header(bufnr) then
    return
  end
  if vu.cold_gate(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'macro_def') then
    return
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return
  end
  local root = trees[1]:root()
  local okq, q = pcall(vim.treesitter.query.parse, parser:lang(), '[ (preproc_function_def) (preproc_def) ] @m')
  if not okq or not q then
    return
  end

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vu.buf_lines(bufnr)
  local get = function(r)
    return lines[r + 1] or ''
  end

  for _, node in q:iter_captures(root, bufnr, s0, e0) do
    local sr, _, er = node:range()
    -- node:range()'s end row lands on the line break after the macro, so walk back
    -- over trailing blanks to the real closing `} while (0)` row.
    while er > sr and get(er):match '^%s*$' do
      er = er - 1
    end
    -- multi-line define whose first body row is `do` and last row is `} while (0)`.
    local _, do_txt = strip_cont(get(sr + 1))
    local _, end_txt = strip_cont(get(er))
    if er > sr + 1 and (do_txt == 'do' or do_txt:match '^do%s*{$') and end_txt:match '^}%s*while%s*%(%s*0%s*%)%s*;?$' then
      local base = #(get(sr):match '^%s*' or '') -- the macro's own indentation column
      local he = head_end(node, sr)

      -- The brace row (the `do`) and the bare `{` row, if separate.
      local do_row = sr + 1
      local combined = do_txt:match '{%s*$' ~= nil -- `do {` on one line
      local brace_only_row = combined and nil or (sr + 2)
      local body_start = (brace_only_row or do_row) + 1

      -- Dedent for the body, measured off its first row, preserving inner nesting.
      local first_body = get(body_start)
      local fb_indent = #(first_body:match '^%s*' or '')
      local dedent = math.max(0, fb_indent - (base + SHIFT))

      -- 1. define row: `#define` -> green `Macro`, drop the trailing `\`.
      if he and not skip.skip(sr) then
        conceal(bufnr, sr, base, base + 7) -- `#define`
        inject(bufnr, sr, base, 'Macro', 'DansLambda')
        conceal(bufnr, sr, he, #get(sr))
      end

      -- 2. the `do` row becomes the Allman brace at the macro's column.
      if not skip.skip(do_row) then
        local dl = get(do_row)
        conceal(bufnr, do_row, 0, #dl)
        inject(bufnr, do_row, 0, string.rep(' ', base) .. '{')
      end

      -- 3. a separate bare `{` row collapses into the brace above -> blank.
      if brace_only_row and not skip.skip(brace_only_row) then
        conceal(bufnr, brace_only_row, 0, #get(brace_only_row))
      end

      -- 4. body rows: dedent one level and drop the trailing `\`.
      for r = body_start, er - 1 do
        if not skip.skip(r) then
          local bl = get(r)
          if dedent > 0 and #(bl:match '^%s*' or '') >= dedent then
            conceal(bufnr, r, 0, dedent)
          end
          local ce = strip_cont(bl)
          conceal(bufnr, r, ce, #bl)
        end
      end

      -- 5. closing row: `} while (0)` -> a lone `}` at the macro's column.
      if not skip.skip(er) then
        local cl = get(er)
        local cb = cl:find('}', 1, true)
        if cb then
          conceal(bufnr, er, 0, cb - 1) -- leading indent
          inject(bufnr, er, cb - 1, string.rep(' ', base))
          conceal(bufnr, er, cb, #cl) -- ` while (0);`
        end
      end
    end
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_macro_def', { clear = true })
  vu.on_decorate(group, { 'FileType', 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, refresh)
end

return M
