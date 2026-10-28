---@type AmberUtil
local util = ...
local run, exists = util.run, util.exists

local function timed_run(argv, opts, deadline)
  opts = opts or {}
  if deadline then
    local remaining = deadline - os.time()
    if remaining <= 0 then
      return nil, "action time budget exhausted; retry remaining plugins"
    end
    opts.timeout = math.min(opts.timeout or 20, remaining)
  end
  return run(argv, opts)
end

---@param plugin AmberPlugin
---@param dir string
---@return string? version
---@return string? err
local function resolve_version(plugin, dir, deadline)
  local version = assert(plugin.version)
  local operator = version:sub(1, 1)
  if operator == "^" or operator == "~" then
    local major, minor, patch = version:match("^[%^~](%d+)%.(%d+)%.(%d+)$")
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    local tags, err = timed_run({ "git", "tag", "--list" }, { cwd = dir }, deadline)
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
    local tag = timed_run(
      { "git", "show-ref", "--verify", "--quiet", "refs/tags/" .. version },
      { cwd = dir },
      deadline
    )
    if not tag then
      local branch = timed_run(
        { "git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/" .. version },
        { cwd = dir },
        deadline
      )
      if branch then
        version = "origin/" .. version
      end
    end
  end
  return version
end

local function checkout_version(plugin, dir, deadline)
  local version, err = resolve_version(plugin, dir, deadline)
  if not version then
    return nil, err
  end
  return timed_run(
    { "git", "checkout", "--detach", version, "--" },
    { cwd = dir, timeout = 5 },
    deadline
  )
end

local function version_status(plugin, deadline)
  if not plugin.version then
    return nil, nil
  end
  local ref, err = resolve_version(plugin, plugin.dir, deadline)
  if not ref then
    return nil, err
  end
  local target, target_err = timed_run(
    { "git", "rev-parse", "--verify", ref .. "^{commit}" },
    { cwd = plugin.dir, timeout = 2 },
    deadline
  )
  if not target then
    return nil, target_err
  end
  local head, head_err = timed_run(
    { "git", "rev-parse", "--verify", "HEAD^{commit}" },
    { cwd = plugin.dir, timeout = 2 },
    deadline
  )
  if not head then
    return nil, head_err
  end
  return head.stdout:gsub("%s+$", "") == target.stdout:gsub("%s+$", "")
end

---@param plugin AmberPlugin
---@return string? status
---@return string? err
local function install_unlocked(plugin, deadline, locked_commit)
  if plugin.local_path then
    return nil, "local plugins are managed outside amber"
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
  local temp, temp_err = run({ "mktemp", "-d", plugin.parent .. "/.amber-XXXXXXXX" })
  if not temp then
    return nil, temp_err
  end
  local dir = temp.stdout:gsub("%s+$", "")
  local result, clone_err = timed_run({ "git", "clone", "--", plugin.url, dir }, {
    timeout = 20,
    env = { GIT_TERMINAL_PROMPT = "0" },
  }, deadline)
  if not result then
    run({ "rm", "-rf", "--", dir })
    return nil, clone_err
  end
  if plugin.version or locked_commit then
    local checked, checkout_err
    if locked_commit then
      checked, checkout_err = timed_run(
        { "git", "checkout", "--detach", locked_commit, "--" },
        { cwd = dir, timeout = 5 },
        deadline
      )
    else
      checked, checkout_err = checkout_version(plugin, dir, deadline)
    end
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

---@param plugin AmberPlugin
---@return string? status
---@return string? err
local function install(plugin, deadline, locked_commit)
  if deadline and os.time() >= deadline then
    return nil, "action time budget exhausted; retry remaining plugins"
  end
  if plugin.local_path then
    return nil, "local plugins are managed outside amber"
  end
  if exists(plugin.dir .. "/.git/HEAD") then
    return "already installed"
  end
  local parent, parent_err = run({ "mkdir", "-p", plugin.parent })
  if not parent then
    return nil, parent_err
  end
  local lock = plugin.dir .. ".amber-lock"
  local locked = run({ "mkdir", "--", lock })
  if not locked then
    return nil, "installation locked: " .. lock
  end
  local ok, status, err = pcall(install_unlocked, plugin, deadline, locked_commit)
  local removed, remove_err = run({ "rmdir", "--", lock })
  if not removed then
    return nil, "cannot release install lock " .. lock .. ": " .. tostring(remove_err)
  end
  if not ok then
    return nil, tostring(status)
  end
  return status, err
end

---@param plugin AmberPlugin
---@return string? status
---@return string? err
local function update(plugin, deadline)
  if deadline and os.time() >= deadline then
    return nil, "action time budget exhausted; retry remaining plugins"
  end
  if plugin.local_path then
    return nil, "local plugins are managed outside amber"
  end
  if not exists(plugin.dir .. "/.git/HEAD") then
    return nil, "not installed"
  end
  if plugin.version then
    local result, err = timed_run({ "git", "fetch", "--tags", "origin" }, {
      cwd = plugin.dir,
      timeout = 20,
      env = { GIT_TERMINAL_PROMPT = "0" },
    }, deadline)
    if not result then
      return nil, err
    end
    result, err = checkout_version(plugin, plugin.dir, deadline)
    if not result then
      return nil, err
    end
    return "updated"
  end
  local branch, branch_err = rex.exec({ "git", "symbolic-ref", "--quiet", "HEAD" }, {
    cwd = plugin.dir,
    timeout = 2,
  })
  if not branch then
    return nil, branch_err
  end
  if not branch.ok and branch.code ~= 1 then
    return nil, "cannot determine checkout branch"
  end
  if not branch.ok then
    local clean, clean_err = timed_run(
      { "git", "status", "--porcelain", "--untracked-files=normal" },
      { cwd = plugin.dir, timeout = 5 },
      deadline
    )
    if not clean then
      return nil, clean_err
    end
    if clean.stdout ~= "" then
      return nil, "working tree is not clean; refusing to update detached checkout"
    end
    local fetched, fetch_err = timed_run(
      { "git", "fetch", "origin" },
      { cwd = plugin.dir, timeout = 20, env = { GIT_TERMINAL_PROMPT = "0" } },
      deadline
    )
    if not fetched then
      return nil, fetch_err
    end
    local default, default_err = timed_run(
      { "git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" },
      { cwd = plugin.dir, timeout = 2 },
      deadline
    )
    if not default then
      return nil, "cannot determine origin default branch: " .. tostring(default_err)
    end
    local ref = default.stdout:gsub("%s+$", "")
    if not ref:match("^refs/remotes/origin/") then
      return nil, "invalid origin default branch"
    end
    local ancestor, ancestor_err = timed_run(
      { "git", "merge-base", "--is-ancestor", "HEAD", ref },
      { cwd = plugin.dir, timeout = 5 },
      deadline
    )
    if not ancestor then
      return nil, "cannot fast-forward detached checkout: " .. tostring(ancestor_err)
    end
    local result, err = timed_run(
      { "git", "checkout", "--detach", ref, "--" },
      { cwd = plugin.dir, timeout = 5 },
      deadline
    )
    if not result then
      return nil, err
    end
  else
    local result, err = timed_run({ "git", "pull", "--ff-only" }, {
      cwd = plugin.dir,
      timeout = 20,
      env = { GIT_TERMINAL_PROMPT = "0" },
    }, deadline)
    if not result then
      return nil, err
    end
  end
  return "updated"
end

local function commit(plugin, deadline)
  local result, err = timed_run(
    { "git", "rev-parse", "--verify", "HEAD^{commit}" },
    { cwd = plugin.dir, timeout = 2 },
    deadline
  )
  if not result then
    return nil, err
  end
  local hash = result.stdout:gsub("%s+$", "")
  if not hash:match("^[0-9a-f]+$") or (#hash ~= 40 and #hash ~= 64) then
    return nil, "invalid Git commit"
  end
  return hash
end

local function restore(plugin, deadline, hash)
  if plugin.local_path then
    return nil, "local plugins are managed outside amber"
  end
  if not exists(plugin.dir .. "/.git/HEAD") then
    return install(plugin, deadline, hash)
  end
  local status, err = timed_run(
    { "git", "status", "--porcelain", "--untracked-files=normal" },
    { cwd = plugin.dir, timeout = 5 },
    deadline
  )
  if not status then
    return nil, err
  end
  if status.stdout ~= "" then
    return nil, "working tree is not clean; refusing to restore"
  end
  local result, checkout_err = timed_run(
    { "git", "checkout", "--detach", hash, "--" },
    { cwd = plugin.dir, timeout = 5 },
    deadline
  )
  if not result then
    return nil, checkout_err
  end
  return "restored"
end

return {
  install = install,
  update = update,
  restore = restore,
  commit = commit,
  version_status = version_status,
}
