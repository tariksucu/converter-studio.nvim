-- :ConverterStudio, the picker, completion and the desktop handoff, with no program installed
-- (every tool turned off) so the results do not depend on the computer.
local cs = require('converter-studio')
local cloud = require('converter-studio.cloud')
local desktop = require('converter-studio.desktop')
local fake_api = require('helpers.fake_api')
local h = require('helpers')
local eq = MiniTest.expect.equality

local NO_TOOLS = { ffmpeg = false, soffice = false, pandoc = false, magick = false, gs = false, tesseract = false }

local dir, notes, undo = nil, nil, {}

local function setup(extra)
  cs.setup(vim.tbl_deep_extend('force', { tools = NO_TOOLS }, extra or {}))
end

local function stub(tbl, key, value)
  local original = tbl[key]
  tbl[key] = value
  undo[#undo + 1] = function()
    tbl[key] = original
  end
end

local function wait_for(fn, ms)
  vim.wait(ms or 10000, fn, 10)
  return fn()
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = h.tmpdir()
      local restore
      notes, restore = h.stub_notify()
      undo = { restore }
      -- As on a desktop: these tests may themselves run over SSH.
      local conn, tty = vim.env.SSH_CONNECTION, vim.env.SSH_TTY
      vim.env.SSH_CONNECTION, vim.env.SSH_TTY = nil, nil
      undo[#undo + 1] = function()
        vim.env.SSH_CONNECTION, vim.env.SSH_TTY = conn, tty
      end
      setup()
      cloud.forget_catalog()
    end,
    post_case = function()
      for i = #undo, 1, -1 do
        undo[i]()
      end
      vim.cmd('silent! %bwipeout!')
      cs.setup({})
      cloud.forget_catalog()
    end,
  },
})

local function last_message()
  return notes[#notes] and notes[#notes].msg or nil
end

T['converts the current file with a built-in conversion'] = function()
  vim.cmd.edit(h.write(dir .. '/people.csv', 'name,role\nAda,engineer\n'))
  vim.cmd('ConverterStudio json')
  eq(
    wait_for(function()
      return h.read(dir .. '/people.json') ~= nil
    end),
    true
  )
  eq(vim.json.decode(h.read(dir .. '/people.json')), { { name = 'Ada', role = 'engineer' } })
  eq(last_message(), 'Converter Studio: people.csv → people.json (on this computer, built in)')
  -- Again: the first result is kept, the second gets a number.
  vim.cmd('ConverterStudio json')
  eq(
    wait_for(function()
      return h.read(dir .. '/people (2).json') ~= nil
    end),
    true
  )
end

T['refuses a buffer with unsaved changes or without a file'] = function()
  vim.cmd.edit(h.write(dir .. '/a.csv', 'a\n1\n'))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b', '2' })
  vim.cmd('ConverterStudio json')
  eq(last_message(), 'Converter Studio: the buffer has changes that are not written: write it first (:w)')
  vim.cmd('enew!')
  vim.cmd('ConverterStudio json')
  eq(last_message(), 'Converter Studio: this buffer has no file')
end

T['without a program for it: says which one would, and how to use the cloud'] = function()
  vim.cmd.edit(h.write(dir .. '/IMG_1.heic', 'not really a photo'))
  vim.cmd('ConverterStudio jpg')
  eq(
    last_message(),
    'Converter Studio: nothing on this computer converts HEIC to JPG (ImageMagick with HEIC support (libheif) would). '
      .. 'In the cloud: :ConverterStudio cloud jpg (uploads the file to converter.studio, uses credits)'
  )
  eq(notes[#notes].level, vim.log.levels.ERROR)
end

T['the picker says where each target runs; the cloud is its own choice'] = function()
  local seen, restore = h.stub_select(function()
    return nil
  end)
  undo[#undo + 1] = restore
  vim.cmd.edit(h.write(dir .. '/data.json', '[{"a": 1}]'))
  vim.cmd('ConverterStudio')
  wait_for(function()
    return #seen > 0
  end)
  eq(seen[1].prompt, 'Convert data.json to')
  eq(seen[1].labels, {
    'CSV            on this computer (built in)',
    'YAML           on this computer (built in)',
    'In the cloud…  uploads the file to converter.studio, uses credits',
  })
end

T['the cloud picker lists what Converter Studio offers and says it uploads'] = function()
  local server = fake_api.start()
  undo[#undo + 1] = server.stop
  setup({ cloud = { api_url = server.api } })
  local seen, restore = h.stub_select(function(labels)
    return #labels -- In the cloud…, then nothing
  end)
  undo[#undo + 1] = restore
  vim.cmd.edit(h.write(dir .. '/IMG_1.heic', 'x'))
  vim.cmd('ConverterStudio')
  eq(
    wait_for(function()
      return #seen >= 2
    end),
    true
  )
  eq(seen[2].prompt, 'Convert IMG_1.heic in the cloud (uploads it to converter.studio, uses credits) to')
  eq(seen[2].labels, { 'JPG', 'PNG', 'WebP' })
  -- Choosing the last one (WebP) without a key: nothing is sent, the message says why.
  eq(
    wait_for(function()
      return (last_message() or ''):match('no API key') ~= nil
    end),
    true
  )
  eq(#server.find('POST', '/api/v1/uploads'), 0)
end

T['with the desktop app: formats nothing here converts are handed to it'] = function()
  local server = fake_api.start()
  undo[#undo + 1] = server.stop
  setup({ desktop = { enabled = true }, cloud = { api_url = server.api } })
  local opened = {}
  stub(desktop, 'installed', function()
    return true
  end)
  stub(desktop, 'open_command', function()
    return nil
  end)
  stub(vim.ui, 'open', function(url)
    opened[#opened + 1] = url
    return { pid = 1 }, nil
  end)
  local seen, restore = h.stub_select(function()
    return 2 -- PNG, desktop app
  end)
  undo[#undo + 1] = restore
  local photo = h.write(dir .. '/IMG 1.heic', 'x')
  vim.cmd.edit(vim.fn.fnameescape(photo))
  vim.cmd('ConverterStudio')
  eq(
    wait_for(function()
      return #opened > 0
    end),
    true
  )
  eq(seen[1].labels, {
    'JPG            Converter Studio desktop app',
    'PNG            Converter Studio desktop app',
    'WebP           Converter Studio desktop app',
    'In the cloud…  uploads the file to converter.studio, uses credits',
  })
  eq(opened[1], 'converter-studio://convert?to=png&from=neovim&file=' .. desktop.encode(photo))
  eq(
    last_message(),
    'Converter Studio: sent IMG 1.heic to the desktop app: press Continue, then Convert there (to PNG). '
      .. 'If the app only comes to the front, it needs Converter Studio for desktop 0.1.11 or later '
      .. '(https://converter.studio/download).'
  )
  -- `:ConverterStudio jpg` goes to the app too, as nothing here converts HEIC.
  vim.cmd('ConverterStudio jpg')
  eq(opened[2], 'converter-studio://convert?to=jpg&from=neovim&file=' .. desktop.encode(photo))
end

T['the desktop app that is not installed is not opened'] = function()
  setup({ desktop = { enabled = true } })
  stub(desktop, 'installed', function()
    return false
  end)
  local opened = false
  stub(vim.ui, 'open', function()
    opened = true
  end)
  vim.cmd.edit(h.write(dir .. '/a.heic', 'x'))
  vim.cmd('ConverterStudio desktop jpg')
  eq(opened, false)
  eq(
    last_message():match('the desktop app is not installed: this needs Converter Studio for desktop 0%.1%.11 or later')
      ~= nil,
    true
  )
end

T['over SSH the desktop app is neither offered nor used'] = function()
  setup({ desktop = { enabled = true } })
  vim.env.SSH_CONNECTION = '192.0.2.1 50000 192.0.2.2 22'
  local seen, restore = h.stub_select(function()
    return nil
  end)
  undo[#undo + 1] = restore
  vim.cmd.edit(h.write(dir .. '/a.heic', 'x'))
  vim.cmd('ConverterStudio')
  wait_for(function()
    return #seen > 0
  end)
  eq(seen[1].labels, { 'In the cloud…  uploads the file to converter.studio, uses credits' })
  vim.cmd('ConverterStudio jpg')
  eq(last_message():match('^Converter Studio: nothing on this computer converts HEIC to JPG') ~= nil, true)
  vim.cmd('ConverterStudio desktop jpg')
  eq(
    last_message(),
    'Converter Studio: Neovim runs over SSH: the files are not on the computer where the desktop app runs'
  )
end

T['completion: local targets, then subcommands; all formats after cloud'] = function()
  vim.cmd.edit(h.write(dir .. '/subs.srt', '1\n00:00:01,000 --> 00:00:02,000\nHi\n'))
  eq(cs.complete('', 'ConverterStudio '), { 'vtt', 'cloud', 'desktop', 'cancel' })
  eq(cs.complete('c', 'ConverterStudio c'), { 'cloud', 'cancel' })
  eq(cs.complete('we', 'ConverterStudio cloud we'), { 'webm', 'webp' })
  eq(cs.complete('', 'ConverterStudio vtt '), {})
  -- The command itself completes the same way.
  eq(vim.fn.getcompletion('ConverterStudio d', 'cmdline'), { 'desktop' })
end

T['cancel with nothing running says so'] = function()
  eq(cs.cancel(), 0)
  eq(last_message(), 'Converter Studio: nothing is running')
end

T['the command loads nothing until it is used'] = function()
  local child = MiniTest.new_child_neovim()
  child.start({ '-u', 'tests/minimal_init.lua' })
  eq(child.lua_get('package.loaded["converter-studio"] == nil'), true)
  eq(child.lua_get('vim.fn.exists(":ConverterStudio")'), 2)
  eq(child.lua_get('vim.fn.maparg("<Plug>(converter-studio)", "n") ~= ""'), true)
  child.stop()
end

return T
