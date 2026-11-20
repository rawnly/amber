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
  package.loaded.example, package.loaded.shared, package.loaded.keys, package.loaded.tools =
    nil, nil, nil, nil
  package.loaded.built, package.loaded.plain = nil, nil
  _G.built_ctx, _G.plain_ctx = nil, nil
  _G.plugin_message = nil
  _G.subdir_message = nil
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
      if argv[1] == "sh" and argv[2] == "-c" then
        local failed = behavior.build_fail
        return {
          ok = not failed,
          stdout = "",
          stderr = failed and "build exploded" or "",
          code = failed and 1 or 0,
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
  local amber = dofile("amber.lua")
  local setup = amber.setup
  ---@diagnostic disable-next-line: duplicate-set-field
  amber.setup = function(config)
    config = config or {}
    config.lockfile = lock_path
    return setup(config)
  end
  local ok, err = pcall(fn, amber, actions, logs, calls, behavior)
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

test("loads installed plugins without shadowing user modules", function(amber, actions, logs, calls)
  amber.setup({
    root = root,
    plugins = { { "alice/example", opts = { message = "configured" } }, "bob/missing" },
  })
  assert(_G.plugin_message == "configured" and require("example") == package.loaded.example)
  assert(require("keys") == "user")
  assert(logs[1][2]:match("not found") and not called(calls, "git", "clone"))
  local report = actions.amber_status.run({}, {})
  assert(report["alice/example"].loaded == "loaded" and report["bob/missing"].loaded == "missing")
  assert(not pcall(actions.amber_install.run, {}, {}))
end)

test("bulk results are keyed by plugin name, even when empty", function(amber, actions)
  amber.setup({ root = root, install = "manual", plugins = {} })
  local result = actions.amber_install.run({}, {})
  assert(type(result.plugins) == "table" and next(result.plugins) == nil)
  amber.setup({ root = root, install = "manual", plugins = { "alice/example" } })
  result = actions.amber_install.run({}, {})
  assert(result.plugins["alice/example"].status == "already installed")
end)

test("configuration loading never clones", function(amber, _, _, calls)
  amber.setup({ root = root, plugins = { "bob/missing" } })
  assert(not called(calls, "git", "clone"))
end)

test("disabled plugins neither load nor install", function(amber, actions, logs, calls)
  amber.setup({
    root = root,
    plugins = { { "alice/example", enabled = false }, { "bob/missing", enabled = false } },
  })
  assert(_G.plugin_message == nil and #logs == 0 and not called(calls, "git", "clone"))
  assert(not pcall(actions.amber_install.run, {}, { plugin = "alice/example" }))
  assert(not pcall(actions.amber_update.run, {}, { plugin = "alice/example" }))
end)

test("loads a local checkout without a cached module", function(amber, actions)
  amber.setup({
    root = root,
    plugins = { { "alice/example", path = root .. "/alice/example", opts = { message = "local" } } },
  })
  assert(_G.plugin_message == "local")
  assert(not pcall(actions.amber_update.run, {}, { plugin = "alice/example" }))
end)

test("reports invalid and duplicate specifications", function(amber, _, logs)
  ---@diagnostic disable-next-line: assign-type-mismatch
  amber.setup({
    root = root,
    install = "manual",
    plugins = { "../escape", { "a/b", enabled = "no" } },
  })
  assert(logs[#logs][2]:match("invalid plugin"))
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "alice/example", version = ">=1.0.0" } },
  })
  assert(logs[#logs][2]:match("invalid version"))
  amber.setup({ root = root, install = "manual", plugins = { "alice/example", "bob/example" } })
  assert(logs[#logs][2]:match("duplicate"))
  amber.setup({ root = root, install = "manual", plugins = { { "alice/example", verison = "v1" } } })
  assert(logs[#logs][2]:match("did you mean version"))
end)

test("prefers Rex modules without falling back for submodules", function(amber)
  amber.setup({ root = root, plugins = { "carol/shared" } })
  ---@diagnostic disable-next-line: undefined-field
  assert(_G.shared_source == "rex")
  assert(not pcall(require, "shared.missing"))
end)

test(
  "selects compatible versions and warns about drift",
  function(amber, actions, logs, calls, behavior)
    behavior.mismatch = true
    amber.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
    assert(logs[#logs][2]:match("checkout does not match"))
    behavior.mismatch = false
    assert(actions.amber_update.run({}, { plugin = "alice/example" }).status == "updated")
    local checkout = called(calls, "git", "checkout")
    assert(checkout and checkout.argv[4] == "v1.4.0")
  end
)

test(
  "installs a missing plugin and publishes its checkout",
  function(amber, actions, _, calls, behavior)
    behavior.clone_success = true
    amber.setup({ root = root, install = "manual", plugins = { { "bob/new", version = "~1.2.0" } } })
    assert(actions.amber_install.run({}, { plugin = "bob/new" }).status == "installed")
    local checkout = called(calls, "git", "checkout")
    assert(checkout and checkout.argv[4] == "v1.2.0")
    local head = assert(io.open(root .. "/bob/new/.git/HEAD", "r"))
    head:close()
  end
)

test(
  "installs the locked commit despite a changed version spec",
  function(amber, actions, _, calls, behavior)
    amber.setup({ root = root, plugins = { "alice/example", { "bob/pinned", version = "^1.2.0" } } })
    actions.amber_install.run({}, { plugin = "alice/example" })
    behavior.lock_data.plugins["bob/pinned"] = { commit = string.rep("b", 40), version = "v1.0.0" }
    behavior.clone_success, behavior.temp = true, "locked"
    assert(actions.amber_install.run({}, { plugin = "bob/pinned" }).status == "installed")
    local checkout = called(calls, "git", "checkout")
    assert(checkout and checkout.argv[4] == string.rep("b", 40))
    assert(behavior.lock_data.plugins["bob/pinned"].version == "v1.0.0")
  end
)

test("selects caret ranges in major version zero", function(amber, actions, _, calls, behavior)
  behavior.tags = "v0.2.0\nv0.2.8\nv0.3.0\n"
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "alice/example", version = "^0.2.0" } },
  })
  actions.amber_update.run({}, { plugin = "alice/example" })
  local checkout = called(calls, "git", "checkout")
  assert(checkout and checkout.argv[4] == "v0.2.8")
end)

test("cleans up after version checkout failure", function(amber, actions, _, calls, behavior)
  behavior.clone_success, behavior.checkout_failure = true, true
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "bob/failed", version = "~1.2.0" } },
  })
  local ok, err = pcall(actions.amber_install.run, {}, { plugin = "bob/failed" })
  assert(not ok and tostring(err):match("checkout failed"))
  assert(called(calls, "rm", "-rf"))
end)

test("bulk operations skip local and disabled plugins", function(amber, actions, _, calls)
  amber.setup({
    root = root,
    install = "manual",
    plugins = {
      { "alice/example", path = root .. "/alice/example" },
      { "bob/missing", enabled = false },
    },
  })
  local result = actions.amber_install.run({}, {})
  assert(next(result.plugins) == nil and not called(calls, "git", "clone"))
end)

test("loads a subdir plugin from its own module root", function(amber, actions)
  amber.setup({
    root = root,
    plugins = { { "elly/utility", subdir = "panes/tools", main = "tools" } },
  })
  assert(_G.subdir_message == "installed")
  assert(not pcall(require, "utility"), "the repo-root module must not resolve")
  local report = actions.amber_status.run({}, {})
  local row = report["elly/utility@panes/tools"]
  assert(row and row.subdir == "panes/tools" and row.path == root .. "/elly/utility--panes-tools")
end)

test("requires main for subdir plugins", function(amber, _, logs)
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "elly/utility", subdir = "panes/tools" } },
  })
  assert(logs[1][2]:match("main is required for subdir plugins"))
end)

test("rejects malformed subdir values", function(amber, _, logs)
  for _, subdir in ipairs({
    "/abs",
    "leaf/",
    ".",
    "..",
    "a/../b",
    "a//b",
    "panes/to ols",
    "a!b/c",
    "",
    7,
    true,
  }) do
    amber.setup({
      root = root,
      install = "manual",
      ---@diagnostic disable-next-line: assign-type-mismatch
      plugins = { { "elly/utility", subdir = subdir, main = "tools" } },
    })
    assert(
      logs[1][2]:match("invalid plugin specification"),
      "expected rejection of " .. tostring(subdir)
    )
  end
end)

test(
  "installs subdir clones into sanitized locations and keys results by identity",
  function(amber, actions, _, calls, behavior)
    behavior.clone_success = true
    behavior.temp = "temporary2"
    amber.setup({
      root = root,
      install = "manual",
      plugins = { { "elly/other", subdir = "panes/bells", main = "bells" } },
    })
    local result = actions.amber_install.run({}, { plugin = "elly/other@panes/bells" })
    assert(result.status == "installed", tostring(result))
    local move
    for _, call in ipairs(calls) do
      if call.argv[1] == "mv" and call.argv[2] == "-n" then
        move = call
      end
    end
    assert(move and move.argv[5] == root .. "/elly/other--panes-bells")
    local head = assert(io.open(root .. "/elly/other--panes-bells/.git/HEAD", "r"))
    head:close()
  end
)

test("reports duplicate dirs: sanitized collision and plain repo", function(amber, actions, logs)
  -- A plain repository whose name already carries the sanitized suffix
  -- collides with the sibling that owns `subdir`.
  amber.setup({
    root = root,
    install = "manual",
    plugins = {
      { "elly/utility--panes-tools", main = "chimes" },
      { "elly/utility", subdir = "panes/tools", main = "tools" },
    },
  })
  assert(logs[1][2]:match("duplicate install location"))
  -- The same clash when the plain repository is disabled: the enabled subdir
  -- plugin must not adopt that checkout, so it is skipped as well.
  local first = #logs
  amber.setup({
    root = root,
    install = "manual",
    plugins = {
      { "elly/utility--panes-tools", main = "chimes", enabled = false },
      { "elly/utility", subdir = "panes/tools", main = "tools" },
    },
  })
  assert(logs[first + 1][2]:match("duplicate install location"))
  assert(_G.subdir_message == nil, "a disabled checkout must not satisfy a subdir plugin")
  assert(actions.amber_status.run({}, {})["elly/utility@panes/tools"] == nil)
  -- Different subdirs can sanitize to the same install directory.
  amber.setup({
    root = root,
    install = "manual",
    plugins = {
      { "elly/utility", subdir = "panes/tools", main = "tools" },
      { "elly/utility", subdir = "panes-tools", main = "mirror" },
    },
  })
  assert(logs[#logs][2]:match("duplicate install location"))
  amber.setup({
    root = root,
    install = "manual",
    plugins = {
      { "elly/utility", subdir = "panes/tools", main = "tools" },
      { "elly/utility", subdir = "panes/tools", main = "mirror" },
    },
  })
  assert(logs[#logs][2]:match("duplicate plugin"))
end)

test("suggests subdir for near-miss option names", function(amber, _, logs)
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "elly/utility", subdirt = "panes/tools", main = "tools" } },
  })
  assert(logs[1][2]:match("did you mean subdir"))
end)

test(
  "a plain repo and a subdir plugin of one repo coexist with separate locks",
  function(amber, actions, _, calls, behavior)
    behavior.clone_success = true
    behavior.temp = "temporary3"
    amber.setup({
      root = root,
      install = "manual",
      plugins = {
        { "elly/utility" },
        { "elly/monorepo", subdir = "panes/tools", main = "tools" },
      },
    })
    assert(actions.amber_install.run({}, { plugin = "elly/utility" }).status == "installed")
    behavior.temp = "temporary4"
    assert(
      actions.amber_install.run({}, { plugin = "elly/monorepo@panes/tools" }).status == "installed"
    )
    local report = actions.amber_status.run({}, {})
    assert(report["elly/utility"] and report["elly/monorepo@panes/tools"])
    assert(
      #report["elly/utility"].commit == 40 and #report["elly/monorepo@panes/tools"].commit == 40
    )
  end
)

test("marks a missing subdirectory and names it", function(amber, actions)
  amber.setup({
    root = root,
    plugins = { { "alice/example", path = root .. "/bob", subdir = "gone", main = "tools" } },
  })
  local row = actions.amber_status.run({}, {})["alice/example@gone"]
  assert(row and row.loaded == "missing" and row.error:match("subdir gone not found"))
end)

test("warns instead of erroring for an uninstalled subdir checkout", function(amber, actions, logs)
  -- The clone does not exist yet, so setup must not claim the subdirectory is
  -- missing; it reports the module like a plain uninstalled plugin does.
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "elly/notyet", subdir = "panes/tools", main = "tools" } },
  })
  for _, entry in ipairs(logs) do
    assert(entry[1] ~= "error", "unexpected error log: " .. entry[2])
  end
  local row = actions.amber_status.run({}, {})["elly/notyet@panes/tools"]
  assert(row and row.loaded == "missing")
  assert(row.error:match("module tools not found in"))
  assert(not row.error:match("subdir"))
end)

test("names a missing subdirectory in an existing checkout", function(amber, actions, logs)
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "elly/claimed", subdir = "gone", main = "tools" } },
  })
  local errors = {}
  for _, entry in ipairs(logs) do
    if entry[1] == "error" then
      errors[#errors + 1] = entry[2]
    end
  end
  assert(#errors == 1 and errors[1]:match("subdir gone not found in"), table.concat(errors, "; "))
  local row = actions.amber_status.run({}, {})["elly/claimed@gone"]
  assert(row and row.loaded == "missing" and row.error:match("subdir gone not found"))
end)

test("rejects unknown plugin names for targeted actions", function(amber, actions)
  amber.setup({ root = root, install = "manual", plugins = { "elly/utility" } })
  assert(not pcall(actions.amber_install.run, {}, { plugin = "bob/none" }))
end)

test(
  "moves two subdirs of one repo to different pinned versions",
  function(amber, actions, _, calls, behavior)
    behavior.clone_success = true
    amber.setup({
      root = root,
      install = "manual",
      plugins = {
        { "elly/utility", subdir = "panes/tools", main = "tools", version = "^1.2.0" },
        { "elly/utility", subdir = "panes/bells", main = "bells", version = "~2.0.0" },
      },
    })
    local update = actions.amber_update
    assert(update.run({}, { plugin = "elly/utility@panes/tools" }).status == "updated")
    assert(update.run({}, { plugin = "elly/utility@panes/bells" }).status == "updated")
    local checkouts = {}
    for _, call in ipairs(calls) do
      if call.argv[1] == "git" and call.argv[2] == "checkout" then
        checkouts[#checkouts + 1] = call.argv[4]
      end
    end
    assert(#checkouts == 2, "expected two pinned checkouts")
    local saw_v14, saw_v20 = false, false
    for _, ref in ipairs(checkouts) do
      if ref == "v1.4.0" then
        saw_v14 = true
      end
      if ref == "v2.0.0" then
        saw_v20 = true
      end
    end
    assert(saw_v14 and saw_v20)
  end
)

test("resolves path + subdir inside the local checkout", function(amber)
  amber.setup({
    root = root,
    plugins = {
      { "alice/example", path = root .. "/local-mono", subdir = "panes/tools", main = "tools" },
    },
  })
  assert(_G.subdir_message == "local")
end)

test("reports clone timeouts and cleans up", function(amber, actions, _, calls, behavior)
  behavior.clone_timeout = true
  amber.setup({ root = root, install = "manual", plugins = { "bob/missing" } })
  local ok, err = pcall(actions.amber_install.run, {}, { plugin = "bob/missing" })
  assert(not ok and tostring(err):match("timed out"))
  assert(called(calls, "rm", "-rf"))
end)

test(
  "records commits and refuses to restore dirty checkouts",
  function(amber, actions, _, calls, behavior)
    amber.setup({ root = root, plugins = { "alice/example" } })
    assert(
      actions.amber_install.run({}, { plugin = "alice/example" }).status == "already installed"
    )
    behavior.dirty = true
    local ok, err = pcall(actions.amber_restore.run, {}, { plugin = "alice/example" })
    assert(not ok and tostring(err):match("working tree is not clean"))
    assert(not called(calls, "git", "checkout"))
    behavior.dirty = false
    assert(actions.amber_restore.run({}, { plugin = "alice/example" }).status == "restored")
    assert(called(calls, "git", "checkout").argv[4] == string.rep("a", 40))
  end
)

test("updates the lock only on an explicit update", function(amber, actions, logs, _, behavior)
  amber.setup({ root = root, plugins = { "alice/example" } })
  actions.amber_install.run({}, { plugin = "alice/example" })
  behavior.head_hash = string.rep("b", 40)
  amber.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
  local found = false
  for _, log in ipairs(logs) do
    if log[2]:match("version spec changed") then
      found = true
    end
  end
  assert(found)
  local before = actions.amber_status.run({}, {})["alice/example"]
  assert(before.locked_commit == string.rep("a", 40) and before.lock_matches == false)
  actions.amber_update.run({}, { plugin = "alice/example" })
  local after = actions.amber_status.run({}, {})["alice/example"]
  assert(after.locked_commit == string.rep("b", 40) and after.lock_matches == true)
end)

test("rejects a corrupt lockfile without overwriting it", function(amber, actions)
  local path = root .. "/test-lock.json"
  local file = assert(io.open(path, "w"))
  file:write("not json")
  file:close()
  amber.setup({ root = root, plugins = { "alice/example" } })
  assert(not pcall(actions.amber_install.run, {}, { plugin = "alice/example" }))
  file = assert(io.open(path, "r"))
  assert(file:read("*a") == "not json")
  file:close()
end)

test("updates a clean detached checkout after restore", function(amber, actions, _, calls, behavior)
  amber.setup({ root = root, plugins = { "alice/example" } })
  actions.amber_install.run({}, { plugin = "alice/example" })
  behavior.detached = true
  assert(actions.amber_update.run({}, { plugin = "alice/example" }).status == "updated")
  local checkout = called(calls, "git", "checkout")
  assert(checkout and checkout.argv[4] == "refs/remotes/origin/main")
end)

local function count_calls(calls, command)
  local total = 0
  for _, call in ipairs(calls) do
    if call.argv[1] == command then
      total = total + 1
    end
  end
  return total
end

test("passes a runtime context to setup", function(amber, actions)
  amber.setup({ root = root, plugins = { "dave/plain" } })
  local context = assert(_G.plain_ctx, "setup must receive a context")
  assert(context.name == "dave/plain" and context.dir == root .. "/dave/plain")
  assert(context.module_dir == context.dir and context.commit == nil)
  assert(context.data_dir:match("/rex/amber/dave/plain$"))
  actions.amber_install.run({}, { plugin = "dave/plain" })
  amber.setup({ root = root, plugins = { "dave/plain" } })
  assert(_G.plain_ctx.commit == string.rep("a", 40))
end)

test("builds on install and gates setup until built", function(amber, actions, logs, calls)
  local spec = { "dave/built", build = "make" }
  amber.setup({ root = root, plugins = { spec } })
  assert(_G.built_ctx == nil, "setup must wait for the build")
  assert(logs[#logs][2]:match("run amber_build"))
  assert(actions.amber_status.run({}, {})["dave/built"].loaded == "unbuilt")
  assert(actions.amber_install.run({}, { plugin = "dave/built" }).status == "already installed")
  local build = assert(called(calls, "sh", "-c"))
  assert(build.argv[3] == "make" and build.opts.cwd == root .. "/dave/built")
  assert(build.opts.env.AMBER_PLUGIN_NAME == "dave/built")
  assert(build.opts.timeout and build.opts.timeout <= 23)
  amber.setup({ root = root, plugins = { spec } })
  assert(_G.built_ctx and _G.built_ctx.commit == string.rep("a", 40))
  assert(actions.amber_status.run({}, {})["dave/built"].built == true)
  actions.amber_install.run({}, { plugin = "dave/built" })
  assert(count_calls(calls, "sh") == 1, "an unchanged commit must not rebuild")
end)

test("a failed build is retryable", function(amber, actions, _, calls, behavior)
  amber.setup({ root = root, plugins = { { "dave/built", build = { "make", "make install" } } } })
  behavior.build_fail = true
  local ok, err = pcall(actions.amber_install.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("build step 1 failed: build exploded"), tostring(err))
  assert(count_calls(calls, "sh") == 1, "later steps must not run after a failure")
  local entry = behavior.lock_data.plugins["dave/built"]
  assert(entry.commit == string.rep("a", 40) and entry.built == nil)
  assert(actions.amber_status.run({}, {})["dave/built"].built == false)
  behavior.build_fail = false
  assert(actions.amber_build.run({}, { plugin = "dave/built" }).status == "built")
  assert(count_calls(calls, "sh") == 3)
  assert(behavior.lock_data.plugins["dave/built"].built == string.rep("a", 40))
end)

test("amber_build rebuilds and skips plugins without one", function(amber, actions, _, calls, b)
  local behavior = b
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" }, "dave/plain" } })
  actions.amber_install.run({}, {})
  assert(count_calls(calls, "sh") == 1)
  local result = actions.amber_build.run({}, {})
  assert(result.plugins["dave/built"].status == "built")
  assert(result.plugins["dave/plain"].status == "no build step")
  assert(count_calls(calls, "sh") == 2, "amber_build must rebuild even when already built")
  assert(behavior.lock_data.plugins["dave/built"].built == string.rep("a", 40))
  amber.setup({ root = root, plugins = { { "bob/missing", build = "make" } } })
  local ok, err = pcall(actions.amber_build.run, {}, { plugin = "bob/missing" })
  assert(not ok and tostring(err):match("not installed"))
end)

test("a new commit invalidates the recorded build", function(amber, actions, _, calls, behavior)
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" } } })
  actions.amber_install.run({}, { plugin = "dave/built" })
  actions.amber_update.run({}, { plugin = "dave/built" })
  assert(count_calls(calls, "sh") == 1, "an update to the same commit keeps the build")
  behavior.head_hash = string.rep("b", 40)
  actions.amber_update.run({}, { plugin = "dave/built" })
  assert(count_calls(calls, "sh") == 2)
  local entry = behavior.lock_data.plugins["dave/built"]
  assert(entry.commit == string.rep("b", 40) and entry.built == string.rep("b", 40))
end)

test("runs function build steps and reports failures", function(amber, actions, _, _, behavior)
  local seen
  local mode = "ok"
  amber.setup({
    root = root,
    plugins = {
      {
        "dave/built",
        build = function(ctx)
          seen = ctx
          if mode == "false" then
            return false
          elseif mode == "message" then
            return nil, "no compiler"
          elseif mode == "raise" then
            error("boom", 0)
          end
          return ctx.exec({ "sh", "-c", "true" })
        end,
      },
    },
  })
  assert(actions.amber_install.run({}, { plugin = "dave/built" }).status == "already installed")
  assert(seen.name == "dave/built" and seen.commit == string.rep("a", 40))
  assert(seen.dir == root .. "/dave/built" and seen.module_dir == seen.dir)
  assert(behavior.lock_data.plugins["dave/built"].built == string.rep("a", 40))
  for failure, expected in pairs({
    ["false"] = "returned false",
    message = "no compiler",
    raise = "boom",
  }) do
    mode = failure
    local ok, err = pcall(actions.amber_build.run, {}, { plugin = "dave/built" })
    assert(not ok and tostring(err):match(expected), failure .. ": " .. tostring(err))
  end
end)

test("validates build specifications", function(amber, _, logs)
  for _, build in ipairs({ 7, true, {}, { 1 }, { "" }, { make = "make" }, "   " }) do
    amber.setup({
      root = root,
      install = "manual",
      ---@diagnostic disable-next-line: assign-type-mismatch
      plugins = { { "dave/built", build = build } },
    })
    assert(logs[#logs][2]:match("invalid plugin specification"), "accepted " .. tostring(build))
  end
  amber.setup({
    root = root,
    install = "manual",
    plugins = { { "dave/built", path = root .. "/dave/built", build = "make" } },
  })
  assert(logs[#logs][2]:match("build is not supported for local plugins"))
  local before = #logs
  amber.setup({ root = root, plugins = { { "dave/plain", build = false } } })
  assert(#logs == before and _G.plain_ctx, "build = false must disable the build")
end)

test("rejects malformed built entries in the lockfile", function()
  local path = root .. "/test-lock.json"
  local file = assert(io.open(path, "w"))
  file:write("{}")
  file:close()
  local lock = assert(loadfile("amber/lock.lua"))(dofile("amber/util.lua"))
  for _, built in ipairs({ "xyz", 7 }) do
    ---@diagnostic disable-next-line: duplicate-set-field
    rex.json.decode = function()
      return {
        format = 1,
        plugins = { ["a/b"] = { commit = string.rep("a", 40), built = built } },
      }
    end
    local data, err = lock.read(path)
    assert(not data and err:match("invalid lockfile entry"), tostring(built))
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  rex.json.decode = function()
    return {
      format = 1,
      plugins = { ["a/b"] = { commit = string.rep("a", 40), built = string.rep("a", 40) } },
    }
  end
  assert(lock.read(path))
end)

test("amber_build requires a lock entry", function(amber, actions, _, calls)
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" } } })
  local ok, err = pcall(actions.amber_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("no lockfile entry"), tostring(err))
  assert(count_calls(calls, "sh") == 0, "nothing may be built without a lock entry")
end)

test("does not build a drifted checkout", function(amber, actions, _, calls, behavior)
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" } } })
  actions.amber_install.run({}, { plugin = "dave/built" })
  assert(count_calls(calls, "sh") == 1)
  behavior.head_hash = string.rep("b", 40)
  local ok, err = pcall(actions.amber_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("checkout differs from lockfile"), tostring(err))
  assert(count_calls(calls, "sh") == 1, "a drifted checkout must not be built")
  assert(behavior.lock_data.plugins["dave/built"].built == string.rep("a", 40))
end)

test("builds outside the lockfile guard", function(amber, actions, _, calls, behavior)
  local guard = root .. "/test-lock.json.lock"
  local function held()
    local depth = 0
    for _, call in ipairs(calls) do
      if call.argv[3] == guard then
        depth = depth + (call.argv[1] == "mkdir" and 1 or -1)
      end
    end
    return depth
  end
  local during
  local move_lock = false
  amber.setup({
    root = root,
    plugins = {
      {
        "dave/built",
        build = function(ctx)
          during = held()
          if move_lock then
            behavior.lock_data.plugins["dave/built"].commit = string.rep("c", 40)
          end
          return ctx.exec({ "sh", "-c", "true" }, { env = { EXTRA = "1" } })
        end,
      },
    },
  })
  actions.amber_install.run({}, { plugin = "dave/built" })
  assert(during == 0, "the lockfile guard must be released before building")
  local build = assert(called(calls, "sh", "-c"))
  assert(build.opts.env.EXTRA == "1" and build.opts.env.AMBER_PLUGIN_NAME == "dave/built")
  assert(build.opts.env.AMBER_PLUGIN_DIR == root .. "/dave/built")
  assert(build.opts.env.AMBER_PLUGIN_MODULE_DIR == root .. "/dave/built")
  move_lock = true
  local ok, err = pcall(actions.amber_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("lockfile changed during the build"), tostring(err))
  assert(behavior.lock_data.plugins["dave/built"].built == string.rep("a", 40))
end)

test("rejects expired operation budgets", function()
  local git = assert(loadfile("amber/git.lua"))(dofile("amber/util.lua"))
  local status, err = git.install({ local_path = false }, os.time() - 1)
  assert(not status and err:match("time budget exhausted"))
end)

print("tests passed")
