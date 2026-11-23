if vim.g.loaded_converter_studio then
  return
end
vim.g.loaded_converter_studio = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('converter-studio.nvim needs Neovim 0.10 or later', vim.log.levels.WARN)
  return
end

-- Loads nothing until the command is used.
vim.api.nvim_create_user_command('ConverterStudio', function(cmd)
  require('converter-studio').command(cmd.fargs)
end, {
  nargs = '*',
  desc = 'Convert the current file with Converter Studio',
  complete = function(arglead, line)
    return require('converter-studio').complete(arglead, line)
  end,
})

vim.keymap.set('n', '<Plug>(converter-studio)', function()
  require('converter-studio').pick()
end, { desc = 'Convert the current file with Converter Studio' })

-- Programs still converting when Neovim quits are stopped with it.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('converter-studio', { clear = true }),
  callback = function()
    if package.loaded['converter-studio.job'] then
      require('converter-studio.job').cancel_all()
    end
  end,
})
