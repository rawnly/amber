---@type RpmUtil
local util = ...
local run = util.run

local M = {}

---@param path string
---@return table? data
---@return string? err
function M.read(path)
  local file, open_err = io.open(path, "r")
  if not file then
    local exists, check_err = rex.exec({ "test", "-e", path })
    if not exists then
      return nil, check_err
    end
    if exists.ok then
      return nil, open_err
    end
    if exists.code ~= 1 then
      return nil, "cannot inspect lockfile: " .. tostring(exists.stderr)
    end
    return { format = 1, plugins = {} }
  end
  local text, read_err = file:read("*a")
  file:close()
  if not text then
    return nil, "cannot read lockfile: " .. tostring(read_err)
  end
  local data, err = rex.json.decode(text)
  if not data then
    return nil, "invalid lockfile: " .. tostring(err)
  end
  if type(data) ~= "table" or data.format ~= 1 or type(data.plugins) ~= "table" then
    return nil, "invalid or unsupported RPM lockfile"
  end
  for name, entry in pairs(data.plugins) do
    if
      type(name) ~= "string"
      or type(entry) ~= "table"
      or type(entry.commit) ~= "string"
      or not entry.commit:match("^[0-9a-f]+$")
      or (#entry.commit ~= 40 and #entry.commit ~= 64)
      or (entry.version ~= nil and type(entry.version) ~= "string")
    then
      return nil, "invalid lockfile entry: " .. tostring(name)
    end
  end
  return data
end

---@param path string
---@param callback fun(data: table): any, string?, boolean?
---@return any result
---@return string? err
function M.transaction(path, callback)
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    parent = "/"
  end
  local result, err = run({ "mkdir", "-p", parent })
  if not result then
    return nil, err
  end
  local guard = path .. ".lock"
  local locked = run({ "mkdir", "--", guard })
  if not locked then
    return nil, "lockfile is busy: " .. guard
  end
  local ok, value, failure = pcall(function()
    local data, read_err = M.read(path)
    if not data then
      return nil, read_err
    end
    local value, callback_err, changed = callback(data)
    if not value then
      return nil, callback_err
    end
    if changed then
      local json, json_err = rex.json.encode(data, { indent = true })
      if not json then
        return nil, json_err
      end
      local temp, temp_err = run({ "mktemp", path .. ".tmp.XXXXXXXX" })
      if not temp then
        return nil, temp_err
      end
      local temp_path = temp.stdout:gsub("%s+$", "")
      local file, file_err = io.open(temp_path, "w")
      if not file then
        os.remove(temp_path)
        return nil, file_err
      end
      local wrote, write_err = file:write(json, "\n")
      local closed, close_err = file:close()
      if not wrote or not closed then
        os.remove(temp_path)
        return nil, write_err or close_err
      end
      local renamed, rename_err = os.rename(temp_path, path)
      if not renamed then
        os.remove(temp_path)
        return nil, rename_err
      end
    end
    return value
  end)
  local removed, remove_err = run({ "rmdir", "--", guard })
  if not removed then
    return nil, "cannot release lockfile guard: " .. tostring(remove_err)
  end
  if not ok then
    return nil, tostring(value)
  end
  return value, failure
end

return M
