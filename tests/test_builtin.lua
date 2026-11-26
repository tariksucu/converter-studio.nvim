local builtin = require('converter-studio.builtin')
local eq = MiniTest.expect.equality
local err = MiniTest.expect.error

local T = MiniTest.new_set()

T['csv'] = MiniTest.new_set()

T['csv']['parses quotes, commas, line breaks and CRLF'] = function()
  local rows = builtin.parse_csv('\239\187\191a,b\r\n"x, y","say ""hi"""\r\n"multi\nline",\n\n')
  eq(rows, { { 'a', 'b' }, { 'x, y', 'say "hi"' }, { 'multi\nline', '' } })
end

T['csv']['refuses an unclosed quote'] = function()
  err(function()
    builtin.parse_csv('a\n"open')
  end, 'not closed')
end

T['csv']['to JSON keeps the column order and the text of every value'] = function()
  local json = builtin.to_json(builtin.csv_records('name,age,name\nAda,036,x\nAlan\n'))
  eq(
    json,
    table.concat({
      '[',
      '  {',
      '    "name": "Ada",',
      '    "age": "036",',
      '    "name_2": "x"',
      '  },',
      '  {',
      '    "name": "Alan",',
      '    "age": "",',
      '    "name_2": ""',
      '  }',
      ']',
      '',
    }, '\n')
  )
  -- Neovim's own decoder reads it back.
  eq(vim.json.decode(json)[1].age, '036')
end

T['csv']['to YAML quotes what YAML would read as another type'] = function()
  local yaml = builtin.to_yaml(builtin.csv_records('k,v\nyes,1.5\nplain text,: colon\n'))
  eq(yaml, '- k: "yes"\n  v: "1.5"\n- k: plain text\n  v: ": colon"\n')
end

T['json'] = MiniTest.new_set()

T['json']['decodes in order, with escapes and the text of numbers'] = function()
  local v = builtin.decode_json('{"b": 1.50, "a": "\\u00e9\\ud83d\\ude00\\n", "c": [true, null, {}]}')
  eq(v.keys, { 'b', 'a', 'c' })
  eq(v.values.b, { kind = 'number', text = '1.50' })
  eq(v.values.a, 'é😀\n')
  eq(v.values.c[1], true)
  eq(v.values.c[2], builtin.NULL)
end

T['json']['says where the JSON is broken'] = function()
  err(function()
    builtin.decode_json('{\n  "a": tru\n}')
  end, 'line 2, column 8')
end

T['json']['to CSV: columns in order of appearance, nested values as JSON'] = function()
  local csv = builtin.json_to_csv('[{"id": 1, "tags": ["a","b"]}, {"id": 2, "name": "x,y", "ok": false, "n": null}]')
  eq(csv, 'id,tags,name,ok,n\r\n1,"[""a"",""b""]",,,\r\n2,,"x,y",false,\r\n')
end

T['csv']['every column gets a name of its own'] = function()
  eq(builtin.column_names({ 'column2' }, 2), { 'column2', 'column2_2' })
  eq(builtin.column_names({ 'id', 'id', 'id_2' }, 3), { 'id', 'id_3', 'id_2' })
  eq(builtin.column_names({ '', 'column1' }, 2), { 'column1_2', 'column1' })
  eq(builtin.separator('\r\na;b\n'), ';')
  eq(builtin.separator('"a;b",c\n'), ',')
end

T['json']['numbers as JSON writes them, nothing else'] = function()
  for _, bad in ipairs({ '01', '1.', '.5', '1e', '+1', '-' }) do
    err(function()
      builtin.decode_json(bad)
    end)
  end
  eq(builtin.decode_json('-0.10e+2'), { kind = 'number', text = '-0.10e+2' })
end

-- The cases every editor plugin runs (the same file in the VS Code, JetBrains and Sublime ones).
T['shared data cases'] = function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local file = assert(io.open(root .. '/data-cases.json', 'rb'))
  local cases = vim.json.decode(file:read('*a')).cases
  file:close()
  local convert = {
    ['csv>json'] = function(t)
      return builtin.to_json(builtin.csv_records(t))
    end,
    ['csv>yaml'] = function(t)
      return builtin.to_yaml(builtin.csv_records(t))
    end,
    ['json>csv'] = builtin.json_to_csv,
    ['json>yaml'] = function(t)
      return builtin.to_yaml(builtin.decode_json(t))
    end,
  }
  local failed = {}
  for _, case in ipairs(cases) do
    local name = ('%s to %s: %s'):format(case.from, case.to, case.name)
    local ok, out = pcall(convert[case.from .. '>' .. case.to], case.input)
    if case.error then
      if ok then
        failed[#failed + 1] = name .. ' (not refused)'
      end
    elseif not ok then
      failed[#failed + 1] = name .. ': ' .. tostring(out)
    elseif out ~= case.output then
      failed[#failed + 1] = ('%s\n  expected %q\n  got      %q'):format(name, case.output, out)
    end
  end
  eq(table.concat(failed, '\n'), '')
  eq(#cases, 48)
end

T['json']['to CSV refuses what is not a list of objects'] = function()
  err(function()
    builtin.json_to_csv('[1, 2]')
  end, 'array of objects')
end

T['json']['to YAML'] = function()
  local yaml = builtin.to_yaml(
    builtin.decode_json('{"name": "x", "n": 2, "list": [{"a": 1, "b": [true]}, "s"], "empty": {}, "null": null}')
  )
  -- `n` and `null` are quoted: some YAML readers take them for false and nothing.
  eq(yaml, 'name: x\n"n": 2\nlist:\n  - a: 1\n    b:\n      - true\n  - s\nempty: {}\n"null": null\n')
end

T['subtitles'] = MiniTest.new_set()

T['subtitles']['SRT to WebVTT'] = function()
  local vtt = builtin.srt_to_vtt(
    '1\r\n00:00:01,000 --> 00:00:02,500\r\n<font color="red">Hello</font>\r\n\r\n2\r\n00:01:03,040 --> 00:01:04,000\r\n<i>World</i>\r\nline two\r\n'
  )
  eq(vtt, 'WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n00:01:03.040 --> 00:01:04.000\n<i>World</i>\nline two\n')
end

T['subtitles']['WebVTT to SRT: short times, notes, settings and voice tags'] = function()
  local srt = builtin.vtt_to_srt(
    'WEBVTT - title\n\nNOTE a comment\n\nintro\n01:02.5 --> 01:04.000 align:start\n<v Ada>Hi</v> <c.big>there</c>\n\n00:00:05.000 --> 00:00:06.000\n<b>Bye</b>\n'
  )
  eq(srt, '1\n00:01:02,500 --> 00:01:04,000\nHi there\n\n2\n00:00:05,000 --> 00:00:06,000\n<b>Bye</b>\n')
end

T['subtitles']['WebVTT must start with WEBVTT'] = function()
  err(function()
    builtin.vtt_to_srt('00:00:01.000 --> 00:00:02.000\nx\n')
  end, 'WEBVTT')
end

T['recipes are offered only for their formats'] = function()
  local keys = function(from)
    return vim.tbl_map(function(r)
      return r.key
    end, builtin.recipes(from))
  end
  eq(keys('csv'), { 'json', 'yaml' })
  eq(keys('json'), { 'csv', 'yaml' })
  eq(keys('srt'), { 'vtt' })
  eq(keys('vtt'), { 'srt' })
  eq(keys('png'), {})
end

return T
