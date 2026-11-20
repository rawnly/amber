---@type AmberUtil
local util = ...

local function remaining_budget(deadline)
  if not deadline then
    return nil
  end
  local remaining = deadline - os.time()
  if remaining <= 0 then
    return nil, "action time budget exhausted; run amber_build to retry"
  end
  return remaining
end

-- Run every build step of a managed plugin in order, stopping at the first
-- failure. String steps run through `sh -c` with the plugin directory as the
-- working directory; function steps receive a context and fail by raising an
-- error, returning false, or returning nil and a message. All steps share the
-- action time budget, so long-running work belongs in a detached process that
-- the plugin starts itself.
---@param plugin AmberPlugin
---@param commit string
---@param deadline? number
---@return boolean? ok
---@return string? err
local function run(plugin, commit, deadline)
  local base_env = {
    AMBER_PLUGIN_NAME = plugin.name,
    AMBER_PLUGIN_DIR = plugin.dir,
    AMBER_PLUGIN_MODULE_DIR = plugin.module_dir,
    AMBER_PLUGIN_DATA_DIR = plugin.data_dir,
  }
  ---@type AmberBuildContext
  local context = {
    name = plugin.name,
    dir = plugin.dir,
    module_dir = plugin.module_dir,
    data_dir = plugin.data_dir,
    commit = commit,
    exec = function(argv, opts)
      local timeout, budget_err = remaining_budget(deadline)
      if budget_err then
        return nil, budget_err
      end
      opts = opts or {}
      -- Caller variables extend the Amber ones instead of replacing them.
      local env = {}
      for key, value in pairs(base_env) do
        env[key] = value
      end
      for key, value in pairs(opts.env or {}) do
        env[key] = value
      end
      local limit = timeout
      if opts.timeout then
        limit = limit and math.min(limit, opts.timeout) or opts.timeout
      end
      return util.run(argv, {
        cwd = opts.cwd or plugin.module_dir,
        env = env,
        timeout = limit,
      })
    end,
  }
  for index, step in ipairs(plugin.build or {}) do
    local ok, err
    if type(step) == "string" then
      ok, err = context.exec({ "sh", "-c", step })
    else
      local called, first, second = pcall(step, context)
      if not called then
        ok, err = nil, tostring(first)
      elseif first == false or (first == nil and second ~= nil) then
        ok, err = nil, tostring(second or "build function returned false")
      else
        ok = true
      end
    end
    if not ok then
      return nil, "build step " .. index .. " failed: " .. tostring(err)
    end
  end
  return true
end

return { run = run }
