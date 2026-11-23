-- :checkhealth converter-studio

local config = require('converter-studio.config')
local tools = require('converter-studio.tools')
local formats = require('converter-studio.formats')
local recipes = require('converter-studio.recipes')

local M = {}

local health = vim.health

-- What a program adds, from the recipes it gives for a few common sources.
local function enables(name, found)
  local samples = {
    ffmpeg = { 'mp4', 'mov', 'mp3', 'wav' },
    soffice = { 'docx', 'xlsx', 'pptx', 'odt' },
    pandoc = { 'md', 'docx', 'html' },
    magick = { 'heic', 'png', 'jpg', 'svg' },
    gs = { 'pdf' },
    tesseract = { 'png', 'jpg' },
  }
  local only = { [name] = found[name] }
  local lines = {}
  for _, from in ipairs(samples[name] or {}) do
    local targets = {}
    for _, recipe in ipairs(recipes.for_format(from, only)) do
      if recipe.tool == name then
        local label = formats.label(recipe.to)
        if recipe.variant then
          label = ('%s (%s)'):format(label, recipe.variant)
        end
        targets[#targets + 1] = label
      end
    end
    if #targets > 0 then
      lines[#lines + 1] = ('%s → %s'):format(formats.label(from), table.concat(targets, ', '))
    end
  end
  return lines
end

function M.check()
  health.start('Converter Studio')
  if vim.fn.has('nvim-0.10') == 1 then
    health.ok(('converter-studio.nvim %s on Neovim %s'):format(config.VERSION, tostring(vim.version())))
  else
    health.error('Neovim 0.10 or later is needed')
  end
  local ok, err = pcall(config.get)
  if not ok then
    health.error('setup(): ' .. tostring(err))
    return
  end

  health.start('On this computer (files stay here)')
  health.ok('Built in: CSV → JSON or YAML, JSON → CSV or YAML, SRT ↔ WebVTT')
  local found = tools.detect(true)
  for _, name in ipairs(tools.ORDER) do
    local tool = found[name]
    local label = tools.NAMES[name]
    if tool then
      local version = tool.version and (' ' .. tool.version) or ''
      local lines = enables(name, found)
      if name == 'magick' then
        local can = tool.formats
        lines[#lines + 1] = ('HEIC photos: %s; AVIF: %s'):format(
          can.read.heic and 'read' or 'not supported by this build',
          can.write.avif and 'write' or 'not supported by this build'
        )
      elseif name == 'pandoc' then
        lines[#lines + 1] = tool.pdf_engine and ('PDF with %s'):format(tool.pdf_engine)
          or 'no PDF from Pandoc: no PDF engine found '
            .. '(typst, tectonic, xelatex, lualatex, pdflatex, weasyprint or wkhtmltopdf)'
      elseif name == 'tesseract' then
        local langs = tool.langs or {}
        lines[#lines + 1] = ('languages: %s (uses %s)'):format(
          #langs > 0 and table.concat(langs, ', ') or 'none found',
          tools.ocr_language(tool)
        )
      end
      health.ok(('%s%s: %s%s'):format(label, version, tool.path, tool.configured and ' (from setup)' or ''))
      for _, line in ipairs(lines) do
        health.info('  ' .. line)
      end
    else
      local disabled = config.get().tools[name] == false
      health.info(('%s: %s (%s)'):format(label, disabled and 'turned off in setup' or 'not found', tools.PURPOSE[name]))
    end
  end

  health.start('Converter Studio desktop app')
  local desktop = require('converter-studio.desktop')
  local here, why_not = desktop.available()
  if not config.get().desktop.enabled then
    health.info('Not used (desktop.enabled = false). It needs ' .. desktop.requirement())
  elseif not here then
    health.warn('Enabled, but not used here: ' .. why_not)
  else
    local installed = desktop.installed()
    if installed == true then
      health.ok('Installed: files that nothing on this computer converts are handed to it')
    elseif installed == false then
      health.warn('Not installed (no handler for converter-studio:// links)', { 'Install ' .. desktop.requirement() })
    else
      health.info('Enabled; whether it is installed cannot be checked here')
    end
    health.info('Needs ' .. desktop.requirement())
    health.info('The Snap and Flatpak builds of the app only see files in your home folder')
  end

  health.start('Cloud (converter.studio, only when you choose it)')
  if vim.fn.executable('curl') == 1 then
    health.ok('curl: ' .. vim.fn.exepath('curl'))
  else
    health.warn('curl not found: the cloud needs it')
  end
  local _, source = config.api_key()
  if source == 'environment' then
    health.ok('API key: from the environment variable CONVERTER_STUDIO_API_KEY (the plugin never stores it)')
  elseif source == 'setup' then
    if config.api_key() then
      health.ok('API key: from setup({ cloud = { api_key = … } }) (the plugin never stores it)')
    else
      health.warn('API key: setup() gives one, but it is empty')
    end
  else
    health.info(
      ('No API key: the cloud stays off until you set CONVERTER_STUDIO_API_KEY. Make a key at %s'):format(
        config.KEYS_URL
      )
    )
  end
  local url, why = config.api_url()
  if url then
    health.ok('API: ' .. url)
  else
    health.error(why)
  end
  health.info(('Asks before a conversion over %d credits (cloud.max_credits)'):format(config.get().cloud.max_credits))
end

return M
