local root = assert(arg[1], "pass fixture directory")
local original_path = package.path
local original_loaders = {}
for i, loader in ipairs(package.loaders) do
  original_loaders[i] = loader
end

local function test(name, fn)
  local actions, logs, calls = {}, {}, {}
  local lock_path = root .. "/test-lock.json"
  os.remove(lock_path)
  local saved_lock
  ---@type table<string, any>
  local behavior = { tags = "v1.2.0\nv1.4.0\nv2.0.0\n", mismatch = false }
  package.path = root .. "/?.lua;" .. original_path
  for i = #package.loaders, 1, -1 do
    package.loaders[i] = nil
  end
  for i, loader in ipairs(original_loaders) do
    package.loaders[i] = loader
  end
  package.loaded.example, package.loaded.shared, package.loaded.keys = nil, nil, nil
  _G.plugin_message = nil
  rex = {
    json = {
      encode = function(value)
        saved_lock = value
        behavior.lock_data = value
        return "test-lock"
      end,
      decode = function()
        return saved_lock
      end,
    },
    action = function(action)
      actions[action.name] = action
    end,
    log = function(level, message)
      logs[#logs + 1] = { level, message }
    end,
    exec = function(argv, opts)
      if argv[1] == "test" and (argv[2] == "-d" or argv[2] == "-e") then
        local file = io.open(argv[3], "r")
        if file then
          file:close()
        end
        return { ok = file ~= nil, stdout = "", stderr = "", code = file and 0 or 1 }
      end
      calls[#calls + 1] = { argv = argv, opts = opts }
      if argv[1] == "mkdir" or argv[1] == "rm" or argv[1] == "rmdir" then
        return { ok = true, stdout = "", stderr = "", code = 0 }
      end
      if argv[1] == "mktemp" then
        if argv[2] ~= "-d" then
          local path = root .. "/lock-temp"
          local file = assert(io.open(path, "w"))
          file:close()
          return { ok = true, stdout = path .. "\n", stderr = "", code = 0 }
        end
        return {
          ok = true,
          stdout = root .. "/" .. (behavior.temp or "temporary") .. "\n",
          stderr = "",
          code = 0,
        }
      end
      if argv[1] == "git" and argv[2] == "clone" then
        if behavior.clone_success then
          return { ok = true, stdout = "", stderr = "", code = 0 }
        end
        return {
          ok = false,
          stdout = "",
          stderr = "clone failed",
          code = 1,
          timed_out = behavior.clone_timeout,
        }
      end
      if argv[1] == "mv" and behavior.clone_success then
        local ok, err = os.rename(argv[4], argv[5])
        return { ok = ok ~= nil, stdout = "", stderr = err or "", code = ok and 0 or 1 }
      end
      if argv[1] == "git" and argv[2] == "tag" then
        return { ok = true, stdout = behavior.tags, stderr = "", code = 0 }
      end
      if argv[1] == "git" and argv[2] == "checkout" and behavior.checkout_failure then
        return { ok = false, stdout = "", stderr = "checkout failed", code = 1 }
      end
      if argv[1] == "git" and argv[2] == "symbolic-ref" then
        if argv[4] == "HEAD" and behavior.detached then
          return { ok = false, code = 1, stdout = "", stderr = "" }
        end
        return { ok = true, code = 0, stdout = "refs/remotes/origin/main\n", stderr = "" }
      end
      if argv[1] == "git" and argv[2] == "merge-base" then
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end
      if argv[1] == "git" and argv[2] == "status" then
        return { ok = true, stdout = behavior.dirty and " M file\n" or "", stderr = "", code = 0 }
      end
      if argv[1] == "git" and argv[2] == "rev-parse" then
        local is_head = argv[4] == "HEAD^{commit}" or argv[3] == "HEAD"
        local value = behavior.mismatch and is_head and string.rep("b", 40)
          or (is_head and behavior.head_hash or nil)
          or string.rep("a", 40)
        return { ok = true, stdout = value .. "\n", stderr = "", code = 0 }
      end
      if
        argv[1] == "git" and (argv[2] == "pull" or argv[2] == "fetch" or argv[2] == "checkout")
      then
        return { ok = true, stdout = "updated", stderr = "", code = 0 }
      end
      return nil, "unexpected command"
    end,
  }
  local rpm = dofile("rex_plugin_manager.lua")
  local setup = rpm.setup
  ---@diagnostic disable-next-line: duplicate-set-field
  rpm.setup = function(config)
    config = config or {}
    config.lockfile = lock_path
    return setup(config)
  end
  local ok, err = pcall(fn, rpm, actions, logs, calls, behavior)
  if not ok then
    error(name .. ": " .. tostring(err), 0)
  end
  print("ok - " .. name)
end

local function called(calls, command, argument)
  for _, call in ipairs(calls) do
    if call.argv[1] == command and call.argv[2] == argument then
      return call
    end
  end
end

test("loads installed plugins without shadowing user modules", function(rpm, actions, logs, calls)
  rpm.setup({
    root = root,
    plugins = { { "alice/example", opts = { message = "configured" } }, "bob/missing" },
  })
  assert(_G.plugin_message == "configured" and require("example") == package.loaded.example)
  assert(require("keys") == "user")
  assert(logs[1][2]:match("not found") and not called(calls, "git", "clone"))
  local report = actions.rpm_status.run({}, {})
  assert(report["alice/example"].loaded == "loaded" and report["bob/missing"].loaded == "missing")
  assert(not pcall(actions.rpm_install.run, {}, {}))
end)

test("bulk results are keyed by plugin name, even when empty", function(rpm, actions)
  rpm.setup({ root = root, install = "manual", plugins = {} })
  local result = actions.rpm_install.run({}, {})
  assert(type(result.plugins) == "table" and next(result.plugins) == nil)
  rpm.setup({ root = root, install = "manual", plugins = { "alice/example" } })
  result = actions.rpm_install.run({}, {})
  assert(result.plugins["alice/example"].status == "already installed")
end)

test("configuration loading never clones", function(rpm, _, _, calls)
  rpm.setup({ root = root, plugins = { "bob/missing" } })
  assert(not called(calls, "git", "clone"))
end)

test("disabled plugins neither load nor install", function(rpm, actions, logs, calls)
  rpm.setup({
    root = root,
    plugins = { { "alice/example", enabled = false }, { "bob/missing", enabled = false } },
  })
  assert(_G.plugin_message == nil and #logs == 0 and not called(calls, "git", "clone"))
  assert(not pcall(actions.rpm_install.run, {}, { plugin = "alice/example" }))
  assert(not pcall(actions.rpm_update.run, {}, { plugin = "alice/example" }))
end)

test("loads a local checkout without a cached module", function(rpm, actions)
  rpm.setup({
    root = root,
    plugins = { { "alice/example", path = root .. "/alice/example", opts = { message = "local" } } },
  })
  assert(_G.plugin_message == "local")
  assert(not pcall(actions.rpm_update.run, {}, { plugin = "alice/example" }))
end)

test("reports invalid and duplicate specifications", function(rpm, _, logs)
  ---@diagnostic disable-next-line: assign-type-mismatch
  rpm.setup({
    root = root,
    install = "manual",
    plugins = { "../escape", { "a/b", enabled = "no" } },
  })
  assert(logs[#logs][2]:match("invalid plugin"))
  rpm.setup({
    root = root,
    install = "manual",
    plugins = { { "alice/example", version = ">=1.0.0" } },
  })
  assert(logs[#logs][2]:match("invalid version"))
  rpm.setup({ root = root, install = "manual", plugins = { "alice/example", "bob/example" } })
  assert(logs[#logs][2]:match("duplicate"))
  rpm.setup({ root = root, install = "manual", plugins = { { "alice/example", verison = "v1" } } })
  assert(logs[#logs][2]:match("did you mean version"))
end)

test("prefers Rex modules without falling back for submodules", function(rpm)
  rpm.setup({ root = root, plugins = { "carol/shared" } })
  ---@diagnostic disable-next-line: undefined-field
  assert(_G.shared_source == "rex")
  assert(not pcall(require, "shared.missing"))
end)

test(
  "selects compatible versions and warns about drift",
  function(rpm, actions, logs, calls, behavior)
    behavior.mismatch = true
    rpm.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
    assert(logs[#logs][2]:match("checkout does not match"))
    behavior.mismatch = false
    assert(actions.rpm_update.run({}, { plugin = "alice/example" }).status == "updated")
    local checkout = called(calls, "git", "checkout")
    assert(checkout and checkout.argv[4] == "v1.4.0")
  end
)

test(
  "installs a missing plugin and publishes its checkout",
  function(rpm, actions, _, calls, behavior)
    behavior.clone_success = true
    rpm.setup({ root = root, install = "manual", plugins = { { "bob/new", version = "~1.2.0" } } })
    assert(actions.rpm_install.run({}, { plugin = "bob/new" }).status == "installed")
    local checkout = called(calls, "git", "checkout")
    assert(checkout and checkout.argv[4] == "v1.2.0")
    local head = assert(io.open(root .. "/bob/new/.git/HEAD", "r"))
    head:close()
  end
)

test(
  "installs the locked commit despite a changed version spec",
  function(rpm, actions, _, calls, behavior)
    rpm.setup({ root = root, plugins = { "alice/example", { "bob/pinned", version = "^1.2.0" } } })
    actions.rpm_install.run({}, { plugin = "alice/example" })
    behavior.lock_data.plugins["bob/pinned"] = { commit = string.rep("b", 40), version = "v1.0.0" }
    behavior.clone_success, behavior.temp = true, "locked"
    assert(actions.rpm_install.run({}, { plugin = "bob/pinned" }).status == "installed")
    local checkout = called(calls, "git", "checkout")
    assert(checkout and checkout.argv[4] == string.rep("b", 40))
    assert(behavior.lock_data.plugins["bob/pinned"].version == "v1.0.0")
  end
)

test("selects caret ranges in major version zero", function(rpm, actions, _, calls, behavior)
  behavior.tags = "v0.2.0\nv0.2.8\nv0.3.0\n"
  rpm.setup({
    root = root,
    install = "manual",
    plugins = { { "alice/example", version = "^0.2.0" } },
  })
  actions.rpm_update.run({}, { plugin = "alice/example" })
  local checkout = called(calls, "git", "checkout")
  assert(checkout and checkout.argv[4] == "v0.2.8")
end)

test("cleans up after version checkout failure", function(rpm, actions, _, calls, behavior)
  behavior.clone_success, behavior.checkout_failure = true, true
  rpm.setup({ root = root, install = "manual", plugins = { { "bob/failed", version = "~1.2.0" } } })
  local ok, err = pcall(actions.rpm_install.run, {}, { plugin = "bob/failed" })
  assert(not ok and tostring(err):match("checkout failed"))
  assert(called(calls, "rm", "-rf"))
end)

test("bulk operations skip local and disabled plugins", function(rpm, actions, _, calls)
  rpm.setup({
    root = root,
    install = "manual",
    plugins = {
      { "alice/example", path = root .. "/alice/example" },
      { "bob/missing", enabled = false },
    },
  })
  local result = actions.rpm_install.run({}, {})
  assert(next(result.plugins) == nil and not called(calls, "git", "clone"))
end)

test("reports clone timeouts and cleans up", function(rpm, actions, _, calls, behavior)
  behavior.clone_timeout = true
  rpm.setup({ root = root, install = "manual", plugins = { "bob/missing" } })
  local ok, err = pcall(actions.rpm_install.run, {}, { plugin = "bob/missing" })
  assert(not ok and tostring(err):match("timed out"))
  assert(called(calls, "rm", "-rf"))
end)

test(
  "records commits and refuses to restore dirty checkouts",
  function(rpm, actions, _, calls, behavior)
    rpm.setup({ root = root, plugins = { "alice/example" } })
    assert(actions.rpm_install.run({}, { plugin = "alice/example" }).status == "already installed")
    behavior.dirty = true
    local ok, err = pcall(actions.rpm_restore.run, {}, { plugin = "alice/example" })
    assert(not ok and tostring(err):match("working tree is not clean"))
    assert(not called(calls, "git", "checkout"))
    behavior.dirty = false
    assert(actions.rpm_restore.run({}, { plugin = "alice/example" }).status == "restored")
    assert(called(calls, "git", "checkout").argv[4] == string.rep("a", 40))
  end
)

test("updates the lock only on an explicit update", function(rpm, actions, logs, _, behavior)
  rpm.setup({ root = root, plugins = { "alice/example" } })
  actions.rpm_install.run({}, { plugin = "alice/example" })
  behavior.head_hash = string.rep("b", 40)
  rpm.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
  local found = false
  for _, log in ipairs(logs) do
    if log[2]:match("version spec changed") then
      found = true
    end
  end
  assert(found)
  local before = actions.rpm_status.run({}, {})["alice/example"]
  assert(before.locked_commit == string.rep("a", 40) and before.lock_matches == false)
  actions.rpm_update.run({}, { plugin = "alice/example" })
  local after = actions.rpm_status.run({}, {})["alice/example"]
  assert(after.locked_commit == string.rep("b", 40) and after.lock_matches == true)
end)

test("rejects a corrupt lockfile without overwriting it", function(rpm, actions)
  local path = root .. "/test-lock.json"
  local file = assert(io.open(path, "w"))
  file:write("not json")
  file:close()
  rpm.setup({ root = root, plugins = { "alice/example" } })
  assert(not pcall(actions.rpm_install.run, {}, { plugin = "alice/example" }))
  file = assert(io.open(path, "r"))
  assert(file:read("*a") == "not json")
  file:close()
end)

test("updates a clean detached checkout after restore", function(rpm, actions, _, calls, behavior)
  rpm.setup({ root = root, plugins = { "alice/example" } })
  actions.rpm_install.run({}, { plugin = "alice/example" })
  behavior.detached = true
  assert(actions.rpm_update.run({}, { plugin = "alice/example" }).status == "updated")
  local checkout = called(calls, "git", "checkout")
  assert(checkout and checkout.argv[4] == "refs/remotes/origin/main")
end)

test("rejects expired operation budgets", function()
  local git = assert(loadfile("rpm/git.lua"))(dofile("rpm/util.lua"))
  local status, err = git.install({ local_path = false }, os.time() - 1)
  assert(not status and err:match("time budget exhausted"))
end)

print("tests passed")
