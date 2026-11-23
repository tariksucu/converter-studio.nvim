std = 'luajit'
globals = { 'vim' }
max_line_length = 120
-- Long strings in tests (expected command lines and messages) are clearer on one line.
files['tests'] = { read_globals = { 'MiniTest' }, max_line_length = false }
files['e2e'] = { read_globals = { 'MiniTest' }, max_line_length = false }
