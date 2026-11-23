-- What the programs report about themselves, parsed (real output, shortened).
local tools = require('converter-studio.tools')
local config = require('converter-studio.config')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.set({})
      tools.reset()
    end,
  },
})

T['ImageMagick formats: read and write separately'] = function()
  local can = tools.parse.magick_formats(table.concat({
    '   Format  Mode  Description',
    '-------------------------------------------------------------------------------',
    '     AVIF  rw+   AV1 Image File Format (1.17.6)',
    '      BMP* rw-   Microsoft Windows bitmap image',
    '     HEIC  r--   High Efficiency Image Format (1.17.6)',
    '     JPEG* rw-   Joint Photographic Experts Group JFIF format (libjpeg-turbo 2.1.5)',
    '      SVG  rw+   Scalable Vector Graphics (RSVG 2.58.0)',
    '      PDF  ---   Portable Document Format',
  }, '\n'))
  eq(can.read.heic, true)
  eq(can.write.heic, nil)
  eq(can.write.avif, true)
  eq(can.read.jpeg, true)
  eq(can.read.pdf, nil)
end

T['ImageMagick security policy: what it forbids is not offered'] = function()
  local formats = {
    read = { pdf = true, png = true, jpeg = true, ps = true },
    write = { pdf = true, png = true, jpeg = true, ps = true },
  }
  -- `convert -list policy` of Ubuntu's ImageMagick 6 (shortened).
  local rules = tools.parse.magick_policy(table.concat({
    'Path: /etc/ImageMagick-6/policy.xml',
    '  Policy: Resource',
    '    name: memory',
    '    value: 256MiB',
    '  Policy: Coder',
    '    rights: None ',
    '    pattern: PS',
    '  Policy: Coder',
    '    rights: Read ',
    '    pattern: PDF',
    'Path: [built-in]',
    '  Policy: Undefined',
    '    rights: None ',
  }, '\n'))
  tools.apply_policy(formats, rules)
  eq(formats.read, { pdf = true, png = true, jpeg = true })
  eq(formats.write, { png = true, jpeg = true })
  -- A web-safe policy: nothing, then four formats.
  local strict = tools.parse.magick_policy(
    '  Policy: Coder\n    rights: None\n    pattern: *\n  Policy: Coder\n    rights: Read Write\n    pattern: {GIF,JPEG,PNG,WEBP}\n'
  )
  local f = tools.apply_policy({ read = { png = true, heic = true }, write = { png = true, avif = true } }, strict)
  eq(f, { read = { png = true }, write = { png = true } })
end

T['FFmpeg encoders'] = function()
  local encoders = tools.parse.ffmpeg_encoders(table.concat({
    'Encoders:',
    ' V..... = Video',
    ' ------',
    ' V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)',
    ' V....D libvpx-vp9           libvpx VP9 (codec vp9)',
    ' A....D aac                  AAC (Advanced Audio Coding)',
    ' A....D pcm_s16le            PCM signed 16-bit little-endian',
  }, '\n'))
  eq(encoders, { libx264 = true, ['libvpx-vp9'] = true, aac = true, pcm_s16le = true })
end

T['Tesseract: image libraries and languages'] = function()
  local images = tools.parse.tesseract_images(
    'tesseract 5.3.4\n leptonica-1.82.0\n  libgif 5.2.1 : libjpeg 8d (libjpeg-turbo 2.1.5) : libpng 1.6.43 : libtiff 4.5.1 : zlib 1.3'
  )
  eq(images, { bmp = true, gif = true, jpg = true, png = true, tiff = true })
  eq(
    tools.parse.tesseract_langs('List of available languages in "/usr/share/tessdata/" (3):\neng\ndeu\nosd\n'),
    { 'eng', 'deu' }
  )
end

T['the OCR language: setting, then English, then the first installed'] = function()
  eq(tools.ocr_language({ langs = { 'deu', 'eng' } }), 'eng')
  eq(tools.ocr_language({ langs = { 'deu', 'fra' } }), 'deu')
  config.set({ ocr_language = 'tur+eng' })
  eq(tools.ocr_language({ langs = { 'eng' } }), 'tur+eng')
end

T['a program set to false is never used, a path is used as given'] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local fake = vim.fs.joinpath(dir, 'gs')
  local f = assert(io.open(fake, 'w'))
  f:write('#!/bin/sh\necho 10.05.0\n')
  f:close()
  vim.uv.fs_chmod(fake, 493) -- 0755
  config.set({ tools = { ffmpeg = false, gs = fake } })
  tools.reset()
  local found = tools.detect()
  eq(found.ffmpeg, nil)
  if vim.fn.has('win32') == 0 then
    eq(found.gs.path, fake)
    eq(found.gs.version, '10.05.0')
    eq(found.gs.configured, true)
  end
end

T['ImageMagick 6 is found as convert, not on Windows'] = function()
  local list = tools._candidates('magick')
  eq(list[1], 'magick')
  eq(vim.tbl_contains(list, 'convert'), vim.fn.has('win32') == 0)
end

T['unknown tool names in setup are refused'] = function()
  MiniTest.expect.error(function()
    config.set({ tools = { imagemagick = '/usr/bin/magick' } })
  end, 'unknown tool')
end

return T
