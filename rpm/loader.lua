---@type RpmUtil
local util = ...
local exists = util.exists
local module_roots = {}

local function plugin_searcher(name)
  for main, root in pairs(module_roots) do
    if name == main or name:sub(1, #main + 1) == main .. "." then
      local relative = name:gsub("%.", "/")
      for _, path in ipairs({
        root .. "/" .. relative .. ".lua",
        root .. "/" .. relative .. "/init.lua",
      }) do
        if exists(path) then
          return assert(loadfile(path))
        end
      end
      return "\n\trpm: module " .. name .. " not found in " .. root
    end
  end
  return "\n\trpm: no plugin owns " .. name
end

table.insert(package.loaders, 2, plugin_searcher)

---@param name string
---@param title string
---@param operation fun(plugin: RpmPlugin): string?, string?
---@param plugins table<string, RpmPlugin>
---@param ordered RpmPlugin[]
---@param all? boolean
local function register_action(name, title, operation, plugins, ordered, all)
  rex.action({
    name = name,
    title = title,
    category = "Plugins",
    args = { plugin = all and "string?" or "string" },
    run = function(_, args)
      local deadline = os.time() + 23
      if all and not args.plugin then
        local results = {}
        local failed = false
        for _, plugin in ipairs(ordered) do
          if plugin.enabled and not plugin.local_path then
            local status, err = operation(plugin, deadline)
            results[#results + 1] =
              { plugin = plugin.name, status = status or "failed", error = err }
            if not status then
              failed = true
            end
          end
        end
        if failed then
          local errors = {}
          for _, result in ipairs(results) do
            if result.error then
              errors[#errors + 1] = result.plugin .. ": " .. result.error
            end
          end
          error("plugin operation failed: " .. table.concat(errors, "; "), 0)
        end
        return { plugins = results, reload = "rex config reload" }
      end
      local plugin = plugins[args.plugin]
      if not plugin then
        error("unknown plugin: " .. args.plugin, 0)
      end
      if not plugin.enabled then
        error(plugin.name .. ": plugin is disabled", 0)
      end
      local status, err = operation(plugin, deadline)
      if not status then
        error(plugin.name .. ": " .. err, 0)
      end
      return { plugin = plugin.name, status = status, reload = "rex config reload" }
    end,
  })
end

---@param plugin RpmPlugin
local function load_plugin(plugin)
  if not plugin.enabled then
    return
  end

  local rex_dir = plugin.dir .. "/rex/lua"
  local result, err = rex.exec({ "test", "-d", rex_dir })
  if not result then
    rex.log(
      "error",
      "rpm: " .. plugin.name .. ": cannot inspect module directory: " .. tostring(err)
    )
    return
  end
  local lua_dir = result.ok and rex_dir or (plugin.dir .. "/lua")
  local relative = plugin.main:gsub("%.", "/")
  if
    not exists(lua_dir .. "/" .. relative .. ".lua")
    and not exists(lua_dir .. "/" .. relative .. "/init.lua")
  then
    rex.log(
      "warn",
      "rpm: " .. plugin.name .. ": module " .. plugin.main .. " not found in " .. lua_dir
    )
    return
  end

  local ok, load_err = pcall(function()
    module_roots[plugin.main] = lua_dir
    local module = require(plugin.main)
    assert(
      type(module) == "table" and type(module.setup) == "function",
      plugin.main .. " must return a table with setup(opts)"
    )
    module.setup(plugin.opts)
  end)
  if not ok then
    rex.log("error", "rpm: " .. plugin.name .. ": " .. tostring(load_err))
  end
end

return { register_action = register_action, load_plugin = load_plugin }
