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
  -- Seeds the lockfile the way the CLI would have written it.
  behavior.seed = function(plugins)
    local file = assert(io.open(lock_path, "w"))
    file:write("seeded")
    file:close()
    saved_lock = { format = 1, plugins = plugins }
    behavior.lock_data = saved_lock
  end
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
    layout = {
      block = function(spec)
        return { block = spec }
      end,
    },
    session = {
      new_layer = function(args)
        behavior.layer = args
        return { layer_id = "layer:1", block_ids = { "block:1" } }
      end,
    },
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
    if config.cli == nil then
      config.cli = root .. "/bin-amber"
    end
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

local function count_calls(calls, command)
  local total = 0
  for _, call in ipairs(calls) do
    if call.argv[1] == command then
      total = total + 1
    end
  end
  return total
end

local A, B, C = string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)
local session = { session_id = "session:1" }

local binary = assert(io.open(root .. "/bin-amber", "w"))
binary:close()

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
end)

test("configuration loading never clones", function(amber, _, _, calls)
  amber.setup({ root = root, plugins = { "bob/missing" } })
  assert(not called(calls, "git", "clone"))
end)

test("disabled plugins neither load nor open the CLI", function(amber, actions, logs, calls)
  amber.setup({
    root = root,
    plugins = { { "alice/example", enabled = false }, { "bob/missing", enabled = false } },
  })
  assert(_G.plugin_message == nil and #logs == 0 and not called(calls, "git", "clone"))
  local ok, err = pcall(actions.amber_install.run, session, { plugin = "alice/example" })
  assert(not ok and tostring(err):match("disabled"))
  assert(not pcall(actions.amber_lua_build.run, session, { plugin = "alice/example" }))
end)

test("loads a local checkout without a cached module", function(amber, actions)
  amber.setup({
    root = root,
    plugins = { { "alice/example", path = root .. "/alice/example", opts = { message = "local" } } },
  })
  assert(_G.plugin_message == "local")
  local ok, err = pcall(actions.amber_update.run, session, { plugin = "alice/example" })
  assert(not ok and tostring(err):match("managed outside amber"))
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

test("warns when a checkout does not match its version", function(amber, _, logs, _, behavior)
  behavior.mismatch = true
  amber.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
  assert(logs[#logs][2]:match("checkout does not match"))
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

test("resolves path + subdir inside the local checkout", function(amber)
  amber.setup({
    root = root,
    plugins = {
      { "alice/example", path = root .. "/local-mono", subdir = "panes/tools", main = "tools" },
    },
  })
  assert(_G.subdir_message == "local")
end)

test("warns about a changed version spec and reports drift", function(amber, actions, logs, _, b)
  b.seed({ ["alice/example"] = { commit = A } })
  b.head_hash = B
  amber.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
  local found = false
  for _, log in ipairs(logs) do
    if log[2]:match("version spec changed") then
      found = true
    end
  end
  assert(found)
  local row = actions.amber_status.run({}, {})["alice/example"]
  assert(row.locked_commit == A and row.lock_matches == false)
end)

test("reports a corrupt lockfile without overwriting it", function(amber, actions)
  local path = root .. "/test-lock.json"
  local file = assert(io.open(path, "w"))
  file:write("not json")
  file:close()
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" } } })
  assert(actions.amber_info.run({}, {}).lock_error)
  assert(not pcall(actions.amber_lua_build.run, {}, { plugin = "dave/built" }))
  file = assert(io.open(path, "r"))
  assert(file:read("*a") == "not json")
  file:close()
end)

test("passes a runtime context to setup", function(amber, _, _, _, behavior)
  amber.setup({ root = root, plugins = { "dave/plain" } })
  local context = assert(_G.plain_ctx, "setup must receive a context")
  assert(context.name == "dave/plain" and context.dir == root .. "/dave/plain")
  assert(context.module_dir == context.dir and context.commit == nil)
  assert(context.data_dir:match("/rex/amber/dave/plain$"))
  behavior.seed({ ["dave/plain"] = { commit = A } })
  amber.setup({ root = root, plugins = { "dave/plain" } })
  assert(_G.plain_ctx.commit == A)
end)

test("gates setup until built and builds in Rex", function(amber, actions, logs, calls, behavior)
  local spec = { "dave/built", build = "make" }
  behavior.seed({ ["dave/built"] = { commit = A } })
  amber.setup({ root = root, plugins = { spec } })
  assert(_G.built_ctx == nil, "setup must wait for the build")
  assert(logs[#logs][2]:match("run amber build"))
  assert(actions.amber_status.run({}, {})["dave/built"].loaded == "unbuilt")
  assert(actions.amber_info.run({}, {}).plugins[1].load_status == "unbuilt")
  assert(actions.amber_lua_build.run({}, { plugin = "dave/built" }).status == "built")
  local build = assert(called(calls, "sh", "-c"))
  assert(build.argv[3] == "make" and build.opts.cwd == root .. "/dave/built")
  assert(build.opts.env.AMBER_PLUGIN_NAME == "dave/built")
  assert(build.opts.timeout and build.opts.timeout <= 23)
  assert(behavior.lock_data.plugins["dave/built"].built == A)
  amber.setup({ root = root, plugins = { spec } })
  assert(_G.built_ctx and _G.built_ctx.commit == A)
  assert(actions.amber_status.run({}, {})["dave/built"].built == true)
end)

test("a failed build is retryable", function(amber, actions, _, calls, behavior)
  behavior.seed({ ["dave/built"] = { commit = A } })
  amber.setup({ root = root, plugins = { { "dave/built", build = { "make", "make install" } } } })
  behavior.build_fail = true
  local ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("build step 1 failed: build exploded"), tostring(err))
  assert(count_calls(calls, "sh") == 1, "later steps must not run after a failure")
  assert(behavior.lock_data.plugins["dave/built"].built == nil)
  behavior.build_fail = false
  assert(actions.amber_lua_build.run({}, { plugin = "dave/built" }).status == "built")
  assert(count_calls(calls, "sh") == 3)
  assert(behavior.lock_data.plugins["dave/built"].built == A)
end)

test("amber_lua_build skips plugins without a build and needs a checkout", function(amber, actions)
  amber.setup({ root = root, plugins = { "dave/plain", { "bob/missing", build = "make" } } })
  assert(actions.amber_lua_build.run({}, { plugin = "dave/plain" }).status == "no build step")
  local ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "bob/missing" })
  assert(not ok and tostring(err):match("not installed"))
  ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "nobody/none" })
  assert(not ok and tostring(err):match("unknown plugin"))
end)

test("runs function build steps and reports failures", function(amber, actions, _, _, behavior)
  local seen
  local mode = "ok"
  behavior.seed({ ["dave/built"] = { commit = A } })
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
  assert(actions.amber_lua_build.run({}, { plugin = "dave/built" }).status == "built")
  assert(seen.name == "dave/built" and seen.commit == A)
  assert(seen.dir == root .. "/dave/built" and seen.module_dir == seen.dir)
  assert(behavior.lock_data.plugins["dave/built"].built == A)
  for failure, expected in pairs({
    ["false"] = "returned false",
    message = "no compiler",
    raise = "boom",
  }) do
    mode = failure
    local ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "dave/built" })
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
        plugins = { ["a/b"] = { commit = A, built = built } },
      }
    end
    local data, err = lock.read(path)
    assert(not data and err:match("invalid lockfile entry"), tostring(built))
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  rex.json.decode = function()
    return { format = 1, plugins = { ["a/b"] = { commit = A, built = A } } }
  end
  assert(lock.read(path))
end)

test("amber_lua_build requires a lock entry", function(amber, actions, _, calls)
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" } } })
  local ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("no lockfile entry"), tostring(err))
  assert(count_calls(calls, "sh") == 0, "nothing may be built without a lock entry")
end)

test("does not build a drifted checkout", function(amber, actions, _, calls, behavior)
  behavior.seed({ ["dave/built"] = { commit = A } })
  behavior.head_hash = B
  amber.setup({ root = root, plugins = { { "dave/built", build = "make" } } })
  local ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("checkout differs from lockfile"), tostring(err))
  assert(count_calls(calls, "sh") == 0, "a drifted checkout must not be built")
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
  behavior.seed({ ["dave/built"] = { commit = A } })
  amber.setup({
    root = root,
    plugins = {
      {
        "dave/built",
        build = function(ctx)
          during = held()
          if move_lock then
            behavior.lock_data.plugins["dave/built"].commit = C
          end
          return ctx.exec({ "sh", "-c", "true" }, { env = { EXTRA = "1" } })
        end,
      },
    },
  })
  actions.amber_lua_build.run({}, { plugin = "dave/built" })
  assert(during == 0, "the lockfile guard must be released before building")
  local build = assert(called(calls, "sh", "-c"))
  assert(build.opts.env.EXTRA == "1" and build.opts.env.AMBER_PLUGIN_NAME == "dave/built")
  assert(build.opts.env.AMBER_PLUGIN_DIR == root .. "/dave/built")
  assert(build.opts.env.AMBER_PLUGIN_MODULE_DIR == root .. "/dave/built")
  move_lock = true
  local ok, err = pcall(actions.amber_lua_build.run, {}, { plugin = "dave/built" })
  assert(not ok and tostring(err):match("lockfile changed during the build"), tostring(err))
end)

test("rejects expired build budgets", function()
  local build = assert(loadfile("amber/build.lua"))(dofile("amber/util.lua"))
  local ok, err = build.run({ name = "a/b", build = { "make" } }, A, os.time() - 1)
  assert(not ok and err:match("time budget exhausted"))
end)

test("amber_info reports every plugin in order", function(amber, actions)
  amber.setup({
    root = root,
    plugins = {
      {
        "elly/utility",
        subdir = "panes/tools",
        main = "tools",
        build = { "make", function() end },
      },
      { "bob/local", path = root .. "/bob" },
      { "old/thing", enabled = false, version = "v1.0.0" },
    },
  })
  local info = actions.amber_info.run({}, {})
  assert(info.version == amber.version and info.root == root and info.dir:sub(-1) ~= "/")
  assert(info.lockfile == root .. "/test-lock.json" and info.lock_error == nil)
  local p = info.plugins
  assert(#p == 3 and p[1].name == "elly/utility@panes/tools" and p[1].subdir == "panes/tools")
  assert(p[1].dir == root .. "/elly/utility--panes-tools" and p[1].parent == root .. "/elly")
  assert(p[1].module_dir == p[1].dir .. "/panes/tools" and p[1].load_status == "unbuilt")
  assert(p[1].url == "https://github.com/elly/utility.git" and p[1].data_dir)
  assert(p[1].build[1].type == "shell" and p[1].build[1].command == "make")
  assert(p[1].build[2].type == "lua" and p[1].build[2].command == nil)
  assert(p[2].local_path == true and p[2].dir == root .. "/bob")
  assert(p[3].enabled == false and p[3].version == "v1.0.0" and p[3].load_status == "disabled")
end)

test("actions open the CLI in a floating pane", function(amber, actions, _, _, behavior)
  amber.setup({
    root = root,
    plugins = { "alice/example", { "elly/utility", subdir = "panes/tools", main = "tools" } },
  })
  local result = actions.amber_update.run(session, { plugin = "elly/utility@panes/tools" })
  assert(result.opened == "layer:1")
  local layer = behavior.layer
  assert(layer.focus == true and layer.bounds[1] == 0.125 and layer.bounds[2] == 0.125)
  assert(layer.bounds[3] == 0.75 and layer.bounds[4] == 0.75)
  local block = layer.layout.block
  assert(block.flavor == "com.superlogical.terminal.shell" and block.options.shell == "none")
  local argv = block.options.command
  assert(argv[1] == root .. "/bin-amber" and argv[2] == "update")
  assert(argv[3] == "elly/utility@panes/tools" and argv[4] == nil)
  for action, subcommand in pairs({
    amber_install = "install",
    amber_restore = "restore",
    amber_build = "build",
    amber_outdated = "outdated",
    amber_clean = "clean",
  }) do
    actions[action].run(session, {})
    local command = behavior.layer.layout.block.options.command
    assert(command[2] == subcommand and command[3] == nil, action)
  end
  actions.amber.run(session, {})
  assert(#behavior.layer.layout.block.options.command == 1)
  local ok, err = pcall(actions.amber_update.run, session, { plugin = "nobody/none" })
  assert(not ok and tostring(err):match("unknown plugin: nobody/none"))
end)

test("explains a missing session or CLI", function(amber, actions, logs)
  amber.setup({ root = root, plugins = { "alice/example" } })
  local ok, err = pcall(actions.amber_update.run, {}, {})
  assert(
    not ok and tostring(err):match("no Rex session") and tostring(err):match("bin%-amber update")
  )
  amber.setup({ root = root, cli = root .. "/nope", plugins = { "alice/example" } })
  ok, err = pcall(actions.amber_update.run, session, {})
  assert(not ok and tostring(err):match("Amber CLI not found at " .. root .. "/nope"))
  local before = #logs
  amber.setup({ root = root, cli = "relative/amber", plugins = { "alice/example" } })
  assert(#logs == before + 1 and logs[#logs][2]:match("cli must be an absolute path"))
  assert(actions.amber_info == nil or true)
end)

print("tests passed")
