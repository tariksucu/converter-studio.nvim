-- A small stand-in for Converter Studio's API on 127.0.0.1, served from this Neovim's event loop,
-- so the cloud flow is tested with the real curl and no network. It records every request.

local uv = vim.uv

local M = {}

M.KEY = 'cvs_live_test_key_0123456789'

local REASONS = {
  [200] = 'OK',
  [201] = 'Created',
  [400] = 'Bad Request',
  [401] = 'Unauthorized',
  [404] = 'Not Found',
  [503] = 'Service Unavailable',
}

local function respond(client, status, body, headers)
  local payload = type(body) == 'table' and vim.json.encode(body) or (body or '')
  local lines = {
    ('HTTP/1.1 %d %s'):format(status, REASONS[status] or 'Status'),
    'Content-Length: ' .. #payload,
    'Connection: close',
  }
  if type(body) == 'table' then
    lines[#lines + 1] = 'Content-Type: application/json'
  end
  for k, v in pairs(headers or {}) do
    lines[#lines + 1] = k .. ': ' .. v
  end
  client:write(table.concat(lines, '\r\n') .. '\r\n\r\n' .. payload, function()
    client:shutdown(function()
      client:close()
    end)
  end)
end

--- Starts the server. `scenario`: `part_bytes`, `price` (credits; above `maxCredits` the
--- conversion waits for a confirmation), `fail` (an error message), `busy` (how many times
--- `POST /v1/conversions` answers 503 first). Returns the server: `url`, `requests`,
--- `uploaded` (the bytes received), `stop()`.
function M.start(scenario)
  scenario = scenario or {}
  local server = { requests = {}, uploaded = '', busy = scenario.busy or 0, conversions = {} }
  local tcp = assert(uv.new_tcp())
  assert(tcp:bind('127.0.0.1', 0))
  local port = tcp:getsockname().port
  server.url = ('http://127.0.0.1:%d'):format(port)
  local base = server.url .. '/api'
  server.api = base

  local function view(conversion)
    return {
      id = conversion.id,
      status = conversion.status,
      to = conversion.to,
      credits = conversion.credits,
      maxCredits = conversion.maxCredits,
      -- Named like the API names results: the upload's name with the new extension.
      outputName = conversion.status == 'done'
          and (server.upload_request.fileName:gsub('%.[^.]+$', '') .. '.' .. conversion.to)
        or nil,
      downloadUrl = conversion.status == 'done'
          and (server.url .. '/api/jobs/' .. conversion.id .. '/download?token=dl_secret')
        or nil,
      error = conversion.error,
    }
  end

  local function route(req, client)
    local path, query = req.target:match('^([^?]*)%??(.*)$')
    local authed = req.headers['authorization'] == 'Bearer ' .. M.KEY
    local function need_key()
      if not authed then
        respond(client, 401, {
          error = {
            code = 'invalidApiKey',
            message = 'This API key is not valid. Make a new one on your account page.',
          },
        })
        return false
      end
      return true
    end
    if req.method == 'GET' and path == '/api/v1/formats' then
      return respond(client, 200, {
        formats = {
          { id = 'heic', name = 'HEIC', category = 'image', extensions = { 'heic' }, to = { 'jpg', 'png', 'webp' } },
          { id = 'png', name = 'PNG', category = 'image', extensions = { 'png' }, to = { 'jpg', 'webp', 'avif' } },
        },
      })
    elseif req.method == 'POST' and path == '/api/v1/uploads' then
      if not need_key() then
        return
      end
      local body = vim.json.decode(req.body)
      server.upload_request = body
      return respond(client, 201, {
        id = 'up_1',
        uploadUrl = base .. '/v1/uploads/up_1?token=up_secret',
        method = 'PUT',
        maxBytes = 1000000000,
        partBytes = scenario.part_bytes or 99614720,
      })
    elseif req.method == 'PUT' and path == '/api/v1/uploads/up_1' then
      if query ~= 'token=up_secret' then
        return respond(client, 401, { error = { code = 'invalidRequest', message = 'bad upload token' } })
      end
      local offset = tonumber(req.headers['upload-offset'] or '0')
      if offset ~= #server.uploaded then
        return respond(client, 400, { error = { code = 'invalidRequest', message = 'wrong offset' } })
      end
      server.uploaded = server.uploaded .. req.body
      local ready = #server.uploaded >= server.upload_request.size
      return respond(
        client,
        200,
        ready and { id = 'up_1', status = 'ready' } or { id = 'up_1', status = 'partial', received = #server.uploaded }
      )
    elseif req.method == 'POST' and path == '/api/v1/conversions' then
      if not need_key() then
        return
      end
      if server.busy > 0 then
        server.busy = server.busy - 1
        return respond(client, 503, { error = { code = 'serverBusy', message = 'Busy, try again.' } })
      end
      local body = vim.json.decode(req.body)
      local key = req.headers['idempotency-key']
      local existing = key and server.conversions[key]
      if existing then
        return respond(client, 200, view(existing), { ['Idempotent-Replayed'] = 'true' })
      end
      local price = scenario.price or 1
      local conversion = {
        id = 'conv_' .. (vim.tbl_count(server.conversions) + 1),
        to = body.to,
        credits = price,
        maxCredits = body.maxCredits,
        status = price > body.maxCredits and 'quoted' or 'processing',
      }
      server.conversions[key or conversion.id] = conversion
      server.last = conversion
      return respond(client, 201, view(conversion))
    elseif req.method == 'GET' and path:match('^/api/v1/conversions/[%w_]+$') then
      if not need_key() then
        return
      end
      local conversion = server.last
      if conversion.status == 'processing' then
        if scenario.fail then
          conversion.status = 'failed'
          conversion.error = { code = 'conversionFailed', message = scenario.fail }
        else
          conversion.status = 'done'
        end
      end
      return respond(client, 200, view(conversion))
    elseif req.method == 'POST' and path:match('^/api/v1/conversions/[%w_]+/confirm$') then
      if not need_key() then
        return
      end
      server.last.status = 'processing'
      server.confirmed = true
      return respond(client, 200, view(server.last))
    elseif req.method == 'GET' and path:match('^/api/jobs/[%w_]+/download$') then
      if query ~= 'token=dl_secret' then
        return respond(client, 404, 'not found')
      end
      return respond(client, 200, 'converted:' .. server.uploaded, { ['Content-Type'] = 'application/octet-stream' })
    end
    respond(client, 404, { error = { code = 'notFound', message = 'Not found.' } })
  end

  tcp:listen(16, function(err)
    assert(not err, err)
    local client = uv.new_tcp()
    tcp:accept(client)
    local buffer = ''
    local req
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      buffer = buffer .. chunk
      if not req then
        local head_end = buffer:find('\r\n\r\n', 1, true)
        if not head_end then
          return
        end
        local head = buffer:sub(1, head_end - 1)
        buffer = buffer:sub(head_end + 4)
        local lines = vim.split(head, '\r\n', { plain = true })
        local method, target = lines[1]:match('^(%u+) (%S+)')
        req = { method = method, target = target, headers = {}, body = '' }
        for i = 2, #lines do
          local k, v = lines[i]:match('^([^:]+):%s*(.*)$')
          if k then
            req.headers[k:lower()] = v
          end
        end
        if (req.headers['expect'] or ''):lower() == '100-continue' then
          client:write('HTTP/1.1 100 Continue\r\n\r\n')
        end
      end
      local length = tonumber(req.headers['content-length'] or '0')
      if #buffer >= length then
        req.body = buffer:sub(1, length)
        client:read_stop()
        server.requests[#server.requests + 1] = req
        vim.schedule(function()
          route(req, client)
        end)
      end
    end)
  end)

  function server.stop()
    if not tcp:is_closing() then
      tcp:close()
    end
  end

  --- Requests whose path starts with `prefix`.
  function server.find(method, prefix)
    local out = {}
    for _, r in ipairs(server.requests) do
      if r.method == method and vim.startswith(r.target, prefix) then
        out[#out + 1] = r
      end
    end
    return out
  end

  return server
end

return M
