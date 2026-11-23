local files = require('converter-studio.files')
local formats = require('converter-studio.formats')
local config = require('converter-studio.config')
local desktop = require('converter-studio.desktop')
local h = require('helpers')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.set({})
    end,
  },
})

T['formats'] = MiniTest.new_set()

T['formats']['by extension, double extensions too'] = function()
  eq(formats.of('/a/Photo.HEIC'), 'heic')
  eq(formats.of('/a/b.jpeg'), 'jpg')
  eq(formats.of('/a/backup.tar.gz'), 'tgz')
  eq(formats.of('/a/notes.md'), 'md')
  eq(formats.of('/a/Makefile'), nil)
  eq(formats.stem('/a/backup.tar.gz'), 'backup')
  eq(formats.stem('/a/my.report.docx'), 'my.report')
  eq(formats.stem('/a/.bashrc'), '.bashrc')
  eq(formats.extension('jpg'), 'jpg')
  eq(formats.extension('tgz'), 'tar.gz')
end

T['names'] = MiniTest.new_set()

T['names']['a taken name gets (2), (3)…, never replaced'] = function()
  local dir = h.tmpdir()
  h.write(dir .. '/photo.webp', 'old')
  h.write(dir .. '/photo (2).webp', 'old 2')
  eq(files.free_name(dir, 'photo', 'webp'), dir .. '/photo (3).webp')
  local src = h.write(dir .. '/.result', 'new')
  local placed = files.place(src, dir, 'photo', 'webp')
  eq(placed, dir .. '/photo (3).webp')
  eq(h.read(dir .. '/photo.webp'), 'old')
  eq(h.read(placed), 'new')
  eq(h.read(src), nil)
end

T['names']['the work folder is hidden, private and removed'] = function()
  local dir = h.tmpdir()
  local work = assert(files.workdir(dir))
  eq(vim.fs.basename(work):match('^%.converter%-studio%-%x+$') ~= nil, true)
  if vim.fn.has('win32') == 0 then
    eq(vim.uv.fs_stat(work).mode % 512, 448) -- 0700
  end
  h.write(work .. '/x', 'y')
  files.remove(work)
  eq(h.ls(dir), {})
end

T['names']['a name from the API is only a file name'] = function()
  eq(files.safe_name('../../etc/passwd'), 'passwd')
  eq(files.safe_name('C:\\x\\report-compressed.pdf'), 'report-compressed.pdf')
  eq(files.safe_name('a:b?.txt'), 'a_b_.txt')
  eq(files.safe_name('..'), nil)
  eq(files.safe_name(nil), nil)
end

T['desktop'] = MiniTest.new_set()

T['desktop']['the link carries the format, the client and every file, encoded'] = function()
  local url = desktop.url({ '/home/me/My Photos/IMG_1.HEIC', 'C:\\Users\\me\\a&b+c#d%e~f.png' }, 'jpg')
  eq(
    url,
    'converter-studio://convert?to=jpg&from=neovim&file=%2Fhome%2Fme%2FMy%20Photos%2FIMG_1.HEIC'
      .. '&file=C%3A%5CUsers%5Cme%5Ca%26b%2Bc%23d%25e~f.png'
  )
  eq(desktop.encode('Ünï-_.~'), '%C3%9Cn%C3%AF-_.~')
end

T['desktop']['not offered over SSH'] = function()
  local saved_conn, saved_tty = vim.env.SSH_CONNECTION, vim.env.SSH_TTY
  vim.env.SSH_CONNECTION = '192.0.2.1 50000 192.0.2.2 22'
  local ok, why = desktop.available()
  eq(ok, false)
  eq(why:match('SSH') ~= nil, true)
  local err
  desktop.handoff({ '/a.heic' }, 'jpg', function(e)
    err = e
  end)
  eq(err, why)
  vim.env.SSH_CONNECTION, vim.env.SSH_TTY = nil, nil
  if vim.fn.has('wsl') == 0 then
    eq(desktop.available(), true)
  end
  vim.env.SSH_CONNECTION, vim.env.SSH_TTY = saved_conn, saved_tty
end

T['desktop']['Windows opens the link without cmd.exe'] = function()
  local argv = desktop.open_command('converter-studio://convert?to=jpg&from=neovim')
  if vim.fn.has('win32') == 1 then
    eq(argv, { 'rundll32', 'url.dll,FileProtocolHandler', 'converter-studio://convert?to=jpg&from=neovim' })
  else
    eq(argv, nil) -- `open` or `xdg-open` through vim.ui.open
  end
  eq(desktop.requirement(), 'Converter Studio for desktop 0.1.11 or later (https://converter.studio/download)')
end

T['config'] = MiniTest.new_set()

T['config']['the key: setup first, then the environment; never empty'] = function()
  local saved = vim.env.CONVERTER_STUDIO_API_KEY
  vim.env.CONVERTER_STUDIO_API_KEY = ' cvs_live_env '
  eq({ config.api_key() }, { 'cvs_live_env', 'environment' })
  config.set({ cloud = { api_key = 'cvs_live_setup' } })
  eq({ config.api_key() }, { 'cvs_live_setup', 'setup' })
  config.set({
    cloud = {
      api_key = function()
        return 'cvs_live_fn'
      end,
    },
  })
  eq({ config.api_key() }, { 'cvs_live_fn', 'setup' })
  config.set({ cloud = { api_key = '' } })
  eq({ config.api_key() }, { 'cvs_live_env', 'environment' })
  vim.env.CONVERTER_STUDIO_API_KEY = saved
end

T['config']['the API address: https, or http only to this computer'] = function()
  local function url(value)
    config.set({ cloud = { api_url = value } })
    return (config.api_url())
  end
  eq(url('https://converter.studio/api/'), 'https://converter.studio/api')
  eq(url('http://localhost:4391/api'), 'http://localhost:4391/api')
  eq(url('http://[::1]:4391/api'), 'http://[::1]:4391/api')
  eq(url('http://converter.studio/api'), nil)
  eq(url('https://user:pw@example.com/api'), nil)
  eq(url('file:///etc/passwd'), nil)
end

T['config']['wrong options are refused with a clear message'] = function()
  MiniTest.expect.error(function()
    config.set({ timeout = -1 })
  end, 'timeout')
  MiniTest.expect.error(function()
    config.set({ cloud = { max_credits = 'many' } })
  end, 'max_credits')
  MiniTest.expect.error(function()
    config.set({ desktop = { enabled = 'yes' } })
  end, 'desktop.enabled')
end

T['config']['vim.g.converter_studio works without setup()'] = function()
  vim.g.converter_studio = { desktop = { enabled = true } }
  eq(config.set().desktop.enabled, true)
  vim.g.converter_studio = nil
end

return T
