-- The cloud flow with the real curl against a fake API on 127.0.0.1 (tests/helpers/fake_api.lua).
local cloud = require('converter-studio.cloud')
local config = require('converter-studio.config')
local fake_api = require('helpers.fake_api')
local h = require('helpers')
local eq = MiniTest.expect.equality

local server, restore_select, restore_notify, notes, dir
local saved_env = vim.env.CONVERTER_STUDIO_API_KEY

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if vim.fn.executable('curl') == 0 then
        MiniTest.skip('curl is not installed')
      end
      vim.env.CONVERTER_STUDIO_API_KEY = nil
      cloud.sleep_ms = function(_, cb)
        vim.defer_fn(cb, 1)
      end
      dir = h.tmpdir()
      notes, restore_notify = h.stub_notify()
    end,
    post_case = function()
      if server then
        server.stop()
        server = nil
      end
      if restore_select then
        restore_select()
        restore_select = nil
      end
      if restore_notify then
        restore_notify()
      end
      vim.env.CONVERTER_STUDIO_API_KEY = saved_env
      config.set({})
    end,
  },
})

local function start(scenario)
  server = fake_api.start(scenario)
  config.set({ cloud = { api_url = server.api, api_key = fake_api.KEY } })
end

T['the key goes to curl on its standard input, not on its command line'] = function()
  local argv, stdin = cloud.command({
    url = 'https://converter.studio/api/v1/uploads',
    method = 'POST',
    key = 'cvs_live_secret',
    json = { fileName = 'a "quoted" \\ name.png', size = 3 },
    headers = { ['Idempotency-Key'] = 'k1' },
  })
  eq(vim.tbl_contains(argv, '--config'), true)
  eq(table.concat(argv, ' '):find('cvs_live_secret', 1, true), nil)
  eq(stdin:find('header = "Authorization: Bearer cvs_live_secret"', 1, true) ~= nil, true)
  eq(stdin:find('header = "X-Converter-Studio-Client: neovim/' .. config.VERSION .. '"', 1, true) ~= nil, true)
  eq(stdin:find('header = "Idempotency-Key: k1"', 1, true) ~= nil, true)
  -- Quotes and backslashes are escaped for curl's config syntax: read back, it is the same JSON.
  local data = stdin:match('\ndata%-binary = (".-")\n')
  local unquoted = data:sub(2, -2):gsub('\\(.)', { ['\\'] = '\\', ['"'] = '"', n = '\n', r = '\r', t = '\t' })
  eq(vim.json.decode(unquoted), { fileName = 'a "quoted" \\ name.png', size = 3 })
  eq(
    cloud._scrub('curl: (6) https://x/v1/uploads/u?token=abc123&x=1 cvs_live_abc Bearer xyz'),
    'curl: (6) https://x/v1/uploads/u?token=…&x=1 cvs_… Bearer …'
  )
end

T['converts: upload, conversion with an Idempotency-Key, download next to the file'] = function()
  start()
  local src = h.write(dir .. '/photo.heic', 'HEICDATA')
  local err, path = h.convert({ file = src, to = 'jpg', route = 'cloud' })
  eq(err, nil)
  eq(path, dir .. '/photo.jpg')
  eq(h.read(path), 'converted:HEICDATA')
  eq(server.upload_request, { fileName = 'photo.heic', size = 8 })
  -- The API calls carry the key and the client's name; the upload and download links do not.
  local create = server.find('POST', '/api/v1/conversions')[1]
  eq(create.headers['authorization'], 'Bearer ' .. fake_api.KEY)
  eq(create.headers['x-converter-studio-client'], 'neovim/' .. config.VERSION)
  eq(create.headers['idempotency-key']:match('^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$') ~= nil, true)
  eq(vim.json.decode(create.body), { uploadId = 'up_1', to = 'jpg', maxCredits = 20 })
  eq(server.find('PUT', '/api/v1/uploads/up_1')[1].headers['authorization'], nil)
  eq(server.find('GET', '/api/jobs/')[1].headers['authorization'], nil)
  -- Nothing is left behind but the source and the result.
  eq(h.ls(dir), { 'photo.heic', 'photo.jpg' })
end

T['a large file goes up in parts with Upload-Offset'] = function()
  start({ part_bytes = 4 })
  local src = h.write(dir .. '/clip.heic', '0123456789')
  local err, path = h.convert({ file = src, to = 'png', route = 'cloud' })
  eq(err, nil)
  eq(server.uploaded, '0123456789')
  local puts = server.find('PUT', '/api/v1/uploads/up_1')
  eq(#puts, 3)
  eq(
    { puts[1].headers['upload-offset'], puts[2].headers['upload-offset'], puts[3].headers['upload-offset'] },
    { '0', '4', '8' }
  )
  eq(h.read(path), 'converted:0123456789')
  eq(h.ls(dir), { 'clip.heic', 'clip.png' })
end

T['a busy API is tried again with the same Idempotency-Key'] = function()
  start({ busy = 2 })
  local src = h.write(dir .. '/a.png', 'PNG')
  local err = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err, nil)
  local creates = server.find('POST', '/api/v1/conversions')
  eq(#creates, 3)
  eq(creates[1].headers['idempotency-key'], creates[3].headers['idempotency-key'])
end

T["a wrong key shows the API's message"] = function()
  start()
  config.set({ cloud = { api_url = server.api, api_key = 'cvs_live_wrong' } })
  local src = h.write(dir .. '/a.png', 'PNG')
  local err = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err, 'This API key is not valid. Make a new one on your account page.')
  eq(h.ls(dir), { 'a.png' })
end

T["a failed conversion shows the API's message"] = function()
  start({ fail = 'This file is damaged and cannot be read.' })
  local src = h.write(dir .. '/a.png', 'PNG')
  local err = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err, 'This file is damaged and cannot be read.')
  eq(h.ls(dir), { 'a.png' })
end

T['a price above the limit asks first; no means nothing is charged'] = function()
  start({ price = 30 })
  local seen
  seen, restore_select = h.stub_select(function()
    return 2 -- Do not convert
  end)
  local src = h.write(dir .. '/long.png', 'PNG')
  local err = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err:match('^not converted: it costs 30 credits') ~= nil, true)
  eq(seen[1].labels, { 'Convert for 30 credits', 'Do not convert' })
  eq(server.confirmed, nil)
end

T['a price above the limit asks first; yes confirms'] = function()
  start({ price = 30 })
  local _
  _, restore_select = h.stub_select(function()
    return 1
  end)
  local src = h.write(dir .. '/long.png', 'PNG')
  local err, path = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err, nil)
  eq(server.confirmed, true)
  eq(path, dir .. '/long.webp')
end

T['no key: says where to make one, sends nothing'] = function()
  start()
  config.set({ cloud = { api_url = server.api } })
  local src = h.write(dir .. '/a.png', 'PNG')
  local err = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err:match('^no API key: set CONVERTER_STUDIO_API_KEY') ~= nil, true)
  eq(err:find('converter.studio/account#api-keys', 1, true) ~= nil, true)
  eq(#server.requests, 0)
end

T['the key never appears in a message'] = function()
  start({ fail = 'failed for cvs_live_test_key_0123456789' })
  local src = h.write(dir .. '/a.png', 'PNG')
  local err = h.convert({ file = src, to = 'webp', route = 'cloud' })
  eq(err:find(fake_api.KEY, 1, true), nil)
  for _, note in ipairs(notes) do
    eq(note.msg:find(fake_api.KEY, 1, true), nil)
  end
end

T['the list of formats is read once and cached'] = function()
  start()
  cloud.forget_catalog()
  local got
  cloud.catalog(function(err, catalog)
    got = { err, catalog }
  end)
  vim.wait(10000, function()
    return got ~= nil
  end)
  eq(got[1], nil)
  eq(cloud.targets(got[2], 'heic'), { 'jpg', 'png', 'webp' })
  local again
  cloud.catalog(function(_, catalog)
    again = catalog
  end)
  vim.wait(5000, function()
    return again ~= nil
  end)
  eq(#server.find('GET', '/api/v1/formats'), 1)
  -- No key is sent for the public list.
  eq(server.find('GET', '/api/v1/formats')[1].headers['authorization'], nil)
  cloud.forget_catalog()
end

return T
