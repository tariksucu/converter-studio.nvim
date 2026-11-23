-- Options: the defaults, `vim.g.converter_studio` and what `setup()` was given, merged in that order.

local M = {}

M.VERSION = '1.0.0'
-- Sent as `X-Converter-Studio-Client` with every request to the API.
M.CLIENT = 'neovim'
M.DEFAULT_API_URL = 'https://converter.studio/api'
-- The desktop app opens `converter-studio://convert` links from this version on (older versions
-- only come to the front).
M.DESKTOP_MIN_VERSION = '0.1.11'
M.DESKTOP_URL = 'https://converter.studio/download'
M.KEYS_URL = 'https://converter.studio/account#api-keys'

M.defaults = {
  -- Programs to use, by name: a path, or false to never use it. Unset: found on PATH and in the
  -- usual install folders.
  tools = {},
  -- Seconds a conversion on this computer may take before it is stopped.
  timeout = 1800,
  -- Tesseract's languages for text recognition ('eng', 'deu', 'eng+deu'…). Unset: English when
  -- installed, otherwise the first installed language.
  ocr_language = nil,
  desktop = {
    -- Use the Converter Studio desktop app when installed: formats no program on this computer
    -- converts are handed over to it (the file is shown in its Convert tab, nothing runs by itself).
    enabled = false,
  },
  cloud = {
    -- The API key of your Converter Studio account: a string, or a function that returns one.
    -- Unset: the environment variable CONVERTER_STUDIO_API_KEY. The plugin never writes it anywhere.
    api_key = nil,
    api_url = M.DEFAULT_API_URL,
    -- A cloud conversion that costs more credits than this asks first (0: always ask).
    max_credits = 20,
  },
}

local options

local TOOL_NAMES = { ffmpeg = true, soffice = true, pandoc = true, magick = true, gs = true, tesseract = true }

local function check(opts)
  vim.validate({
    tools = { opts.tools, 'table' },
    timeout = { opts.timeout, 'number' },
    ocr_language = { opts.ocr_language, 'string', true },
    desktop = { opts.desktop, 'table' },
    cloud = { opts.cloud, 'table' },
  })
  for name, value in pairs(opts.tools) do
    if not TOOL_NAMES[name] then
      error(('converter-studio: unknown tool "%s" in tools'):format(name), 0)
    end
    if value ~= false and type(value) ~= 'string' then
      error(('converter-studio: tools.%s must be a path or false'):format(name), 0)
    end
  end
  if opts.timeout <= 0 then
    error('converter-studio: timeout must be more than 0 seconds', 0)
  end
  vim.validate({
    ['desktop.enabled'] = { opts.desktop.enabled, 'boolean' },
    ['cloud.api_key'] = { opts.cloud.api_key, { 'string', 'function' }, true },
    ['cloud.api_url'] = { opts.cloud.api_url, 'string' },
    ['cloud.max_credits'] = { opts.cloud.max_credits, 'number' },
  })
  if opts.cloud.max_credits < 0 then
    error('converter-studio: cloud.max_credits must be 0 or more', 0)
  end
end

--- Merges `opts` over the defaults and `vim.g.converter_studio`; raises on a wrong option.
function M.set(opts)
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), vim.g.converter_studio or {}, opts or {})
  check(merged)
  options = merged
  return options
end

function M.get()
  return options or M.set()
end

--- `1 credit`, `30 credits`.
function M.credits(n)
  return ('%s credit%s'):format(tostring(n), tonumber(n) == 1 and '' or 's')
end

--- The API key and where it came from ('setup', 'environment'), or nil. Never logged.
function M.api_key()
  local configured = M.get().cloud.api_key
  if type(configured) == 'function' then
    local ok, value = pcall(configured)
    if ok and type(value) == 'string' and vim.trim(value) ~= '' then
      return vim.trim(value), 'setup'
    end
    return nil, 'setup'
  end
  if type(configured) == 'string' and vim.trim(configured) ~= '' then
    return vim.trim(configured), 'setup'
  end
  local env = vim.env.CONVERTER_STUDIO_API_KEY
  if type(env) == 'string' and vim.trim(env) ~= '' then
    return vim.trim(env), 'environment'
  end
  return nil, nil
end

--- The API's address without a trailing slash, or nil and why it is refused: the key only travels
--- over HTTPS (plain HTTP only to this computer, for a local test server).
function M.api_url()
  local url = vim.trim(M.get().cloud.api_url):gsub('/+$', '')
  local scheme, rest = url:match('^(%a[%w+.-]*)://(.+)$')
  local host = rest and (rest:match('^(%[[^%]]+%])') or rest:match('^([^/:?#@]+)'))
  if not scheme or not host or rest:match('^[^/?#]*@') then
    return nil, 'cloud.api_url must be a web address (https://…) without a user name'
  end
  scheme = scheme:lower()
  if scheme == 'https' then
    return url
  end
  host = host:lower()
  if scheme == 'http' and (host == 'localhost' or host == '127.0.0.1' or host == '[::1]') then
    return url
  end
  return nil, 'cloud.api_url must start with https:// (plain http only for localhost)'
end

return M
