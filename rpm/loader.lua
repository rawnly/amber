local util = ...
local exists = util.exists

---@param name string
---@param title string
---@param operation fun(plugin: RpmPlugin): string?, string?
---@param plugins table<string, RpmPlugin>
local function register_action(name, title, operation, plugins)
  rex.action({
    name = name,
    title = title,
    category = "Plugins",
    args = { plugin = "string" },
    run = function(_, args)
      local plugin = plugins[args.plugin]
      if not plugin then
        error("unknown plugin: " .. args.plugin, 0)
      end
      if not plugin.enabled then
        error(plugin.name .. ": plugin is disabled", 0)
      end
      local status, err = operation(plugin)
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
    local paths = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;"
    if not package.path:find(paths, 1, true) then
      package.path = paths .. package.path
    end
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
