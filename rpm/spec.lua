---@param spec string|RpmPluginSpec
---@param root string
---@return RpmPlugin
local function parse(spec, root)
  if type(spec) == "string" then
    spec = { spec }
  end
  assert(
    type(spec) == "table" and type(spec[1]) == "string",
    "plugin must be an owner/repository string or table"
  )
  local owner, repo = spec[1]:match("^([%w_.-]+)/([%w_.-]+)$")
  assert(
    owner and owner ~= "." and owner ~= ".." and repo ~= "." and repo ~= "..",
    "invalid plugin name: " .. spec[1]
  )
  assert(spec.opts == nil or type(spec.opts) == "table", "plugin opts must be a table: " .. spec[1])
  assert(
    spec.enabled == nil or type(spec.enabled) == "boolean",
    "plugin enabled must be a boolean: " .. spec[1]
  )
  assert(
    spec.version == nil
      or (
        type(spec.version) == "string"
        and (spec.version:match("^[%w][%w._/-]*$") or spec.version:match("^[%^~]%d+%.%d+%.%d+$"))
        and not spec.version:find("..", 1, true)
      ),
    "invalid plugin version: " .. spec[1]
  )
  assert(
    not spec.path or not spec.version,
    "version is not supported for local plugins: " .. spec[1]
  )
  assert(
    spec.path == nil or (type(spec.path) == "string" and spec.path:sub(1, 1) == "/"),
    "plugin path must be absolute: " .. spec[1]
  )
  assert(spec.entry == nil, "entry is no longer supported; use main: " .. spec[1])
  local main = spec.main or repo
  assert(
    type(main) == "string"
      and main:match("^[%w_-]+[.%w_-]*$")
      and not main:find("..", 1, true)
      and main:sub(-1) ~= ".",
    "invalid main module: " .. spec[1]
  )
  return {
    name = spec[1],
    url = "https://github.com/" .. spec[1] .. ".git",
    dir = spec.path or (root .. "/" .. owner .. "/" .. repo),
    parent = root .. "/" .. owner,
    opts = spec.opts or {},
    main = main,
    local_path = spec.path ~= nil,
    enabled = spec.enabled ~= false,
    version = spec.version,
  }
end

return parse
