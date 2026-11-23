-- What this computer can convert by itself: the plugin's own Lua conversions and short, public
-- recipes for the programs that `tools.detect()` found. Each recipe builds an argument list (never
-- a shell string) that writes into a private work folder; `convert.lua` runs it and moves the
-- result next to the source.

local formats = require('converter-studio.formats')
local tools = require('converter-studio.tools')

local M = {}

local function set(list)
  local out = {}
  for _, v in ipairs(list) do
    out[v] = true
  end
  return out
end

-- file:///… for LibreOffice's -env:UserInstallation (spaces and other characters encoded).
local function file_uri(path)
  path = path:gsub('\\', '/')
  if not path:match('^/') then
    path = '/' .. path -- C:/… on Windows
  end
  local encoded = path:gsub('[^%w%-%._~/:]', function(c)
    return ('%%%02X'):format(c:byte())
  end)
  return 'file://' .. encoded
end
M._file_uri = file_uri

---------------------------------------------------------------------------------------------------
-- ImageMagick
---------------------------------------------------------------------------------------------------

-- Format id → ImageMagick's coder name in `-list format`.
local MAGICK_CODER = {
  jpg = 'jpeg',
  png = 'png',
  webp = 'webp',
  heic = 'heic',
  avif = 'avif',
  gif = 'gif',
  bmp = 'bmp',
  tiff = 'tiff',
  ico = 'ico',
  svg = 'svg',
  pdf = 'pdf',
}
local MAGICK_IN = { 'jpg', 'png', 'webp', 'heic', 'avif', 'gif', 'bmp', 'tiff', 'ico', 'svg' }
local MAGICK_OUT = { 'jpg', 'png', 'webp', 'avif', 'gif', 'tiff', 'bmp', 'ico', 'heic', 'pdf' }
-- Formats that hold one picture: an animation or a multi-page TIFF gives its first frame.
local ONE_FRAME = set({ 'jpg', 'png', 'bmp', 'ico', 'avif', 'heic' })
local NO_ALPHA = set({ 'jpg', 'bmp' })
local QUALITY = { jpg = '90', webp = '80', avif = '60', heic = '70' }

local function magick_recipes(from, tool, out)
  local can = tool.formats or { read = {}, write = {} }
  if not vim.tbl_contains(MAGICK_IN, from) or not can.read[MAGICK_CODER[from]] then
    return
  end
  for _, to in ipairs(MAGICK_OUT) do
    if to ~= from and can.write[MAGICK_CODER[to]] then
      out[#out + 1] = {
        key = to,
        to = to,
        tool = 'magick',
        build = function(ctx)
          local input = ctx.input .. (ONE_FRAME[to] and '[0]' or '')
          local argv = { tool.path, input, '-auto-orient' }
          if NO_ALPHA[to] then
            vim.list_extend(argv, { '-background', 'white', '-alpha', 'remove', '-alpha', 'off' })
          end
          if to == 'ico' then
            vim.list_extend(argv, { '-background', 'none', '-resize', '256x256>' })
            vim.list_extend(argv, { '-define', 'icon:auto-resize=256,128,64,48,32,16' })
          end
          if QUALITY[to] then
            vim.list_extend(argv, { '-quality', QUALITY[to] })
          end
          -- The extension tells ImageMagick which format to write.
          local output = vim.fs.joinpath(ctx.workdir, 'out.' .. formats.extension(to))
          argv[#argv + 1] = output
          return { argv = argv, output = output }
        end,
      }
    end
  end
end

---------------------------------------------------------------------------------------------------
-- FFmpeg
---------------------------------------------------------------------------------------------------

local VIDEO_IN = set({ 'mp4', 'mov', 'mkv', 'avi', 'webm', 'flv', '3gp', 'wmv' })
local AUDIO_IN = set({ 'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wma', 'aiff' })

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    vim.list_extend(out, list)
  end
  return out
end

local H264 = { '-c:v', 'libx264', '-preset', 'medium', '-crf', '23', '-pix_fmt', 'yuv420p' }
-- H.264 in 4:2:0 needs an even width and height.
local EVEN = { '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2' }
local AAC = { '-c:a', 'aac', '-b:a', '160k' }
local FIRST_STREAMS = { '-map', '0:v:0', '-map', '0:a:0?' }

-- to = { encoders needed, arguments after the input }
local FFMPEG_VIDEO = {
  mp4 = {
    { 'libx264', 'aac' },
    concat(FIRST_STREAMS, H264, EVEN, AAC, { '-movflags', '+faststart' }),
  },
  mov = {
    { 'libx264', 'aac' },
    concat(FIRST_STREAMS, H264, EVEN, AAC, { '-movflags', '+faststart' }),
  },
  webm = {
    { 'libvpx-vp9', 'libopus' },
    {
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-c:v',
      'libvpx-vp9',
      '-crf',
      '32',
      '-b:v',
      '0',
      '-row-mt',
      '1',
      '-c:a',
      'libopus',
      '-b:a',
      '128k',
    },
  },
  -- Matroska holds nearly every codec: the streams are copied, not encoded again.
  mkv = { {}, { '-map', '0:v', '-map', '0:a?', '-c', 'copy' } },
  gif = {
    { 'gif' },
    {
      '-an',
      '-vf',
      "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
      '-loop',
      '0',
    },
  },
}

local FFMPEG_AUDIO = {
  mp3 = { 'libmp3lame', { '-c:a', 'libmp3lame', '-q:a', '2' } },
  m4a = { 'aac', { '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart' } },
  aac = { 'aac', { '-c:a', 'aac', '-b:a', '192k', '-f', 'adts' } },
  wav = { 'pcm_s16le', { '-c:a', 'pcm_s16le' } },
  flac = { 'flac', { '-c:a', 'flac' } },
  ogg = { 'libvorbis', { '-c:a', 'libvorbis', '-q:a', '5' } },
  opus = { 'libopus', { '-c:a', 'libopus', '-b:a', '128k' } },
  aiff = { 'pcm_s16be', { '-c:a', 'pcm_s16be' } },
}

local function ffmpeg_recipes(from, tool, out)
  local video, audio = VIDEO_IN[from], AUDIO_IN[from]
  local gif = from == 'gif' -- an animated GIF becomes a video
  if not (video or audio or gif) then
    return
  end
  local has = tool.encoders or {}
  local function add(to, args)
    out[#out + 1] = {
      key = to,
      to = to,
      tool = 'ffmpeg',
      build = function(ctx)
        local output = vim.fs.joinpath(ctx.workdir, 'out.' .. formats.extension(to))
        local argv = { tool.path, '-hide_banner', '-nostdin', '-loglevel', 'error', '-i', ctx.input }
        vim.list_extend(argv, args)
        argv[#argv + 1] = output
        return { argv = argv, output = output }
      end,
    }
  end
  if video or gif then
    for _, to in ipairs({ 'mp4', 'webm', 'mov', 'mkv', 'gif' }) do
      local spec = FFMPEG_VIDEO[to]
      local ok = to ~= from and not (gif and (to == 'mkv' or to == 'gif'))
      for _, encoder in ipairs(spec[1]) do
        ok = ok and has[encoder]
      end
      if ok then
        add(to, spec[2])
      end
    end
  end
  if video or audio then
    for _, to in ipairs({ 'mp3', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'aac', 'aiff' }) do
      local spec = FFMPEG_AUDIO[to]
      if to ~= from and has[spec[1]] then
        add(to, vim.list_extend({ '-vn', '-map', '0:a:0' }, spec[2]))
      end
    end
  end
end

---------------------------------------------------------------------------------------------------
-- LibreOffice
---------------------------------------------------------------------------------------------------

-- Filters for `--convert-to`: LibreOffice's own export filter names.
local OFFICE_FILTER = {
  pdf = 'pdf',
  docx = 'docx:MS Word 2007 XML',
  doc = 'doc:MS Word 97',
  odt = 'odt',
  rtf = 'rtf',
  txt = 'txt:Text (encoded):UTF8',
  xlsx = 'xlsx:Calc MS Excel 2007 XML',
  xls = 'xls:MS Excel 97',
  ods = 'ods',
  csv = 'csv:Text - txt - csv (StarCalc):44,34,76,1',
  pptx = 'pptx:Impress MS PowerPoint 2007 XML',
  ppt = 'ppt:MS PowerPoint 97',
  odp = 'odp',
}
local OFFICE = {
  { from = { 'docx', 'doc', 'odt', 'rtf' }, to = { 'pdf', 'docx', 'odt', 'doc', 'rtf', 'txt' } },
  { from = { 'html' }, to = { 'pdf', 'docx', 'odt' }, infilter = 'HTML (StarWriter)' },
  { from = { 'xlsx', 'xls', 'ods' }, to = { 'pdf', 'xlsx', 'ods', 'xls', 'csv' } },
  { from = { 'csv' }, to = { 'xlsx', 'ods', 'pdf' }, infilter = 'CSV:44,34,76,1' },
  { from = { 'pptx', 'ppt', 'odp' }, to = { 'pdf', 'pptx', 'odp', 'ppt' } },
}

local function office_recipes(from, tool, out)
  for _, group in ipairs(OFFICE) do
    if vim.tbl_contains(group.from, from) then
      for _, to in ipairs(group.to) do
        if to ~= from then
          out[#out + 1] = {
            key = to,
            to = to,
            tool = 'soffice',
            build = function(ctx)
              -- A profile of its own: a LibreOffice window that is open does not take the job.
              local profile = vim.fs.joinpath(ctx.workdir, 'profile')
              local argv = {
                tool.path,
                '-env:UserInstallation=' .. file_uri(profile),
                '--headless',
                '--norestore',
                '--nolockcheck',
                '--nodefault',
              }
              if group.infilter then
                argv[#argv + 1] = '--infilter=' .. group.infilter
              end
              vim.list_extend(argv, { '--convert-to', OFFICE_FILTER[to], '--outdir', ctx.workdir, ctx.input })
              -- LibreOffice names the result after the source.
              local name = vim.fn.fnamemodify(ctx.input, ':t:r') .. '.' .. formats.extension(to)
              return { argv = argv, output = vim.fs.joinpath(ctx.workdir, name) }
            end,
          }
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Pandoc
---------------------------------------------------------------------------------------------------

local PANDOC_READ =
  { md = 'markdown', html = 'html', docx = 'docx', odt = 'odt', epub = 'epub', rtf = 'rtf', fb2 = 'fb2' }
local PANDOC_WRITE = {
  { 'html', 'html5' },
  { 'docx', 'docx' },
  { 'pdf', 'pdf' },
  { 'odt', 'odt' },
  { 'epub', 'epub3' },
  { 'md', 'gfm' },
  { 'rtf', 'rtf' },
  { 'txt', 'plain' },
  { 'fb2', 'fb2' },
}

local function pandoc_recipes(from, tool, out)
  local reader = PANDOC_READ[from]
  if not reader or not (tool.readers or {})[reader] then
    return
  end
  for _, pair in ipairs(PANDOC_WRITE) do
    local to, writer = pair[1], pair[2]
    local ok = to ~= from
    if to == 'pdf' then
      ok = ok and tool.pdf_engine ~= nil
    else
      ok = ok and (tool.writers or {})[writer]
    end
    if ok then
      out[#out + 1] = {
        key = to,
        to = to,
        tool = 'pandoc',
        note = to == 'pdf' and ('with ' .. tool.pdf_engine) or nil,
        build = function(ctx)
          local output = vim.fs.joinpath(ctx.workdir, 'out.' .. formats.extension(to))
          local argv = { tool.path, '--from', reader }
          if to == 'pdf' then
            vim.list_extend(argv, { '--pdf-engine', tool.pdf_engine_path })
          else
            vim.list_extend(argv, { '--to', writer })
          end
          if to == 'html' then
            vim.list_extend(argv, { '--standalone', '--metadata', 'pagetitle=' .. ctx.stem })
          end
          if to == 'md' then
            argv[#argv + 1] = '--wrap=none'
          end
          vim.list_extend(argv, { '--output', output, '--', ctx.input })
          return { argv = argv, output = output }
        end,
      }
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Ghostscript
---------------------------------------------------------------------------------------------------

local function gs_recipes(from, tool, out)
  if from == 'pdf' then
    out[#out + 1] = {
      key = 'pdf',
      to = 'pdf',
      tool = 'gs',
      variant = 'smaller',
      suffix = '-compressed',
      must_shrink = true,
      build = function(ctx)
        local output = vim.fs.joinpath(ctx.workdir, 'out.pdf')
        return {
          argv = {
            tool.path,
            '-sDEVICE=pdfwrite',
            '-dCompatibilityLevel=1.5',
            '-dPDFSETTINGS=/ebook',
            '-dSAFER',
            '-dNOPAUSE',
            '-dBATCH',
            '-dQUIET',
            -- `%` would start a page number in Ghostscript's output name.
            '-sOutputFile=' .. output:gsub('%%', '%%%%'),
            '--',
            ctx.input,
          },
          output = output,
        }
      end,
    }
  elseif from == 'eps' then
    out[#out + 1] = {
      key = 'pdf',
      to = 'pdf',
      tool = 'gs',
      build = function(ctx)
        local output = vim.fs.joinpath(ctx.workdir, 'out.pdf')
        return {
          argv = {
            tool.path,
            '-sDEVICE=pdfwrite',
            '-dEPSCrop',
            '-dSAFER',
            '-dNOPAUSE',
            '-dBATCH',
            '-dQUIET',
            '-sOutputFile=' .. output:gsub('%%', '%%%%'),
            '--',
            ctx.input,
          },
          output = output,
        }
      end,
    }
  end
end

---------------------------------------------------------------------------------------------------
-- Tesseract
---------------------------------------------------------------------------------------------------

local function tesseract_recipes(from, tool, out)
  if not (tool.images or {})[from] then
    return
  end
  for _, spec in ipairs({ { 'txt', 'txt', nil }, { 'pdf', 'pdf:ocr', 'pdf' } }) do
    local to, key, config_name = spec[1], spec[2], spec[3]
    out[#out + 1] = {
      key = key,
      to = to,
      tool = 'tesseract',
      variant = to == 'pdf' and 'searchable, text recognition' or 'text recognition',
      build = function(ctx)
        local base = vim.fs.joinpath(ctx.workdir, 'out')
        local argv = { tool.path, ctx.input, base, '-l', tools.ocr_language(tool) }
        if config_name then
          argv[#argv + 1] = config_name
        end
        return { argv = argv, output = base .. '.' .. to }
      end,
    }
  end
end

---------------------------------------------------------------------------------------------------

local BUILDERS = {
  magick = magick_recipes,
  ffmpeg = ffmpeg_recipes,
  soffice = office_recipes,
  pandoc = pandoc_recipes,
  gs = gs_recipes,
  tesseract = tesseract_recipes,
}
-- When two programs make the same format, the first one is used by `:ConverterStudio <format>`:
-- LibreOffice keeps an office document's layout, Pandoc reads Markdown, HTML and e-books better.
local PREFERENCE = { 'magick', 'ffmpeg', 'soffice', 'pandoc', 'gs', 'tesseract' }
local PANDOC_FIRST = set({ 'md', 'html', 'epub', 'fb2' })

--- The local conversions of a file of format `from`, with the programs `found`, in order:
--- `{ { key, to, tool, variant?, build | run }, … }`. Keys are unique (`pdf`, `pdf:ocr`).
function M.for_format(from, found)
  local all = {}
  for _, recipe in ipairs(require('converter-studio.builtin').recipes(from)) do
    all[#all + 1] = recipe
  end
  local order = PREFERENCE
  if PANDOC_FIRST[from] then
    order = { 'magick', 'ffmpeg', 'pandoc', 'soffice', 'gs', 'tesseract' }
  end
  for _, name in ipairs(order) do
    if found[name] and BUILDERS[name] then
      BUILDERS[name](from, found[name], all)
    end
  end
  local seen, out = {}, {}
  for _, recipe in ipairs(all) do
    if not seen[recipe.key] then
      seen[recipe.key] = true
      out[#out + 1] = recipe
    end
  end
  return out
end

--- Where a recipe runs, for people: `ImageMagick`, `built in`.
function M.where(recipe)
  if recipe.tool == 'builtin' then
    return 'built in'
  end
  return tools.NAMES[recipe.tool] or recipe.tool
end

--- A program that would add this conversion, for the message when none is installed.
function M.hint(from, to)
  local cat_from, cat_to = formats.category(from), formats.category(to)
  if cat_from == 'video' or cat_from == 'audio' then
    return 'FFmpeg'
  end
  if from == 'pdf' and to == 'pdf' then
    return 'Ghostscript'
  end
  if (cat_from == 'image' or cat_from == 'vector') and to == 'txt' then
    return 'Tesseract'
  end
  if cat_from == 'image' or cat_from == 'vector' then
    return from == 'heic' and 'ImageMagick with HEIC support (libheif)' or 'ImageMagick'
  end
  if from == 'md' or to == 'md' or cat_from == 'ebook' then
    return 'Pandoc'
  end
  if cat_from == 'document' or cat_from == 'spreadsheet' or cat_from == 'presentation' or cat_to == 'document' then
    return 'LibreOffice'
  end
  return nil
end

return M
