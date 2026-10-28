local root = assert(arg[1], "pass fixture directory")
local actions, logs, calls = {}, {}, {}
rex = {
  action = function(action)
    actions[action.name] = action
  end,
  log = function(level, message)
    logs[#logs + 1] = { level, message }
  end,
  exec = function(argv, opts)
    if argv[1] == "test" and argv[2] == "-d" then
      local file = io.open(argv[3], "r")
      if file then
        file:close()
      end
      return { ok = file ~= nil, stdout = "", stderr = "", code = file and 0 or 1 }
    end
    calls[#calls + 1] = { argv = argv, opts = opts }
    if argv[1] == "git" and argv[2] == "tag" then
      return { ok = true, stdout = "v1.2.0\nv1.4.0\nv2.0.0\n", stderr = "", code = 0 }
    end
    if argv[1] == "git" and (argv[2] == "pull" or argv[2] == "fetch" or argv[2] == "checkout") then
      return { ok = true, stdout = "updated", stderr = "", code = 0 }
    end
    return nil, "unexpected command"
  end,
}
local rpm = dofile("rex_plugin_manager.lua")
rpm.setup({
  root = root,
  plugins = {
    { "alice/example", opts = { message = "configured" } },
    "bob/missing",
  },
})
assert(_G.plugin_message == "configured")
assert(require("example") == package.loaded.example)
assert(#logs == 1 and logs[1][2]:match("bob/missing"))
assert(actions.rpm_install and actions.rpm_update)
assert(actions.rpm_install.run({}, { plugin = "alice/example" }).status == "already installed")
assert(actions.rpm_update.run({}, { plugin = "alice/example" }).status == "updated")
assert(calls[1].argv[1] == "git" and calls[1].opts.cwd == root .. "/alice/example")
assert(not pcall(actions.rpm_install.run, {}, { plugin = "unknown/repo" }))
assert(not pcall(rpm.setup, { root = root, plugins = { "../escape" } }))
assert(not pcall(rpm.setup, { root = root, plugins = { "a/b", "a/b" } }))
assert(not pcall(rpm.setup, { root = root, plugins = { { "a/b", enabled = "no" } } }))
_G.plugin_message = nil
logs = {}
rpm.setup({
  root = root,
  plugins = {
    { "alice/example", enabled = false },
    { "bob/missing", enabled = false },
  },
})
assert(_G.plugin_message == nil and #logs == 0)
assert(not pcall(actions.rpm_install.run, {}, { plugin = "alice/example" }))
assert(not pcall(actions.rpm_update.run, {}, { plugin = "alice/example" }))
rpm.setup({
  root = root,
  plugins = {
    {
      "alice/example",
      path = root .. "/alice/example",
      enabled = true,
      opts = { message = "local" },
    },
  },
})
assert(_G.plugin_message == "local")
assert(not pcall(actions.rpm_update.run, {}, { plugin = "alice/example" }))
rpm.setup({ root = root, plugins = { { "alice/example", version = "^1.2.0" } } })
assert(actions.rpm_update.run({}, { plugin = "alice/example" }).status == "updated")
assert(calls[#calls].argv[2] == "checkout" and calls[#calls].argv[4] == "v1.4.0")
assert(
  not pcall(rpm.setup, { root = root, plugins = { { "alice/example", version = ">=1.0.0" } } })
)
rpm.setup({ root = root, plugins = { "carol/shared" } })
assert(_G.shared_source == "rex")
assert(not pcall(rpm.setup, { root = root, plugins = { "alice/example", "bob/example" } }))
assert(not pcall(rpm.setup, { root = root, plugins = { { "alice/example", entry = "init.lua" } } }))
print("tests passed")
