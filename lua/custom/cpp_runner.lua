-- :DansRunFunction -- compile and execute a constrained probe for the C++
-- function under the cursor.
--
-- The user supplies a full C++ invocation expression.  A temporary harness
-- includes the saved translation unit, calls that expression, and prints a
-- streamable or ADL-to_string result.  This intentionally favors explicitness
-- over pretending arbitrary functions can be isolated: project link
-- dependencies, GPU/device execution, environment state, and process-global
-- initialization may still make a probe unsuitable.  Failure output includes
-- the exact compiler command so the limitation is inspectable.

local M = {}
local context = require 'custom.cpp_tools.context'
local jobs = require 'custom.cpp_tools.jobs'
local scratch = require 'custom.cpp_tools.scratch'

local sessions = {} -- source bufnr -> current temporary probe
local last = {} -- source bufnr -> last invocation/stdin, even after result closes

local function quote_include(path)
  return path:gsub('\\', '\\\\'):gsub('"', '\\"')
end

-- Pure generator used by integration tests.  `rename_main` prevents a source
-- translation unit's entry point from colliding with the probe entry point.
function M.harness_source(source, expression, rename_main)
  local include = '#include "' .. quote_include(source) .. '"'
  if rename_main then
    include = table.concat({
      '#define main dans_probe_original_main',
      include,
      '#undef main',
    }, '\n')
  end
  return table.concat({
    '// Generated, temporary function probe. Never written into the project.',
    '#include <concepts>',
    '#include <iostream>',
    '#include <type_traits>',
    '#include <utility>',
    '',
    include,
    '',
    'namespace dans_probe_detail',
    '{',
    'template <typename T>',
    'concept Streamable = requires(std::ostream& stream, T&& value) {',
    '    stream << std::forward<T>(value);',
    '};',
    '',
    'template <typename T>',
    'concept AdlStringable = requires(std::ostream& stream, T&& value) {',
    '    stream << to_string(std::forward<T>(value));',
    '};',
    '',
    'template <typename T>',
    'auto emit(T&& value) -> void',
    '{',
    '    if constexpr (Streamable<T>)',
    '    {',
    '        std::cout << std::forward<T>(value);',
    '    }',
    '    else if constexpr (AdlStringable<T>)',
    '    {',
    '        std::cout << to_string(std::forward<T>(value));',
    '    }',
    '    else',
    '    {',
    '        std::cout << "<result is neither streamable nor ADL-to_string compatible>";',
    '    }',
    "    std::cout << '\\n';",
    '}',
    '',
    'template <typename Invocation>',
    'auto run(Invocation&& invocation) -> void',
    '{',
    '    using Result = std::invoke_result_t<Invocation>;',
    '    if constexpr (std::is_void_v<Result>)',
    '    {',
    '        std::forward<Invocation>(invocation)();',
    '        std::cout << "<void>\\n";',
    '    }',
    '    else',
    '    {',
    '        decltype(auto) result = std::forward<Invocation>(invocation)();',
    '        emit(result);',
    '    }',
    '}',
    '}',
    '',
    'auto main() -> int',
    '{',
    '    dans_probe_detail::run([&]() -> decltype(auto) { return (' .. expression .. '); });',
    '    return 0;',
    '}',
    '',
  }, '\n')
end

local function source_has_main(bufnr)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  return text:match '%f[%w_]main%s*%(' ~= nil
end

local function cleanup(bufnr)
  local session = sessions[bufnr]
  jobs.cancel('probe-compile:' .. bufnr)
  jobs.cancel('probe-run:' .. bufnr)
  if session and session.directory and session.directory:find('dans%-probe', 1) then
    pcall(vim.fn.delete, session.directory, 'rf')
  end
  sessions[bufnr] = nil
end

local function section(lines, title, text)
  lines[#lines + 1] = title
  if text == '' then
    lines[#lines + 1] = '  <empty>'
  else
    for value in (text .. '\n'):gmatch '(.-)\n' do
      lines[#lines + 1] = '  ' .. value
    end
  end
end

local function command_text(argv)
  local escaped = {}
  for _, value in ipairs(argv) do
    escaped[#escaped + 1] = vim.fn.shellescape(value)
  end
  return table.concat(escaped, ' ')
end

local compile_and_run

local function edit_expression(session)
  vim.ui.input({ prompt = 'C++ invocation: ', default = session.expression }, function(value)
    value = value and vim.trim(value) or ''
    if value == '' or sessions[session.sbuf] ~= session then
      return
    end
    session.expression = value
    last[session.sbuf] = { expression = value, stdin = session.stdin, function_name = session.function_name }
    compile_and_run(session)
  end)
end

local function edit_stdin(session)
  local current = (session.stdin or ''):gsub('\n', '\\n')
  vim.ui.input({ prompt = 'stdin (\\n becomes newline): ', default = current }, function(value)
    if value == nil or sessions[session.sbuf] ~= session then
      return
    end
    session.stdin = value:gsub('\\n', '\n')
    last[session.sbuf] = {
      expression = session.expression,
      stdin = session.stdin,
      function_name = session.function_name,
    }
    compile_and_run(session)
  end)
end

local function show_harness(session)
  scratch.open {
    key = 'probe-harness-' .. session.sbuf,
    name = 'dans://function-probe-harness',
    lines = vim.split(session.harness_text, '\n', { plain = true }),
    filetype = 'cpp',
    vertical = true,
    wrap = false,
  }
end

local function open_result(session, content)
  local bufnr = scratch.open {
    key = 'probe-result-' .. session.sbuf,
    name = 'dans://function-probe/' .. (session.function_name or 'function'),
    lines = content,
    filetype = 'text',
    vertical = true,
    wrap = false,
    on_close = function()
      cleanup(session.sbuf)
    end,
    mappings = {
      r = {
        function()
          if sessions[session.sbuf] == session then
            compile_and_run(session)
          end
        end,
        desc = 'Recompile and rerun probe',
      },
      e = {
        function()
          edit_expression(session)
        end,
        desc = 'Edit invocation expression',
      },
      i = {
        function()
          edit_stdin(session)
        end,
        desc = 'Edit standard input and rerun',
      },
      h = {
        function()
          show_harness(session)
        end,
        desc = 'Show generated harness',
      },
    },
  }
  session.result_buf = bufnr
end

local function status_lines(session, status)
  return {
    'Function probe: ' .. (session.function_name or '?'),
    'Invocation:     ' .. session.expression,
    'Status:         ' .. status,
    '',
    'Keys: r rerun   e edit invocation   i edit stdin   h harness   q close',
  }
end

compile_and_run = function(session)
  if sessions[session.sbuf] ~= session then
    return
  end
  session.harness_text = M.harness_source(session.source, session.expression, session.rename_main)
  vim.fn.writefile(vim.split(session.harness_text, '\n', { plain = true }), session.harness)
  local command = context.compile_command(session.source, {
    mode = 'link',
    input = session.harness,
    output = session.executable,
    opt = vim.g.dans_probe_opt or '0',
    extra = vim.g.dans_probe_link_flags or {},
  })
  if not command then
    open_result(session, status_lines(session, 'no C++ compiler found'))
    return
  end
  session.command = command
  session.started = (vim.uv or vim.loop).hrtime()
  open_result(session, status_lines(session, 'compiling'))
  local process, start_error = jobs.start('probe-compile:' .. session.sbuf, command.argv, { cwd = command.cwd }, function(result)
    if sessions[session.sbuf] ~= session then
      return
    end
    if result.code ~= 0 then
      local lines = status_lines(session, 'compile failed (exit ' .. tostring(result.code) .. ')')
      lines[#lines + 1] = ''
      lines[#lines + 1] = '$ ' .. command_text(command.argv)
      lines[#lines + 1] = ''
      section(lines, 'compiler stdout:', result.stdout or '')
      section(lines, 'compiler stderr:', result.stderr or '')
      open_result(session, lines)
      return
    end
    scratch.set_lines(session.result_buf, status_lines(session, 'running'))
    local run_process, run_error = jobs.start('probe-run:' .. session.sbuf, { session.executable }, {
      cwd = vim.fn.fnamemodify(session.source, ':p:h'),
      stdin = session.stdin or '',
    }, function(run_result)
      if sessions[session.sbuf] ~= session then
        return
      end
      local elapsed_ms = ((vim.uv or vim.loop).hrtime() - session.started) / 1e6
      local lines = {
        'Function probe: ' .. (session.function_name or '?'),
        'Invocation:     ' .. session.expression,
        'Compiler:       ' .. command.source,
        'Exit:           ' .. tostring(run_result.code) .. '  signal: ' .. tostring(run_result.signal),
        string.format('Compile + run: %.2f ms', elapsed_ms),
        '',
        'Keys: r rerun   e edit invocation   i edit stdin   h harness   q close',
        '',
      }
      section(lines, 'stdout:', run_result.stdout or '')
      section(lines, 'stderr:', run_result.stderr or '')
      open_result(session, lines)
    end)
    if not run_process then
      open_result(session, status_lines(session, 'could not start executable: ' .. tostring(run_error)))
    end
  end)
  if not process then
    open_result(session, status_lines(session, 'could not start compiler: ' .. tostring(start_error)))
  end
end

local function start(sbuf, fn, expression, stdin)
  cleanup(sbuf)
  local directory = vim.fn.tempname() .. '-dans-probe'
  vim.fn.mkdir(directory, 'p')
  local session = {
    sbuf = sbuf,
    source = vim.api.nvim_buf_get_name(sbuf),
    function_name = fn.qualified_name or fn.name,
    expression = expression,
    stdin = stdin or '',
    directory = directory,
    harness = directory .. '/probe.cpp',
    executable = directory .. '/probe',
    rename_main = source_has_main(sbuf),
  }
  sessions[sbuf] = session
  last[sbuf] = { expression = expression, stdin = session.stdin, function_name = session.function_name }
  compile_and_run(session)

  local group = vim.api.nvim_create_augroup('ds_cpp_probe_source_' .. sbuf, { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = sbuf,
    once = true,
    callback = function()
      cleanup(sbuf)
      last[sbuf] = nil
    end,
  })
end

function M.run(options)
  options = options or {}
  local sbuf = vim.api.nvim_get_current_buf()
  local source = vim.api.nvim_buf_get_name(sbuf)
  if source == '' or not context.is_source(source) or context.extension(source) == 'c' then
    return vim.notify('DansRunFunction: use a saved C++ translation unit', vim.log.levels.WARN)
  end
  if context.extension(source) == 'cu' then
    return vim.notify('DansRunFunction: CUDA/device probes are not isolated safely yet', vim.log.levels.WARN)
  end
  if vim.bo[sbuf].modified then
    return vim.notify('DansRunFunction: save first so the harness matches the visible source', vim.log.levels.WARN)
  end
  local fn = context.function_at(sbuf)
  if not fn or not fn.name then
    return vim.notify('DansRunFunction: put the cursor inside a function definition', vim.log.levels.WARN)
  end
  local previous = last[sbuf]
  local supplied = options.expression and vim.trim(options.expression) or ''
  if supplied ~= '' then
    start(sbuf, fn, supplied, previous and previous.stdin or '')
    return
  end
  if options.rerun and previous and previous.expression ~= '' and previous.function_name == (fn.qualified_name or fn.name) then
    start(sbuf, fn, previous.expression, previous.stdin)
    return
  end
  local default = previous and previous.function_name == (fn.qualified_name or fn.name) and previous.expression or ((fn.qualified_name or fn.name) .. '()')
  vim.ui.input({ prompt = 'C++ invocation: ', default = default }, function(value)
    value = value and vim.trim(value) or ''
    if value ~= '' and vim.api.nvim_buf_is_valid(sbuf) then
      start(sbuf, fn, value, previous and previous.stdin or '')
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('DansRunFunction', function(options)
    M.run { expression = options.args, rerun = options.bang }
  end, {
    nargs = '*',
    bang = true,
    desc = 'Compile and execute an invocation of the C++ function under the cursor',
  })
end

return M
