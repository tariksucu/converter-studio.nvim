local M = {}

--- A new empty folder, removed when Neovim exits (it is inside Neovim's own temporary folder).
function M.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

function M.write(path, text)
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
  return path
end

function M.read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local text = f:read('*a')
  f:close()
  return text
end

--- Every entry of a folder, hidden ones too, sorted.
function M.ls(dir)
  local out = {}
  for name in vim.fs.dir(dir) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Runs `require('converter-studio').convert(opts)` and waits for it: returns err, path.
function M.convert(opts, timeout)
  local done, err, path = false, nil, nil
  opts.on_done = function(e, p)
    done, err, path = true, e, p
  end
  require('converter-studio').convert(opts)
  vim.wait(timeout or 120000, function()
    return done
  end, 20)
  assert(done, 'the conversion did not finish in time')
  return err, path
end

--- Replaces `vim.ui.select` with a function that records the question and picks `choose(items)`.
function M.stub_select(choose)
  local seen = {}
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    local labels = {}
    for i, item in ipairs(items) do
      labels[i] = opts.format_item and opts.format_item(item) or tostring(item)
    end
    seen[#seen + 1] = { prompt = opts.prompt, labels = labels, items = items }
    local index = choose and choose(labels, opts.prompt) or nil
    vim.schedule(function()
      on_choice(index and items[index] or nil, index)
    end)
  end
  return seen, function()
    vim.ui.select = original
  end
end

--- Captures `vim.notify` messages.
function M.stub_notify()
  local messages = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = msg, level = level }
  end
  return messages, function()
    vim.notify = original
  end
end

return M
