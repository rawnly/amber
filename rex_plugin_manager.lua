-- Rex Plugin Manager: install GitHub repositories and load their Lua entry points.

---@class RpmPluginSpec
---@field [1] string GitHub owner/repository identity.
---@field opts? table Options passed to the plugin's setup function.
---@field enabled? boolean Defaults to true.
---@field path? string Absolute path to an externally managed checkout.
---@field main? string Lua module name; defaults to the repository name.
---@field version? string Git ref or supported semver constraint.

---@class RpmConfig
---@field root? string Directory for managed checkouts.
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
  assert(type(root) == "string" and root ~= "", "plugin root must be a nonempty path")

  local plugins, by_name, modules = {}, {}, {}
  for _, spec in ipairs(config.plugins or {}) do
    local plugin = parse(spec, root)
    assert(not by_name[plugin.name], "duplicate plugin: " .. plugin.name)
    if plugin.enabled then
      assert(not modules[plugin.main], "duplicate main module: " .. plugin.main)
      modules[plugin.main] = true
    end
    by_name[plugin.name] = plugin
    plugins[#plugins + 1] = plugin
  end

  register_action("rpm_install", "Install Rex Plugin", install, by_name)
  register_action("rpm_update", "Update Rex Plugin", update, by_name)
  for _, plugin in ipairs(plugins) do
    load_plugin(plugin)
  end
end

return M
