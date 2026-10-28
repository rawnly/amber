# Rex Plugin Manager

A small GitHub plugin manager for Rex. Plugins are Lua modules installed on the machine running the Rex server. Requires Git and the macOS/Linux `mkdir`, `mktemp`, `mv`, and `rm` utilities.

## Installation

Clone RPM on the Rex server:

```sh
mkdir -p "$HOME/.local/share/rex"
git clone https://github.com/rawnly/rpm.git "$HOME/.local/share/rex/rpm"
```

Then load it from your Rex config (`~/.config/rex/init.lua` by default). This example uses [smart-splits-backend-rex](https://github.com/rawnly/smart-splits-backend-rex), which connects Neovim's smart-splits with Rex pane navigation:

```lua
local rpm = dofile(os.getenv("HOME") .. "/.local/share/rex/rpm/rex_plugin_manager.lua")

rpm.setup({
  plugins = {
    {
      "rawnly/smart-splits-backend-rex",
      main = "smart-splits-rex",
      opts = { resize_amount = 3 },
    },
  },
})
```

If you cloned RPM elsewhere, change the path accordingly. The Rex-side module must be published to the smart-splits repository before Git installation can use it; until then, use the local checkout example below. RPM never installs plugins during configuration loading or `rex config check`. Install them explicitly and reload: Once published, run:

```sh
rex config check
rex config reload
rex do rpm_install
rex config reload
```

Update with `rex do rpm_update plugin=rawnly/smart-splits-backend-rex`, then reload. Unversioned updates use `git pull --ff-only`; versioned updates fetch and resolve the configured version. Failures are reported without resetting local changes. `rex do rpm_install` attempts all enabled managed plugins sequentially and reports failures as an action error; `rex do rpm_install plugin=owner/repo` targets one. Rex actions have a time limit; RPM limits Git operation time and reports when its action budget is exhausted. Retry or install plugins individually. Git authentication must work non-interactively; terminal prompts are disabled.

By default plugins live at `$XDG_DATA_HOME/rex/plugins/<owner>/<repo>`, or `~/.local/share/rex/plugins/<owner>/<repo>` if `XDG_DATA_HOME` is unset. Override with `root = "/absolute/path"` in `setup`; relative paths and `~` are not expanded. Only GitHub `owner/repo` shorthand is supported for fetching. Plugins load in declaration order; missing plugins and load errors are logged and do not stop other plugins loading.

For development or repositories that contain both Neovim and Rex code, specify an absolute local checkout and its Rex module name:

```lua
{ "rawnly/smart-splits-backend-rex",
  path = "/absolute/path/to/smart-splits-backend-rex",
  main = "smart-splits-rex",
  opts = { resize_amount = 3 },
}
```

`path` checkouts are managed externally: install and update actions will not modify them. `main` is the Lua module name and defaults to the repository name, with a trailing `.rex` removed. Dots in the module name denote Lua module directories.

Use `rex do rpm_status` to inspect declared plugins, their load status, errors, paths, versions, and available Git commits. RPM also writes load failures with `rex.log`; log locations depend on server mode (see [Rex shared-server logs](https://www.superlogical.com/rex/docs/linux/shared-server#logs)). The status reports the current config load, the locked commit and whether the checkout matches it, and for versioned managed plugins compares the checkout with the locally resolved version. `version_matches = false` means an update is needed; `version_error` means RPM could not resolve or compare it. Status does not fetch new tags or branches. Use `rex do rpm_update` to update all enabled managed plugins, or pass `plugin=owner/repo` to update one. Actions share a bounded time budget and can be retried if it is exhausted.

Set `enabled = false` on any plugin specification to skip loading it without removing the declaration or its files. Disabled plugins produce no missing-plugin warning and cannot be installed or updated through manager actions. Re-enable it by setting `enabled = true` (or removing the field), then run `rex config reload`.

## Editor completion

For completion and diagnostics in your Rex `init.lua`, configure [Lua Language Server](https://luals.github.io/) in your editor. Add a `.luarc.json` to your Rex config workspace (typically `~/.config/rex/`):

```json
{
  "runtime.version": "Lua 5.1",
  "workspace.library": ["/absolute/path/to/rex-plugin-manager/types"],
  "diagnostics.globals": ["rex"]
}
```

Replace the library path with the `types` directory in your manager checkout on the **editor's** machine. If you already have a `.luarc.json`, merge these settings into it. Open the Rex config directory as the editor workspace so Lua Language Server reads the file.

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

`mise run test` runs the Lua 5.1 tests using a temporary fixture. `mise run fmt` formats the Lua files with StyLua, and `mise run fmt:check` checks formatting without changing files. `mise run types` runs Lua Language Server diagnostics. `mise run check` runs the tests, formatting and type checks, and validates Lua syntax. Rex is not required for these tests.

Lua Language Server reads `.luarc.json` and the editor-only Rex API declarations in `types/rex.lua`. Plugin specifications and manager functions use LuaLS annotations for completion and diagnostics; these types do not enforce checks at runtime. The Rex declarations cover only the API used by this project.

## Plugin contract

RPM looks for modules in `rex/lua/` if that directory exists, otherwise in `lua/`. The selected directory is exclusive: if the module is missing from `rex/lua/`, RPM does not fall back to `lua/`. For example, a plugin named `example` can provide `lua/example/init.lua`:

```lua
local M = {}

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

RPM installs a Lua module searcher scoped to each plugin's `main` namespace, requires the `main` module, and calls `setup(opts)` without adding unrelated plugin files to `package.path`. Users can subsequently call its public API with `require("example")`. Lua's module namespace and `package.loaded` cache are shared: choose a unique module name. RPM rejects duplicate enabled `main` names but cannot prevent collisions with unrelated Lua modules. `setup` runs on every Rex config load and receives the declaration's `opts` table (empty by default). Register actions and bindings there, not later inside an action. Metadata is optional and informational. Plugins execute arbitrary Lua with the Rex server's privileges; only install repositories you trust. Rex config checks also load plugins, so plugin setup should avoid side effects beyond configuration.

## Plugin authoring skill

The repository includes an [agent skill](.agents/skills/rex-plugin-authoring/SKILL.md) for building and testing RPM-compatible plugins. Agents that discover project skills can use it when working in this repository. To use it while working in a separate plugin repository, copy the `rex-plugin-authoring` directory into that repository's `.agents/skills/` directory or your agent's user-level skills directory. Reload the agent's skills if needed.

## Versions

Specify a Git tag or commit, or a simple semver range:

```lua
{ "alice/rex-projects", version = "v1.2.0" }, -- exact Git tag
{ "bob/rex-workspaces", version = "^1.2.0" }, -- latest stable 1.x tag
{ "carol/rex-tools", version = "~1.2.0" }, -- latest stable 1.2.x tag
```

For `^` and `~`, the manager selects the highest matching stable `1.2.3` or `v1.2.3` Git tag at install or update. Three numeric components are required; prereleases, wildcard ranges, and other lazy.nvim version expressions are not supported. Caret ranges follow semver's special rules for major version zero. Exact versions are Git refs (use the tag's `v` prefix if present). Tags take precedence over remote branches of the same name; branch names resolve to the fetched `origin` branch. Versions check out detached; updates fetch tags and re-resolve the constraint. They do not change an existing checkout until `rpm_update` is run. Versions are not supported for local `path` plugins.

This first version does not provide dependency resolution, lazy loading, uninstall, arbitrary Git URLs, or Windows support. A failed or interrupted install can leave a `.rpm-*` temporary directory or a sibling `.rpm-lock` directory. They are not treated as installed plugins. After confirming no install is still running, remove a stale lock to retry.

## Lockfile

RPM records exact Git commits in `rpm-lock.json` alongside Rex's config file (`$XDG_CONFIG_HOME/rex/rpm-lock.json`, or `~/.config/rex/rpm-lock.json` by default). Set `lockfile = "/absolute/path/rpm-lock.json"` in `rpm.setup` to override it; the path is on the Rex server. The lockfile is JSON and may be committed alongside your config.

`rex do rpm_install` uses an existing locked commit for missing plugins. If a plugin has no entry, a successful install records its commit; running install on an already installed checkout records its current commit without changing it. Existing lock entries are never replaced by install. `rex do rpm_update` explicitly resolves and records a new commit. Changing `version` alone does not update the lock; RPM warns until you run update.

```sh
rex do rpm_restore                          # restore all enabled managed plugins
rex do rpm_restore plugin=owner/repository   # restore one
rex config reload
```

Restore refuses checkouts with tracked or untracked changes. It can clone a missing checkout, but fails if Git cannot obtain the locked commit; it does not silently choose another. Restoring checks out a detached commit. For an unversioned plugin, a later update fetches the origin default branch and advances only if the checkout is clean and can be fast-forwarded. Local `path` plugins are never locked or restored; disabled and removed plugins' entries are preserved. RPM does not automatically prune entries.

Lockfile writes are serialized with a sibling `.lock` directory and written via a temporary file and rename. A killed process may leave the guard behind; after confirming no RPM action is running, remove `<lockfile>.lock` to retry. A corrupt lockfile causes actions to fail rather than overwriting it. If Git changes a checkout but writing the lockfile fails, RPM reports the error; inspect the checkout and lockfile before retrying. `rex config check` and config reload can read the lockfile to report drift, but do not create or modify it.

## Inspiration

RPM takes inspiration from [lazy.nvim](https://github.com/folke/lazy.nvim), particularly its Lua plugin specifications, and [TPM](https://github.com/tmux-plugins/tpm), the Tmux Plugin Manager's Git-based installation workflow.
