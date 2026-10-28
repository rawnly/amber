-- Rex Plugin Manager: install GitHub repositories and load their Lua entry points.

---@type RpmModule
---@diagnostic disable-next-line: missing-fields
local M = { version = "0.1.0" }

local source = debug.getinfo(1, "S").source
local directory = source:match("^@?(.*/)") or "./"
local util = assert(loadfile(directory .. "rpm/util.lua"))()
local parse = assert(loadfile(directory .. "rpm/spec.lua"))()
local git = assert(loadfile(directory .. "rpm/git.lua"))(util)
local loader = assert(loadfile(directory .. "rpm/loader.lua"))(util)
local lock = assert(loadfile(directory .. "rpm/lock.lua"))(util)
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
  if config.install ~= nil and config.install ~= "manual" then
    rex.log("error", "rpm: automatic installation is not supported; use rpm_install")
    return
  end

  local config_home = os.getenv("XDG_CONFIG_HOME") or (home and home .. "/.config")
  local config_path = os.getenv("REX_CONFIG")
  local config_dir = config_path and config_path:match("^(.*)/[^/]+$")
  local lockfile = config.lockfile
    or (config_dir and config_dir .. "/rpm-lock.json")
    or (config_home and config_home .. "/rex/rpm-lock.json")
  if type(lockfile) ~= "string" or lockfile:sub(1, 1) ~= "/" or lockfile:sub(-1) == "/" then
    rex.log("error", "rpm: lockfile must be an absolute file path")
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

  local function manage(plugin, deadline, operation)
    return lock.transaction(lockfile, function(data)
      local entry = data.plugins[plugin.name]
      if operation == "restore" and not entry then
        return nil, "no lockfile entry for " .. plugin.name
      end
      local status, err
      if operation == "install" then
        status, err = git.install(plugin, deadline, entry and entry.commit)
      elseif operation == "restore" then
        status, err = git.restore(plugin, deadline, entry.commit)
      else
        status, err = git.update(plugin, deadline)
      end
      if not status then
        return nil, err
      end
      if operation == "restore" or (operation == "install" and entry) then
        return status
      end
      local hash, hash_err = git.commit(plugin, deadline)
      if not hash then
        return nil, "checkout succeeded but lockfile was not updated: " .. tostring(hash_err)
      end
      data.plugins[plugin.name] = { commit = hash, version = plugin.version }
      return status, nil, true
    end)
  end
  register_action("rpm_install", "Install Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "install")
  end, by_name, plugins, true)
  register_action("rpm_update", "Update Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "update")
  end, by_name, plugins, true)
  register_action("rpm_restore", "Restore Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "restore")
  end, by_name, plugins, true)
  rex.action({
    name = "rpm_status",
    title = "Rex Plugin Status",
    category = "Plugins",
    run = function()
      local result = {}
      local lock_data, lock_error = lock.read(lockfile)
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
        local locked = lock_data and lock_data.plugins[plugin.name]
        local head = git_result and git_result.stdout:gsub("%s+$", "") or nil
        local lock_matches
        if locked and head then
          lock_matches = locked.commit == head
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
          commit = head,
          locked_commit = locked and locked.commit or nil,
          lock_matches = lock_matches,
          lock_error = lock_error,
        }
      end
      return result
    end,
  })
  local lock_data, lock_error = lock.read(lockfile)
  if not lock_data then
    rex.log("error", "rpm: " .. tostring(lock_error))
  end
  for _, plugin in ipairs(plugins) do
    local locked = lock_data and lock_data.plugins[plugin.name]
    if plugin.enabled and not plugin.local_path and locked then
      if locked.version ~= plugin.version then
        rex.log(
          "warn",
          "rpm: "
            .. plugin.name
            .. ": version spec changed; lock remains authoritative until rpm_update"
        )
      end
      if util.exists(plugin.dir .. "/.git/HEAD") then
        local head, err = git.commit(plugin, os.time() + 3)
        if head and head ~= locked.commit then
          rex.log(
            "warn",
            "rpm: " .. plugin.name .. ": checkout differs from lockfile; run rpm_restore"
          )
        elseif err then
          rex.log("warn", "rpm: " .. plugin.name .. ": cannot check lockfile: " .. err)
        end
      end
    end
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

return M
