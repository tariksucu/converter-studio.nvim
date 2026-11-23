-- Work folders and result names. A result never replaces a file: `photo.webp` is taken, so the
-- result becomes `photo (2).webp`, then `photo (3).webp`…

local uv = vim.uv

local M = {}

local function exists(path)
  return uv.fs_lstat(path) ~= nil
end

--- `name.ext`, `name (2).ext`, `name (3).ext`… for the n-th try.
function M.numbered(dir, base, ext, n)
  local name = n == 1 and base or ('%s (%d)'):format(base, n)
  return vim.fs.joinpath(dir, ext ~= '' and (name .. '.' .. ext) or name)
end

--- The first free name in `dir` for `base.ext` (checked again when the file is placed).
function M.free_name(dir, base, ext)
  for n = 1, 10000 do
    local path = M.numbered(dir, base, ext, n)
    if not exists(path) then
      return path
    end
  end
  error('no free file name for ' .. base, 0)
end

local function random_hex(bytes)
  local ok, data = pcall(uv.random, bytes)
  if not ok or not data then
    data = tostring(uv.hrtime()) .. tostring(math.random())
  end
  return (data:gsub('.', function(c)
    return ('%02x'):format(c:byte())
  end)):sub(1, bytes * 2)
end
M.random_hex = random_hex

--- A new hidden folder next to the source for the program's output: the result is moved from it
--- without copying (same file system), and a large video does not fill a small /tmp.
function M.workdir(dir)
  for _ = 1, 20 do
    local path = vim.fs.joinpath(dir, '.converter-studio-' .. random_hex(6))
    local ok, err = uv.fs_mkdir(path, 448) -- 0700
    if ok then
      return path
    end
    if not tostring(err):match('^EEXIST') then
      return nil, ('cannot write in %s (%s)'):format(dir, tostring(err))
    end
  end
  return nil, 'cannot make a work folder in ' .. dir
end

--- Deletes a work folder and everything in it.
function M.remove(path)
  if path and exists(path) then
    vim.fn.delete(path, 'rf')
  end
end

--- Moves `from` to the first free name for `base.ext` in `dir`, never replacing a file that is
--- there (a hard link fails if the name is taken; across file systems an exclusive copy does).
--- Returns the new path.
function M.place(from, dir, base, ext)
  for n = 1, 10000 do
    local target = M.numbered(dir, base, ext, n)
    if not exists(target) then
      local ok, err = uv.fs_link(from, target)
      if ok then
        uv.fs_unlink(from)
        return target
      end
      err = tostring(err)
      if not err:match('^EEXIST') then
        ok, err = uv.fs_copyfile(from, target, { excl = true })
        if ok then
          uv.fs_unlink(from)
          return target
        end
        err = tostring(err)
        if not err:match('^EEXIST') then
          return nil, ('cannot save %s (%s)'):format(vim.fs.basename(target), err)
        end
      end
    end
  end
  return nil, 'no free file name for ' .. base
end

--- A name the API gave (`report-compressed.pdf`) as a plain file name in this folder.
function M.safe_name(name)
  name = vim.fs.basename((name or ''):gsub('\\', '/') .. '')
  name = name:gsub('[%c<>:"/\\|?*]', '_') .. ''
  if name == '' or name == '.' or name == '..' then
    return nil
  end
  return name
end

return M
