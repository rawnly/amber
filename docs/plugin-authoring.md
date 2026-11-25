# Writing an Amber plugin

An Amber plugin is a GitHub repository containing a Lua 5.1 module that registers Rex actions and bindings. This guide covers what Amber expects from that repository. For the user-side spec options, see the [README](../README.md#-configuration); for how loading works internally, see [architecture.md](architecture.md).

Amber's tests stub Rex. Check Rex APIs beyond `rex.action`, `rex.exec`, and `rex.log` against the current [Rex Lua reference](https://www.superlogical.com/rex/docs/reference/lua); `types/rex.lua` declares only the parts Amber itself uses.

## Layout

```text
example-rex/
├── lua/
│   └── example_rex/
│       ├── init.lua      -- entry point: require("example_rex")
│       └── helper.lua    -- require("example_rex.helper")
└── README.md
```

- **Module tree.** Amber loads from `rex/lua/` if that directory exists, otherwise `lua/`. It never falls back to `lua/` when `rex/lua/` exists, so a repository that also ships code for another host (for example a Neovim plugin in `lua/`) puts its Rex code under `rex/lua/`.
- **Entry point.** `main` names the module Amber requires. It defaults to the repository name with a trailing `.rex` removed. Dots map to directories, and Amber looks for `<main>.lua`, then `<main>/init.lua`. If your module name differs from the default, tell users to set `main`.
- **Submodules.** Put them under the `main` namespace. Amber's searcher only resolves `main` and its dotted descendants (`example_rex.helper`) from your module tree; it does not add your directory to `package.path`, and other names are left to the regular Lua searchers.
- **Unique names.** `package.loaded` and the module namespace are shared by every plugin and the user's config. Pick a distinctive `main`. Amber rejects two enabled plugins with the same `main`, and refuses to load a module that is already loaded from another source.
- **Subdirectories.** A monorepo can hold several plugins, each with its own `rex/lua/` or `lua/` tree inside a subdirectory. Users then declare `subdir` and must set `main`. See [Subdirectory plugins](../README.md#subdirectory-plugins).

## The `setup` contract

The entry module returns a table with a `setup` function:

```lua
local M = {}

---@param opts table
---@param ctx? AmberPluginContext
function M.setup(opts, ctx)
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

- `opts` is the spec's `opts` table, `{}` when the user sets none. Handle missing fields and document defaults.
- `setup` runs on **every** config load, reload, and `rex config check`. Do not assume it runs once, and avoid side effects beyond registering configuration: no network, no installs, no writes the user did not ask for.
- Register actions and bindings in `setup`. Work that needs a live session or client belongs in action callbacks.
- Errors raised by `require` or `setup` are caught and logged. That plugin's status becomes `error`, and Amber moves on to the next plugin.
- `setup` is skipped while a declared `build` has not succeeded for the locked commit (status `unbuilt`).

### Context

`setup` receives a second argument, `ctx`, so a plugin can find its own files without paths substituted at install time:

| Field | Meaning |
| --- | --- |
| `ctx.name` | Plugin identity, `owner/repo` or `owner/repo@subdir`. |
| `ctx.dir` | Checkout directory. |
| `ctx.module_dir` | Directory the module tree resolves from; differs from `dir` for `subdir` plugins. |
| `ctx.commit` | Commit recorded in the lockfile, or `nil` (for example a local `path` plugin). |
| `ctx.data_dir` | State directory `$XDG_STATE_HOME/rex/amber/<owner>/<repo>` (default `~/.local/state`). Amber names it but never creates it. |

Plugins that ignore `ctx` keep working. Treat `ctx` as optional in your own tests. Amber does not tell a plugin where the `rex` binary is.

### Editor types

`AmberPluginContext` is declared in Amber's `types/amber.lua`, not in your repository, so the Lua Language Server reports `Undefined type or alias` until you point it at Amber's types. Add a `.luarc.json` to the plugin repository:

```json
{
  "runtime.version": "Lua 5.1",
  "workspace.library": ["~/.local/share/rex/amber/types"],
  "diagnostics.globals": ["rex"]
}
```

Use the directory Amber was installed to (`~/.local/share/rex/amber` by default) plus `/types`. Then annotate `setup`; the type is not inferred without the annotation:

```lua
---@param opts table
---@param ctx? AmberPluginContext
function M.setup(opts, ctx)
  if ctx then
    local state = ctx.data_dir -- string?
  end
end
```

The same library also declares `AmberPluginSpec` and `AmberBuildContext`, and `types/rex.lua` covers the part of the `rex` global that Amber uses. Mark `ctx` optional (`ctx?`) and check it before use: it is `nil` when your tests call `setup` directly, and `commit` and `data_dir` are optional fields.

This was checked with `lua-language-server` 3.19.2 in `--check` mode, where both an absolute path and a `~/` path resolved the type. Completion inside a particular editor was not tested.

The library path is machine-specific, so contributors or CI without Amber installed still get `Undefined type or alias`. Either install Amber there, or copy the `AmberPluginContext` class into a `---@meta` file in your repository and keep it in sync with Amber yourself.

## Running on the Rex server

- Plugin code runs in the Rex server process, not on the client. Do not assume client-side files or Neovim APIs.
- `os.execute` and `io.popen` are unavailable. Run subprocesses with `rex.exec` and an argument array, and check both the start error and the exit status.
- Rex actions have a short deadline. Keep callbacks fast.
- Plugins are trusted code with the server's privileges. Amber does not sandbox them.

## Build steps

If the plugin needs work after checkout, such as compiling a helper, document a `build` value for users to put in their spec instead of shipping an install script:

```lua
{ "alice/example-rex", main = "example_rex", build = "make release" }
```

A build can be a shell command, a list of commands, or a function; the [README](../README.md#build-steps) has the full rules. For authors, the important ones:

- It runs on install and on update when the locked commit changed. Shell steps run in the `amber` command, up to 30 minutes each; a build with a Lua function step runs entirely inside a Rex action, within a roughly 23-second budget. Prefer shell steps for anything slow.
- Shell steps run in `module_dir` with `AMBER_PLUGIN_NAME`, `AMBER_PLUGIN_DIR`, `AMBER_PLUGIN_MODULE_DIR`, and `AMBER_PLUGIN_DATA_DIR` set.
- Keep output out of Git's way: list generated files in `.gitignore` or write them to the data directory. `amber update` and `amber restore` refuse checkouts with untracked or modified files.
- `setup` is not called until the build has succeeded for the locked commit.

## Background processes

Amber manages files, not processes: it has no service support and does not write launchd or systemd units. A plugin that needs a long-running watcher starts it itself. Amber's tests do not exercise this, so verify against the Rex reference and a live Rex:

- `rex.on` and `rex.every` are documented as script-only, so the watcher is a Lua script run with `rex do`, not code in `setup`.
- `rex.exec.start` with `detach = true` starts a process that outlives the config load. Resolve the script path from `ctx.dir` and keep state in `ctx.data_dir`.
- `setup` runs on every config load, reload, and check. Make the script exit when another instance is already running (for example by labeling its client connection and checking for the label), and decide whether a config check should start it at all.
- Amber does not stop the process on update or removal; handle restarts in the plugin.

## Documenting installation

Give users a declaration that matches the published repository and module name:

```lua
amber.setup({
  plugins = {
    { "alice/example-rex", main = "example_rex", opts = { message = "Hello!" } },
  },
})
```

Then tell them to install explicitly, since config load never installs:

```sh
amber install alice/example-rex
```

`amber install` reloads the Rex config when it is done, so the plugin loads right away.

Document your options and defaults, the actions you register, and any key bindings users must add themselves. Do not promise features Amber lacks, such as dependency resolution or lazy loading. If you tag releases as `vX.Y.Z` or `X.Y.Z`, users can pin with `version = "^1.2.0"`.

## Developing and testing

Point a spec at a local checkout while developing:

```lua
{ "alice/example-rex", main = "example_rex", path = "/absolute/path/to/example-rex" }
```

Local `path` plugins are never installed, updated, locked, or built; run any build step yourself. Edit, then `rex config reload`.

- Unit-test the entry point, submodule resolution, option defaults and overrides, and repeated `setup` calls with stubbed Rex APIs. Stubs cannot prove live Rex behavior.
- When Rex is available, run `rex config check` against a temporary configuration that uses the absolute local path, so your real config is not touched.
- Use `amber ls` or `amber doctor` to see load status and errors; failures also go to the Rex log.

## Agent skill

The same guidance is packaged as an agent skill:

```sh
npx skills add rawnly/amber --skill rex-plugin-authoring
```
