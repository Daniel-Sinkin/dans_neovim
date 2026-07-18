-- Headless spec for the CUDA runtime-API rendering: aliases.lua (ds_cpp_aliases
-- inject) snake-cases a `cudaXxx(` CALL and rewrites CUDA_CHECK -> `?`, while
-- markers.lua (ds_cpp_markers_conceal) strips the prefix from a `cudaXxx`
-- CONSTANT (no `(`) and from other CUDA_ macros. Filetype is `cuda`. Each line
-- under test sits on its own row with the cursor parked on a leading `// top`
-- line, so no row under test is revealed. Run:
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/cuda_raw_spec.lua" -c "qa!"

local pass, fail, fails = 0, 0, {}

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  '// top',
  '    CUDA_CHECK(cudaMalloc(&d_ptr, size));',
  '    cudaMemcpy(dst, src, n, cudaMemcpyHostToDevice);',
  '    cudaStreamSynchronize(stream);',
  '    cudaSetDevice(0);',
  '    CUDA_NOCHECK(cudaFree(d_ptr));',
  '    cudaMemcpy(h_dst, d_src, n, cudaMemcpyDeviceToHost);',
  '    check(cudaSuccess);',
  '    log("cudaMalloc(x)");',
})
vim.bo[b].filetype = 'cuda'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b):parse()
end)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd 'doautocmd FileType'
vim.cmd 'doautocmd BufEnter'
vim.cmd 'doautocmd CursorMoved'

-- displayed text: apply every ds_* namespace's conceals (hide) and inline
-- virt_text (insert) to the raw line, then return the visible string.
local function ds_ns()
  local out = {}
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:match '^ds_' then
      out[#out + 1] = id
    end
  end
  return out
end
local ns_ids = ds_ns()

local function display(row0)
  local line = vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1] or ''
  local hidden, inserts = {}, {}
  for _, nsid in ipairs(ns_ids) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, nsid, { row0, 0 }, { row0, -1 }, { details = true })) do
      local d = m[4]
      if d.conceal ~= nil and d.end_col then
        for c = m[3], d.end_col - 1 do
          hidden[c] = true
        end
      end
      if d.virt_text and d.virt_text_pos == 'inline' then
        local t = ''
        for _, ch in ipairs(d.virt_text) do
          t = t .. ch[1]
        end
        inserts[m[3]] = (inserts[m[3]] or '') .. t
      end
    end
  end
  local s = {}
  for c = 0, #line do
    if inserts[c] then
      s[#s + 1] = inserts[c]
    end
    if c < #line and not hidden[c] then
      s[#s + 1] = line:sub(c + 1, c + 1)
    end
  end
  return table.concat(s)
end

local function chk(desc, got, exp)
  if got == exp then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, tostring(exp), tostring(got))
  end
end

-- CUDA_CHECK -> `?`, and the wrapped cudaMalloc call snake-cases.
chk('CUDA_CHECK + call', display(1), '    ?(malloc(&d_ptr, size));')
-- call snake-cases; the trailing cudaMemcpyHostToDevice CONSTANT keeps CamelCase.
chk('call vs constant', display(2), '    memcpy(dst, src, n, MemcpyHostToDevice);')
-- multi-word names -> snake_case.
chk('StreamSynchronize', display(3), '    stream_synchronize(stream);')
chk('SetDevice', display(4), '    set_device(0);')
-- CUDA_NOCHECK keeps the plain prefix-strip; cudaFree call snake-cases.
chk('CUDA_NOCHECK + call', display(5), '    NOCHECK(free(d_ptr));')
chk('DeviceToHost constant', display(6), '    memcpy(h_dst, d_src, n, MemcpyDeviceToHost);')
-- a bare cudaSuccess (no `(`) is a constant: prefix stripped, CamelCase kept.
chk('bare constant', display(7), '    check(Success);')
-- cuda inside a string literal is untouched.
chk('string literal untouched', display(8), '    log("cudaMalloc(x)");')

-- CUDA_CHECK's own outer parens are painted the CUDA color at priority 175 so they
-- pair with the injected `?`. 175 is above the scope module's blue ancestor (150)
-- and plain parens, below its orange active pair (200) -- so the current-scope
-- orange still wins when the cursor sits inside these parens.
-- Line 1 is `    CUDA_CHECK(cudaMalloc(&d_ptr, size));`: outer `(` at col 14, `)` at 39.
local function paren_mark(row0, col)
  local ans = vim.api.nvim_get_namespaces()['ds_cpp_aliases']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ans, { row0, 0 }, { row0, -1 }, { details = true })) do
    if m[3] == col and m[4].hl_group then
      return m[4].hl_group, m[4].priority
    end
  end
end
do
  local ho, po = paren_mark(1, 14)
  local hc, pc = paren_mark(1, 39)
  chk('open paren color', ho, 'DansCUDA')
  chk('open paren priority', po, 175)
  chk('close paren color', hc, 'DansCUDA')
  chk('close paren priority', pc, 175)
end

if fail == 0 then
  print(string.format('cuda_raw_spec: PASS %d/%d', pass, pass))
else
  print(string.format('cuda_raw_spec: %d passed, %d FAILED', pass, fail))
  for _, f in ipairs(fails) do
    print(f)
  end
end
