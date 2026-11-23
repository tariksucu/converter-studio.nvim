-- The argument lists each program gets (no program runs here).
local recipes = require('converter-studio.recipes')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local magick = {
  path = '/opt/im/magick',
  formats = {
    read = { jpeg = true, png = true, heic = true, webp = true, gif = true },
    write = { jpeg = true, png = true, webp = true, avif = true, pdf = true },
  },
}
local ffmpeg = { path = '/usr/bin/ffmpeg', encoders = { libx264 = true, aac = true, libmp3lame = true, gif = true } }
local soffice = { path = '/usr/bin/soffice' }
local pandoc = {
  path = '/usr/bin/pandoc',
  readers = { markdown = true, html = true, docx = true },
  writers = { html5 = true, docx = true, gfm = true, plain = true },
}
local gs = { path = '/usr/bin/gs' }
local tesseract = { path = '/usr/bin/tesseract', images = { png = true, jpg = true }, langs = { 'eng' } }
local all = { magick = magick, ffmpeg = ffmpeg, soffice = soffice, pandoc = pandoc, gs = gs, tesseract = tesseract }

local function keys(from, found)
  return vim.tbl_map(function(r)
    return r.key
  end, recipes.for_format(from, found or all))
end

local function find(from, key, found)
  for _, r in ipairs(recipes.for_format(from, found or all)) do
    if r.key == key then
      return r
    end
  end
end

local ctx = { input = '/home/me/photos/IMG 1.heic', workdir = '/home/me/photos/.converter-studio-ab', stem = 'IMG 1' }

T['targets depend on what each program can do'] = function()
  -- HEIC is readable, AVIF writable; HEIC itself is not writable here.
  eq(keys('heic'), { 'jpg', 'png', 'webp', 'avif', 'pdf' })
  -- Without ImageMagick nothing converts HEIC on this computer.
  eq(keys('heic', { ffmpeg = ffmpeg }), {})
  -- Tesseract adds text recognition; ImageMagick's PDF stays the plain `pdf`.
  eq(keys('png'), { 'jpg', 'webp', 'avif', 'pdf', 'txt', 'pdf:ocr' })
  -- FFmpeg only offers what its encoders can write (no libvpx-vp9, no libopus here).
  eq(keys('mov'), { 'mp4', 'mkv', 'gif', 'mp3', 'm4a', 'aac' })
  eq(keys('unknown'), {})
end

T['ImageMagick: first frame for still formats, white background for JPG'] = function()
  local spec = find('heic', 'jpg').build(ctx)
  eq(spec.argv, {
    '/opt/im/magick',
    '/home/me/photos/IMG 1.heic[0]',
    '-auto-orient',
    '-background',
    'white',
    '-alpha',
    'remove',
    '-alpha',
    'off',
    '-quality',
    '90',
    '/home/me/photos/.converter-studio-ab/out.jpg',
  })
  eq(spec.output, '/home/me/photos/.converter-studio-ab/out.jpg')
  -- An animated GIF stays animated in WebP.
  eq(find('gif', 'webp').build(ctx).argv[2], '/home/me/photos/IMG 1.heic')
end

T['FFmpeg: H.264 with AAC for MP4, audio only for MP3'] = function()
  local mp4 = find('mov', 'mp4').build(ctx)
  eq(
    vim.list_slice(mp4.argv, 1, 7),
    { '/usr/bin/ffmpeg', '-hide_banner', '-nostdin', '-loglevel', 'error', '-i', ctx.input }
  )
  eq(vim.tbl_contains(mp4.argv, 'libx264'), true)
  eq(vim.tbl_contains(mp4.argv, '+faststart'), true)
  eq(mp4.argv[#mp4.argv], ctx.workdir .. '/out.mp4')
  local mp3 = find('mov', 'mp3').build(ctx)
  eq(
    vim.list_slice(mp3.argv, 8),
    { '-vn', '-map', '0:a:0', '-c:a', 'libmp3lame', '-q:a', '2', ctx.workdir .. '/out.mp3' }
  )
end

T['LibreOffice: its own profile, the export filter, the output folder'] = function()
  local spec = find('docx', 'pdf').build({ input = '/w/Report v2.docx', workdir = '/w/.cs', stem = 'Report v2' })
  eq(spec.argv, {
    '/usr/bin/soffice',
    '-env:UserInstallation=file:///w/.cs/profile',
    '--headless',
    '--norestore',
    '--nolockcheck',
    '--nodefault',
    '--convert-to',
    'pdf',
    '--outdir',
    '/w/.cs',
    '/w/Report v2.docx',
  })
  eq(spec.output, '/w/.cs/Report v2.pdf')
  local csv = find('xlsx', 'csv').build({ input = '/w/a.xlsx', workdir = '/w/.cs', stem = 'a' })
  eq(csv.argv[8], 'csv:Text - txt - csv (StarCalc):44,34,76,1')
  eq(recipes._file_uri('/tmp/a b/é'), 'file:///tmp/a%20b/%C3%A9')
end

T['Office documents go to LibreOffice first, Markdown to Pandoc'] = function()
  eq(find('docx', 'docx'), nil)
  eq(find('docx', 'html').tool, 'pandoc') -- LibreOffice does not offer HTML here
  eq(find('html', 'docx').tool, 'pandoc')
  eq(find('md', 'html').tool, 'pandoc')
  eq(find('md', 'pdf'), nil) -- no PDF engine for Pandoc
  local with_engine = vim.tbl_extend('force', pandoc, { pdf_engine = 'typst', pdf_engine_path = '/usr/bin/typst' })
  local pdf = find('md', 'pdf', { pandoc = with_engine })
  eq(pdf.build({ input = '/w/a.md', workdir = '/w/.cs', stem = 'a' }).argv, {
    '/usr/bin/pandoc',
    '--from',
    'markdown',
    '--pdf-engine',
    '/usr/bin/typst',
    '--output',
    '/w/.cs/out.pdf',
    '--',
    '/w/a.md',
  })
end

T['Ghostscript: a smaller PDF, a % in the folder name is escaped'] = function()
  local recipe = find('pdf', 'pdf')
  eq(recipe.tool, 'gs')
  eq(recipe.must_shrink, true)
  eq(recipe.suffix, '-compressed')
  local spec = recipe.build({ input = '/w/100%/a.pdf', workdir = '/w/100%/.cs', stem = 'a' })
  eq(vim.tbl_contains(spec.argv, '-sOutputFile=/w/100%%/.cs/out.pdf'), true)
  eq(vim.tbl_contains(spec.argv, '-dSAFER'), true)
end

T['Tesseract: text and a searchable PDF'] = function()
  local spec = find('png', 'pdf:ocr').build({ input = '/w/scan.png', workdir = '/w/.cs', stem = 'scan' })
  eq(spec.argv, { '/usr/bin/tesseract', '/w/scan.png', '/w/.cs/out', '-l', 'eng', 'pdf' })
  eq(spec.output, '/w/.cs/out.pdf')
end

T['a hint names the program that would add a conversion'] = function()
  eq(recipes.hint('heic', 'jpg'), 'ImageMagick with HEIC support (libheif)')
  eq(recipes.hint('mkv', 'mp4'), 'FFmpeg')
  eq(recipes.hint('docx', 'pdf'), 'LibreOffice')
  eq(recipes.hint('pdf', 'pdf'), 'Ghostscript')
  eq(recipes.hint('png', 'txt'), 'Tesseract')
end

return T
