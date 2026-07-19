-- Central owner-facing command palette.
--
-- `:Dans` (and the historical <leader>dan mapping) opens one vertical menu for
-- display mode, font size, authoring, analysis, project inspection, and developer
-- tools.  Individual :Dans* commands remain stable implementation/API entry
-- points, but the owner is not expected to remember them.
--
-- Navigation: j/k or arrows, gg/G, Enter/Space to activate, q/Escape to close.

local M = {}

local mode = require 'custom.dans_mode'
local ns = vim.api.nvim_create_namespace 'ds_dans_menu'
local state
local setup_done = false
local FONT_MIN_PT = 8
local FONT_MAX_PT = 32

-- Every registered owner-facing Dans command must be represented by a menu item.
-- Some low-level compatibility toggles map to the aggregate frontend item, and
-- the dedicated code generators map to the generation chooser.
local COMMAND_COVERAGE = {
  Dans = 'menu',
  DansFrontend = 'frontend',
  DansDocMarkdown = 'frontend',
  DansMacros = 'frontend',
  DansAsm = 'assembly',
  DansRunFunction = 'function-runner',
  DansCppGenerate = 'codegen',
  DansCppEnumToString = 'codegen',
  DansCppStructToString = 'codegen',
  DansCppValidity = 'codegen',
  DansCppDeclareFunction = 'codegen',
  DansCppHeaderDraft = 'codegen',
  DansSnippet = 'snippet',
  DansCppFormat = 'format',
  DansCppProjectIndex = 'project-index',
  DansCppProjectWhy = 'project-why',
  DansCppProjectJson = 'project-json',
  DansMacrosRescan = 'macro-rescan',
  DansDevMarkerTidy = 'marker-tidy',
  DansPerf = 'performance',
  DansProfile = 'profile',
  DansKeylog = 'keylog',
  DansScopeDepth = 'scope-depth',
}

function M.covered_commands()
  return vim.deepcopy(COMMAND_COVERAGE)
end

-- ---------------------------------------------------------------- font state

local function font_pt()
  return tonumber((vim.o.guifont or ''):match ':h(%d+%.?%d*)')
end

local function set_font_pt(pt)
  if type(pt) ~= 'number' or pt < FONT_MIN_PT or pt > FONT_MAX_PT then
    return false
  end
  local font = vim.o.guifont or ''
  if font == '' then
    font = 'Monaspace Krypton:h' .. pt
  elseif font:match ':h%d' then
    font = font:gsub(':h%d+%.?%d*', ':h' .. pt)
  else
    font = font .. ':h' .. pt
  end
  vim.o.guifont = font
  return true
end

local function parse_font_pt(input)
  if type(input) ~= 'string' then
    return nil
  end
  return tonumber(input:match '^%s*(%d+%.?%d*)%s*$')
end

-- --------------------------------------------------------------- item model

local function section(label)
  return { kind = 'section', label = label }
end

local function toggle(label, checked, activate, options)
  options = options or {}
  return {
    kind = 'toggle',
    label = label,
    checked = checked,
    activate = activate,
    locked = options.locked,
    detail = options.detail,
    id = options.id,
  }
end

local function action(label, run, options)
  options = options or {}
  return {
    kind = 'action',
    label = label,
    activate = run,
    detail = options.detail,
    value = options.value,
    id = options.id,
  }
end

local function target_context(snapshot, callback)
  M.close()
  if snapshot.target_win and vim.api.nvim_win_is_valid(snapshot.target_win) then
    vim.api.nvim_set_current_win(snapshot.target_win)
  elseif snapshot.target_buf and vim.api.nvim_buf_is_valid(snapshot.target_buf) then
    vim.api.nvim_set_current_buf(snapshot.target_buf)
  end
  callback()
end

local function target_action(label, callback, options)
  return action(label, function()
    local snapshot = state
    target_context(snapshot, callback)
  end, options)
end

local function choose_snippet()
  local authoring = require 'custom.cpp_authoring'
  vim.ui.select(authoring.CATALOG, {
    prompt = 'C++ template:',
    format_item = function(item)
      return '$' .. item.trigger .. '  —  ' .. item.description
    end,
  }, function(item)
    if not item then
      return
    end
    local ok, err = authoring.expand_trigger(item.trigger)
    if not ok then
      vim.notify('C++ template: ' .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

local function command_if_exists(name)
  if vim.fn.exists(':' .. name) ~= 2 then
    vim.notify(name .. ' is not available in this session', vim.log.levels.WARN)
    return
  end
  vim.cmd(name)
end

local function build_items(target_buf)
  local perf = require 'custom.dans_perf'
  return {
    section 'Display',
    toggle('Frontend presentation', mode.frontend_enabled, function()
      mode.toggle_frontend()
      M.render()
    end, {
      id = 'frontend',
      locked = function()
        return not mode.frontend_menu_available(target_buf)
      end,
      detail = function()
        if not mode.frontend_menu_available(target_buf) then
          return 'C/C++/CUDA source files only'
        end
        return mode.frontend_enabled() and 'Odin/Jai view' or 'source-faithful view'
      end,
    }),
    toggle('Monochrome', function()
      return mode.monochrome_effective(target_buf)
    end, function()
      mode.toggle_monochrome { bufnr = target_buf }
      M.render()
    end, {
      id = 'monochrome',
      locked = function()
        return mode.monochrome_locked(target_buf)
      end,
      detail = function()
        if mode.monochrome_locked(target_buf) then
          return 'required by frontend — locked'
        end
        return mode.monochrome_effective(target_buf) and 'flattened syntax' or 'normal highlighting'
      end,
    }),
    target_action('Font size', function()
      vim.ui.input({ prompt = 'Font size: ', default = tostring(font_pt() or '') }, function(input)
        if input ~= nil and not set_font_pt(parse_font_pt(input)) then
          vim.notify(string.format('Font size must be between %d and %d pt', FONT_MIN_PT, FONT_MAX_PT), vim.log.levels.WARN)
        end
      end)
    end, {
      id = 'font-size',
      value = function()
        return tostring(font_pt() or '?') .. ' pt'
      end,
    }),

    section 'C++ authoring and generation',
    target_action('Generate / refactor C++', function()
      require('custom.cpp_codegen').choose()
    end, { id = 'codegen', detail = 'Validity, to_string, declarations, header draft' }),
    target_action('Insert named C++ template', choose_snippet, {
      id = 'snippet',
      detail = 'first-party snippet catalog',
    }),
    target_action('Format C++ file', function()
      require('custom.cpp_type_snippets').format()
    end, { id = 'format', detail = 'dans include/layout convention' }),

    section 'C++ analysis and execution',
    target_action('Assembly for current function', function()
      require('custom.dans_asm').show()
    end, { id = 'assembly', detail = 'source-color-matched assembly' }),
    target_action('Run current function', function()
      require('custom.cpp_runner').run()
    end, { id = 'function-runner', detail = 'interactive constrained probe' }),

    section 'Project intelligence',
    target_action('Inspect project structure', function()
      require('custom.cpp_tools.project').show()
    end, { id = 'project-index', detail = 'components, targets, edges, cycles' }),
    target_action('Explain include under cursor', function()
      require('custom.cpp_tools.project').why()
    end, { id = 'project-why', detail = 'provider and search provenance' }),
    target_action('Show raw project index', function()
      require('custom.cpp_tools.project').raw()
    end, { id = 'project-json', detail = 'machine-readable JSON' }),
    target_action('Rescan project macros', function()
      command_if_exists 'DansMacrosRescan'
    end, { id = 'macro-rescan', detail = 'refresh #define provenance' }),
    target_action('Run dev-marker tidy', function()
      command_if_exists 'DansDevMarkerTidy'
    end, { id = 'marker-tidy', detail = 'when enabled by project .dans_dev' }),

    section 'Developer utilities',
    toggle('Performance overlay', perf.monitor_enabled, function()
      perf.monitor_toggle()
      M.render()
    end, { id = 'performance', detail = function()
      return perf.monitor_enabled() and 'running' or 'stopped'
    end }),
    target_action('Lua sampling profiler', function()
      perf.profile_toggle()
    end, { id = 'profile', detail = function()
      return perf.profile_running() and 'stop and show report' or 'start recording'
    end }),
    target_action('Recent key / mouse log', function()
      require('custom.dans_keylog').show()
    end, { id = 'keylog', detail = 'debug accidental interactions' }),
    target_action('Scope highlight depth', function()
      local scope = require 'custom.dans_frontend_cpp.scope'
      vim.ui.input({ prompt = 'Scope ancestor depth: ', default = tostring(scope.depth) }, function(input)
        local value = input and tonumber(input:match '^%s*(%d+)%s*$')
        if value then
          vim.cmd('DansScopeDepth ' .. value)
        end
      end)
    end, { id = 'scope-depth', value = function()
      return tostring(require('custom.dans_frontend_cpp.scope').depth)
    end }),
  }
end

-- ---------------------------------------------------------------- rendering

local function evaluated(value)
  if type(value) == 'function' then
    return value()
  end
  return value
end

local function fit_line(left, right, width)
  right = right and tostring(right) or ''
  if right == '' then
    return left
  end
  local spaces = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
  if spaces < 2 then
    return left
  end
  return left .. string.rep(' ', spaces) .. right
end

local function item_line(item, width)
  if item.kind == 'section' then
    return item.label
  end
  local prefix = '  > '
  if item.kind == 'toggle' then
    prefix = '  [' .. (item.checked() and 'x' or ' ') .. '] '
  end
  local right = evaluated(item.value) or evaluated(item.detail)
  return fit_line(prefix .. item.label, right, width)
end

local function rebuild()
  local menu = state
  menu.lines, menu.selectable, menu.row_to_selection, menu.sections = {}, {}, {}, {}
  for _, item in ipairs(menu.items) do
    if item.kind == 'section' and #menu.lines > 0 then
      menu.lines[#menu.lines + 1] = ''
    end
    menu.lines[#menu.lines + 1] = item_line(item, menu.width)
    local row = #menu.lines
    if item.kind == 'section' then
      menu.sections[row] = true
    else
      menu.selectable[#menu.selectable + 1] = { item = item, row = row }
      menu.row_to_selection[row] = #menu.selectable
    end
  end
  menu.lines[#menu.lines + 1] = ''
  menu.lines[#menu.lines + 1] = 'j/k navigate  ·  Enter activate  ·  q close'
  if menu.selected > #menu.selectable then
    menu.selected = #menu.selectable
  end
end

function M.render()
  local menu = state
  if not menu or not vim.api.nvim_buf_is_valid(menu.buf) then
    return
  end
  rebuild()
  vim.bo[menu.buf].modifiable = true
  vim.api.nvim_buf_set_lines(menu.buf, 0, -1, false, menu.lines)
  vim.bo[menu.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(menu.buf, ns, 0, -1)
  for row in pairs(menu.sections) do
    vim.api.nvim_buf_set_extmark(menu.buf, ns, row - 1, 0, { line_hl_group = 'Title' })
  end
  for index, entry in ipairs(menu.selectable) do
    local locked = evaluated(entry.item.locked) == true
    local group = locked and 'Comment' or 'Normal'
    if entry.item.kind == 'toggle' and entry.item.checked() and not locked then
      group = 'DiagnosticOk'
    end
    if index == menu.selected and not locked then
      group = 'PmenuSel'
    end
    vim.api.nvim_buf_set_extmark(menu.buf, ns, entry.row - 1, 0, {
      line_hl_group = group,
      priority = 200,
    })
  end
  local selected = menu.selectable[menu.selected]
  if selected and menu.win and vim.api.nvim_win_is_valid(menu.win) then
    pcall(vim.api.nvim_win_set_cursor, menu.win, { selected.row, 0 })
  end
end

local function navigate(delta)
  if not state or #state.selectable == 0 then
    return
  end
  local count = math.max(1, vim.v.count1)
  state.selected = ((state.selected - 1 + delta * count) % #state.selectable) + 1
  M.render()
end

local function activate()
  local menu = state
  if not menu then
    return
  end
  local entry = menu.selectable[menu.selected]
  if not entry then
    return
  end
  if evaluated(entry.item.locked) then
    if entry.item.id == 'monochrome' then
      entry.item.activate()
    end
    M.render()
    return
  end
  entry.item.activate()
  if state then
    M.render()
  end
end

-- -------------------------------------------------------------- open / close

function M.close()
  local menu = state
  state = nil
  if menu and menu.win and vim.api.nvim_win_is_valid(menu.win) then
    pcall(vim.api.nvim_win_close, menu.win, true)
  end
end

function M.open()
  if state then
    M.close()
  end
  local target_win = vim.api.nvim_get_current_win()
  local target_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'dansmenu'
  local width = math.max(30, math.min(88, vim.o.columns - 6))
  state = {
    buf = buf,
    target_buf = target_buf,
    target_win = target_win,
    items = build_items(target_buf),
    width = width,
    selected = 1,
  }
  rebuild()
  local height = math.min(#state.lines, math.max(8, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' DANS ',
    title_pos = 'center',
  })
  state.win = win
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  M.render()

  local function map(lhs, callback)
    vim.keymap.set('n', lhs, callback, { buffer = buf, nowait = true, silent = true })
  end
  map('j', function()
    navigate(1)
  end)
  map('k', function()
    navigate(-1)
  end)
  map('<Down>', function()
    navigate(1)
  end)
  map('<Up>', function()
    navigate(-1)
  end)
  map('gg', function()
    state.selected = 1
    M.render()
  end)
  map('G', function()
    state.selected = #state.selectable
    M.render()
  end)
  map('<CR>', activate)
  map('<Space>', activate)
  map('q', M.close)
  map('<Esc>', M.close)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      if not state or state.buf ~= buf then
        return
      end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local selected = state.row_to_selection[row]
      if selected then
        state.selected = selected
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = M.close })
  return buf, win
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  vim.api.nvim_create_user_command('Dans', M.open, {
    desc = 'Open the central DANS command palette',
  })
end

return M
