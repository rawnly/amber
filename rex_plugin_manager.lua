-- Rex Plugin Manager: install GitHub repositories and load their Lua entry points.

---@class RpmPluginSpec
---@field [1] string GitHub owner/repository identity.
---@field opts? table Options passed to the plugin's setup function.
---@field enabled? boolean Defaults to true.
---@field path? string Absolute path to an externally managed checkout.
---@field main? string Lua module name; defaults to the repository name.
---@field version? string Git ref or supported semver constraint.

---@class RpmConfig
---@field root? string Absolute directory for managed checkouts.
---@field install? "auto"|"manual" Installation behavior; defaults to auto.
---@field plugins? (string|RpmPluginSpec)[] Plugins in load order.

---@class RpmPlugin
---@field name string
---@field url string
---@field dir string
---@field parent string
---@field opts table
---@field main string
---@field local_path boolean
---@field enabled boolean
---@field version? string

---@class RpmModule
---@field version string
---@field setup fun(config?: RpmConfig)
local M = { version = "0.1.0" }

local source = debug.getinfo(1, "S").source
local directory = source:match("^@?(.*/)") or "./"
local util = dofile(directory .. "rpm/util.lua")
local parse = dofile(directory .. "rpm/spec.lua")
local git = assert(loadfile(directory .. "rpm/git.lua"))(util)
local loader = assert(loadfile(directory .. "rpm/loader.lua"))(util)
local install, update = git.install, git.update
local register_action, load_plugin = loader.register_action, loader.load_plugin

---@param config? RpmConfig
function M.setup(config)
  config = config or {}
  local home = os.getenv("HOME")
  local root = config.root
    or (
      (os.getenv("XDG_DATA_HOME") or (assert(home, "HOME is not set") .. "/.local/share"))
      .. "/rex/plugins"
    )
  if type(root) ~= "string" or root:sub(1, 1) ~= "/" then
    rex.log("error", "rpm: plugin root must be an absolute path")
    return
  end
  if config.install ~= nil and config.install ~= "auto" and config.install ~= "manual" then
    rex.log("error", "rpm: install must be 'auto' or 'manual'")
    return
  end

  local plugins, by_name, modules = {}, {}, {}
  for _, spec in ipairs(config.plugins or {}) do
    local ok, plugin = pcall(parse, spec, root)
    if not ok then
      rex.log("error", "rpm: invalid plugin specification: " .. tostring(plugin))
    elseif by_name[plugin.name] or (plugin.enabled and modules[plugin.main]) then
      rex.log(
        "error",
        "rpm: duplicate plugin or main module: " .. plugin.name .. " (" .. plugin.main .. ")"
      )
    else
      if plugin.enabled then
        modules[plugin.main] = true
      end
      by_name[plugin.name] = plugin
      plugins[#plugins + 1] = plugin
    end
  end

  register_action("rpm_install", "Install Rex Plugins", install, by_name, plugins, true)
  register_action("rpm_update", "Update Rex Plugin", update, by_name, plugins)
  for _, plugin in ipairs(plugins) do
    local ready = true
    if config.install ~= "manual" and plugin.enabled and not plugin.local_path then
      local status, err = install(plugin)
      if not status then
        ready = false
        rex.log("error", "rpm: " .. plugin.name .. ": install failed: " .. tostring(err))
      end
    end
    if ready then
      load_plugin(plugin)
    end
  end
end

return M
