-- Latency probe for the open-a-big-file path (not pass/fail -- prints timings).
-- Run:  nvim --headless --cmd "set noswapfile" -c "luafile tests/perf_probe.lua" -c "qa!"
--
-- Generates a vk_core-scale C++ source + header (~4000 lines), then measures
-- the wall time of the synchronous work that blocks the first paint:
--   cold open  -- :edit of a never-seen file (BufRead + FileType + BufEnter)
--   re-enter   -- :edit back into a loaded buffer (the jump-to-definition hop)
-- A LuaJIT sampling profile runs across the cold open; the hottest module
-- files are printed so a regression names its culprit.

local hrtime = (vim.uv or vim.loop).hrtime

local function gen_cpp(path, units)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  add '// gen/big_gen.cpp'
  add '// Externals'
  add '#include <vulkan/vulkan.h>'
  add '// StdLib'
  add '#include <array>'
  add '#include <optional>'
  add '#include <string>'
  add '#include <vector>'
  add '//'
  add 'namespace dans::vk {'
  for i = 1, units do
    add ''
    add('/// Frame state for pass ' .. i .. '.')
    add '/// Owns the per-frame Vulkan handles.'
    add('struct FrameState' .. i)
    add '{'
    add '    VkCommandBuffer command_buffer{};'
    add '    VkSemaphore image_available{};'
    add '    VkSemaphore render_finished{};'
    add '    VkFence in_flight{};'
    add '    std::array<f32, 4> clear_color{};'
    add('    u32 image_index_' .. i .. '{0u};')
    add '    bool submitted{false};'
    add '};'
    add ''
    add('auto record_pass_' .. i .. '(const FrameState' .. i .. '& frame, VkCommandBuffer cmd) -> void')
    add '{'
    add '    constexpr u32 k_subpass{0u};'
    add '    constexpr u32 k_flags{0u};'
    add '    const auto begin_info = VkCommandBufferBeginInfo{.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};'
    add '    mut std::vector<VkImageView> attachments{};'
    add '    for (const auto& view : frame.clear_color)'
    add '    {'
    add '        attachments.push_back(static_cast<VkImageView>(nullptr));'
    add '    }'
    add '    const auto submit = [&](VkQueue queue) -> VkResult'
    add '    {'
    add '        return vkQueueSubmit(queue, 1, nullptr, frame.in_flight);'
    add '    };'
    add '    if (auto res = submit(nullptr); res != VK_SUCCESS)'
    add '    {'
    add '        return;'
    add '    }'
    add '}'
    if i % 8 == 0 then
      add ''
      add '#if defined(_GLFW_WIN32)'
      add('inline constexpr u32 k_win_only_' .. i .. '{1u};')
      add '#elif defined(_GLFW_COCOA)'
      add('inline constexpr u32 k_mac_only_' .. i .. '{1u};')
      add '#endif'
    end
    if i % 10 == 0 then
      add ''
      add('static_assert(sizeof(FrameState' .. i .. ') > 0);')
      add('static_assert(alignof(FrameState' .. i .. ') > 0);')
    end
  end
  add ''
  add '} // namespace dans::vk'
  local f = assert(io.open(path, 'w'))
  f:write(table.concat(out, '\n'))
  f:close()
  return #out
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local big = dir .. '/big_gen.cpp'
local hdr = dir .. '/big_gen.hpp'
local nlines = gen_cpp(big, 130)
gen_cpp(hdr, 130) -- .hpp also exercises the treesitter outline folds

local other = dir .. '/other.cpp'
do
  local f = assert(io.open(other, 'w'))
  f:write '// other.cpp\nint main() { return 0; }\n'
  f:close()
end

-- sampling profiler across the cold open, aggregated per source file
local counts, total = {}, 0
local jp_ok, jp = pcall(require, 'jit.profile')
local function prof_start()
  if not jp_ok then
    return
  end
  jp.start('i1', function(thread)
    local loc = jp.dumpstack(thread, 'pl', 1)
    local file = loc:match '^(.-):%d+' or loc
    counts[file] = (counts[file] or 0) + 1
    total = total + 1
  end)
end
local function prof_stop()
  if jp_ok then
    jp.stop()
  end
end

local function ms(t0, t1)
  return (t1 - t0) / 1e6
end

-- the deferred decoration pass (cold-open gate) announces itself via the
-- settled event; record when it lands so the probe shows the full timeline.
local settled_at
vim.api.nvim_create_autocmd('User', {
  pattern = 'DansViewportSettled',
  once = true,
  callback = function()
    settled_at = hrtime()
  end,
})

-- cold open (the time the user stares at nothing before the file appears)
prof_start()
local t0 = hrtime()
vim.cmd('edit ' .. vim.fn.fnameescape(big))
local t_open = hrtime()
vim.cmd 'redraw'
local t_redraw = hrtime()
prof_stop()

-- let the deferred first-decoration pass fire and finish (pumps the loop)
vim.wait(3000, function()
  return settled_at ~= nil
end, 5)

-- hop away and back: the gd-into-loaded-buffer path
vim.cmd('edit ' .. vim.fn.fnameescape(other))
local t1 = hrtime()
vim.cmd('edit ' .. vim.fn.fnameescape(big))
local t_back = hrtime()

-- cold open of the header (adds the .hpp treesitter outline fold pass)
local t2 = hrtime()
vim.cmd('edit ' .. vim.fn.fnameescape(hdr))
local t_hdr = hrtime()

-- attribution: identical fresh copies opened with one suspect disabled each.
-- (the first open above already paid the one-time lua-loader / ts-language
-- costs, so these deltas isolate the per-open suspects.)
local big2 = dir .. '/big2_gen.cpp'
gen_cpp(big2, 130)
pcall(vim.cmd, 'TSContext disable')
pcall(vim.cmd, 'TSContextDisable')
local t3 = hrtime()
vim.cmd('edit ' .. vim.fn.fnameescape(big2))
local t_noctx = hrtime()

local big3 = dir .. '/big3_gen.cpp'
gen_cpp(big3, 130)
pcall(vim.lsp.enable, 'clangd', false)
local t4 = hrtime()
vim.cmd('edit ' .. vim.fn.fnameescape(big3))
local t_nolsp = hrtime()

local lines = {
  string.format('perf_probe (%d-line generated file)', nlines),
  string.format('  cold open  .cpp : %7.1f ms (edit) + %6.1f ms (first redraw)', ms(t0, t_open), ms(t_open, t_redraw)),
  settled_at and string.format('  deferred decorate pass landed %.1f ms after the open', ms(t_open, settled_at)) or '  (no deferred pass observed)',
  string.format('  re-enter   .cpp : %7.1f ms', ms(t1, t_back)),
  string.format('  cold open  .hpp : %7.1f ms', ms(t2, t_hdr)),
  string.format('  cold open, ts-context off       : %7.1f ms', ms(t3, t_noctx)),
  string.format('  cold open, ts-context+clangd off: %7.1f ms', ms(t4, t_nolsp)),
}
if jp_ok and total > 0 then
  local rows = {}
  for file, c in pairs(counts) do
    rows[#rows + 1] = { file = file, c = c }
  end
  table.sort(rows, function(a, b)
    return a.c > b.c
  end)
  lines[#lines + 1] = string.format('  hottest files during cold open (%d samples):', total)
  for i = 1, math.min(10, #rows) do
    lines[#lines + 1] = string.format('    %5.1f%%  %s', 100 * rows[i].c / total, rows[i].file)
  end
end
print(table.concat(lines, '\n'))
