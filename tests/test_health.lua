local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function health_text(setup)
  local child = MiniTest.new_child_neovim()
  child.start({ '-u', 'tests/minimal_init.lua' })
  child.lua('vim.env.CONVERTER_STUDIO_API_KEY = nil; vim.env.SSH_CONNECTION = nil; vim.env.SSH_TTY = nil')
  if setup then
    child.lua(setup)
  end
  child.cmd('checkhealth converter-studio')
  local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
  child.stop()
  return table.concat(lines, '\n')
end

local function has(text, needle)
  if not text:find(needle, 1, true) then
    error(('"%s" not in:\n%s'):format(needle, text), 2)
  end
end

T[':checkhealth reports the programs, the desktop app and the key source'] = function()
  local text = health_text()
  has(text, 'converter-studio.nvim 1.0.0 on Neovim')
  has(text, 'Built in: CSV → JSON or YAML, JSON → CSV or YAML, SRT ↔ WebVTT')
  for _, name in ipairs({ 'FFmpeg', 'LibreOffice', 'Pandoc', 'ImageMagick', 'Ghostscript', 'Tesseract' }) do
    has(text, name)
  end
  has(text, 'Not used (desktop.enabled = false). It needs Converter Studio for desktop 0.1.11 or later')
  has(text, 'No API key: the cloud stays off until you set CONVERTER_STUDIO_API_KEY')
  has(text, 'API: https://converter.studio/api')
end

T[':checkhealth names where the key comes from, never the key'] = function()
  local text = health_text([[
    require('converter-studio').setup({
      tools = { ffmpeg = false },
      desktop = { enabled = true },
      cloud = { api_key = 'cvs_live_do_not_show', api_url = 'http://example.com/api' },
    })
  ]])
  has(text, 'API key: from setup({ cloud = { api_key = … } }) (the plugin never stores it)')
  has(text, 'FFmpeg: turned off in setup')
  has(text, 'cloud.api_url must start with https://')
  eq(text:find('cvs_live_do_not_show', 1, true), nil)
end

return T
