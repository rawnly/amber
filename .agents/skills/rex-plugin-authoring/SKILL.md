---
name: rex-plugin-authoring
description: Build, adapt, test, or review Lua plugins for Rex Plugin Manager (RPM). Use when creating a Rex plugin, adding Rex support to an existing repository, or diagnosing RPM plugin loading and setup.
---

# Authoring Rex Plugin Manager plugins

Build for Lua 5.1 and the Rex server environment. Check the target repository's instructions and current Rex API documentation before using APIs beyond the example below; RPM's bundled `types/rex.lua` is only a partial API declaration. Do not assume Neovim APIs or that client-side files are available on the Rex server.

## Module layout and contract

1. Choose a unique Lua module namespace. RPM defaults `main` to the repository name, with a trailing `.rex` removed; tell users to set `main` explicitly when the entry point differs.
2. Place the entry point at `lua/<main>.lua` or `lua/<main>/init.lua`, replacing dots in `main` with directory separators. For a repository with separate Rex code, use the equivalent path under `rex/lua/`. If `rex/lua/` exists, RPM exclusively uses it and never falls back to `lua/`.
3. Return a table with a `setup(opts)` function. RPM calls it with the plugin spec's `opts` table (empty by default) on every config load, reload, and config check. Metadata is optional. Handle missing option fields, document defaults, and do not rely on setup running only once.
4. Put plugin-owned submodules beneath the main namespace, e.g. `require("example_rex.helper")` at `lua/example_rex/helper.lua`. RPM's searcher is scoped to `main` and its dotted descendants; it does not add arbitrary plugin directories to `package.path` or resolve dependencies. Lua's `package.loaded` and module names are shared, so avoid collisions.

Minimal `lua/example_rex/init.lua`:

```lua
local M = {}

function M.setup(opts)
  local message = opts.message or "Hello!"
  rex.action({
    name = "example_hello",
    title = "Example: Hello",
    run = function()
      return { message = message }
    end,
  })
end

return M
```

Register actions and bindings during setup; defer operations that require a live session or client to callbacks. Config checks execute setup too, so avoid runtime, network, and filesystem side effects during setup beyond configuration. Plugins are trusted code, not sandboxed. For subprocesses use `rex.exec` with an argument array, check startup errors and nonzero exit status, and respect action deadlines; `os.execute` and `io.popen` are unavailable in Rex.

## Document installation

Give users an RPM declaration matching the actual published repository and module name, for example:

```lua
rpm.setup({
  plugins = {
    { "alice/example-rex", main = "example_rex", opts = { message = "Hello!" } },
  },
})
```

For development, add `path = "/absolute/path/to/example-rex"` to that spec. Local paths are server-side and externally managed; RPM does not install or update them, and `version` cannot be combined with `path`. Managed repositories must be published to GitHub before a fresh install can fetch them. By default RPM installs missing enabled managed plugins during config load, including `rex config check`; `install = "manual"` disables that behavior. Changes made through install/update actions take effect on config reload. Do not promise dependency resolution, lazy loading, or other features RPM does not provide.

## Verify

- Test the entry point and nested module resolution, option defaults and overrides, and registration on repeated setup/config loads. Stub Rex APIs for unit tests, and state what stubs cannot prove.
- When Rex is available, run `rex config check` with a temporary configuration using an absolute local plugin path and `install = "manual"`; test live-session behavior separately where feasible. Avoid modifying the user's active config or triggering network installs unintentionally.
- Check the plugin's documented module name and layout against the actual files. Explain how to call any public API with `require(main)` and document options, actions, and limitations. Report checks performed and any live Rex behavior not verified.
