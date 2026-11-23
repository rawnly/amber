local root = assert(arg[1])
local actions, calls = {}, {}
local saved_lock
local layer_args
local binary = assert(io.open(root .. "/bin-amber", "w"))
binary:close()
rex = {
  json = {
    encode = function(v)
      saved_lock = v
      return "lock"
    end,
    decode = function()
      return saved_lock
    end,
  },
  log = function() end,
  exec = function(argv)
    calls[#calls + 1] = argv
    if argv[1] == "git" and argv[2] == "rev-parse" then
      return { ok = true, stdout = string.rep("a", 40), stderr = "", code = 0 }
    end
    return { ok = true, stdout = "", stderr = "", code = 0 }
  end,
  action = function(a)
    actions[a.name] = a
  end,
  layout = {
    block = function(args)
      return { block = args }
    end,
  },
  session = {
    new_layer = function(args)
      layer_args = args
      return { layer_id = "layer:test" }
    end,
  },
}
local amber = dofile("amber.lua")
amber.setup({
  root = root,
  lockfile = root .. "/lock.json",
  cli = root .. "/bin-amber",
  plugins = {
    { "alice/example", subdir = "src", main = "example", build = { "make", function() end } },
    { "bob/local", path = root .. "/local" },
    { "disabled/plugin", enabled = false },
  },
})
local info = actions.amber_info.run({}, {})
assert(info.version == amber.version and type(info.dir) == "string" and #info.dir > 0)
assert(#info.plugins == 3 and info.plugins[1].name == "alice/example@src")
assert(info.plugins[1].build[1].type == "shell" and info.plugins[1].build[1].command == "make")
assert(info.plugins[1].build[2].type == "lua" and info.plugins[1].subdir == "src")
assert(info.plugins[2].local_path and info.plugins[3].enabled == false)
local result = actions.amber_update.run({ session_id = "s" }, { plugin = "alice/example@src" })
assert(result.opened == "layer:test")
assert(layer_args.bounds[1] == 0.125 and layer_args.bounds[3] == 0.75 and layer_args.focus)
local command = layer_args.layout.block.options.command
assert(
  command[1] == root .. "/bin-amber"
    and command[2] == "update"
    and command[3] == "alice/example@src"
)
assert(not pcall(actions.amber_update.run, {}, {}))
local ok, err = pcall(actions.amber_update.run, { session_id = "s" }, { plugin = "nobody/nope" })
assert(not ok and tostring(err):match("unknown plugin"))
ok, err = pcall(actions.amber_update.run, { session_id = "s" }, { plugin = "bob/local" })
assert(not ok and tostring(err):match("local plugins are managed outside amber"))
ok, err = pcall(actions.amber_update.run, { session_id = "s" }, { plugin = "disabled/plugin" })
assert(not ok and tostring(err):match("disabled"))
assert(actions.amber_status)
print("tests passed")
