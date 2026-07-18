-- View-only alignment of the `=` across an enum body's entries. Source is never
-- changed; inline virt_text padding after each enumerator name makes the *seen*
-- `=` line up. Cursor line renders raw (skipper), like the other view modules.
--
-- Unlike arrow_align there's no width model to mirror: enumerator names aren't
-- concealed or aliased, so a name's treesitter end column is exactly its rendered
-- column. The value side (e.g. GLFW_* macros that markers strips to a bare name)
-- is right of the `=`, so it never affects the aligned column.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_enum_align'
local vu = require 'custom.dans_frontend_cpp.util'

local LIST_QUERY = [[(enumerator_list) @list]]

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vu.is_cpp(vim.bo[bufnr].filetype) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'enum_align') then
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
  local okq, q = pcall(vim.treesitter.query.parse, parser:lang(), LIST_QUERY)
  if not okq or not q then
    return
  end

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)

  for _, list in q:iter_captures(trees[1]:root(), bufnr, s0, e0) do
    -- enumerators that carry a value; align their `=` to one column (max name
    -- end). maxend is over the whole list so alignment is stable while scrolling.
    local entries, maxend = {}, 0
    for child in list:iter_children() do
      if child:type() == 'enumerator' then
        local nm = child:field('name')[1]
        local val = child:field('value')[1]
        if nm and val then
          local nr, _, ner, nec = nm:range()
          if nr == ner then
            entries[#entries + 1] = { row = nr, col = nec }
            if nec > maxend then
              maxend = nec
            end
          end
        end
      end
    end
    if #entries >= 2 then
      for _, en in ipairs(entries) do
        local pad = maxend - en.col
        if pad > 0 and not skip.skip(en.row) then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, en.row, en.col, {
            virt_text = { { string.rep(' ', pad), 'Normal' } },
            virt_text_pos = 'inline',
          })
        end
      end
    end
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_enum_align', { clear = true })
  vu.on_decorate(group, { 'FileType', 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, refresh)
end

return M
