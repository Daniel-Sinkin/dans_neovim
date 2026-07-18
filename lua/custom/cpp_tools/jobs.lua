-- Cancellable latest-result-wins process orchestration for C++ tools.

local M = {}
local active = {}
local sequence = 0

function M.cancel(key)
  local job = active[key]
  active[key] = nil
  if job and job.process then
    pcall(job.process.kill, job.process, 15)
  end
end

function M.start(key, argv, options, callback)
  M.cancel(key)
  sequence = sequence + 1
  local generation = sequence
  local slot = { generation = generation }
  active[key] = slot
  local system_options = vim.tbl_extend('force', { text = true }, options or {})
  local ok, process = pcall(
    vim.system,
    argv,
    system_options,
    vim.schedule_wrap(function(result)
      local current = active[key]
      if not current or current.generation ~= generation then
        return
      end
      active[key] = nil
      callback(result, generation)
    end)
  )
  if not ok then
    active[key] = nil
    return nil, process
  end
  slot.process = process
  return process, generation
end

function M.running(key)
  return active[key] ~= nil
end

function M.cancel_all()
  local keys = vim.tbl_keys(active)
  for _, key in ipairs(keys) do
    M.cancel(key)
  end
end

return M
