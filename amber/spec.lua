local function closest_option(key, options)
  if type(key) ~= "string" then
    return nil
  end
  local best, distance
  for _, option in ipairs(options) do
    local previous = {}
    for i = 0, #option do
      previous[i] = i
    end
    for i = 1, #key do
      local current = { [0] = i }
      for j = 1, #option do
        local cost = key:sub(i, i) == option:sub(j, j) and 0 or 1
        current[j] = math.min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
      end
      previous = current
    end
    if not distance or previous[#option] < distance then
      best, distance = option, previous[#option]
    end
  end
  return distance <= 2 and best or nil
end

-- Map a subdirectory to its install-directory suffix: a single path
-- segment where slashes become - and other symbols become - too.
-- Collisions between different subdirs resolve to the same directory
-- and are rejected by the duplicate-location check at setup.
local function sanitize_subdir(subdir)
  return (subdir:gsub("/", "-"):gsub("[^%w%.%-]", "-"))
end

-- Normalize the build option to a list of steps. A step is a shell command
-- string or a function; false disables the build, like lazy.nvim.
---@param build any
---@param name string
---@return (string|fun(ctx: AmberBuildContext): any)[]?
local function parse_build(build, name)
  if build == nil or build == false then
    return nil
  end
  local steps = type(build) == "table" and build or { build }
  assert(#steps > 0, "plugin build must not be an empty list: " .. name)
  for key in pairs(steps) do
    assert(
      type(key) == "number" and key >= 1 and key <= #steps and key % 1 == 0,
      "plugin build must be a command, a function, or a list of them: " .. name
    )
  end
  local normalized = {}
  for i, step in ipairs(steps) do
    assert(
      type(step) == "function" or (type(step) == "string" and step:match("%S")),
      "plugin build step " .. i .. " must be a command string or a function: " .. name
    )
    normalized[i] = step
  end
  return normalized
end

---@param spec string|AmberPluginSpec
---@param root string
---@return AmberPlugin
local function parse(spec, root)
  if type(spec) == "string" then
    spec = { spec }
  end
  assert(
    type(spec) == "table" and type(spec[1]) == "string",
    "plugin must be an owner/repository string or table"
  )
  local options = { "opts", "enabled", "path", "main", "version", "subdir", "build" }
  local allowed = {
    [1] = true,
    opts = true,
    enabled = true,
    path = true,
    main = true,
    version = true,
    subdir = true,
    build = true,
  }
  for key in pairs(spec) do
    if not allowed[key] then
      local suggestion = closest_option(key, options)
      error(
        "unknown plugin option "
          .. tostring(key)
          .. " in "
          .. spec[1]
          .. (
            suggestion and "; did you mean " .. suggestion .. "?"
            or "; allowed: " .. table.concat(options, ", ")
          ),
        0
      )
    end
  end
  local owner, repo = spec[1]:match("^([%w_.-]+)/([%w_.-]+)$")
  assert(
    owner and owner ~= "." and owner ~= ".." and repo ~= "." and repo ~= "..",
    "invalid plugin name: " .. spec[1]
  )
  local subdir = spec.subdir
  if subdir ~= nil then
    assert(type(subdir) == "string" and #subdir > 0, "invalid subdir: " .. tostring(subdir))
    assert(
      subdir:sub(1, 1) ~= "/" and subdir:sub(-1) ~= "/" and not subdir:find("//", 1, true),
      "subdir must be relative to the repository root: " .. tostring(subdir)
    )
    for segment in subdir:gmatch("[^/]+") do
      assert(
        segment ~= "." and segment ~= ".." and segment:match("^[%w_%.%-]+$"),
        "invalid subdir: " .. tostring(subdir)
      )
    end
  end
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
    "invalid version "
      .. tostring(spec.version)
      .. " for "
      .. spec[1]
      .. "; expected a tag, commit, ^1.2.3, or ~1.2.3"
  )
  assert(
    not spec.path or not spec.version,
    "version is not supported for local plugins: " .. spec[1]
  )
  assert(
    spec.path == nil or (type(spec.path) == "string" and spec.path:sub(1, 1) == "/"),
    "plugin path must be absolute: " .. spec[1]
  )
  assert(
    not spec.path or not spec.build,
    "build is not supported for local plugins: " .. spec[1] .. " (Amber never runs them)"
  )
  local build = parse_build(spec.build, spec[1])
  assert(
    not subdir or type(spec.main) == "string",
    "main is required for subdir plugins: "
      .. spec[1]
      .. " (the repository-name default cannot resolve inside a subdirectory)"
  )
  local main = spec.main or repo:gsub("%.rex$", "")
  assert(
    type(main) == "string"
      and main:match("^[%w_-]+[.%w_-]*$")
      and not main:find("..", 1, true)
      and main:sub(-1) ~= ".",
    "invalid main module: " .. spec[1]
  )
  -- A subdir plugin owns the repository's identity: its name carries the
  -- subdirectory so lockfile, status, and per-plugin action targets stay
  -- unique while module resolution looks inside that subdirectory.
  local name = subdir and (spec[1] .. "@" .. subdir) or spec[1]
  local slug = owner .. "/" .. repo .. (subdir and "--" .. sanitize_subdir(subdir) or "")
  local dir = spec.path or (root .. "/" .. slug)
  return {
    name = name,
    slug = slug,
    subdir = subdir,
    url = "https://github.com/" .. spec[1] .. ".git",
    dir = dir,
    -- Modules resolve inside the subdirectory of the checkout (the install
    -- directory for managed plugins, the local checkout for path plugins).
    module_dir = dir .. (subdir and "/" .. subdir or ""),
    parent = root .. "/" .. owner,
    opts = spec.opts or {},
    main = main,
    local_path = spec.path ~= nil,
    enabled = spec.enabled ~= false,
    version = spec.version,
    build = build,
  }
end

return parse
