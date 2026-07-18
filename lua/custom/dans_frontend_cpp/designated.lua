-- Designated-initializer rendering (treesitter, view-only). For each
-- `.field = value` aggregate pair:
--   .width = 800      ->  width=800     (drop the dot, tighten the `=`)
--   .width = width    ->  width         (pun: value == field, hide ` = value`)
-- The field name gets the muted hint color (DansHint). Skips shared reveal rows
-- and any line view overlays (it renders those itself). Conceal-based, so the
-- value keeps its normal coloring.
--
-- Covers the non-overlay lines: multi-line aggregate openers' body lines, call-site
-- temporaries, returns. Designated inits *inside* a overlay-covered declaration's
-- value are not handled here (the overlay draws that line); that's a separate follow-up.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_designated'
local vu = require 'custom.dans_frontend_cpp.util'
local P = require 'custom.dans_frontend_cpp.parse'

local DESIG_QUERY = [[(field_designator) @fd]]

-- VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO -> InstanceCreateInfo. Each _-word is
-- Capitalized; a trailing vendor tag (EXT/KHR/NV/...) stays all-caps to match the
-- real Vk type name (VkDebugUtilsMessengerCreateInfoEXT).
local VK_VENDOR = {
  KHR = true, KHX = true, EXT = true, NV = true, NVX = true, AMD = true, AMDX = true,
  INTEL = true, GOOGLE = true, MVK = true, NN = true, QCOM = true, ARM = true,
  IMG = true, FUCHSIA = true, HUAWEI = true, VALVE = true, SEC = true, GGP = true,
  QNX = true, ANDROID = true, MESA = true, LUNARG = true,
}
local function vk_struct_camel(rest)
  local out = {}
  for word in rest:gmatch '[^_]+' do
    out[#out + 1] = VK_VENDOR[word] and word or (word:sub(1, 1):upper() .. word:sub(2):lower())
  end
  return table.concat(out)
end

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
  if not vu.module_enabled(bufnr, 'designated') then
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
  local lang = parser:lang()

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)

  local okq, q = pcall(vim.treesitter.query.parse, lang, DESIG_QUERY)
  if not okq or not q then
    return
  end
  -- Per-list cache: a multi-line aggregate aligns its `=` (like struct fields);
  -- a single-line one stays tight (`field=value`). maxw = widest field name.
  local list_info = {}
  local function list_meta(pair)
    local list = pair:parent()
    if not list or list:type() ~= 'initializer_list' then
      return { multiline = false, maxw = 0 }
    end
    local lsr, lsc, ler = list:range()
    local key = lsr .. ',' .. lsc
    if list_info[key] then
      return list_info[key]
    end
    local maxw = 0
    if lsr ~= ler then
      for child in list:iter_children() do
        if child:type() == 'initializer_pair' then
          for d in child:iter_children() do
            if d:type() == 'field_designator' then
              local _, dc, _, dec = d:range()
              maxw = math.max(maxw, dec - dc - 1) -- field width (minus the dot)
            end
          end
        end
      end
    end
    local meta = { multiline = lsr ~= ler, maxw = maxw }
    list_info[key] = meta
    return meta
  end

  for _, node in q:iter_captures(root, bufnr, s0, e0) do
    local sr, sc, ser, fec = node:range() -- field_designator `.field`
    local pair = node:parent()
    if sr == ser and not skip.skip(sr) and pair and pair:type() == 'initializer_pair' then
      local psr, _, per, pec = pair:range()
      if psr == sr then -- the `.field` is on the pair's first line (value may span more)
        local single = per == sr
        local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ''
        local field = line:sub(sc + 2, fec) -- drop the leading '.'
        -- multi-line value: render only the first line's `= value-start`; the
        -- continuation lines carry no field designator, so they stay untouched.
        local rest = line:sub(fec + 1, single and pec or #line)
        local eqs, eqe = rest:find('=%s*')
        if field ~= '' and eqs then
          local value = vim.trim(rest:sub(eqe + 1))
          local stype_rest = single and field == 'sType' and value:match '^VK_STRUCTURE_TYPE_(.+)$'
          if stype_rest then
            -- `.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO` -> `InstanceCreateInfo`.
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_col = pec, conceal = '' })
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, {
              virt_text = { { vk_struct_camel(stype_rest), 'DansVkStructName' } },
              virt_text_pos = 'inline',
            })
            goto continue
          end
          -- drop the leading dot
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_col = sc + 1, conceal = '' })
          -- muted hint color on the field name
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc + 1, { end_col = fec, hl_group = 'DansHint' })
          if single and P.field_eq(P.access_tail(value), field) then
            -- pun: `.center = center` / `.center = cfg.center` / `.messageSeverity =
            -- message_severity` -> `center` (the value's last access names the field
            -- across naming conventions, so hide ` = value`).
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, fec, { end_col = pec, conceal = '' })
          else
            local eqcol = fec + eqs - 1
            local valstart = fec + eqe
            local meta = list_meta(pair)
            -- hide the original space(s) before `=` either way.
            if eqcol > fec then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, fec, { end_col = eqcol, conceal = '' })
            end
            if meta.multiline then
              -- align: pad the field so every `=` lands at maxw+1; keep ` = value`.
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, eqcol, {
                virt_text = { { string.rep(' ', meta.maxw - #field + 1), 'Normal' } },
                virt_text_pos = 'inline',
              })
            elseif valstart > eqcol + 1 then
              -- single-line: tighten the space after `=` too -> `field=value`.
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, eqcol + 1, { end_col = valstart, conceal = '' })
            end
            -- multi-line value: re-indent its continuation lines to the (now
            -- constant) value column, so an operator-aligned-under-value layout
            -- (`a\n | b`) stays aligned after the dot / prefix / `=` shifts.
            if not single and meta.multiline then
              local valcol = sc + meta.maxw + 3 -- indent + padded field + ` = `
              for cl = sr + 1, per do
                if not skip.skip(cl) then
                  local cline = vim.api.nvim_buf_get_lines(bufnr, cl, cl + 1, false)[1] or ''
                  local lead = #(cline:match '^%s*' or '')
                  if lead > 0 then
                    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, cl, 0, { end_col = lead, conceal = '' })
                  end
                  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, cl, lead, {
                    virt_text = { { string.rep(' ', valcol), 'Normal' } },
                    virt_text_pos = 'inline',
                  })
                end
              end
            end
          end
        end
      end
    end
    ::continue::
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_designated', { clear = true })
  vu.on_decorate(group, { 'FileType', 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, refresh)
end

return M
