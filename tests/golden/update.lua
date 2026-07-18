-- Regenerate the golden expected outputs from the fixtures. Run headless against
-- the repo whose code you want to snapshot (see tests/golden/render.lua header).
-- Review the diff before committing -- this is the only thing that moves a golden.
local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local R = dofile(here .. 'render.lua')
local fixtures_dir = here .. 'fixtures'
local expected_dir = here .. 'expected'
local names = vim.fn.readdir(fixtures_dir)
table.sort(names)
for _, name in ipairs(names) do
  local lines = R.render_file(fixtures_dir .. '/' .. name)
  local f = assert(io.open(expected_dir .. '/' .. name .. '.txt', 'w'))
  f:write(table.concat(lines, '\n') .. '\n')
  f:close()
  print(string.format('wrote %s.txt (%d lines)', name, #lines))
end
print 'done'
