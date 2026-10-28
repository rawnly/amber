-- Rex Plugin Manager: install GitHub repositories and load their Lua entry points.

---@type RpmModule
---@diagnostic disable-next-line: missing-fields
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
  register_action("rpm_update", "Update Rex Plugins", update, by_name, plugins, true)
  rex.action({
    name = "rpm_status",
    title = "Rex Plugin Status",
    category = "Plugins",
    run = function()
      local result = {}
      local deadline = os.time() + 23
      for _, plugin in ipairs(plugins) do
        local git_result
        if
          not plugin.local_path
          and util.exists(plugin.dir .. "/.git/HEAD")
          and os.time() < deadline
        then
          git_result = util.run(
            { "git", "rev-parse", "HEAD" },
            { cwd = plugin.dir, timeout = math.min(2, deadline - os.time()) }
          )
        end
        local version_matches, version_error
        if plugin.version and git_result and os.time() < deadline then
          version_matches, version_error = git.version_status(plugin, deadline)
        end
        result[plugin.name] = {
          enabled = plugin.enabled,
          path = plugin.dir,
          local_path = plugin.local_path,
          installed = plugin.local_path and util.exists(plugin.dir)
            or util.exists(plugin.dir .. "/.git/HEAD"),
          loaded = plugin.load_status or "not loaded",
          error = plugin.load_error,
          version = plugin.version,
          version_matches = version_matches,
          version_error = version_error,
          commit = git_result and git_result.stdout:gsub("%s+$", "") or nil,
        }
      end
      return result
    end,
  })
  for _, plugin in ipairs(plugins) do
    local ready = true
    if config.install ~= "manual" and plugin.enabled and not plugin.local_path then
      local status, err = install(plugin)
      if not status then
        ready = false
        plugin.load_status, plugin.load_error = "error", "install failed: " .. tostring(err)
        rex.log("error", "rpm: " .. plugin.name .. ": " .. plugin.load_error)
      end
    end
    if ready then
      if
        plugin.enabled
        and plugin.version
        and not plugin.local_path
        and util.exists(plugin.dir .. "/.git/HEAD")
      then
        local matches, err = git.version_status(plugin, os.time() + 3)
        if matches == false then
          rex.log(
            "warn",
            "rpm: "
              .. plugin.name
              .. ": checkout does not match version "
              .. plugin.version
              .. "; run rpm_update"
          )
        elseif err then
          rex.log("warn", "rpm: " .. plugin.name .. ": cannot check version: " .. err)
        end
      end
      load_plugin(plugin)
    end
  end
end

return M
