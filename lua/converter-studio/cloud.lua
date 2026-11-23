-- Converter Studio's REST API (https://converter.studio/developers) through curl. Only used when
-- the person picks the cloud: the file is uploaded to converter.studio and the conversion uses
-- credits of their account.
--
-- The API key travels to curl on its standard input (`--config -`), never on a command line that
-- other users of the computer could read, and never in a message or a log. Upload and download
-- links carry their own one-time tokens, so the key is not sent with them.

local config = require('converter-studio.config')
local files = require('converter-studio.files')
local job = require('converter-studio.job')

local M = {}

-- One request of an upload carries at most this much when the API does not say (the CDN stops at
-- 100 MB).
local DEFAULT_PART_BYTES = 95 * 1024 * 1024
-- The longest a status request waits on the server (the API allows 60 seconds).
M.LONG_POLL_SECONDS = 50
local SETTLED = { done = true, failed = true, expired = true, canceled = true, quoted = true }
local RETRY_STATUS = { [408] = true, [429] = true, [500] = true, [502] = true, [503] = true, [504] = true }
-- curl's exit codes for a request that never reached the server or got no answer.
local RETRY_CURL =
  { [5] = true, [6] = true, [7] = true, [28] = true, [35] = true, [52] = true, [55] = true, [56] = true }
local NOTHING_SENT = { [5] = true, [6] = true, [7] = true }

M.sleep_ms = function(ms, cb)
  vim.defer_fn(cb, ms)
end

--- A value for curl's config file: in double quotes, with `\` and `"` escaped.
local function quote(value)
  return '"'
    .. tostring(value):gsub('[\\"\r\n\t]', function(c)
      return ({ ['\\'] = '\\\\', ['"'] = '\\"', ['\r'] = '\\r', ['\n'] = '\\n', ['\t'] = '\\t' })[c]
    end)
    .. '"'
end
M._quote = quote

--- Takes anything that looks like a key or a token out of a text before it is shown.
local function scrub(text)
  return (
    tostring(text or '')
      :gsub('cvs_[%w_%-]+', 'cvs_…')
      :gsub('([?&]token=)[^&%s"]+', '%1…')
      :gsub('[Bb]earer%s+[^%s"]+', 'Bearer …')
  )
end
M._scrub = scrub

local function user_agent()
  local v = vim.version()
  return ('converter-studio.nvim/%s Neovim/%d.%d.%d'):format(config.VERSION, v.major, v.minor, v.patch)
end

--- The curl command and the config it reads from its standard input, for one request.
--- `spec`: `url`, `method`, `key` (sent as Bearer), `json` (a table), `headers`, `upload` (a file
--- path, sent as the body), `output` (a file path for the answer), `timeout` (seconds).
function M.command(spec)
  local lines = {
    'url = ' .. quote(spec.url),
    'request = ' .. quote(spec.method or 'GET'),
    'user-agent = ' .. quote(user_agent()),
    'header = ' .. quote(('X-Converter-Studio-Client: %s/%s'):format(config.CLIENT, config.VERSION)),
  }
  if spec.key then
    lines[#lines + 1] = 'header = ' .. quote('Authorization: Bearer ' .. spec.key)
  end
  for name, value in pairs(spec.headers or {}) do
    lines[#lines + 1] = 'header = ' .. quote(name .. ': ' .. value)
  end
  if spec.json then
    lines[#lines + 1] = 'header = ' .. quote('Content-Type: application/json')
    lines[#lines + 1] = 'data-binary = ' .. quote(vim.json.encode(spec.json))
  end
  local argv = {
    'curl',
    '--silent',
    '--show-error',
    '--proto',
    '=https,http',
    '--connect-timeout',
    '30',
    '--max-time',
    tostring(spec.timeout or 120),
    '--write-out',
    '\\n%{http_code}',
    '--config',
    '-',
  }
  if spec.upload then
    vim.list_extend(argv, { '--upload-file', spec.upload })
  end
  if spec.output then
    vim.list_extend(argv, { '--output', spec.output })
  end
  return argv, table.concat(lines, '\n') .. '\n'
end

--- One request. `cb(err, status, body)`: `body` is the decoded JSON (or the raw text), `err` a
--- sentence for people when the request failed. Returns the running job.
function M.request(spec, cb)
  local argv, stdin = M.command(spec)
  return job.run(argv, { stdin = stdin }, function(result)
    if result.canceled then
      return cb('canceled')
    end
    if result.spawn_failed then
      return cb('curl is needed for the cloud and was not found')
    end
    local out = result.stdout or ''
    local text, status = out:match('^(.*)\n(%d%d%d)$')
    status = tonumber(status)
    if result.code ~= 0 or not status or status == 0 then
      local reason = vim.trim(scrub(result.stderr))
      return cb(reason ~= '' and reason or 'no answer from Converter Studio', nil, nil, result.code)
    end
    local body = text
    if text and text:match('^%s*[{%[]') then
      local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
      if ok then
        body = decoded
      end
    end
    cb(nil, status, body)
  end)
end

--- The API's message for a failed answer (`{ error: { code, message } }`).
function M.error_message(status, body)
  if type(body) == 'table' and type(body.error) == 'table' and body.error.message then
    return scrub(body.error.message), body.error.code
  end
  if status == 401 then
    return 'the API key was not accepted', 'invalidApiKey'
  end
  return ('Converter Studio answered %s'):format(tostring(status)), nil
end

local function uuid()
  local hex = files.random_hex(16)
  local variant = ('89ab'):sub((tonumber(hex:sub(17, 17), 16) % 4) + 1, (tonumber(hex:sub(17, 17), 16) % 4) + 1)
  return ('%s-%s-4%s-%s%s-%s'):format(
    hex:sub(1, 8),
    hex:sub(9, 12),
    hex:sub(14, 16),
    variant,
    hex:sub(18, 20),
    hex:sub(21, 32)
  )
end
M._uuid = uuid

---------------------------------------------------------------------------------------------------
-- A conversion, step by step (a coroutine resumed by each finished request)
---------------------------------------------------------------------------------------------------

--- Converts `input` to `to` in the cloud. `opts`: `workdir` (where the result is saved first),
--- `on_quote(view, answer)` (asked when the price is above `max_credits`; call `answer(true)` to
--- go ahead), `on_progress(text)`. `done(err, result)`; `result`: `{ path, name, credits }`.
--- Returns a handle with `cancel()`.
function M.convert(input, to, opts, done)
  local handle = { canceled = false }
  local current -- the request that is running
  local key = config.api_key()
  local base, why = config.api_url()
  if not key then
    vim.schedule(function()
      done(
        ('no API key: set CONVERTER_STUDIO_API_KEY or setup({ cloud = { api_key = … } }). Create one at %s'):format(
          config.KEYS_URL
        )
      )
    end)
    handle.cancel = function() end
    return handle
  end
  if not base then
    vim.schedule(function()
      done(why)
    end)
    handle.cancel = function() end
    return handle
  end

  local co
  local finished = false
  local function finish(err, result)
    if finished then
      return
    end
    finished = true
    vim.schedule(function()
      done(err, result)
    end)
  end
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      finish(handle.canceled and 'canceled' or scrub(err))
    end
  end
  -- Waits for `start(cb)` to call `cb`, inside the coroutine.
  local function await(start)
    start(function(...)
      local args = vim.F.pack_len(...)
      vim.schedule(function()
        step(vim.F.unpack_len(args))
      end)
    end)
    local results = vim.F.pack_len(coroutine.yield())
    if handle.canceled then
      error('canceled', 0)
    end
    return vim.F.unpack_len(results)
  end
  local function sleep(ms)
    await(function(cb)
      M.sleep_ms(ms, cb)
    end)
  end

  -- A JSON request with the key, tried again when the API is busy or out of reach.
  local function api(method, path, json, extra)
    extra = extra or {}
    local waits = { 1000, 3000, 9000 }
    for attempt = 1, #waits + 1 do
      local err, status, body, curl_code = await(function(cb)
        current = M.request({
          url = base .. path,
          method = method,
          key = key,
          json = json,
          headers = extra.headers,
          timeout = extra.timeout,
        }, cb)
      end)
      local retry = (err and RETRY_CURL[curl_code]) or (status and RETRY_STATUS[status])
      if retry and attempt <= #waits and (extra.retry ~= false) then
        sleep(waits[attempt])
      elseif err then
        error(err, 0)
      elseif status >= 400 then
        local message = M.error_message(status, body)
        error(message, 0)
      else
        return body, status
      end
    end
  end

  local function upload()
    local stat = vim.uv.fs_stat(input)
    if not stat or stat.size == 0 then
      error('the file is empty', 0)
    end
    local slot = api('POST', '/v1/uploads', { fileName = vim.fs.basename(input), size = stat.size })
    if type(slot) ~= 'table' or type(slot.uploadUrl) ~= 'string' then
      error('Converter Studio gave no upload address', 0)
    end
    local part_bytes = (tonumber(slot.partBytes) or 0) > 0 and tonumber(slot.partBytes) or DEFAULT_PART_BYTES
    local offset = 0
    while offset < stat.size do
      local size = math.min(part_bytes, stat.size - offset)
      local body_path = input
      local headers
      if stat.size > part_bytes then
        -- A large file goes in parts: each part is copied to the work folder and sent from there.
        body_path = vim.fs.joinpath(opts.workdir, 'part')
        local src = assert(vim.uv.fs_open(input, 'r', 0))
        local dst = assert(vim.uv.fs_open(body_path, 'w', 384))
        local sent = 0
        while sent < size do
          local n = vim.uv.fs_sendfile(dst, src, offset + sent, size - sent)
          if not n or n <= 0 then
            break
          end
          sent = sent + n
        end
        vim.uv.fs_close(src)
        vim.uv.fs_close(dst)
        if sent ~= size then
          error('could not read the file', 0)
        end
        headers = { ['Upload-Offset'] = tostring(offset) }
      end
      if opts.on_progress then
        opts.on_progress(('uploading %d%%'):format(math.floor(offset * 100 / stat.size)))
      end
      local attempt = 0
      while true do
        attempt = attempt + 1
        local err, status, body, curl_code = await(function(cb)
          current = M.request({
            url = slot.uploadUrl,
            method = 'PUT',
            upload = body_path,
            headers = headers,
            -- Two minutes, and two more seconds a megabyte.
            timeout = 120 + math.ceil(size / 1000000) * 2,
          }, cb)
        end)
        if err and NOTHING_SENT[curl_code] and attempt <= 3 then
          sleep(attempt * 2000)
        elseif err then
          error(err, 0)
        elseif status >= 400 then
          error((M.error_message(status, body)), 0)
        else
          break
        end
      end
      offset = offset + size
    end
    if stat.size > part_bytes then
      vim.uv.fs_unlink(vim.fs.joinpath(opts.workdir, 'part'))
    end
    return slot.id
  end

  co = coroutine.create(function()
    local upload_id = upload()
    if opts.on_progress then
      opts.on_progress('converting')
    end
    local view = api('POST', '/v1/conversions', {
      uploadId = upload_id,
      to = to,
      maxCredits = config.get().cloud.max_credits,
    }, { headers = { ['Idempotency-Key'] = uuid() } })
    while type(view) == 'table' and not SETTLED[view.status] do
      view = api('GET', ('/v1/conversions/%s?wait=%d'):format(view.id, M.LONG_POLL_SECONDS), nil, {
        timeout = M.LONG_POLL_SECONDS + 20,
      })
    end
    if type(view) ~= 'table' then
      error('Converter Studio gave an answer this plugin does not understand', 0)
    end
    if view.status == 'quoted' then
      local go = await(function(cb)
        opts.on_quote(view, cb)
      end)
      if not go then
        local limit = config.get().cloud.max_credits
        error(
          ('not converted: it costs %s, more than your limit of %d (nothing was charged)'):format(
            config.credits(view.credits),
            limit
          ),
          0
        )
      end
      view = api('POST', ('/v1/conversions/%s/confirm'):format(view.id))
      while type(view) == 'table' and not SETTLED[view.status] do
        view = api('GET', ('/v1/conversions/%s?wait=%d'):format(view.id, M.LONG_POLL_SECONDS), nil, {
          timeout = M.LONG_POLL_SECONDS + 20,
        })
      end
    end
    if view.status == 'failed' then
      local message = type(view.error) == 'table' and view.error.message or 'the conversion failed'
      error(scrub(message), 0)
    elseif view.status ~= 'done' then
      error(('the conversion ended as "%s"'):format(tostring(view.status)), 0)
    end
    if type(view.downloadUrl) ~= 'string' then
      error('Converter Studio gave no download address', 0)
    end
    if opts.on_progress then
      opts.on_progress('downloading')
    end
    local target = vim.fs.joinpath(opts.workdir, 'result')
    local err, status, body = await(function(cb)
      -- The link carries its own token: no key.
      current = M.request({ url = view.downloadUrl, output = target, timeout = 3600 }, cb)
    end)
    if err then
      error(err, 0)
    elseif status >= 400 then
      local text = ''
      local f = io.open(target, 'rb')
      if f then
        text = f:read('*a') or ''
        f:close()
      end
      local ok, decoded = pcall(vim.json.decode, text)
      error((M.error_message(status, ok and decoded or body)), 0)
    end
    finish(nil, { path = target, name = view.outputName, credits = view.credits })
  end)

  handle.cancel = function()
    if handle.canceled or finished then
      return
    end
    handle.canceled = true
    if current then
      current.cancel()
    end
    finish('canceled')
  end
  step()
  return handle
end

---------------------------------------------------------------------------------------------------

--- The formats Converter Studio converts (`GET /v1/formats`, no key), cached for a day in
--- Neovim's cache folder. `cb(err, formats)`.
local CATALOG_TTL = 24 * 3600
local memory

local function catalog_path()
  return vim.fs.joinpath(vim.fn.stdpath('cache'), 'converter-studio', 'formats.json')
end

function M.catalog(cb)
  local now = os.time()
  if memory and now - memory.at < CATALOG_TTL then
    return vim.schedule(function()
      cb(nil, memory.formats)
    end)
  end
  local path = catalog_path()
  local stat = vim.uv.fs_stat(path)
  if stat and now - stat.mtime.sec < CATALOG_TTL then
    local f = io.open(path, 'rb')
    local ok, decoded = pcall(vim.json.decode, f and f:read('*a') or '')
    if f then
      f:close()
    end
    if ok and type(decoded) == 'table' and type(decoded.formats) == 'table' then
      memory = { at = stat.mtime.sec, formats = decoded.formats }
      return vim.schedule(function()
        cb(nil, memory.formats)
      end)
    end
  end
  local base, why = config.api_url()
  if not base then
    return vim.schedule(function()
      cb(why)
    end)
  end
  M.request({ url = base .. '/v1/formats', timeout = 30 }, function(err, status, body)
    if err then
      return cb(err)
    end
    if status ~= 200 or type(body) ~= 'table' or type(body.formats) ~= 'table' then
      return cb((M.error_message(status, body)))
    end
    memory = { at = now, formats = body.formats }
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f = io.open(path, 'wb')
    if f then
      f:write(vim.json.encode({ formats = body.formats }))
      f:close()
    end
    cb(nil, body.formats)
  end)
end

--- Targets of format `from` in a catalog, in the API's order.
function M.targets(catalog, from)
  for _, format in ipairs(catalog or {}) do
    if format.id == from then
      return format.to or {}
    end
  end
  return {}
end

function M.forget_catalog()
  memory = nil
  pcall(vim.uv.fs_unlink, catalog_path())
end

return M
