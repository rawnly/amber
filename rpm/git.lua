---@type RpmUtil
local util = ...
local run, exists = util.run, util.exists

---@param plugin RpmPlugin
---@param dir string
---@return RexExecResult? result
---@return string? err
local function checkout_version(plugin, dir)
  local version = plugin.version
  local operator = version:sub(1, 1)
  if operator == "^" or operator == "~" then
    local major, minor, patch = version:match("^[%^~](%d+)%.(%d+)%.(%d+)$")
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    local tags, err = run({ "git", "tag", "--list" }, { cwd = dir })
    if not tags then
      return nil, err
    end
    local best, best_a, best_b, best_c
    for tag in tags.stdout:gmatch("[^\r\n]+") do
      local a, b, c = tag:match("^v?(%d+)%.(%d+)%.(%d+)$")
      if a then
        a, b, c = tonumber(a), tonumber(b), tonumber(c)
        local above = a > major or (a == major and (b > minor or (b == minor and c >= patch)))
        local within = operator == "~" and a == major and b == minor
          or operator == "^"
            and a == major
            and (major > 0 or (b == minor and (minor > 0 or c == patch)))
        if
          above
          and within
          and (
            not best
            or a > best_a
            or (a == best_a and (b > best_b or (b == best_b and c > best_c)))
          )
        then
          best, best_a, best_b, best_c = tag, a, b, c
        end
      end
    end
    if not best then
      return nil, "no stable tag matches " .. version
    end
    version = best
  end
  if operator ~= "^" and operator ~= "~" then
    local tag = run(
      { "git", "show-ref", "--verify", "--quiet", "refs/tags/" .. version },
      { cwd = dir }
    )
    if not tag then
      local branch = run(
        { "git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/" .. version },
        { cwd = dir }
      )
      if branch then
        version = "origin/" .. version
      end
    end
  end
  return run({ "git", "checkout", "--detach", version, "--" }, { cwd = dir, timeout = 5 })
end

---@param plugin RpmPlugin
---@return string? status
---@return string? err
local function install_unlocked(plugin)
  if plugin.local_path then
    return nil, "local plugins are managed outside rpm"
  end
  if exists(plugin.dir .. "/.git/HEAD") then
    return "already installed"
  end
  if exists(plugin.dir) then
    return nil, "destination already exists but is not a Git checkout: " .. plugin.dir
  end
  local _, err = run({ "mkdir", "-p", plugin.parent })
  if err then
    return nil, err
  end
  -- mktemp creates a unique sibling, so an interrupted clone never looks installed.
  local temp, temp_err = run({ "mktemp", "-d", plugin.parent .. "/.rpm-XXXXXXXX" })
  if not temp then
    return nil, temp_err
  end
  local dir = temp.stdout:gsub("%s+$", "")
  local result, clone_err = run({ "git", "clone", "--", plugin.url, dir }, {
    timeout = 20,
    env = { GIT_TERMINAL_PROMPT = "0" },
  })
  if not result then
    run({ "rm", "-rf", "--", dir })
    return nil, clone_err
  end
  if plugin.version then
    local checked, checkout_err = checkout_version(plugin, dir)
    if not checked then
      run({ "rm", "-rf", "--", dir })
      return nil, checkout_err
    end
  end
  if exists(plugin.dir) then
    run({ "rm", "-rf", "--", dir })
    return nil, "destination appeared during installation"
  end
  local moved, move_err = run({ "mv", "-n", "--", dir, plugin.dir })
  if not moved or exists(dir) then
    run({ "rm", "-rf", "--", dir })
    return nil, move_err or "destination appeared during installation"
  end
  return "installed"
end

---@param plugin RpmPlugin
---@return string? status
---@return string? err
local function install(plugin)
  if plugin.local_path then
    return nil, "local plugins are managed outside rpm"
  end
  if exists(plugin.dir .. "/.git/HEAD") then
    return "already installed"
  end
  local parent, parent_err = run({ "mkdir", "-p", plugin.parent })
  if not parent then
    return nil, parent_err
  end
  local lock = plugin.dir .. ".rpm-lock"
  local locked = run({ "mkdir", "--", lock })
  if not locked then
    return nil, "installation locked: " .. lock
  end
  local ok, status, err = pcall(install_unlocked, plugin)
  local removed, remove_err = run({ "rmdir", "--", lock })
  if not removed then
    return nil, "cannot release install lock " .. lock .. ": " .. tostring(remove_err)
  end
  if not ok then
    return nil, tostring(status)
  end
  return status, err
end

---@param plugin RpmPlugin
---@return string? status
---@return string? err
local function update(plugin)
  if plugin.local_path then
    return nil, "local plugins are managed outside rpm"
  end
  if not exists(plugin.dir .. "/.git/HEAD") then
    return nil, "not installed"
  end
  if plugin.version then
    local result, err = run({ "git", "fetch", "--tags", "origin" }, {
      cwd = plugin.dir,
      timeout = 20,
      env = { GIT_TERMINAL_PROMPT = "0" },
    })
    if not result then
      return nil, err
    end
    result, err = checkout_version(plugin, plugin.dir)
    if not result then
      return nil, err
    end
    return "updated"
  end
  local result, err = run({ "git", "pull", "--ff-only" }, {
    cwd = plugin.dir,
    timeout = 20,
    env = { GIT_TERMINAL_PROMPT = "0" },
  })
  if not result then
    return nil, err
  end
  return "updated"
end

return { install = install, update = update }
