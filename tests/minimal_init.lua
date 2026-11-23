-- Test setup: this plugin and mini.test (deps/mini.test, or the folder in $MINI_TEST).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.env.MINI_TEST or (root .. '/deps/mini.test'))
package.path = ('%s/tests/?.lua;%s/tests/?/init.lua;'):format(root, root) .. package.path
vim.opt.swapfile = false
vim.cmd('runtime plugin/converter-studio.lua')
require('mini.test').setup()
