-- Amber: install GitHub repositories and load their Lua entry points.

---@type AmberModule
---@diagnostic disable-next-line: missing-fields
local M = { version = "0.1.0" }

local source = debug.getinfo(1, "S").source
local directory = source:match("^@?(.*/)") or "./"
local util = assert(loadfile(directory .. "amber/util.lua"))()
local parse = assert(loadfile(directory .. "amber/spec.lua"))()
local git = assert(loadfile(directory .. "amber/git.lua"))(util)
local cli_path_default = directory .. "bin/amber"
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

  local cli_path = config.cli or cli_path_default
  if type(cli_path) ~= "string" or cli_path:sub(1, 1) ~= "/" then
    rex.log("error", "amber: cli must be an absolute path")
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
      plugin.data_dir = state_root and state_root .. "/" .. plugin.slug or nil
      by_name[plugin.name] = plugin
      plugins[#plugins + 1] = plugin
    end
  end

  local function build_plugin(plugin, deadline)
    if plugin.local_path then
      return nil, "local plugins are managed outside amber"
    end
    if not plugin.enabled then
      return nil, "plugin is disabled"
    end
    if not util.exists(plugin.dir .. "/.git/HEAD") then
      return nil, "not installed"
    end
    if not plugin.build then
      return "no build step"
    end
    local result, err = lock.transaction(lockfile, function(data)
      local entry = data.plugins[plugin.name]
      if not entry then
        return nil, "no lockfile entry; run amber install"
      end
      return entry.commit
    end)
    if not result then
      return nil, err
    end
    local head, head_err = git.commit(plugin, deadline)
    if not head then
      return nil, head_err
    end
    if head ~= result then
      return nil, "checkout differs from lockfile; run amber restore before building"
    end
    local ok, build_err = build.run(plugin, result, deadline)
    if not ok then
      return nil, build_err
    end
    local saved, save_err = lock.transaction(lockfile, function(data)
      local entry = data.plugins[plugin.name]
      if not entry or entry.commit ~= result then
        return nil, "lockfile changed during the build; run amber build again"
      end
      entry.built = result
      return true, nil, true
    end)
    if not saved then
      return nil, save_err
    end
    return "built"
  end
  -- Data operations the amber command calls through the single `amber` action.
  local ops = {}
  local function cli_action(action, title, subcommand, optional)
    rex.action({
      name = action,
      title = title,
      category = "Plugins",
      args = action == "amber" and { op = "string?", plugin = "string?" }
        or (optional and { plugin = "string?" } or nil),
      run = function(ctx, args)
        if args and args.op then
          local handler = action == "amber" and ops[args.op]
          if not handler then
            error("unknown op: " .. tostring(args.op), 0)
          end
          return handler(ctx, args)
        end
        local plugin = args and args.plugin
        if plugin then
          local entry = by_name[plugin]
          if not entry then
            error("unknown plugin: " .. plugin, 0)
          end
          if not entry.enabled then
            error(plugin .. ": plugin is disabled", 0)
          end
          if entry.local_path then
            error("local plugins are managed outside amber", 0)
          end
        end
        if not util.exists(cli_path) then
          error(
            "Amber CLI not found at "
              .. cli_path
              .. "; build it with `mise run cli:build` or reinstall Amber",
            0
          )
        end
        if not ctx.session_id then
          local terminal_command = cli_path .. (subcommand ~= "" and " " .. subcommand or "")
          error(
            "no Rex session to open Amber in; run `"
              .. terminal_command
              .. "` in a terminal instead",
            0
          )
        end
        local argv = { cli_path, subcommand }
        if plugin then
          argv[#argv + 1] = plugin
        end
        if action == "amber" then
          argv = { cli_path }
        end
        local layer = rex.session.new_layer({
          bounds = { 0.125, 0.125, 0.75, 0.75 },
          focus = true,
          layout = rex.layout.block({
            flavor = "com.superlogical.terminal.shell",
            options = { command = argv, shell = "none" },
          }),
        })
        return { opened = layer.layer_id }
      end,
    })
  end
  cli_action("amber", "Amber: Open", "", false)
  cli_action("amber_install", "Amber: Install Plugins", "install", true)
  cli_action("amber_update", "Amber: Update Plugins", "update", true)
  cli_action("amber_restore", "Amber: Restore Lockfile Commits", "restore", true)
  cli_action("amber_build", "Amber: Build Plugins", "build", true)
  cli_action("amber_outdated", "Amber: Check for Updates", "outdated", false)
  cli_action("amber_clean", "Amber: Clean", "clean", false)
  ops.build = function(_, args)
    if type(args.plugin) ~= "string" then
      error("build requires a plugin", 0)
    end
    local plugin = by_name[args.plugin]
    if not plugin then
      error("unknown plugin: " .. args.plugin, 0)
    end
    if not plugin.enabled then
      error(plugin.name .. ": plugin is disabled", 0)
    end
    local status, err = build_plugin(plugin, os.time() + 23)
    if not status then
      error(plugin.name .. ": " .. tostring(err), 0)
    end
    return { plugin = plugin.name, status = status }
  end
  ops.info = function()
    local lock_data, lock_error = lock.read(lockfile)
    local info = {
      version = M.version,
      dir = directory:gsub("/$", ""),
      root = root,
      lockfile = lockfile,
      state_root = state_root,
      plugins = {},
    }
    for _, plugin in ipairs(plugins) do
      local row = {
        name = plugin.name,
        slug = plugin.slug,
        url = plugin.url,
        dir = plugin.dir,
        module_dir = plugin.module_dir,
        parent = plugin.parent,
        subdir = plugin.subdir,
        main = plugin.main,
        version = plugin.version,
        enabled = plugin.enabled,
        local_path = plugin.local_path,
        data_dir = plugin.data_dir,
        build = {},
        load_status = plugin.load_status or (plugin.enabled and "not loaded" or "disabled"),
        load_error = plugin.load_error,
      }
      for _, step in ipairs(plugin.build or {}) do
        row.build[#row.build + 1] = type(step) == "string" and { type = "shell", command = step }
          or { type = "lua" }
      end
      info.plugins[#info.plugins + 1] = row
    end
    if not lock_data then
      info.lock_error = lock_error
    end
    return info
  end
  ops.status = function()
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
  end
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
            .. ": version spec changed; lock remains authoritative until amber update"
        )
      end
      if util.exists(plugin.dir .. "/.git/HEAD") then
        local head, err = git.commit(plugin, os.time() + 3)
        if head and head ~= locked.commit then
          rex.log(
            "warn",
            "amber: " .. plugin.name .. ": checkout differs from lockfile; run amber restore"
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
            .. "; run amber update"
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
      data_dir = plugin.data_dir,
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
      plugin.load_error = "build has not run for the locked commit; run amber build"
      rex.log("warn", "amber: " .. plugin.name .. ": " .. plugin.load_error)
    else
      load_plugin(plugin, context)
    end
  end
end

return M
