# Rex Plugin Manager

A small GitHub plugin manager for Rex. Plugins are Lua modules installed on the machine running the Rex server. Requires Git and the macOS/Linux `mkdir`, `mktemp`, `mv`, and `rm` utilities.

## Installation

Clone this repository anywhere on the Rex server, then load the manager by absolute path from your Rex config (`~/.config/rex/init.lua` by default). This example uses [smart-splits-backend-rex](https://github.com/rawnly/smart-splits-backend-rex), which connects Neovim's smart-splits with Rex pane navigation:

```lua
local rpm = dofile(os.getenv("HOME") .. "/path/to/rex-plugin-manager/rex_plugin_manager.lua")

rpm.setup({
  plugins = {
    {
      "rawnly/smart-splits-backend-rex",
      main = "smart-splits-rex",
      opts = { resize = false },
    },
  },
})
```

Replace the manager path with your actual checkout path. The Rex-side module must be published to the smart-splits repository before Git installation can use it; until then, use the local checkout example below. Once published, reload, install, and reload again:

```sh
rex config check
rex config reload
rex do rpm_install plugin=rawnly/smart-splits-backend-rex
rex config reload
```

Update with `rex do rpm_update plugin=rawnly/smart-splits-backend-rex`, then reload. Updates use `git pull --ff-only`; failures are reported without resetting local changes. Each action handles one plugin to fit Rex's action time limit. Git authentication must work non-interactively; terminal prompts are disabled.

By default plugins live at `$XDG_DATA_HOME/rex/plugins/<owner>/<repo>`, or `~/.local/share/rex/plugins/<owner>/<repo>` if `XDG_DATA_HOME` is unset. Override with `root = "/absolute/path"` in `setup`. Only GitHub `owner/repo` shorthand is supported for fetching. Plugins load in declaration order; missing plugins and load errors are logged and do not stop other plugins loading.

For development or repositories that contain both Neovim and Rex code, specify an absolute local checkout and its Rex module name:

```lua
{ "rawnly/smart-splits-backend-rex",
  path = "/absolute/path/to/smart-splits-backend-rex",
  main = "smart-splits-rex",
  opts = { resize = false },
}
```

`path` checkouts are managed externally: install and update actions will not modify them. `main` is the Lua module name and defaults to the repository name.

Set `enabled = false` on any plugin specification to skip loading it without removing the declaration or its files. Disabled plugins produce no missing-plugin warning and cannot be installed or updated through manager actions. Re-enable it by setting `enabled = true` (or removing the field), then run `rex config reload`.

## Editor completion

For completion and diagnostics in your Rex `init.lua`, configure [Lua Language Server](https://luals.github.io/) in your editor. Add a `.luarc.json` to your Rex config workspace (typically `~/.config/rex/`):

```json
{
  "runtime.version": "Lua 5.1",
  "workspace.library": ["/absolute/path/to/rex-plugin-manager"],
  "diagnostics.globals": ["rex"]
}
```

Replace the library path with the location of your manager checkout on the **editor's** machine. If you already have a `.luarc.json`, merge these settings into it. Open the Rex config directory as the editor workspace so Lua Language Server reads the file.

Because `dofile` uses a runtime path, annotate its result in `init.lua`:

```lua
---@type RpmModule
local rpm = dofile("/absolute/path/to/rex-plugin-manager/rex_plugin_manager.lua")

rpm.setup({
  plugins = {
    { "rawnly/smart-splits-backend-rex", main = "smart-splits-rex", enabled = true },
  },
})
```

The annotations describe RPM's options; they do not change runtime behavior. The bundled `types/rex.lua` declarations cover only the Rex API used by RPM, not the complete Rex API. This external-workspace setup has not yet been verified in an editor.

## Development

Install [mise](https://mise.jdx.dev/), then install the pinned tools:

```sh
mise trust
mise install
mise run check
```

`mise run test` runs the Lua 5.1 tests using a temporary fixture. `mise run fmt` formats the Lua files with StyLua, and `mise run fmt:check` checks formatting without changing files. `mise run check` runs both checks and validates Lua syntax. Rex is not required for these tests.

Lua Language Server reads `.luarc.json` and the editor-only Rex API declarations in `types/rex.lua`. Plugin specifications and manager functions use LuaLS annotations for completion and diagnostics; these types do not enforce checks at runtime. The Rex declarations cover only the API used by this project.

## Plugin contract

RPM looks for modules in `rex/lua/` if that directory exists, otherwise in `lua/`. The selected directory is exclusive: if the module is missing from `rex/lua/`, RPM does not fall back to `lua/`. For example, a plugin named `example` can provide `lua/example/init.lua`:

```lua
local M = {}
M.version = "0.1.0"
M.author = "user@me.it"

function M.setup(opts)
  rex.action({
    name = "example_hello",
    title = "Example: Hello",
    run = function()
      return { message = opts.message or "Hello!" }
    end,
  })
end

return M
```

RPM adds the selected directory to `package.path`, requires the `main` module, and calls `setup(opts)`. Users can subsequently call its public API with `require("example")`. Lua's module namespace and `package.loaded` cache are shared: choose a unique module name. RPM rejects duplicate enabled `main` names but cannot prevent collisions with unrelated Lua modules. `setup` runs on every Rex config load and receives the declaration's `opts` table (empty by default). Register actions and bindings there, not later inside an action. Metadata is optional and informational. Plugins execute arbitrary Lua with the Rex server's privileges; only install repositories you trust. Rex config checks also load plugins, so plugin setup should avoid side effects beyond configuration.

## Versions

Specify a Git tag or commit, or a simple semver range:

```lua
{ "alice/rex-projects", version = "v1.2.0" }, -- exact Git tag
{ "bob/rex-workspaces", version = "^1.2.0" }, -- latest stable 1.x tag
{ "carol/rex-tools", version = "~1.2.0" }, -- latest stable 1.2.x tag
```

For `^` and `~`, the manager selects the highest matching stable `1.2.3` or `v1.2.3` Git tag at install or update. Three numeric components are required; prereleases, wildcard ranges, and other lazy.nvim version expressions are not supported. Caret ranges follow semver's special rules for major version zero. Exact versions are Git refs (use the tag's `v` prefix if present). Versions check out detached; updates fetch tags and re-resolve the constraint. They do not change an existing checkout until `rpm_update` is run. Versions are not supported for local `path` plugins. There is no lockfile, so ranges may resolve differently over time.

This first version does not provide lockfiles, dependency resolution, lazy loading, uninstall, arbitrary Git URLs, or Windows support. A failed or interrupted install can leave a `.rpm-*` temporary directory; it is not treated as an installed plugin.
