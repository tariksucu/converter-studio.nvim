-- Hands files to the Converter Studio desktop app through its link:
-- converter-studio://convert?to=<format>&from=neovim&file=<path>[&file=…]
-- The app shows a "Files from Neovim" card (Continue / Ignore), then the files in its Convert tab
-- with the format chosen; the person presses Convert there. Nothing is uploaded and nothing runs
-- by itself, and the app sends no answer back.

local config = require('converter-studio.config')

local M = {}

local is_windows = vim.fn.has('win32') == 1
local is_mac = vim.fn.has('mac') == 1

-- Windows cuts longer links; the app takes up to 200 files a link.
M.MAX_URL_LENGTH = 2000
M.MAX_FILES = 200

--- Percent-encodes like JavaScript's encodeURIComponent, but stricter: everything except
--- A-Z a-z 0-9 - _ . ~ (so `+ # & %` and every non-ASCII byte are encoded).
function M.encode(value)
  return (value:gsub('[^A-Za-z0-9%-_.~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- The link for `paths` (absolute) and format `to`.
function M.url(paths, to)
  local parts = { 'to=' .. M.encode(to), 'from=' .. M.encode(config.CLIENT) }
  for _, path in ipairs(paths) do
    parts[#parts + 1] = 'file=' .. M.encode(path)
  end
  return 'converter-studio://convert?' .. table.concat(parts, '&')
end

--- Whether a hand-off can reach the app: not over SSH and not inside WSL, where the files are not
--- on the computer the app runs on. Returns true, or false and why.
function M.available()
  if (vim.env.SSH_CONNECTION or '') ~= '' or (vim.env.SSH_TTY or '') ~= '' then
    return false, 'Neovim runs over SSH: the files are not on the computer where the desktop app runs'
  end
  if vim.fn.has('wsl') == 1 then
    return false, 'Neovim runs inside WSL: the desktop app cannot open its files'
  end
  return true
end

local function quiet(argv)
  local ok, obj = pcall(vim.system, argv, { text = true })
  if not ok then
    return nil
  end
  return obj:wait(5000)
end

--- Whether the app is installed: true, false, or nil when this system cannot tell.
--- Linux asks xdg-mime for the handler of converter-studio:// links, Windows the registry where
--- the app registers it, macOS the usual Applications folders.
function M.installed()
  if is_windows then
    for _, root in ipairs({ 'HKCU', 'HKLM' }) do
      local result = quiet({ 'reg', 'query', root .. '\\Software\\Classes\\converter-studio', '/ve' })
      if result and result.code == 0 then
        return true
      end
    end
    return false
  elseif is_mac then
    for _, dir in ipairs({ '/Applications', vim.fs.joinpath(vim.env.HOME or '', 'Applications') }) do
      if vim.uv.fs_stat(vim.fs.joinpath(dir, 'Converter Studio.app')) then
        return true
      end
    end
    return nil
  end
  if vim.fn.executable('xdg-mime') == 1 then
    local result = quiet({ 'xdg-mime', 'query', 'default', 'x-scheme-handler/converter-studio' })
    if result then
      return vim.trim(result.stdout or '') ~= ''
    end
  end
  return nil
end

function M.requirement()
  return ('Converter Studio for desktop %s or later (%s)'):format(config.DESKTOP_MIN_VERSION, config.DESKTOP_URL)
end

--- The command that opens the link on Windows, where `vim.ui.open` goes through
--- `cmd.exe /c start` in recent Neovim versions and cmd.exe would cut the link at its first `&`.
--- Elsewhere nil: `vim.ui.open` runs `open` or `xdg-open` without a shell.
function M.open_command(url)
  if is_windows then
    return { 'rundll32', 'url.dll,FileProtocolHandler', url }
  end
  return nil
end

--- Opens the link with the system. `cb(err)`.
function M.handoff(paths, to, cb)
  local ok_here, why = M.available()
  if not ok_here then
    return cb(why)
  end
  if #paths > M.MAX_FILES then
    return cb(('the desktop app takes up to %d files at once'):format(M.MAX_FILES))
  end
  if M.installed() == false then
    return cb(('the desktop app is not installed: this needs %s'):format(M.requirement()))
  end
  local url = M.url(paths, to)
  if is_windows and #url > M.MAX_URL_LENGTH then
    return cb('the file path is too long for a link to the desktop app')
  end
  local argv = M.open_command(url)
  local ok, obj, err
  if argv then
    ok, obj = pcall(vim.system, argv, { detach = true })
  else
    ok, obj, err = pcall(vim.ui.open, url)
  end
  if not ok then
    return cb(tostring(obj))
  end
  if not obj then
    return cb(err or 'the system could not open the link')
  end
  cb(nil)
end

return M
