-- File formats by the ids Converter Studio's API uses (`GET /v1/formats`), so that a local
-- conversion, the desktop app and the cloud all name a format the same way.

local M = {}

-- id = { label, category, extensions (the first is the one written) }
M.list = {
  jpg = { 'JPG', 'image', { 'jpg', 'jpeg', 'jpe', 'jfif' } },
  png = { 'PNG', 'image', { 'png' } },
  webp = { 'WebP', 'image', { 'webp' } },
  heic = { 'HEIC', 'image', { 'heic', 'heif' } },
  avif = { 'AVIF', 'image', { 'avif' } },
  gif = { 'GIF', 'image', { 'gif' } },
  bmp = { 'BMP', 'image', { 'bmp' } },
  tiff = { 'TIFF', 'image', { 'tiff', 'tif' } },
  ico = { 'ICO', 'image', { 'ico' } },
  cr2 = { 'CR2', 'image', { 'cr2' } },
  nef = { 'NEF', 'image', { 'nef' } },
  arw = { 'ARW', 'image', { 'arw' } },
  dng = { 'DNG', 'image', { 'dng' } },
  mp4 = { 'MP4', 'video', { 'mp4', 'm4v' } },
  mov = { 'MOV', 'video', { 'mov', 'qt' } },
  mkv = { 'MKV', 'video', { 'mkv' } },
  avi = { 'AVI', 'video', { 'avi' } },
  webm = { 'WebM', 'video', { 'webm' } },
  flv = { 'FLV', 'video', { 'flv' } },
  ['3gp'] = { '3GP', 'video', { '3gp', '3g2' } },
  wmv = { 'WMV', 'video', { 'wmv' } },
  mp3 = { 'MP3', 'audio', { 'mp3' } },
  wav = { 'WAV', 'audio', { 'wav' } },
  m4a = { 'M4A', 'audio', { 'm4a' } },
  aac = { 'AAC', 'audio', { 'aac' } },
  flac = { 'FLAC', 'audio', { 'flac' } },
  ogg = { 'OGG', 'audio', { 'ogg', 'oga' } },
  opus = { 'Opus', 'audio', { 'opus' } },
  wma = { 'WMA', 'audio', { 'wma' } },
  aiff = { 'AIFF', 'audio', { 'aiff', 'aif' } },
  pdf = { 'PDF', 'document', { 'pdf' } },
  docx = { 'DOCX', 'document', { 'docx' } },
  doc = { 'DOC', 'document', { 'doc' } },
  odt = { 'ODT', 'document', { 'odt' } },
  rtf = { 'RTF', 'document', { 'rtf' } },
  txt = { 'TXT', 'document', { 'txt', 'text' } },
  md = { 'Markdown', 'document', { 'md', 'markdown' } },
  html = { 'HTML', 'document', { 'html', 'htm' } },
  xlsx = { 'XLSX', 'spreadsheet', { 'xlsx' } },
  xls = { 'XLS', 'spreadsheet', { 'xls' } },
  ods = { 'ODS', 'spreadsheet', { 'ods' } },
  csv = { 'CSV', 'spreadsheet', { 'csv' } },
  pptx = { 'PPTX', 'presentation', { 'pptx' } },
  ppt = { 'PPT', 'presentation', { 'ppt' } },
  odp = { 'ODP', 'presentation', { 'odp' } },
  json = { 'JSON', 'data', { 'json' } },
  xml = { 'XML', 'data', { 'xml' } },
  yaml = { 'YAML', 'data', { 'yaml', 'yml' } },
  epub = { 'EPUB', 'ebook', { 'epub' } },
  mobi = { 'MOBI', 'ebook', { 'mobi' } },
  azw3 = { 'AZW3', 'ebook', { 'azw3' } },
  fb2 = { 'FB2', 'ebook', { 'fb2' } },
  srt = { 'SRT', 'subtitle', { 'srt' } },
  vtt = { 'WebVTT', 'subtitle', { 'vtt' } },
  ass = { 'ASS', 'subtitle', { 'ass', 'ssa' } },
  zip = { 'ZIP', 'archive', { 'zip' } },
  ['7z'] = { '7Z', 'archive', { '7z' } },
  rar = { 'RAR', 'archive', { 'rar' } },
  tar = { 'TAR', 'archive', { 'tar' } },
  tgz = { 'TAR.GZ', 'archive', { 'tar.gz', 'tgz' } },
  ttf = { 'TTF', 'font', { 'ttf' } },
  otf = { 'OTF', 'font', { 'otf' } },
  woff = { 'WOFF', 'font', { 'woff' } },
  woff2 = { 'WOFF2', 'font', { 'woff2' } },
  svg = { 'SVG', 'vector', { 'svg' } },
  eps = { 'EPS', 'vector', { 'eps' } },
  ai = { 'AI', 'vector', { 'ai' } },
}

local by_extension = {}
for id, spec in pairs(M.list) do
  for _, ext in ipairs(spec[3]) do
    by_extension[ext] = id
  end
end

--- The format id of a file, from its name (`photo.HEIC` → `heic`, `a.tar.gz` → `tgz`), or nil.
function M.of(path)
  local name = vim.fs.basename(path):lower()
  local double = name:match('%.([^.]+%.[^.]+)$')
  if double and by_extension[double] then
    return by_extension[double]
  end
  local ext = name:match('%.([^.]+)$')
  return ext and by_extension[ext] or nil
end

--- A format's name for people (`webp` → `WebP`); unknown ids in capitals.
function M.label(id)
  local spec = M.list[id]
  return spec and spec[1] or id:upper()
end

function M.category(id)
  local spec = M.list[id]
  return spec and spec[2] or nil
end

--- The extension a file of this format is written with (`jpg`, `tar.gz`).
function M.extension(id)
  local spec = M.list[id]
  return spec and spec[3][1] or id
end

--- `photo.HEIC` → `photo`, `backup.tar.gz` → `backup`, `.bashrc` → `.bashrc`.
function M.stem(path)
  local name = vim.fs.basename(path)
  local lower = name:lower()
  local double = lower:match('%.([^.]+%.[^.]+)$')
  if double and by_extension[double] then
    return name:sub(1, #name - #double - 1)
  end
  local stem = name:match('^(.+)%.[^.]+$')
  return stem or name
end

return M
