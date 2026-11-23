-- Finds the conversion programs installed on this computer and what each of them can do.
-- Nothing is assumed: ImageMagick lists the formats it reads and writes, FFmpeg its encoders,
-- Pandoc its readers and writers, Tesseract its image libraries and languages.

local config = require('converter-studio.config')

local M = {}

local is_windows = vim.fn.has('win32') == 1
local is_mac = vim.fn.has('mac') == 1

M.ORDER = { 'ffmpeg', 'soffice', 'pandoc', 'magick', 'gs', 'tesseract' }

M.NAMES = {
  ffmpeg = 'FFmpeg',
  soffice = 'LibreOffice',
  pandoc = 'Pandoc',
  magick = 'ImageMagick',
  gs = 'Ghostscript',
  tesseract = 'Tesseract',
}

M.PURPOSE = {
  ffmpeg = 'video and audio',
  soffice = 'Word, Excel, PowerPoint and OpenDocument files, to PDF and between each other',
  pandoc = 'Markdown, HTML, Word, OpenDocument and EPUB',
  magick = 'images',
  gs = 'smaller PDF files',
  tesseract = 'text recognition (OCR) of images',
}

-- How long one probe (`ffmpeg -encoders`…) may take, in milliseconds.
local PROBE_TIMEOUT = 10000

local function env_dir(name, ...)
  local base = vim.env[name]
  if not base or base == '' then
    return nil
  end
  return vim.fs.joinpath(base, ...)
end

--- Every match of a glob, newest version last (sorted by name).
local function glob(pattern)
  if not pattern then
    return {}
  end
  local found = vim.fn.glob(pattern, true, true)
  table.sort(found)
  return found
end

-- Where each program is looked for after PATH: the folders its installers use.
local function candidates(name)
  local list = {}
  local function add(path)
    if path then
      list[#list + 1] = path
    end
  end
  local function add_glob(pattern)
    local found = glob(pattern)
    for i = #found, 1, -1 do
      add(found[i])
    end
  end
  local brew = { '/opt/homebrew/bin', '/usr/local/bin' }
  if name == 'ffmpeg' then
    add('ffmpeg')
    if is_windows then
      add(env_dir('LOCALAPPDATA', 'Microsoft', 'WinGet', 'Links', 'ffmpeg.exe'))
      add(env_dir('ProgramFiles', 'ffmpeg', 'bin', 'ffmpeg.exe'))
      add('C:\\ffmpeg\\bin\\ffmpeg.exe')
      add(env_dir('USERPROFILE', 'scoop', 'shims', 'ffmpeg.exe'))
    elseif is_mac then
      add(brew[1] .. '/ffmpeg')
      add(brew[2] .. '/ffmpeg')
    end
  elseif name == 'soffice' then
    add('soffice')
    add('libreoffice')
    if is_windows then
      add(env_dir('ProgramFiles', 'LibreOffice', 'program', 'soffice.exe'))
      add(env_dir('ProgramFiles(x86)', 'LibreOffice', 'program', 'soffice.exe'))
    elseif is_mac then
      add('/Applications/LibreOffice.app/Contents/MacOS/soffice')
      add(env_dir('HOME', 'Applications', 'LibreOffice.app', 'Contents', 'MacOS', 'soffice'))
    else
      add('/snap/bin/libreoffice')
      add('/var/lib/flatpak/exports/bin/org.libreoffice.LibreOffice')
      add(env_dir('HOME', '.local', 'share', 'flatpak', 'exports', 'bin', 'org.libreoffice.LibreOffice'))
      add_glob('/opt/libreoffice*/program/soffice')
    end
  elseif name == 'pandoc' then
    add('pandoc')
    if is_windows then
      add(env_dir('LOCALAPPDATA', 'Pandoc', 'pandoc.exe'))
      add(env_dir('ProgramFiles', 'Pandoc', 'pandoc.exe'))
    elseif is_mac then
      add(brew[1] .. '/pandoc')
      add(brew[2] .. '/pandoc')
    end
  elseif name == 'magick' then
    add('magick')
    if is_windows then
      add_glob(env_dir('ProgramFiles', 'ImageMagick-*', 'magick.exe'))
    else
      if is_mac then
        add(brew[1] .. '/magick')
        add(brew[2] .. '/magick')
      end
      -- ImageMagick 6 has no `magick`; on Windows `convert` is a system program, never used.
      add('convert')
    end
  elseif name == 'gs' then
    if is_windows then
      add('gswin64c')
      add('gswin32c')
      add_glob(env_dir('ProgramFiles', 'gs', 'gs*', 'bin', 'gswin64c.exe'))
    else
      add('gs')
      if is_mac then
        add(brew[1] .. '/gs')
        add(brew[2] .. '/gs')
      end
    end
  elseif name == 'tesseract' then
    add('tesseract')
    if is_windows then
      add(env_dir('ProgramFiles', 'Tesseract-OCR', 'tesseract.exe'))
      add(env_dir('LOCALAPPDATA', 'Programs', 'Tesseract-OCR', 'tesseract.exe'))
    elseif is_mac then
      add(brew[1] .. '/tesseract')
      add(brew[2] .. '/tesseract')
    end
  end
  return list
end

--- The full path of a program, or nil.
local function resolve(command)
  if command:find('[/\\]') then
    return vim.fn.executable(command) == 1 and command or nil
  end
  local path = vim.fn.exepath(command)
  return path ~= '' and path or nil
end

-- Runs a probe and returns its output (stdout and stderr together), or nil.
local function probe(argv)
  local ok, obj = pcall(vim.system, argv, { text = true })
  if not ok then
    return nil
  end
  local result = obj:wait(PROBE_TIMEOUT)
  if result.code ~= 0 and (result.stdout or '') == '' then
    return nil
  end
  return (result.stdout or '') .. '\n' .. (result.stderr or '')
end

-- Turns the text of each program's probe into what it can do.
M.parse = {}

--- `magick -list format`: `     HEIC  r--   High Efficiency Image Format (1.17.6)`.
function M.parse.magick_formats(text)
  local read, write = {}, {}
  for line in (text or ''):gmatch('[^\n]+') do
    local name, mode = line:match('^%s*([%w%-]+)%*?%s+([r%-][w%-][+%-])%s')
    if name then
      name = name:lower()
      if mode:sub(1, 1) == 'r' then
        read[name] = true
      end
      if mode:sub(2, 2) == 'w' then
        write[name] = true
      end
    end
  end
  return { read = read, write = write }
end

--- `magick -list policy`: the coder rules of a security policy, in order (Ubuntu's ImageMagick 6
--- forbids PDF and PostScript, for example). Returns `{ { names = {…} | '*', read, write }, … }`.
function M.parse.magick_policy(text)
  local rules = {}
  local in_coder, rights = false, nil
  for line in (text or ''):gmatch('[^\r\n]+') do
    local kind = line:match('^%s*Policy:%s*(%w+)')
    if kind then
      in_coder, rights = kind:lower() == 'coder', nil
    elseif in_coder then
      local value = line:match('^%s*rights:%s*(.-)%s*$')
      if value then
        rights = value:lower()
      end
      local pattern = line:match('^%s*pattern:%s*(.-)%s*$')
      if pattern and rights then
        local rule = { read = rights:find('read') ~= nil, write = rights:find('write') ~= nil }
        if pattern == '*' then
          rule.names = '*'
        else
          rule.names = {}
          for name in pattern:gsub('^{', ''):gsub('}$', ''):gmatch('[^,%s]+') do
            rule.names[name:lower()] = true
          end
        end
        rules[#rules + 1] = rule
      end
    end
  end
  return rules
end

--- What the formats list says, less what the policy forbids (the last matching rule wins).
function M.apply_policy(formats, rules)
  for _, mode in ipairs({ 'read', 'write' }) do
    for name in pairs(formats[mode]) do
      local allowed = true
      for _, rule in ipairs(rules) do
        if rule.names == '*' or rule.names[name] then
          allowed = rule[mode]
        end
      end
      if not allowed then
        formats[mode][name] = nil
      end
    end
  end
  return formats
end

--- `ffmpeg -encoders`: ` V....D libx264   libx264 H.264 …`.
function M.parse.ffmpeg_encoders(text)
  local encoders = {}
  for line in (text or ''):gmatch('[^\n]+') do
    local flags, name = line:match('^%s([VAS][F%.][S%.][X%.][B%.][D%.])%s+([%w_%-]+)')
    if flags and name ~= '=' then
      encoders[name] = true
    end
  end
  return encoders
end

--- `pandoc --list-input-formats` (one name a line).
function M.parse.lines(text)
  local set = {}
  for line in (text or ''):gmatch('[^\r\n]+') do
    local word = vim.trim(line)
    if word ~= '' and not word:find('%s') then
      set[word] = true
    end
  end
  return set
end

--- `tesseract --version`: the image libraries Leptonica was built with.
function M.parse.tesseract_images(text)
  text = (text or ''):lower()
  local images = { bmp = true }
  local libs = { libjpeg = 'jpg', libpng = 'png', libtiff = 'tiff', libgif = 'gif', libwebp = 'webp' }
  for lib, id in pairs(libs) do
    if text:find(lib, 1, true) then
      images[id] = true
    end
  end
  return images
end

--- `tesseract --list-langs`: language codes after the first line.
function M.parse.tesseract_langs(text)
  local langs = {}
  for line in (text or ''):gmatch('[^\r\n]+') do
    local code = vim.trim(line)
    if code:match('^[%w_%-]+$') and code ~= 'osd' then
      langs[#langs + 1] = code
    end
  end
  return langs
end

function M.parse.version(text)
  return (text or ''):match('(%d+%.%d+[%.%d]*)')
end

local PDF_ENGINES = { 'typst', 'tectonic', 'xelatex', 'lualatex', 'pdflatex', 'weasyprint', 'wkhtmltopdf' }

-- What each program can do, from its probes.
local function describe(name, path)
  local tool = { name = name, path = path, label = M.NAMES[name] }
  if name == 'magick' then
    tool.v7 = vim.fs.basename(path):lower():match('^magick') ~= nil
    local out = probe({ path, '-version' })
    if not out or not out:find('ImageMagick', 1, true) then
      return nil -- `convert` that is not ImageMagick's
    end
    tool.version = out:match('ImageMagick (%d[%d%.%-]*)')
    tool.formats = M.apply_policy(
      M.parse.magick_formats(probe({ path, '-list', 'format' })),
      M.parse.magick_policy(probe({ path, '-list', 'policy' }))
    )
  elseif name == 'ffmpeg' then
    tool.version = M.parse.version(probe({ path, '-hide_banner', '-version' }))
    tool.encoders = M.parse.ffmpeg_encoders(probe({ path, '-hide_banner', '-encoders' }))
  elseif name == 'pandoc' then
    tool.version = M.parse.version(probe({ path, '--version' }))
    tool.readers = M.parse.lines(probe({ path, '--list-input-formats' }))
    tool.writers = M.parse.lines(probe({ path, '--list-output-formats' }))
    for _, engine in ipairs(PDF_ENGINES) do
      local found = resolve(engine)
      local typst_ok = engine ~= 'typst'
        or vim.version.ge(vim.version.parse(tool.version or '0') or { 0, 0, 0 }, { 3, 1, 2 })
      if found and typst_ok then
        tool.pdf_engine = engine
        tool.pdf_engine_path = found
        break
      end
    end
  elseif name == 'gs' then
    tool.version = M.parse.version(probe({ path, '--version' }))
  elseif name == 'tesseract' then
    local out = probe({ path, '--version' })
    tool.version = M.parse.version(out)
    tool.images = M.parse.tesseract_images(out)
    tool.langs = M.parse.tesseract_langs(probe({ path, '--list-langs' }))
  elseif name == 'soffice' then
    -- Starting LibreOffice to ask its version takes seconds; being there is enough.
    tool.version = nil
  end
  return tool
end

local cache

--- The programs found, by name, each with its abilities: `{ magick = { path, formats… }, … }`.
--- Probed once a session; `refresh` probes again.
function M.detect(refresh)
  if cache and not refresh then
    return cache
  end
  local configured = config.get().tools
  local found = {}
  for _, name in ipairs(M.ORDER) do
    local setting = configured[name]
    if setting ~= false then
      local list = type(setting) == 'string' and { vim.fn.expand(setting) } or candidates(name)
      for _, candidate in ipairs(list) do
        local path = resolve(candidate)
        if path then
          local tool = describe(name, path)
          if tool then
            tool.configured = type(setting) == 'string'
            found[name] = tool
            break
          end
        end
      end
    end
  end
  cache = found
  return found
end

--- Forgets what was found (after `setup()` changes `tools`).
function M.reset()
  cache = nil
end

--- Tesseract's language argument: the configured one, English, or the first installed.
function M.ocr_language(tool)
  local wanted = config.get().ocr_language
  if wanted then
    return wanted
  end
  local langs = tool and tool.langs or {}
  for _, code in ipairs(langs) do
    if code == 'eng' then
      return 'eng'
    end
  end
  return langs[1] or 'eng'
end

M._candidates = candidates

return M
