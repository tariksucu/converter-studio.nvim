-- Conversions written in Lua, with nothing to install: CSV and JSON to each other and to YAML,
-- and subtitles between SRT and WebVTT.

local M = {}

-- Larger files are left to the programs and the cloud: these run inside the editor.
M.MAX_BYTES = 20 * 1024 * 1024

---------------------------------------------------------------------------------------------------
-- CSV (RFC 4180)
---------------------------------------------------------------------------------------------------

--- Rows of fields. Quoted fields may hold commas, quotes ("") and line breaks.
function M.parse_csv(text, sep)
  sep = sep or ','
  text = text:gsub('^\239\187\191', '') -- byte order mark
  local rows, row, field = {}, {}, {}
  local i, n = 1, #text
  local quoted = false
  local function end_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end
  local function end_row()
    end_field()
    rows[#rows + 1] = row
    row = {}
  end
  while i <= n do
    local c = text:sub(i, i)
    if quoted then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          quoted = false
        end
      else
        field[#field + 1] = c
      end
    elseif c == '"' and #field == 0 then
      quoted = true
    elseif c == sep then
      end_field()
    elseif c == '\r' or c == '\n' then
      if c == '\r' and text:sub(i + 1, i + 1) == '\n' then
        i = i + 1
      end
      end_row()
    else
      field[#field + 1] = c
    end
    i = i + 1
  end
  if quoted then
    error('a quoted field is not closed', 0)
  end
  if #field > 0 or #row > 0 then
    end_row()
  end
  -- Blank lines are not records.
  local out = {}
  for _, r in ipairs(rows) do
    if not (#r == 1 and r[1] == '') then
      out[#out + 1] = r
    end
  end
  return out
end

local function csv_field(value)
  if value:find('[,"\r\n]') or value:match('^%s') or value:match('%s$') then
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

---------------------------------------------------------------------------------------------------
-- JSON that keeps the order of keys and the text of numbers
---------------------------------------------------------------------------------------------------

local NULL = { kind = 'null' }
M.NULL = NULL

local function decode_error(text, pos, what)
  local line, col = 1, 1
  for i = 1, math.min(pos - 1, #text) do
    if text:byte(i) == 10 then
      line, col = line + 1, 1
    else
      col = col + 1
    end
  end
  error(('JSON: %s at line %d, column %d'):format(what, line, col), 0)
end

local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function utf8_char(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

--- Objects are `{ kind = 'object', keys = {…}, values = {…} }`, arrays `{ kind = 'array', … }`,
--- numbers `{ kind = 'number', text = '1.50' }`, null `M.NULL`; strings and booleans as in Lua.
function M.decode_json(text)
  local pos = 1
  local function skip()
    pos = text:find('[^ \t\r\n]', pos) or #text + 1
  end
  local value
  local function string_at()
    local out = {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == '' then
        decode_error(text, pos, 'unfinished string')
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == '\\' then
        local e = text:sub(pos + 1, pos + 1)
        if ESCAPES[e] then
          out[#out + 1] = ESCAPES[e]
          pos = pos + 2
        elseif e == 'u' then
          local hex = text:sub(pos + 2, pos + 5)
          if not hex:match('^%x%x%x%x$') then
            decode_error(text, pos, 'bad \\u escape')
          end
          local code = tonumber(hex, 16)
          pos = pos + 6
          if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == '\\u' then
            local low = tonumber(text:sub(pos + 2, pos + 5), 16)
            if low and low >= 0xDC00 and low <= 0xDFFF then
              code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
              pos = pos + 6
            end
          end
          out[#out + 1] = utf8_char(code)
        else
          decode_error(text, pos, 'bad escape')
        end
      elseif c:byte() < 32 then
        decode_error(text, pos, 'control character in a string')
      else
        local stop = text:find('["\\%c]', pos) or #text + 1
        out[#out + 1] = text:sub(pos, stop - 1)
        pos = stop
      end
    end
  end
  function value()
    skip()
    local c = text:sub(pos, pos)
    if c == '{' then
      local obj = { kind = 'object', keys = {}, values = {} }
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == '}' then
        pos = pos + 1
        return obj
      end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then
          decode_error(text, pos, 'expected a key')
        end
        local key = string_at()
        skip()
        if text:sub(pos, pos) ~= ':' then
          decode_error(text, pos, 'expected ":"')
        end
        pos = pos + 1
        local v = value()
        if obj.values[key] == nil then
          obj.keys[#obj.keys + 1] = key
        end
        obj.values[key] = v
        skip()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == '}' then
          return obj
        elseif sep ~= ',' then
          decode_error(text, pos - 1, 'expected "," or "}"')
        end
      end
    elseif c == '[' then
      local arr = { kind = 'array' }
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == ']' then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        skip()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == ']' then
          return arr
        elseif sep ~= ',' then
          decode_error(text, pos - 1, 'expected "," or "]"')
        end
      end
    elseif c == '"' then
      return string_at()
    elseif text:sub(pos, pos + 3) == 'true' then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == 'false' then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == 'null' then
      pos = pos + 4
      return NULL
    else
      local num = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
      if not num or num == '' or num == '-' or not tonumber(num) then
        decode_error(text, pos, 'unexpected character')
      end
      pos = pos + #num
      return { kind = 'number', text = num }
    end
  end
  text = text:gsub('^\239\187\191', '')
  local result = value()
  skip()
  if pos <= #text then
    decode_error(text, pos, 'unexpected text after the value')
  end
  return result
end

local function json_string(s)
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or ('\\u%04x'):format(c:byte())
    end)
    .. '"'
end

local function is_node(v, kind)
  return type(v) == 'table' and v.kind == kind
end

--- Compact JSON text of a decoded value (for nested values in a CSV cell).
local function encode_compact(v)
  if type(v) == 'string' then
    return json_string(v)
  elseif type(v) == 'boolean' then
    return tostring(v)
  elseif v == NULL then
    return 'null'
  elseif is_node(v, 'number') then
    return v.text
  elseif is_node(v, 'array') then
    local parts = {}
    for i, item in ipairs(v) do
      parts[i] = encode_compact(item)
    end
    return '[' .. table.concat(parts, ',') .. ']'
  else
    local parts = {}
    for i, key in ipairs(v.keys) do
      parts[i] = json_string(key) .. ':' .. encode_compact(v.values[key])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
end

---------------------------------------------------------------------------------------------------
-- YAML (block style)
---------------------------------------------------------------------------------------------------

local RESERVED = {
  ['true'] = true,
  ['false'] = true,
  ['null'] = true,
  ['~'] = true,
  yes = true,
  no = true,
  on = true,
  off = true,
  y = true,
  n = true,
}

local function yaml_scalar(s)
  local plain = s ~= ''
    and s:match('^[%w_/][%w_%./%-%+ ]*$')
    and not s:match('%s$')
    and not RESERVED[s:lower()]
    and not tonumber(s)
    and not s:match('^0[xob]')
    and not s:match('^[%d_%.%-:]+$')
  if plain then
    return s
  end
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or ('\\x%02x'):format(c:byte())
    end)
    .. '"'
end

local function yaml_lines(v, indent, out)
  local pad = (' '):rep(indent)
  local function inline(x)
    if type(x) == 'string' then
      return yaml_scalar(x)
    elseif type(x) == 'boolean' then
      return tostring(x)
    elseif x == NULL then
      return 'null'
    elseif is_node(x, 'number') then
      return x.text
    elseif is_node(x, 'array') and #x == 0 then
      return '[]'
    elseif is_node(x, 'object') and #x.keys == 0 then
      return '{}'
    end
    return nil
  end
  if is_node(v, 'object') then
    for _, key in ipairs(v.keys) do
      local child = v.values[key]
      local simple = inline(child)
      if simple then
        out[#out + 1] = pad .. yaml_scalar(key) .. ': ' .. simple
      else
        out[#out + 1] = pad .. yaml_scalar(key) .. ':'
        yaml_lines(child, indent + 2, out)
      end
    end
  elseif is_node(v, 'array') then
    for _, item in ipairs(v) do
      local simple = inline(item)
      if simple then
        out[#out + 1] = pad .. '- ' .. simple
      else
        -- The first line of the nested block goes after the dash.
        local nested = {}
        yaml_lines(item, indent + 2, nested)
        nested[1] = pad .. '- ' .. nested[1]:sub(indent + 3)
        vim.list_extend(out, nested)
      end
    end
  else
    out[#out + 1] = pad .. inline(v)
  end
end

function M.to_yaml(v)
  local out = {}
  yaml_lines(v, 0, out)
  return table.concat(out, '\n') .. '\n'
end

---------------------------------------------------------------------------------------------------
-- Records: CSV ↔ JSON
---------------------------------------------------------------------------------------------------

--- CSV text → an array of objects (the first row names the keys; every value stays text).
function M.csv_records(text)
  local rows = M.parse_csv(text)
  if #rows == 0 then
    error('the CSV file is empty', 0)
  end
  local header, seen = {}, {}
  local width = 0
  for _, row in ipairs(rows) do
    width = math.max(width, #row)
  end
  for i = 1, width do
    local name = vim.trim(rows[1][i] or '')
    if name == '' then
      name = 'column ' .. i
    end
    local unique, n = name, 1
    while seen[unique] do
      n = n + 1
      unique = ('%s (%d)'):format(name, n)
    end
    seen[unique] = true
    header[i] = unique
  end
  local records = { kind = 'array' }
  for r = 2, #rows do
    local obj = { kind = 'object', keys = header, values = {} }
    for i, key in ipairs(header) do
      obj.values[key] = rows[r][i] or ''
    end
    records[#records + 1] = obj
  end
  return records
end

local function json_pretty(v, indent, out)
  local pad = (' '):rep(indent)
  if is_node(v, 'array') and #v > 0 then
    out[#out + 1] = '['
    for i, item in ipairs(v) do
      out[#out + 1] = '\n' .. pad .. '  '
      json_pretty(item, indent + 2, out)
      if i < #v then
        out[#out + 1] = ','
      end
    end
    out[#out + 1] = '\n' .. pad .. ']'
  elseif is_node(v, 'object') and #v.keys > 0 then
    out[#out + 1] = '{'
    for i, key in ipairs(v.keys) do
      out[#out + 1] = '\n' .. pad .. '  ' .. json_string(key) .. ': '
      json_pretty(v.values[key], indent + 2, out)
      if i < #v.keys then
        out[#out + 1] = ','
      end
    end
    out[#out + 1] = '\n' .. pad .. '}'
  else
    out[#out + 1] = encode_compact(v)
  end
end

function M.to_json(v)
  local out = {}
  json_pretty(v, 0, out)
  return table.concat(out) .. '\n'
end

--- JSON (an array of objects, or one object) → CSV text; nested values become JSON text.
function M.json_to_csv(text)
  local data = M.decode_json(text)
  local list
  if is_node(data, 'array') then
    list = data
  elseif is_node(data, 'object') then
    list = { data }
  else
    error('JSON to CSV needs an array of objects', 0)
  end
  local columns, seen = {}, {}
  for _, item in ipairs(list) do
    if not is_node(item, 'object') then
      error(
        'JSON to CSV needs an array of objects (found ' .. (type(item) == 'table' and item.kind or type(item)) .. ')',
        0
      )
    end
    for _, key in ipairs(item.keys) do
      if not seen[key] then
        seen[key] = true
        columns[#columns + 1] = key
      end
    end
  end
  local lines = {}
  local head = {}
  for i, key in ipairs(columns) do
    head[i] = csv_field(key)
  end
  lines[1] = table.concat(head, ',')
  for _, item in ipairs(list) do
    local cells = {}
    for i, key in ipairs(columns) do
      local v = item.values[key]
      local cell
      if v == nil or v == NULL then
        cell = ''
      elseif type(v) == 'string' then
        cell = v
      elseif type(v) == 'boolean' then
        cell = tostring(v)
      elseif is_node(v, 'number') then
        cell = v.text
      else
        cell = encode_compact(v)
      end
      cells[i] = csv_field(cell)
    end
    lines[#lines + 1] = table.concat(cells, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

---------------------------------------------------------------------------------------------------
-- Subtitles: SRT ↔ WebVTT
---------------------------------------------------------------------------------------------------

local function blocks(text)
  text = text:gsub('^\239\187\191', ''):gsub('\r\n?', '\n')
  local out = {}
  for block in (text .. '\n\n'):gmatch('(.-)\n%s*\n') do
    if vim.trim(block) ~= '' then
      local lines = vim.split(block, '\n', { plain = true })
      while lines[1] and vim.trim(lines[1]) == '' do
        table.remove(lines, 1)
      end
      out[#out + 1] = lines
    end
  end
  return out
end

-- `1:02.5`, `00:01:02,500` → hours, minutes, seconds, milliseconds.
local function timestamp(s)
  local h, m, sec, ms = s:match('^(%d+):(%d%d):(%d%d)[,.](%d+)$')
  if not h then
    m, sec, ms = s:match('^(%d+):(%d%d)[,.](%d+)$')
    h = '0'
  end
  if not m then
    return nil
  end
  ms = (ms .. '000'):sub(1, 3)
  return tonumber(h), tonumber(m), tonumber(sec), tonumber(ms)
end

local function timing(line)
  local a, b, rest = line:match('^%s*([%d:,.]+)%s+%-%->%s+([%d:,.]+)(.*)$')
  if not a then
    return nil
  end
  local h1, m1, s1, ms1 = timestamp(a)
  local h2, m2, s2, ms2 = timestamp(b)
  if not h1 or not h2 then
    return nil
  end
  return { h1, m1, s1, ms1 }, { h2, m2, s2, ms2 }, rest
end

local function stamp(t, sep)
  return ('%02d:%02d:%02d%s%03d'):format(t[1], t[2], t[3], sep, t[4])
end

function M.srt_to_vtt(text)
  local out = { 'WEBVTT', '' }
  for _, lines in ipairs(blocks(text)) do
    local i = 1
    if not timing(lines[1]) and lines[2] and timing(lines[2]) then
      i = 2 -- the cue number
    end
    local from, to = timing(lines[i] or '')
    if from then
      out[#out + 1] = stamp(from, '.') .. ' --> ' .. stamp(to, '.')
      for j = i + 1, #lines do
        -- <font> is SRT only; <b>, <i> and <u> mean the same in both.
        out[#out + 1] = (lines[j]:gsub('</?font[^>]*>', ''))
      end
      out[#out + 1] = ''
    end
  end
  if #out == 2 then
    error('no subtitles found in the SRT file', 0)
  end
  return table.concat(out, '\n')
end

function M.vtt_to_srt(text)
  local list = blocks(text)
  if not list[1] or not list[1][1]:match('^WEBVTT') then
    error('a WebVTT file starts with "WEBVTT"', 0)
  end
  local out, n = {}, 0
  for b = 2, #list do
    local lines = list[b]
    local first = lines[1]
    if not (first:match('^NOTE') or first:match('^STYLE') or first:match('^REGION')) then
      local i = timing(first) and 1 or 2
      local from, to = timing(lines[i] or '')
      if from then
        n = n + 1
        out[#out + 1] = tostring(n)
        out[#out + 1] = stamp(from, ',') .. ' --> ' .. stamp(to, ',')
        for j = i + 1, #lines do
          local line = lines
            [j]
            :gsub('<%d[%d:.]*>', '') -- karaoke timestamps
            :gsub('</?[cv][^>]*>', '') -- classes and voices
            :gsub('</?lang[^>]*>', '')
            :gsub('</?ruby>', '')
            :gsub('</?rt>', '')
          out[#out + 1] = line
        end
        out[#out + 1] = ''
      end
    end
  end
  if n == 0 then
    error('no cues found in the WebVTT file', 0)
  end
  return table.concat(out, '\n')
end

---------------------------------------------------------------------------------------------------

local CONVERSIONS = {
  csv = {
    json = function(t)
      return M.to_json(M.csv_records(t))
    end,
    yaml = function(t)
      return M.to_yaml(M.csv_records(t))
    end,
  },
  json = {
    csv = M.json_to_csv,
    yaml = function(t)
      return M.to_yaml(M.decode_json(t))
    end,
  },
  srt = { vtt = M.srt_to_vtt },
  vtt = { srt = M.vtt_to_srt },
}
local ORDER = { 'json', 'csv', 'yaml', 'vtt', 'srt' }

--- The built-in conversions of a format, as recipes with `run(ctx)`.
function M.recipes(from)
  local list = {}
  local targets = CONVERSIONS[from]
  if not targets then
    return list
  end
  for _, to in ipairs(ORDER) do
    local fn = targets[to]
    if fn then
      list[#list + 1] = {
        key = to,
        to = to,
        tool = 'builtin',
        run = function(ctx)
          local stat = vim.uv.fs_stat(ctx.input)
          if stat and stat.size > M.MAX_BYTES then
            error('the file is larger than the built-in converter takes (20 MB)', 0)
          end
          local file = assert(io.open(ctx.input, 'rb'))
          local text = file:read('*a')
          file:close()
          local result = fn(text)
          local out = assert(io.open(ctx.output, 'wb'))
          out:write(result)
          out:close()
        end,
      }
    end
  end
  return list
end

return M
