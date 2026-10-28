-- Rex Plugin Manager: install GitHub repositories and load their Lua entry points.
local M = { version = "0.1.0" }

local function run(argv, opts)
  local result, err = rex.exec(argv, opts)
  if not result then return nil, err end
  if not result.ok then
    return nil, (result.stderr ~= "" and result.stderr) or ("exit status " .. tostring(result.code))
  end
  return result
end

local function parse(spec, root)
  if type(spec) == "string" then spec = { spec } end
  assert(type(spec) == "table" and type(spec[1]) == "string", "plugin must be an owner/repository string or table")
  local owner, repo = spec[1]:match("^([%w_.-]+)/([%w_.-]+)$")
  assert(owner and owner ~= "." and owner ~= ".." and repo ~= "." and repo ~= "..", "invalid plugin name: " .. spec[1])
  assert(spec.opts == nil or type(spec.opts) == "table", "plugin opts must be a table: " .. spec[1])
  assert(spec.enabled == nil or type(spec.enabled) == "boolean", "plugin enabled must be a boolean: " .. spec[1])
  assert(spec.path == nil or (type(spec.path) == "string" and spec.path:sub(1, 1) == "/"), "plugin path must be absolute: " .. spec[1])
  local entry = spec.entry or "init.lua"
  assert(type(entry) == "string" and entry ~= "" and entry:sub(1, 1) ~= "/" and not entry:find("//", 1, true), "invalid plugin entry: " .. spec[1])
  for component in entry:gmatch("[^/]+") do
    assert(component ~= "." and component ~= "..", "invalid plugin entry: " .. spec[1])
  end
  return { name = spec[1], url = "https://github.com/" .. spec[1] .. ".git", dir = spec.path or (root .. "/" .. owner .. "/" .. repo), parent = root .. "/" .. owner, opts = spec.opts or {}, entry = entry, local_path = spec.path ~= nil, enabled = spec.enabled ~= false }
end

local function exists(path)
  local file = io.open(path, "r")
  if file then file:close(); return true end
  return false
end

local function install(plugin)
  if plugin.local_path then return nil, "local plugins are managed outside rpm" end
  if exists(plugin.dir .. "/.git/HEAD") then return "already installed" end
  if exists(plugin.dir) then return nil, "destination already exists but is not a Git checkout: " .. plugin.dir end
  local _, err = run({ "mkdir", "-p", plugin.parent })
  if err then return nil, err end
  -- mktemp creates a unique sibling, so an interrupted clone never looks installed.
  local temp, temp_err = run({ "mktemp", "-d", plugin.parent .. "/.rpm-XXXXXXXX" })
  if not temp then return nil, temp_err end
  local dir = temp.stdout:gsub("%s+$", "")
  local result, clone_err = run({ "git", "clone", "--", plugin.url, dir }, {
    timeout = 20, env = { GIT_TERMINAL_PROMPT = "0" },
  })
  if not result then
    run({ "rm", "-rf", "--", dir })
    return nil, clone_err
  end
  -- Do not replace a destination created while cloning.
  local moved, move_err = run({ "mv", "-n", "--", dir, plugin.dir })
  if not moved or exists(dir) then
    run({ "rm", "-rf", "--", dir })
    return nil, move_err or "destination appeared during installation"
  end
  return "installed"
end

local function update(plugin)
  if plugin.local_path then return nil, "local plugins are managed outside rpm" end
  if not exists(plugin.dir .. "/.git/HEAD") then return nil, "not installed" end
  local result, err = run({ "git", "pull", "--ff-only" }, {
    cwd = plugin.dir, timeout = 20, env = { GIT_TERMINAL_PROMPT = "0" },
  })
  if not result then return nil, err end
  return "updated"
end

function M.setup(config)
  config = config or {}
  local home = os.getenv("HOME")
  local root = config.root or ((os.getenv("XDG_DATA_HOME") or (assert(home, "HOME is not set") .. "/.local/share")) .. "/rex/plugins")
  assert(type(root) == "string" and root ~= "", "plugin root must be a nonempty path")
  local plugins, names = {}, {}
  for _, spec in ipairs(config.plugins or {}) do
    local plugin = parse(spec, root)
    assert(not names[plugin.name], "duplicate plugin: " .. plugin.name)
    names[plugin.name] = true
    plugins[#plugins + 1] = plugin
  end

  -- Install/update one plugin per invocation to stay within Rex's action deadline.
  local function register(name, title, operation)
    rex.action({
      name = name, title = title, category = "Plugins", args = { plugin = "string" },
      run = function(_, args)
        for _, plugin in ipairs(plugins) do
          if plugin.name == args.plugin then
            if not plugin.enabled then error(plugin.name .. ": plugin is disabled", 0) end
            local status, err = operation(plugin)
            if not status then error(plugin.name .. ": " .. err, 0) end
            return { plugin = plugin.name, status = status, reload = "rex config reload" }
          end
        end
        error("unknown plugin: " .. args.plugin, 0)
      end,
    })
  end
  register("rpm_install", "Install Rex Plugin", install)
  register("rpm_update", "Update Rex Plugin", update)

  for _, plugin in ipairs(plugins) do
    if not plugin.enabled then
      -- Disabled plugins remain declared but do not load or emit missing warnings.
    elseif exists(plugin.dir .. "/" .. plugin.entry) then
      local ok, err = pcall(function()
        local module = dofile(plugin.dir .. "/" .. plugin.entry)
        assert(type(module) == "table" and type(module.setup) == "function", plugin.entry .. " must return a table with setup(opts)")
        module.setup(plugin.opts)
      end)
      if not ok then rex.log("error", "rpm: " .. plugin.name .. ": " .. tostring(err)) end
    else
      local hint = plugin.local_path and ("missing entry " .. plugin.dir .. "/" .. plugin.entry) or ("not installed or missing " .. plugin.entry .. "; install with rex do rpm_install plugin=" .. plugin.name)
      rex.log("warn", "rpm: " .. plugin.name .. ": " .. hint)
    end
  end
end

return M
