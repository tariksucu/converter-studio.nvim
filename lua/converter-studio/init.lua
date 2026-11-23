-- Converter Studio for Neovim: convert the current file to another format.
--
--   1. On this computer: built-in Lua conversions and the programs that are installed (FFmpeg,
--      LibreOffice, Pandoc, ImageMagick, Ghostscript, Tesseract). The file does not leave it.
--   2. The Converter Studio desktop app, when enabled: the file is handed to the app.
--   3. The cloud, only when chosen: the file is uploaded to converter.studio and uses credits.

local config = require('converter-studio.config')
local formats = require('converter-studio.formats')
local tools = require('converter-studio.tools')
local recipes = require('converter-studio.recipes')
local files = require('converter-studio.files')
local job = require('converter-studio.job')

local M = {}

local TITLE = 'Converter Studio'

local function notify(message, level)
  vim.notify('Converter Studio: ' .. message, level or vim.log.levels.INFO, { title = TITLE })
end

-- Running cloud conversions (local programs are tracked by `job`).
local cloud_running = {}

--- Options: see `:help converter-studio-setup`. Optional: everything works with the defaults.
function M.setup(opts)
  config.set(opts)
  tools.reset()
end

--- The file of the current buffer, or nil and why not.
local function current_file()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return nil, 'this buffer has no file'
  end
  if vim.bo[buf].modified then
    return nil, 'the buffer has changes that are not written: write it first (:w)'
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
end

local function check_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil, ('%s is not a file'):format(path)
  end
  if stat.size == 0 then
    return nil, ('%s is empty'):format(vim.fs.basename(path))
  end
  return stat
end

local function target_label(recipe)
  local label = formats.label(recipe.to)
  if recipe.variant then
    label = ('%s (%s)'):format(label, recipe.variant)
  end
  return label
end

--- The local conversions of a file: recipes in order (see `recipes.for_format`).
function M.local_targets(path)
  local from = formats.of(path)
  if not from then
    return {}, nil
  end
  return recipes.for_format(from, tools.detect()), from
end

local function short_error(text)
  local lines = vim.split(vim.trim(text or ''), '\n', { trimempty = true })
  local tail = {}
  for i = math.max(1, #lines - 3), #lines do
    tail[#tail + 1] = vim.trim(lines[i])
  end
  return table.concat(tail, ' ')
end

-- Moves a finished result next to the source and says where it is.
local function deliver(source, produced, base, ext, how, done)
  local placed, err = files.place(produced, vim.fs.dirname(source), base, ext)
  if not placed then
    return done(err)
  end
  notify(('%s → %s (%s)'):format(vim.fs.basename(source), vim.fs.basename(placed), how))
  done(nil, placed)
end

---------------------------------------------------------------------------------------------------
-- The three ways
---------------------------------------------------------------------------------------------------

--- Layer 1: a recipe on this computer. `done(err, path)`.
function M.run_local(source, recipe, done)
  local dir = vim.fs.dirname(source)
  local workdir, werr = files.workdir(dir)
  if not workdir then
    return done(werr)
  end
  local function finish(err, path)
    files.remove(workdir)
    done(err, path)
  end
  local base = formats.stem(source) .. (recipe.suffix or '')
  local ext = formats.extension(recipe.to)
  local where = recipes.where(recipe)
  local how = recipe.tool == 'builtin' and 'on this computer, built in' or ('on this computer, ' .. where)
  if recipe.run then
    local output = vim.fs.joinpath(workdir, 'out.' .. ext)
    local ok, err = pcall(recipe.run, { input = source, output = output, workdir = workdir })
    if not ok then
      return finish(tostring(err))
    end
    return deliver(source, output, base, ext, how, finish)
  end
  local spec = recipe.build({ input = source, workdir = workdir, stem = formats.stem(source) })
  local timeout = config.get().timeout
  notify(
    ('converting %s to %s on this computer with %s…'):format(vim.fs.basename(source), target_label(recipe), where)
  )
  job.run(spec.argv, { timeout = timeout * 1000, cwd = workdir }, function(result)
    if result.canceled then
      return finish('canceled')
    end
    if result.timed_out then
      local limit = timeout == 1 and '1 second' or (tostring(timeout) .. ' seconds')
      return finish(('%s was stopped after %s (the timeout setting)'):format(where, limit))
    end
    if result.spawn_failed then
      return finish(('%s could not be started: %s'):format(where, short_error(result.stderr)))
    end
    local stat = vim.uv.fs_stat(spec.output)
    if result.code ~= 0 or not stat or stat.size == 0 then
      local reason = short_error(result.stderr ~= '' and result.stderr or result.stdout)
      return finish(('%s failed%s'):format(where, reason ~= '' and (': ' .. reason) or ''))
    end
    if recipe.must_shrink then
      local before = vim.uv.fs_stat(source)
      if before and stat.size >= before.size then
        notify(('%s is already as small as %s makes it: no new file'):format(vim.fs.basename(source), where))
        return finish(nil, nil)
      end
    end
    deliver(source, spec.output, base, ext, how, finish)
  end)
end

--- Whether files go to the desktop app: enabled in the options, and Neovim runs on the computer
--- where the app is (not over SSH, not inside WSL).
local function desktop_usable()
  return config.get().desktop.enabled and require('converter-studio.desktop').available()
end

--- Layer 2: the desktop app. `done(err)`.
function M.run_desktop(source, to, done)
  local desktop = require('converter-studio.desktop')
  desktop.handoff({ source }, to, function(err)
    if err then
      return done(err)
    end
    local sent = ('sent %s to the desktop app: press Continue, then Convert there (to %s).'):format(
      vim.fs.basename(source),
      formats.label(to)
    )
    notify(('%s If the app only comes to the front, it needs %s.'):format(sent, desktop.requirement()))
    done(nil)
  end)
end

--- Layer 3: the cloud. `done(err, path)`.
function M.run_cloud(source, to, done)
  local cloud = require('converter-studio.cloud')
  local workdir, werr = files.workdir(vim.fs.dirname(source))
  if not workdir then
    return done(werr)
  end
  notify(
    ('uploading %s to converter.studio to convert it to %s (uses credits)…'):format(
      vim.fs.basename(source),
      formats.label(to)
    )
  )
  local handle
  handle = cloud.convert(source, to, {
    workdir = workdir,
    on_quote = function(view, answer)
      local limit = config.get().cloud.max_credits
      local price = ('This conversion costs %s, more than your limit of %d.'):format(
        config.credits(view.credits),
        limit
      )
      vim.ui.select({ 'Convert for ' .. config.credits(view.credits), 'Do not convert' }, {
        prompt = price .. ' Nothing is charged unless you go ahead.',
      }, function(_, index)
        answer(index == 1)
      end)
    end,
  }, function(err, result)
    cloud_running[handle] = nil
    if err then
      files.remove(workdir)
      if err == 'canceled' then
        return done(
          'canceled; a conversion that already started at Converter Studio may still finish there and use its credits'
        )
      end
      return done(err)
    end
    local name = files.safe_name(result.name) or (formats.stem(source) .. '.' .. formats.extension(to))
    local base = formats.stem(name)
    local ext = name:sub(#base + 2)
    local credits = result.credits and (', ' .. config.credits(result.credits)) or ''
    deliver(source, result.path, base, ext, 'converter.studio' .. credits, function(derr, path)
      files.remove(workdir)
      done(derr, path)
    end)
  end)
  cloud_running[handle] = true
end

---------------------------------------------------------------------------------------------------

-- After a failure on this computer: offer the other ways, never take them without asking.
local function offer_fallback(source, to, err, done)
  local choices = {}
  if formats.list[to] then
    choices[#choices + 1] = {
      label = ('Try in the cloud (uploads %s to converter.studio, uses credits)'):format(vim.fs.basename(source)),
      run = function()
        M.run_cloud(source, to, done)
      end,
    }
  end
  if desktop_usable() then
    choices[#choices + 1] = {
      label = 'Open in the Converter Studio desktop app',
      run = function()
        M.run_desktop(source, to, done)
      end,
    }
  end
  if #choices == 0 then
    return done(err)
  end
  notify(err, vim.log.levels.WARN)
  choices[#choices + 1] = { label = 'Do nothing' }
  vim.ui.select(choices, {
    prompt = 'Converting on this computer failed. What now?',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice and choice.run then
      choice.run()
    else
      done(nil)
    end
  end)
end

local function report(err)
  if err then
    notify(err, err:match('^canceled') and vim.log.levels.WARN or vim.log.levels.ERROR)
  end
end

--- Converts a file. `opts`:
---   file   path (default: the current buffer's file)
---   to     target: a format id (`webp`), or a local variant (`pdf:ocr`)
---   route  'auto' (default: this computer, else the desktop app when enabled), 'local',
---          'desktop' or 'cloud'
---   on_done(err, path) instead of a notification of the error
function M.convert(opts)
  opts = opts or {}
  local done = opts.on_done or function(err)
    report(err)
  end
  local source, err = opts.file and vim.fs.normalize(vim.fn.fnamemodify(opts.file, ':p')) or nil, nil
  if not source then
    source, err = current_file()
  end
  if not source then
    return done(err)
  end
  local ok, ferr = check_file(source)
  if not ok then
    return done(ferr)
  end
  local key = opts.to
  if type(key) ~= 'string' or key == '' then
    return done('no target format')
  end
  key = key:lower()
  local to = key:match('^([^:]+)')
  local route = opts.route or 'auto'
  local from = formats.of(source)
  if route == 'cloud' then
    return M.run_cloud(source, to, done)
  end
  if route == 'desktop' then
    return M.run_desktop(source, to, done)
  end
  if not from then
    return done(('%s is a file type this plugin does not know'):format(vim.fs.basename(source)))
  end
  local list = recipes.for_format(from, tools.detect())
  for _, recipe in ipairs(list) do
    if recipe.key == key then
      return M.run_local(source, recipe, function(lerr, path)
        if lerr and lerr ~= 'canceled' and not opts.on_done then
          return offer_fallback(source, to, lerr, done)
        end
        done(lerr, path)
      end)
    end
  end
  if route == 'auto' and desktop_usable() and formats.list[to] then
    return M.run_desktop(source, to, done)
  end
  local hint = recipes.hint(from, to)
  local message = ('nothing on this computer converts %s to %s'):format(formats.label(from), formats.label(to))
  if hint then
    message = message .. (' (%s would)'):format(hint)
  end
  if formats.list[to] then
    message = message
      .. ('. In the cloud: :ConverterStudio cloud %s (uploads the file to converter.studio, uses credits)'):format(to)
  end
  done(message)
end

---------------------------------------------------------------------------------------------------
-- The picker
---------------------------------------------------------------------------------------------------

local function pad(text, width)
  return text .. (' '):rep(math.max(0, width - vim.fn.strdisplaywidth(text)))
end

local function select_items(items, prompt, on_choice)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(item.name))
  end
  vim.ui.select(items, {
    prompt = prompt,
    kind = 'converter-studio',
    format_item = function(item)
      return item.where and (pad(item.name, width) .. '  ' .. item.where) or item.name
    end,
  }, on_choice)
end

--- Lists the cloud's targets for a file and converts there.
function M.pick_cloud(source)
  local from = formats.of(source)
  if not from then
    return report(('%s is a file type Converter Studio does not know'):format(vim.fs.basename(source)))
  end
  require('converter-studio.cloud').catalog(function(err, catalog)
    if err then
      return report('could not read the list of formats: ' .. err)
    end
    local targets = require('converter-studio.cloud').targets(catalog, from)
    if #targets == 0 then
      return report(('Converter Studio does not convert %s files'):format(formats.label(from)))
    end
    local items = {}
    for _, to in ipairs(targets) do
      items[#items + 1] = { name = formats.label(to), to = to }
    end
    select_items(
      items,
      ('Convert %s in the cloud (uploads it to converter.studio, uses credits) to'):format(vim.fs.basename(source)),
      function(item)
        if item then
          M.run_cloud(source, item.to, report)
        end
      end
    )
  end)
end

--- `:ConverterStudio` without a format: where each target runs, local ones first.
function M.pick(path)
  local source, err = path and vim.fs.normalize(vim.fn.fnamemodify(path, ':p')) or nil, nil
  if not source then
    source, err = current_file()
  end
  if not source then
    return report(err)
  end
  local ok, ferr = check_file(source)
  if not ok then
    return report(ferr)
  end
  local list, from = M.local_targets(source)
  local items = {}
  local here = {}
  for _, recipe in ipairs(list) do
    here[recipe.to] = true
    items[#items + 1] = {
      name = target_label(recipe),
      where = 'on this computer (' .. recipes.where(recipe) .. ')',
      run = function()
        M.convert({ file = source, to = recipe.key, route = 'local' })
      end,
    }
  end
  local function finish(desktop_targets)
    for _, to in ipairs(desktop_targets or {}) do
      if not here[to] then
        items[#items + 1] = {
          name = formats.label(to),
          where = 'Converter Studio desktop app',
          run = function()
            M.run_desktop(source, to, report)
          end,
        }
      end
    end
    items[#items + 1] = {
      name = 'In the cloud…',
      where = 'uploads the file to converter.studio, uses credits',
      run = function()
        M.pick_cloud(source)
      end,
    }
    local prompt = ('Convert %s to'):format(vim.fs.basename(source))
    select_items(items, prompt, function(item)
      if item then
        item.run()
      end
    end)
  end
  if desktop_usable() and from then
    local cloud = require('converter-studio.cloud')
    cloud.catalog(function(cerr, catalog)
      if cerr then
        notify('could not read the list of formats for the desktop app: ' .. cerr, vim.log.levels.WARN)
      end
      finish(cloud.targets(catalog, from))
    end)
  else
    finish(nil)
  end
end

--- Stops every conversion that is running. Returns how many.
function M.cancel()
  local n = job.cancel_all()
  for handle in pairs(cloud_running) do
    handle.cancel()
    n = n + 1
  end
  cloud_running = {}
  notify(n == 0 and 'nothing is running' or ('stopped %d conversion%s'):format(n, n == 1 and '' or 's'))
  return n
end

---------------------------------------------------------------------------------------------------
-- :ConverterStudio
---------------------------------------------------------------------------------------------------

--- `:ConverterStudio`, `:ConverterStudio webp`, `:ConverterStudio cloud webp`,
--- `:ConverterStudio desktop webp`, `:ConverterStudio cancel`.
function M.command(args)
  args = args or {}
  local first = args[1]
  if not first then
    return M.pick()
  end
  if first == 'cancel' then
    return M.cancel()
  end
  if first == 'cloud' or first == 'desktop' then
    if not args[2] then
      if first == 'cloud' then
        local source, err = current_file()
        if not source then
          return report(err)
        end
        return M.pick_cloud(source)
      end
      return report('which format? :ConverterStudio desktop <format>')
    end
    return M.convert({ to = args[2], route = first })
  end
  M.convert({ to = first })
end

--- Completion: the local targets of the current file, then the subcommands; after `cloud` and
--- `desktop`, every format id.
function M.complete(arglead, line)
  local words = vim.split(vim.trim(line), '%s+')
  local typing_new = line:match('%s$') ~= nil
  local position = #words - (typing_new and 0 or 1)
  local out = {}
  if position <= 1 then
    local source = current_file()
    if source then
      for _, recipe in ipairs((M.local_targets(source))) do
        out[#out + 1] = recipe.key
      end
    end
    vim.list_extend(out, { 'cloud', 'desktop', 'cancel' })
  elseif position == 2 and (words[2] == 'cloud' or words[2] == 'desktop') then
    out = vim.tbl_keys(formats.list)
    table.sort(out)
  end
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arglead)
  end, out)
end

return M
