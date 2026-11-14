# Amber

Amber: a plugin manager for Rex. Plugins and versions stay locked, like insects in amber.

Amber installs GitHub Lua plugins on the machine running the Rex server and loads them from your Rex config.

- Plugin specs in Lua, in the style of lazy.nvim.
- Semver versions and a lockfile for reproducible installs.
- A `build` step that runs after install or update, like lazy.nvim.
- An agent skill for writing Amber plugins.

## Quick start

Requires Git, a POSIX shell, and macOS or Linux. Run on the Rex server machine.

```sh
curl -fsSL https://raw.githubusercontent.com/rawnly/amber/main/install.sh | sh
```

This clones Amber to `~/.local/share/rex/amber`. When run from a terminal, it asks you to confirm the directory. Answer `n` (or start with a directory that already exists) to type another absolute path; `~/` is expanded. It does not touch your Rex config and refuses to overwrite an existing directory. To inspect it first, download `install.sh` and run `sh install.sh`. To change the default, set `AMBER_INSTALL_DIR=/absolute/path`. Without a terminal (output redirected or no `/dev/tty`), it installs to the default without asking.

Add to your Rex config (`~/.config/rex/init.lua` by default):

```lua
local amber = dofile(os.getenv("HOME") .. "/.local/share/rex/amber/amber.lua")

amber.setup({
  plugins = {
    { "rawnly/smart-splits-backend-rex", main = "smart-splits-rex", opts = { resize_amount = 3 } },
  },
})
```

This registers the Rex actions of [smart-splits-backend-rex](https://github.com/rawnly/smart-splits-backend-rex). It adds no key bindings. For Neovim you also need its Neovim plugin; see its README.

Config load and `rex config check` never install anything. Install explicitly, then reload:

```sh
rex config reload
rex do amber_install
rex config reload
```

The first reload registers Amber's actions. The second loads the installed plugins.

## Commands

Run with `rex do <action>`. Add `plugin=owner/repo` to target one plugin. Without it, an action covers all enabled, managed plugins, one after another. Reload after install, update, or restore.

| Action | What it does |
| --- | --- |
| `amber_install` | Clones missing plugins. Uses the locked commit if one exists. Records new commits in the lockfile. |
| `amber_update` | Resolves the newest commit or version, checks it out, rewrites the lock entry. Unversioned: `git pull --ff-only`. Versioned: fetch tags, check out detached. Never resets local changes. |
| `amber_restore` | Checks out the locked commit (detached). Refuses dirty checkouts. Fails if the commit is unavailable. |
| `amber_build` | Runs the `build` step of plugins that declare one, even if it already ran for the locked commit. |
| `amber_status` | Shows load status, errors, path, commit, lock match, build state, and version match. Does not fetch. |

`amber_status` takes no `plugin` argument. Load failures also go to `rex.log`; see [Rex logs](https://www.superlogical.com/rex/docs/linux/shared-server#logs).

## Plugin spec

A plugin is `"owner/repo"` or a table whose first element is that name. Unknown options are rejected.

| Option | Default | Meaning |
| --- | --- | --- |
| `main` | repo name without trailing `.rex` | Lua module to `require`. Dots map to directories. |
| `opts` | `{}` | Table passed to `setup`. |
| `version` | default branch | Tag, commit, branch, `^1.2.3`, or `~1.2.3`. Not allowed with `path`. |
| `path` | none | Absolute path to a local checkout. Never installed, updated, or locked. |
| `enabled` | `true` | `false` skips loading and rejects actions for it. |
| `subdir` | none | Repository subdirectory to load the plugin from; requires `main`. Enables monorepo layouts. |
| `build` | none | Command, function, or list run after install or update; see [Build steps](#build-steps). Not allowed with `path`. |

Options for `amber.setup` itself:

| Option | Default | Meaning |
| --- | --- | --- |
| `root` | `$XDG_DATA_HOME/rex/plugins`, else `~/.local/share/rex/plugins` | Absolute install directory. Plugins go in `<root>/<owner>/<repo>`. No `~` expansion. |
| `lockfile` | `amber-lock.json` next to `$REX_CONFIG`, else `$XDG_CONFIG_HOME/rex/amber-lock.json`, else `~/.config/rex/amber-lock.json` | Absolute file path on the server. |
| `plugins` | `{}` | Ordered list of specs. Plugins load in this order. |

Invalid specs, duplicate plugins, duplicate enabled `main` names, and duplicate install locations are logged and skipped. A duplicate install location is rejected for every non-local spec, even when one of the entries is disabled.

For development, point `path` at a local checkout:

```lua
{ "rawnly/smart-splits-backend-rex", path = "/absolute/path/to/smart-splits-backend-rex", main = "smart-splits-rex" }
```

## Build steps

Some plugins need work after checkout, such as compiling a helper. Declare it with `build`:

```lua
{ "alice/rex-fast", build = "make release" },                 -- shell command
{ "alice/rex-fast", build = { "make deps", "make release" } }, -- steps run in order
{
  "alice/rex-fast",
  build = function(ctx)
    return ctx.exec({ "make", "release" })
  end,
},
```

- A string runs as `sh -c <string>` in the plugin directory (`module_dir` for `subdir` plugins). `AMBER_PLUGIN_NAME` and `AMBER_PLUGIN_DIR` are set in its environment.
- A function receives `{ name, dir, module_dir, commit, exec }`. `exec(argv, opts)` runs a command in `module_dir` within the remaining action time. The step fails if the function raises an error, returns `false`, or returns `nil` and a message.
- `build = false` disables the step. Local `path` plugins cannot have one: Amber never runs anything for them.
- `amber_install`, `amber_update`, and `amber_restore` run the build when the checked-out commit differs from the one recorded as built in the lockfile (`built`). An unchanged commit is not rebuilt. `amber_build` forces it.
- A failed build still records the checkout in the lockfile, fails the action, and leaves the plugin unbuilt. Fix the cause and run `amber_build`.
- Until a build has run for the locked commit, Amber does not call the plugin's `setup`; `amber_status` reports `unbuilt`. Adding `build` to an existing plugin therefore needs one `amber_build` and a reload. If the lockfile cannot be read, Amber cannot tell and does not hold plugins back.
- Steps share the roughly 23-second action budget with Git. Anything longer fails with a timeout; start long-running work from the plugin itself instead (see [Background processes](#background-processes)).
- Build commands are trusted code with the Rex server's privileges, like plugin Lua. Read them before installing.

## Subdirectory plugins

One repository can carry several plugins. Set `subdir` to the path each plugin loads from, relative to the repository root; `main` is required because the repository-name default cannot resolve inside a subdirectory.

```lua
--- The monorepo plugins for this host, each loading from its own directory.
---@type AmberPluginSpec[]
local subdir_plugins = {
  { "me/menu-rex-extensions", subdir = "panes/roadmap", main = "agent-roadmap" },
  { "me/menu-rex-extensions", subdir = "panes/typing", main = "key-strip", version = "^1.2.0" },
}

amber.setup({
  root = "/absolute/path/to/plugins",
  plugins = subdir_plugins,
})
```

- Identity: name, lockfile key, status, and per-plugin action targets are `me/repo@subdir`.
- Installs: each entry gets its own full clone under `<root>/<owner>/<repo>--<subdir>` (with `/` mapped to `-` and other symbols to `-`). Two subdirs of one repo can sit on different commits or versions. If two entries (or one entry and a plain repository) resolve to the same directory, setup reports a duplicate location; that applies whether the entries are enabled or disabled, so a disabled checkout never stands in for an enabled plugin.
- Modules resolve inside the subdirectory's own `rex/lua` (`lua/` fallback), so two subdir plugins are only isolated by the searcher's main-namespace scope, not by anything stronger; a missing subdirectory in an existing checkout reports a `missing` load status naming the subdir, while a checkout that was never installed keeps the plain missing-module warning.
- `path` combines with `subdir`: local checkout plus module offset.
- Bulk operations share the action budget: several large subdirs of one monorepo can hit "action time budget exhausted" during `amber_install`; use per-plugin install (`plugin=me/repo@subdir`) for those.

## Versions and lockfile

```lua
{ "alice/rex-projects", version = "v1.2.0" },    -- exact tag, commit, or branch
{ "bob/rex-workspaces", version = "^1.2.0" },    -- highest stable 1.x.y tag
{ "carol/rex-tools", version = "~1.2.0" },       -- highest stable 1.2.x tag
```

- `^` and `~` need three numeric parts. They match `1.2.3` and `v1.2.3` tags. Prereleases and wildcards are not supported.
- Tags win over branches of the same name. Branches resolve to `origin/<branch>`.
- Changing `version` does not move an existing checkout. Run `amber_update`.

Amber records exact commits in the lockfile, plus a `built` commit for plugins with a build step. The file is JSON and safe to commit. The lock is authoritative: `amber_install` and `amber_restore` use it until you run `amber_update`. Install never replaces an existing entry. Unrelated entries are kept and nothing is pruned.

```sh
rex do amber_restore                           # all enabled managed plugins
rex do amber_restore plugin=owner/repo         # one plugin
rex config reload
```

Config load only reads the lockfile to warn about drift. A malformed lockfile makes actions fail; Amber never overwrites it.

## Writing a plugin

Amber looks for the module in `rex/lua/` if that directory exists, otherwise `lua/`. It never falls back to `lua/` when `rex/lua/` exists. The module must return a table with `setup(opts)`. `setup` runs on every config load, so register actions and bindings there.

`lua/example/init.lua`:

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

- Pick a unique module name. The Lua module namespace and `package.loaded` are shared.
- `setup` also receives a second argument, `ctx`, so a plugin does not need paths filled in at install time:

  | Field | Meaning |
  | --- | --- |
  | `ctx.name` | Plugin identity, `owner/repo` or `owner/repo@subdir`. |
  | `ctx.dir` | Checkout directory. |
  | `ctx.module_dir` | Directory the module tree resolves from; differs from `dir` for `subdir` plugins. |
  | `ctx.commit` | Commit recorded in the lockfile, or `nil`. |
  | `ctx.data_dir` | State directory `$XDG_STATE_HOME/rex/amber/<owner>/<repo>` (default `~/.local/state`). Amber names it but never creates it. |

  Plugins that ignore `ctx` keep working. Amber does not tell a plugin where the `rex` binary is.
- Plugins are trusted Lua code with the Rex server's privileges. They are not sandboxed.
- Config checks run `setup` too. Avoid side effects beyond configuration.

### Background processes

Amber manages files, not processes: it has no service support and does not write launchd or systemd units. A plugin that needs a long-running watcher should start it itself from `setup`, using paths from `ctx` instead of values substituted at install time. Details to check against the current [Rex Lua reference](https://www.superlogical.com/rex/docs/reference/lua), because Amber's tests stub Rex and do not exercise them:

- `rex.on` and `rex.every` are documented as script-only, so the watcher is a Lua script run with `rex do`, not code in `setup`.
- `rex.exec.start` with `detach = true` starts a process that outlives the config load.
- `setup` runs on every config load, reload, and `rex config check`. Make the script exit when another instance is already running (for example by labeling its client connection and checking for the label), and consider whether a check should start it at all.
- Amber does not stop such a process on update or removal; the plugin should handle restarts itself.

Install the [authoring skill](.agents/skills/rex-plugin-authoring/SKILL.md) for your agent:

```sh
npx skills add rawnly/amber --skill rex-plugin-authoring
```

## Limitations

- Alpha. Expect changes.
- macOS and Linux only. Needs `git`, `mkdir`, `mktemp`, `mv`, `rm`.
- GitHub `owner/repo` only. No other Git URLs.
- No dependency resolution.
- No lazy loading.
- No uninstall. Remove the declaration and delete the directory yourself. Files a build created outside the plugin directory stay too.
- No service or daemon management.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Interrupted install left `.amber-*` directories or `<plugin>.amber-lock` | They are not treated as installed. Confirm no install is running, then delete them and retry. |
| Lockfile guard `<lockfile>.lock` left behind | Confirm no Amber action is running, delete the directory, retry. |
| "action time budget exhausted" | Rex actions have a short deadline, so Amber stops after about 23 seconds. Retry, or target plugins with `plugin=owner/repo`. |
| Git fails on auth | Prompts are disabled (`GIT_TERMINAL_PROMPT=0`). Use credentials that work non-interactively. |
| Lockfile error | The file is corrupt. Fix or remove it. Amber will not overwrite it. |
| Checkout changed but lock write failed | Inspect the checkout and lockfile before retrying. |
| `checkout differs from lockfile` warning | Run `amber_restore`. It refuses dirty checkouts. |
| Plugin reports `unbuilt` | The build has not run for the locked commit. Run `amber_build` (or fix the failing step), then `rex config reload`. |

## Contributing

```sh
mise trust && mise install
mise exec -- lefthook install   # git hooks
mise run check                  # fmt:check, lint, test, types, luac
```

Also: `mise run fmt`, `mise run test`. Tests stub Rex and Git. Rex is not required. See [docs/architecture.md](docs/architecture.md).

## Editor completion

Unverified: not yet tested in an editor. Add a `.luarc.json` to your Rex config directory, with your home directory in place of `/home/you`:

```json
{
  "runtime.version": "Lua 5.1",
  "workspace.library": ["/home/you/.local/share/rex/amber/types"],
  "diagnostics.globals": ["rex"]
}
```

Annotate the result of `dofile` with `---@type AmberModule`. `types/rex.lua` covers only the Rex API Amber uses.

## Migrating from RPM

Amber was previously called Rex Plugin Manager (RPM). This is a clean break with no compatibility aliases:

- Load `amber.lua` from `~/.local/share/rex/amber` and call `amber.setup`.
- Use `amber_install`, `amber_update`, `amber_restore`, and `amber_status` instead of the `rpm_*` actions.
- Rename `rpm-lock.json` to `amber-lock.json`. Amber does not read the old name, so an unrenamed lockfile is ignored and new installs would record fresh commits.
- The installer environment variable is now `AMBER_INSTALL_DIR`.
- Stale `.rpm-*` and `<plugin>.rpm-lock` directories are not recognized; delete them.

`install.sh` leaves an existing RPM install untouched and prints these steps when it finds one.

## Inspiration

[lazy.nvim](https://github.com/folke/lazy.nvim) for specs, [TPM](https://github.com/tmux-plugins/tpm) for Git-based installs.

## License

[Apache License 2.0](LICENSE).
