-- Amber: install GitHub repositories and load their Lua entry points.

---@type AmberModule
---@diagnostic disable-next-line: missing-fields
local M = { version = "0.1.0" }

local source = debug.getinfo(1, "S").source
local directory = source:match("^@?(.*/)") or "./"
local util = assert(loadfile(directory .. "amber/util.lua"))()
local parse = assert(loadfile(directory .. "amber/spec.lua"))()
local git = assert(loadfile(directory .. "amber/git.lua"))(util)
local loader = assert(loadfile(directory .. "amber/loader.lua"))(util)
local lock = assert(loadfile(directory .. "amber/lock.lua"))(util)
local build = assert(loadfile(directory .. "amber/build.lua"))(util)
local register_action, load_plugin = loader.register_action, loader.load_plugin

---@param config? AmberConfig
function M.setup(config)
  config = config or {}
  local home = os.getenv("HOME")
  local root = config.root
    or (
      (os.getenv("XDG_DATA_HOME") or (assert(home, "HOME is not set") .. "/.local/share"))
      .. "/rex/plugins"
    )
  if type(root) ~= "string" or root:sub(1, 1) ~= "/" then
    rex.log("error", "amber: plugin root must be an absolute path")
    return
  end
  if config.install ~= nil and config.install ~= "manual" then
    rex.log("error", "amber: automatic installation is not supported; use amber_install")
    return
  end

  local config_home = os.getenv("XDG_CONFIG_HOME") or (home and home .. "/.config")
  local config_path = os.getenv("REX_CONFIG")
  local config_dir = config_path and config_path:match("^(.*)/[^/]+$")
  local lockfile = config.lockfile
    or (config_dir and config_dir .. "/amber-lock.json")
    or (config_home and config_home .. "/rex/amber-lock.json")
  if type(lockfile) ~= "string" or lockfile:sub(1, 1) ~= "/" or lockfile:sub(-1) == "/" then
    rex.log("error", "amber: lockfile must be an absolute file path")
    return
  end

  -- Per-plugin state directories are only named here; plugins create them.
  local state_home = os.getenv("XDG_STATE_HOME") or (home and home .. "/.local/state")
  local state_root = state_home and state_home .. "/rex/amber"

  local plugins, by_name, modules, by_dir = {}, {}, {}, {}
  for _, spec in ipairs(config.plugins or {}) do
    local ok, plugin = pcall(parse, spec, root)
    if not ok then
      rex.log("error", "amber: invalid plugin specification: " .. tostring(plugin))
    elseif by_name[plugin.name] or (plugin.enabled and modules[plugin.main]) then
      rex.log(
        "error",
        "amber: duplicate plugin or main module: " .. plugin.name .. " (" .. plugin.main .. ")"
      )
    elseif not plugin.local_path and by_dir[plugin.dir] then
      -- Managed specs share one directory per install, so a location clash is
      -- rejected for every non-local spec, including disabled ones: otherwise
      -- a disabled plain repo can stand in for an enabled subdir plugin and
      -- install treats that checkout as already installed.
      rex.log("error", "amber: duplicate install location: " .. plugin.dir)
    else
      if plugin.enabled then
        modules[plugin.main] = true
      end
      if not plugin.local_path then
        by_dir[plugin.dir] = true
      end
      by_name[plugin.name] = plugin
      plugins[#plugins + 1] = plugin
    end
  end

  local function manage(plugin, deadline, operation)
    local build_err
    local result, err = lock.transaction(lockfile, function(data)
      local entry = data.plugins[plugin.name]
      if operation == "restore" and not entry then
        return nil, "no lockfile entry for " .. plugin.name
      end
      local status, err
      if operation == "build" then
        if plugin.local_path then
          return nil, "local plugins are managed outside amber"
        end
        if not util.exists(plugin.dir .. "/.git/HEAD") then
          return nil, "not installed"
        end
        status = plugin.build and "built" or "no build step"
      elseif operation == "install" then
        status, err = git.install(plugin, deadline, entry and entry.commit)
      elseif operation == "restore" then
        status, err = git.restore(plugin, deadline, entry.commit)
      else
        status, err = git.update(plugin, deadline)
      end
      if not status then
        return nil, err
      end
      local changed = false
      local hash, hash_err
      if operation == "update" or (operation == "install" and not entry) then
        hash, hash_err = git.commit(plugin, deadline)
        if not hash then
          return nil, "checkout succeeded but lockfile was not updated: " .. tostring(hash_err)
        end
        -- A new commit invalidates the recorded build; an unchanged one keeps it.
        local kept = entry and entry.commit == hash and entry.built or nil
        entry = { commit = hash, version = plugin.version, built = kept }
        data.plugins[plugin.name] = entry
        changed = true
      end
      if plugin.build and entry then
        if not hash then
          hash, hash_err = git.commit(plugin, deadline)
        end
        if not hash then
          build_err = "cannot read checkout commit for build: " .. tostring(hash_err)
        elseif operation == "build" or entry.built ~= hash then
          local built, built_err = build.run(plugin, hash, deadline)
          if built then
            entry.built = hash
            changed = true
          else
            build_err = built_err
          end
        end
      end
      return status, nil, changed
    end)
    -- The checkout and lock entry are recorded even when the build fails, so
    -- the failure is reported after the transaction and amber_build can retry.
    if result and build_err then
      return nil, build_err
    end
    return result, err
  end
  register_action("amber_install", "Install Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "install")
  end, by_name, plugins, true)
  register_action("amber_update", "Update Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "update")
  end, by_name, plugins, true)
  register_action("amber_restore", "Restore Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "restore")
  end, by_name, plugins, true)
  register_action("amber_build", "Build Rex Plugins", function(plugin, deadline)
    return manage(plugin, deadline, "build")
  end, by_name, plugins, true)
  rex.action({
    name = "amber_status",
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
        local built
        if plugin.build and locked then
          built = locked.built == locked.commit
        end
        result[plugin.name] = {
          enabled = plugin.enabled,
          path = plugin.dir,
          subdir = plugin.subdir,
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
          built = built,
          lock_error = lock_error,
        }
      end
      return result
    end,
  })
  local lock_data, lock_error = lock.read(lockfile)
  if not lock_data then
    rex.log("error", "amber: " .. tostring(lock_error))
  end
  for _, plugin in ipairs(plugins) do
    local locked = lock_data and lock_data.plugins[plugin.name]
    if plugin.enabled and not plugin.local_path and locked then
      if locked.version ~= plugin.version then
        rex.log(
          "warn",
          "amber: "
            .. plugin.name
            .. ": version spec changed; lock remains authoritative until amber_update"
        )
      end
      if util.exists(plugin.dir .. "/.git/HEAD") then
        local head, err = git.commit(plugin, os.time() + 3)
        if head and head ~= locked.commit then
          rex.log(
            "warn",
            "amber: " .. plugin.name .. ": checkout differs from lockfile; run amber_restore"
          )
        elseif err then
          rex.log("warn", "amber: " .. plugin.name .. ": cannot check lockfile: " .. err)
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
          "amber: "
            .. plugin.name
            .. ": checkout does not match version "
            .. plugin.version
            .. "; run amber_update"
        )
      elseif err then
        rex.log("warn", "amber: " .. plugin.name .. ": cannot check version: " .. err)
      end
    end
    local context = {
      name = plugin.name,
      dir = plugin.dir,
      module_dir = plugin.module_dir,
      commit = locked and locked.commit or nil,
      data_dir = state_root and state_root .. "/" .. plugin.slug or nil,
    }
    -- A plugin that needs a build is not set up until the build has run for
    -- its locked commit, since setup typically depends on the build output.
    if
      plugin.enabled
      and plugin.build
      and lock_data
      and util.exists(plugin.dir .. "/.git/HEAD")
      and not (locked and locked.built == locked.commit)
    then
      plugin.load_status = "unbuilt"
      plugin.load_error = "build has not run for the locked commit; run amber_build"
      rex.log("warn", "amber: " .. plugin.name .. ": " .. plugin.load_error)
    else
      load_plugin(plugin, context)
    end
  end
end

return M
