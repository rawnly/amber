---@param argv string[]
---@param opts? RexExecOptions
---@return RexExecResult? result
---@return string? err
local function run(argv, opts)
  local result, err = rex.exec(argv, opts)
  if not result then
    return nil, err
  end
  if not result.ok then
    if result.timed_out then
      return nil, "command timed out"
    end
    if result.signal then
      return nil, "command terminated by " .. result.signal
    end
    local stderr = (result.stderr or ""):gsub("%s+$", "")
    return nil, stderr ~= "" and stderr or ("exit status " .. tostring(result.code))
  end
  return result
end

---@param path string
---@return boolean
local function exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

---@class RpmUtil
---@field run fun(argv: string[], opts?: RexExecOptions): RexExecResult?, string?
---@field exists fun(path: string): boolean
return { run = run, exists = exists }
