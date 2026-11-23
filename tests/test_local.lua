-- Real conversions with the programs installed on this computer. A test whose program is missing
-- is skipped (the CI installs FFmpeg, Pandoc, ImageMagick, Ghostscript and Tesseract).
local cs = require('converter-studio')
local tools = require('converter-studio.tools')
local h = require('helpers')
local eq = MiniTest.expect.equality

local dir, notes, undo

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      cs.setup({})
      dir = h.tmpdir()
      local restore
      notes, restore = h.stub_notify()
      undo = { restore }
    end,
    post_case = function()
      for i = #undo, 1, -1 do
        undo[i]()
      end
      cs.setup({})
    end,
  },
})

local function need(name)
  local tool = tools.detect()[name]
  if not tool then
    MiniTest.skip(tools.NAMES[name] .. ' is not installed')
  end
  return tool
end

local function run(argv)
  local result = vim.system(argv, { text = true }):wait(60000)
  return result.code == 0, result.stderr
end

local function head(path, n)
  return (h.read(path) or ''):sub(1, n)
end

-- Only the source, the result and nothing hidden is left in the folder.
local function only(names)
  table.sort(names)
  eq(h.ls(dir), names)
end

T['FFmpeg: WAV to MP3, and a broken video fails with FFmpeg’s reason'] = function()
  local ffmpeg = need('ffmpeg')
  local wav = dir .. '/tone.wav'
  assert(
    run({ ffmpeg.path, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', wav })
  )
  local err, path = h.convert({ file = wav, to = 'mp3' })
  eq(err, nil)
  eq(path, dir .. '/tone.mp3')
  local bytes = head(path, 3)
  eq(bytes == 'ID3' or bytes:byte(1) == 0xFF, true)
  only({ 'tone.wav', 'tone.mp3' })

  local broken = h.write(dir .. '/broken.mp4', 'this is not a video')
  err = h.convert({ file = broken, to = 'mkv' })
  eq(err:match('^FFmpeg failed: ') ~= nil, true)
  only({ 'tone.wav', 'tone.mp3', 'broken.mp4' })
end

T['ImageMagick: PNG to WebP'] = function()
  local magick = need('magick')
  local png = dir .. '/red.png'
  assert(run({ magick.path, '-size', '40x20', 'xc:#cc0000', png }))
  local err, path = h.convert({ file = png, to = 'webp' })
  if not tools.detect().magick.formats.write.webp then
    eq(err:match('^nothing on this computer') ~= nil, true)
    return
  end
  eq(err, nil)
  local data = h.read(path)
  eq(data:sub(1, 4) .. data:sub(9, 12), 'RIFFWEBP')
  only({ 'red.png', 'red.webp' })
end

T['Pandoc: Markdown to HTML'] = function()
  need('pandoc')
  local md = h.write(dir .. '/notes.md', '# Title\n\nSome *text*.\n')
  local err, path = h.convert({ file = md, to = 'html' })
  eq(err, nil)
  local html = h.read(path)
  eq(html:find('<h1 id="title">Title</h1>', 1, true) ~= nil, true)
  eq(html:find('<title>notes</title>', 1, true) ~= nil, true)
  only({ 'notes.md', 'notes.html' })
end

T['LibreOffice: CSV to XLSX'] = function()
  need('soffice')
  local csv = h.write(dir .. '/table.csv', 'name,qty\napples,3\npears,5\n')
  -- Built in first: JSON; LibreOffice: XLSX.
  local err, path = h.convert({ file = csv, to = 'xlsx' }, 180000)
  eq(err, nil)
  eq(head(path, 2), 'PK')
  only({ 'table.csv', 'table.xlsx' })
end

-- A PDF written by hand: an uncompressed page of repeated text, which Ghostscript compresses.
local function plain_pdf()
  local content = ('BT /F1 12 Tf 72 720 Td (Converter Studio test page) Tj ET\n'):rep(400)
  local objects = {
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    ('<< /Length %d >>\nstream\n%sendstream'):format(#content, content),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  }
  local out = { '%PDF-1.4\n' }
  local offsets = {}
  local size = #out[1]
  for i, body in ipairs(objects) do
    offsets[i] = size
    local text = ('%d 0 obj\n%s\nendobj\n'):format(i, body)
    out[#out + 1] = text
    size = size + #text
  end
  local xref = { ('xref\n0 %d\n0000000000 65535 f \n'):format(#objects + 1) }
  for _, offset in ipairs(offsets) do
    xref[#xref + 1] = ('%010d 00000 n \n'):format(offset)
  end
  out[#out + 1] = table.concat(xref)
  out[#out + 1] = ('trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n'):format(#objects + 1, size)
  return table.concat(out)
end

T['Ghostscript: a smaller PDF next to the original'] = function()
  need('gs')
  local pdf = h.write(dir .. '/report.pdf', plain_pdf())
  local err, path = h.convert({ file = pdf, to = 'pdf' })
  eq(err, nil)
  eq(path, dir .. '/report-compressed.pdf')
  eq(head(path, 5), '%PDF-')
  eq(vim.uv.fs_stat(path).size < vim.uv.fs_stat(pdf).size, true)
  only({ 'report.pdf', 'report-compressed.pdf' })
  -- The compressed one cannot shrink again: no new file.
  err, path = h.convert({ file = dir .. '/report-compressed.pdf', to = 'pdf' })
  eq({ err, path }, { nil, nil })
  only({ 'report.pdf', 'report-compressed.pdf' })
end

T['Tesseract: text from an image'] = function()
  local tesseract = need('tesseract')
  local magick = need('magick')
  local png = dir .. '/scan.png'
  local ok = run({
    magick.path,
    '-size',
    '520x120',
    'xc:white',
    '-fill',
    'black',
    '-pointsize',
    '56',
    '-annotate',
    '+20+80',
    'Converter 2026',
    png,
  })
  if not ok or not (tesseract.images or {}).png then
    MiniTest.skip('no image with text could be made here')
  end
  local err, path = h.convert({ file = png, to = 'txt' })
  eq(err, nil)
  eq(h.read(path):find('Converter', 1, true) ~= nil, true)
end

if vim.fn.has('win32') == 0 then
  -- A stand-in for FFmpeg that answers the probes and then hangs.
  local function hanging_ffmpeg()
    local fake = dir .. '/bin/ffmpeg'
    vim.fn.mkdir(dir .. '/bin', 'p')
    h.write(
      fake,
      '#!/bin/sh\ncase "$*" in\n  *-encoders*) printf " A....D libmp3lame  MP3\\n" ;;\n  *-version*) echo "ffmpeg version 9.9" ;;\n  *) sleep 30 ;;\nesac\n'
    )
    vim.uv.fs_chmod(fake, 493)
    return fake
  end

  T['a program that runs too long is stopped (with what it started)'] = function()
    local fake = hanging_ffmpeg()
    cs.setup({ timeout = 1, tools = { ffmpeg = fake } })
    local wav = h.write(dir .. '/a.wav', 'RIFF')
    local started = vim.uv.hrtime()
    local err = h.convert({ file = wav, to = 'mp3' })
    eq(err, 'FFmpeg was stopped after 1 second (the timeout setting)')
    eq((vim.uv.hrtime() - started) / 1e9 < 8, true)
    only({ 'a.wav', 'bin' })
  end

  T[':ConverterStudio cancel stops a conversion'] = function()
    local fake = hanging_ffmpeg()
    cs.setup({ tools = { ffmpeg = fake } })
    local wav = h.write(dir .. '/a.wav', 'RIFF')
    local done, err = false, nil
    cs.convert({
      file = wav,
      to = 'mp3',
      on_done = function(e)
        done, err = true, e
      end,
    })
    vim.wait(200)
    vim.cmd('ConverterStudio cancel')
    vim.wait(8000, function()
      return done
    end)
    eq(err, 'canceled')
    only({ 'a.wav', 'bin' })
  end

  T['a failure on this computer offers the cloud, never takes it alone'] = function()
    local fake = dir .. '/bin/ffmpeg'
    vim.fn.mkdir(dir .. '/bin', 'p')
    h.write(
      fake,
      '#!/bin/sh\ncase "$*" in\n  *-encoders*) printf " A....D libmp3lame  MP3\\n" ;;\n  *-version*) echo "ffmpeg version 9.9" ;;\n  *) echo "Invalid data found when processing input" >&2; exit 1 ;;\nesac\n'
    )
    vim.uv.fs_chmod(fake, 493)
    cs.setup({ tools = { ffmpeg = fake } })
    local seen, restore = h.stub_select(function(labels)
      return #labels -- Do nothing
    end)
    undo[#undo + 1] = restore
    vim.cmd.edit(h.write(dir .. '/a.wav', 'RIFF'))
    vim.cmd('ConverterStudio mp3')
    vim.wait(5000, function()
      return #seen > 0
    end)
    eq(seen[1].prompt, 'Converting on this computer failed. What now?')
    eq(seen[1].labels, { 'Try in the cloud (uploads a.wav to converter.studio, uses credits)', 'Do nothing' })
    eq(notes[#notes].msg, 'Converter Studio: FFmpeg failed: Invalid data found when processing input')
    vim.cmd('bwipeout!')
    only({ 'a.wav', 'bin' })
  end
end

return T
