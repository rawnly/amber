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

return { commit = commit, version_status = version_status }
