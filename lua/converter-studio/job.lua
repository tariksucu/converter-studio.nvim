-- Runs a program from an argument list (never through a shell) with a time limit, and stops it
-- (with whatever it started, such as LibreOffice's own process) when asked.

local uv = vim.uv

local M = {}

local is_windows = vim.fn.has('win32') == 1

-- Running programs, so that `:ConverterStudio cancel` and leaving Neovim stop them.
local running = {}

local function kill(proc, signal)
  if not proc or not proc.pid then
    return
  end
  if is_windows then
    pcall(proc.kill, proc, signal)
  else
    -- The program leads its own process group (`detach`): stop the whole group.
    if not pcall(uv.kill, -proc.pid, signal) then
      pcall(proc.kill, proc, signal)
    end
  end
end

--- Starts `argv`; `on_exit({ code, stdout, stderr, timed_out, canceled })` runs on the main loop.
--- Options: `timeout` (ms), `stdin` (text), `cwd`. Returns a handle with `cancel()`.
function M.run(argv, opts, on_exit)
  opts = opts or {}
  local handle = { argv = argv, canceled = false, timed_out = false }
  local timer
  local finished = false
  local function finish(result)
    if finished then
      return
    end
    finished = true
    running[handle] = nil
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
    result.timed_out = handle.timed_out
    result.canceled = handle.canceled
    vim.schedule(function()
      on_exit(result)
    end)
  end
  local ok, proc = pcall(vim.system, argv, {
    text = true,
    cwd = opts.cwd,
    stdin = opts.stdin,
    detach = not is_windows,
  }, function(result)
    finish({ code = result.code, signal = result.signal, stdout = result.stdout or '', stderr = result.stderr or '' })
  end)
  if not ok then
    finish({ code = -1, stdout = '', stderr = tostring(proc), spawn_failed = true })
    handle.cancel = function() end
    return handle
  end
  handle.proc = proc
  running[handle] = true

  local function stop(reason)
    if finished or handle.stopping then
      return
    end
    handle.stopping = true
    handle[reason] = true
    kill(proc, 'sigterm')
    -- A program that ignores SIGTERM is killed after three seconds.
    local hard = uv.new_timer()
    hard:start(3000, 0, function()
      hard:close()
      if not finished then
        kill(proc, 'sigkill')
      end
    end)
  end
  handle.cancel = function()
    stop('canceled')
  end
  if opts.timeout then
    timer = uv.new_timer()
    timer:start(opts.timeout, 0, function()
      stop('timed_out')
    end)
  end
  return handle
end

--- Stops every running program (`:ConverterStudio cancel`, leaving Neovim). Returns how many.
function M.cancel_all()
  local n = 0
  for handle in pairs(running) do
    handle.cancel()
    n = n + 1
  end
  return n
end

function M.count()
  return vim.tbl_count(running)
end

return M
