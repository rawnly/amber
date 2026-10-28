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
    return nil, (result.stderr ~= "" and result.stderr) or ("exit status " .. tostring(result.code))
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

return { run = run, exists = exists }
