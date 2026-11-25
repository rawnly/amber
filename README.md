# Amber

Amber: a plugin manager for Rex. Plugins and versions stay locked, like insects in amber.

Amber installs GitHub Lua plugins on the machine running the Rex server and loads them from your Rex config.

- Plugin specs in Lua, in the style of lazy.nvim.
- Semver versions and a lockfile for reproducible installs.
- A `build` step that runs after install or update, like lazy.nvim.
- An `amber` command with a plugin window in the style of lazy.nvim's, which Rex actions open in a floating pane.
- An agent skill for writing Amber plugins.

## Quick start

Requires Git, a POSIX shell, and macOS or Linux. Run on the Rex server machine.

With Homebrew:

```sh
brew tap rawnly/amber https://github.com/rawnly/amber
brew trust rawnly/amber
brew install amber-rex
```

Recent Homebrew versions refuse formulae from a tap you have not trusted, hence `brew trust`. The formula is named `amber-rex` because Homebrew's own `amber` formula (a Crystal framework) also installs an `amber` command, and the two conflict. The install prints the line to put in your Rex config. Its path, `$(brew --prefix)/opt/amber-rex/libexec/amber.lua`, does not change when you upgrade. Update with `brew upgrade amber-rex`; `amber self-update` refuses to run on a Homebrew install.

Or with the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/rawnly/amber/main/install.sh | sh
```

This clones Amber to `~/.local/share/rex/amber` and downloads the `amber` command for your platform from the latest release into its `bin/`, checking its SHA-256 checksum and moving the checkout to the matching release tag. Without a release for your platform, it says so and you can build the command with `mise run cli:build` in that directory. When run from a terminal, it asks you to confirm the directory. Answer `n` (or start with a directory that already exists) to type another absolute path; `~/` is expanded. It does not touch your Rex config and refuses to overwrite an existing directory. To inspect it first, download `install.sh` and run `sh install.sh`. To change the default, set `AMBER_INSTALL_DIR=/absolute/path`. Without a terminal (output redirected or no `/dev/tty`), it installs to the default without asking.

Add to your Rex config (`~/.config/rex/init.lua` by default). With Homebrew, replace the `dofile` path with the one the install printed (also shown by `brew info amber-rex`):

```lua
local amber = dofile(os.getenv("HOME") .. "/.local/share/rex/amber/amber.lua")

amber.setup({
  plugins = {
    { "rawnly/smart-splits-backend-rex", main = "smart-splits-rex", opts = { resize_amount = 3 } },
  },
})
```

This registers the Rex actions of [smart-splits-backend-rex](https://github.com/rawnly/smart-splits-backend-rex). It adds no key bindings. For Neovim you also need its Neovim plugin; see its README.

Config load and `rex config check` never install anything. Reload once so Rex loads Amber, then install:

```sh
rex config reload
amber install
```

`amber install` clones the plugins, records them in the lockfile, and reloads Rex so they load. With the installer, the command is `~/.local/share/rex/amber/bin/amber`; add that directory to your `PATH` to type just `amber`. Homebrew puts it on your `PATH` already.

## Commands

Run `amber` with no arguments to open the plugin window, or give it a command:

| Command | What it does |
| --- | --- |
| `amber install [plugin]` | Clones declared plugins that are missing. Uses the locked commit when there is one; otherwise records the new commit in the lockfile. |
| `amber update [plugin]`, `amber up` | Moves plugins to the newest commit or version and rewrites their lock entries. Unversioned: `git pull --ff-only`. Versioned: fetch tags, check out detached. Never resets local changes. |
| `amber restore [plugin]` | Checks out the locked commits, installing missing ones. Refuses dirty checkouts. |
| `amber build [plugin]` | Runs the build step of plugins that declare one, even if it already ran for the locked commit. |
| `amber outdated [plugin]`, `amber check` | Fetches and shows what an update would change. Changes nothing. |
| `amber list`, `amber ls` | Lists plugins with load status, commit, and version. Reads local state only. `--json` for scripts. |
| `amber doctor` | Checks Git, the Rex connection, the library version, the lockfile, leftover directories, and every plugin. |
| `amber clean` | Removes undeclared checkouts and directories left by interrupted runs, after asking. `--dry-run` lists them; `--yes` skips the question; `--lock` also drops lockfile entries of undeclared plugins. |
| `amber self-update` | Updates the command and the library to the latest release. See [Updating Amber](#updating-amber). |

On a terminal, `install`, `update`, `restore`, `build`, and `outdated` open the plugin window and start right away. Piped, or with `--plain`, they print one line per plugin and exit nonzero if any plugin failed. After anything changes, Amber reloads the Rex config so new plugin code takes effect; `--no-reload` skips that. `--jobs` (default 4) sets how many plugins run at once, and `--server` picks the Rex server (default `$REX_SERVER`, else the local socket). Reloading only works over the local socket, so run `amber` on the Rex server machine.

### Plugin window

Plugins are grouped like in lazy.nvim: Working, Failed, Updated, Updates available, Needs attention, Not installed, Installed, Local, and Disabled. Each row shows the commit and version, and progress while Git or a build runs.

| Key | Action |
| --- | --- |
| `I` `U` `R` `B` `C` | Install, update, restore, build, or check every plugin. |
| `i` `u` `r` `b` `c` | The same for the plugin under the cursor. |
| `X` | Clean, after showing what would be removed. |
| `enter` | Details: paths, commits, new commits after an update or check, and recent output. |
| `j` `k`, `g` `G` | Move; first and last. |
| `L` | Git, build, and Rex reload output. |
| `?` | Help. |
| `q` | Quit. While plugins run, press it twice; that cancels them. |

### Rex actions

The same operations are Rex actions, so they can go in the command palette or a key binding. Each opens a centered floating pane at 75% of the window running `amber`, which closes when you quit it.

| Action | Opens |
| --- | --- |
| `amber` | The plugin window. |
| `amber_install`, `amber_update`, `amber_restore`, `amber_build` | The window, running that operation. Optional `plugin=owner/repo`. |
| `amber_outdated` | The window, checking for updates. |
| `amber_clean` | The clean view. |
| `amber_status` | Nothing: returns load status, errors, path, commit, lock match, build state, and version match. Does not fetch. |

The pane actions need a Rex session, so `rex do amber_update` from a plain shell fails and suggests the `amber` command instead. `amber_info` and `amber_lua_build` are internal: the command reads the configuration through the first and runs Lua build functions through the second. Load failures also go to `rex.log`; see [Rex logs](https://www.superlogical.com/rex/docs/linux/shared-server#logs).

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
| `cli` | `<Amber directory>/bin/amber` | Absolute path to the `amber` command the Rex actions open. |
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

- A string runs as `sh -c <string>` in the plugin directory (`module_dir` for `subdir` plugins). Its environment has `AMBER_PLUGIN_NAME`, `AMBER_PLUGIN_DIR` (the checkout), `AMBER_PLUGIN_MODULE_DIR`, and `AMBER_PLUGIN_DATA_DIR`. Its output shows in the plugin window.
- A function receives `{ name, dir, module_dir, data_dir, commit, exec }`. `exec(argv, opts)` runs a command in `module_dir` within the remaining action time; `opts.env` adds to the variables above instead of replacing them. The step fails if the function raises an error, returns `false`, or returns `nil` and a message.
- Functions can only run inside Rex, so a plugin with any function step builds entirely through the `amber_lua_build` action, within its roughly 23-second budget. Shell-only builds run in the `amber` command with a 30-minute limit per step.
- `build = false` disables the step. Local `path` plugins cannot have one: Amber never runs anything for them.
- `amber install`, `amber update`, and `amber restore` run the build when the locked commit differs from the one recorded as built in the lockfile (`built`). An unchanged commit is not rebuilt. `amber build` forces it.
- A build always targets the locked commit. If the checkout has moved away from it, the build is refused; run `amber restore` first. `amber build` needs a lock entry, so run `amber install` first if the lockfile was removed.
- A failed build still records the checkout in the lockfile and leaves the plugin unbuilt. Fix the cause and run `amber build`.
- Keep build output out of Git's way. `amber restore` and `amber update` refuse checkouts with untracked or modified files, so list generated files in the plugin's `.gitignore` or write them to `data_dir`.
- Until a build has run for the locked commit, Amber does not call the plugin's `setup`; it reports `unbuilt`. Adding `build` to an existing plugin therefore needs one `amber build`. If the lockfile cannot be read, Amber cannot tell and does not hold plugins back.
- The build runs without holding the lockfile guard, so other Amber commands are not blocked by it. If the lock entry changes while it runs, the result is not recorded and `amber build` must run again.
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

- Identity: name, lockfile key, status, and per-plugin targets (`amber update me/repo@subdir`) are `me/repo@subdir`.
- Installs: each entry gets its own full clone under `<root>/<owner>/<repo>--<subdir>` (with `/` mapped to `-` and other symbols to `-`). Two subdirs of one repo can sit on different commits or versions. If two entries (or one entry and a plain repository) resolve to the same directory, setup reports a duplicate location; that applies whether the entries are enabled or disabled, so a disabled checkout never stands in for an enabled plugin.
- Modules resolve inside the subdirectory's own `rex/lua` (`lua/` fallback), so two subdir plugins are only isolated by the searcher's main-namespace scope, not by anything stronger; a missing subdirectory in an existing checkout reports a `missing` load status naming the subdir, while a checkout that was never installed keeps the plain missing-module warning.
- `path` combines with `subdir`: local checkout plus module offset.

## Versions and lockfile

```lua
{ "alice/rex-projects", version = "v1.2.0" },    -- exact tag, commit, or branch
{ "bob/rex-workspaces", version = "^1.2.0" },    -- highest stable 1.x.y tag
{ "carol/rex-tools", version = "~1.2.0" },       -- highest stable 1.2.x tag
```

- `^` and `~` need three numeric parts. They match `1.2.3` and `v1.2.3` tags. Prereleases and wildcards are not supported.
- Tags win over branches of the same name. Branches resolve to `origin/<branch>`.
- Changing `version` does not move an existing checkout. Run `amber update`.

Amber records exact commits in the lockfile, plus a `built` commit for plugins with a build step. The file is JSON and safe to commit. The lock is authoritative: `amber install` and `amber restore` use it until you run `amber update`. Install never replaces an existing entry. Unrelated entries are kept; only `amber clean --lock` prunes entries of undeclared plugins.

```sh
amber restore                  # all enabled managed plugins
amber restore owner/repo       # one plugin
```

Config load only reads the lockfile to warn about drift. A malformed lockfile makes commands fail; Amber never overwrites it.

## Updating Amber

With Homebrew, run `brew upgrade amber-rex`. Otherwise:

```sh
amber self-update            # or --check to only look
```

This downloads the latest release of the `amber` command, verifies its checksum, replaces the binary, checks out the matching release tag in the library directory (the parent of `bin/`, or `--dir`), and reloads Rex. The command and the library are released together and must match; `amber doctor` warns when they differ. It only moves to a newer release, refuses a command built from source (version `dev`), and refuses a library checkout with local changes or on a branch other than `main`, so a development clone is never moved.

### Upgrading from 0.0.x

0.0.x had no `amber` command: the `amber_*` actions ran Git inside Rex. In 0.1.0 those actions open `<Amber directory>/bin/amber` in a floating pane, so a checkout updated with `git pull` has no command and the actions fail with "Amber CLI not found". Your plugin specs and `amber-lock.json` carry over unchanged.

- Get the command: install with Homebrew, or download the installer and run `AMBER_INSTALL_DIR=/new/path sh install.sh` (it refuses an existing directory), then point your `dofile` at the new path. To keep the old checkout, run `mise run cli:build` in it instead.
- Replace `rex do amber_install` (and update, restore, build) in scripts with `amber install` and the rest. The actions now need a Rex session, and they return `{ opened = <layer id> }` instead of the per-plugin results.
- Drop the `rex config reload` after these commands: `amber` reloads for you.

## Writing a plugin

A plugin is a GitHub repository with a Lua module in `rex/lua/` (or `lua/` when `rex/lua/` does not exist) that returns a table with `setup(opts, ctx)`. `setup` runs on every config load, reload, and config check, so register actions and bindings there.

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

See [docs/plugin-authoring.md](docs/plugin-authoring.md) for module layout and naming, the `ctx` fields, build steps, background processes, and local development. Plugins are trusted Lua code with the Rex server's privileges; they are not sandboxed.

Install the [authoring skill](.agents/skills/rex-plugin-authoring/SKILL.md) for your agent:

```sh
npx skills add rawnly/amber --skill rex-plugin-authoring
```

## Limitations

- Alpha. Expect changes.
- macOS and Linux only. Needs `git`; the library also uses `mkdir`, `mktemp`, `mv`, and `rm`.
- GitHub `owner/repo` only. No other Git URLs.
- No dependency resolution.
- No lazy loading.
- No separate uninstall: remove the declaration, then `amber clean` deletes the checkout. Files a build created outside the plugin directory stay.
- No service or daemon management.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Interrupted install left `.amber-*` directories or `<plugin>.amber-lock` | They are not treated as installed. If no Amber command is running, `amber clean` removes them. |
| Lockfile guard `<lockfile>.lock` left behind | Every command fails with "lockfile is busy". If no Amber command is running, `amber clean` removes it. |
| A Rex action fails with "Amber CLI not found" | No release binary was installed. Run `mise run cli:build` in the Amber directory, or point `cli` in `amber.setup` at an `amber` binary. |
| `amber` cannot read the configuration | Rex has not loaded this version of Amber. Run `rex config reload`, then `amber doctor`. |
| "action time budget exhausted" | Only Lua build functions run inside a Rex action. Make them shorter, or start long work from the plugin itself. |
| Git fails on auth | Prompts are disabled (`GIT_TERMINAL_PROMPT=0`). Use credentials that work non-interactively. |
| Lockfile error | The file is corrupt. Fix or remove it. Amber will not overwrite it. |
| Checkout changed but lock write failed | Inspect the checkout and lockfile before retrying. |
| `checkout differs from lockfile` warning | Run `amber restore`. It refuses dirty checkouts. |
| Plugin reports `unbuilt` | The build has not run for the locked commit. Run `amber build` (or fix the failing step). |

## Contributing

```sh
mise trust && mise install
mise exec -- lefthook install   # git hooks
mise run check                  # formatting, lint, Lua and Go tests, types, luac
mise run cli:build              # bin/amber
```

Also: `mise run fmt`, `mise run test`, `mise run cli:test`, `mise run cli:run -- <args>` (run from source), and `mise run cli:go -- <args>` (any `go` command in `cli/`). Two heavier tests are not part of `check`: `mise run e2e` starts a scratch Rex server with local Git origins in place of GitHub and drives the real `bin/amber` through install, build, update, restore, clean, doctor, and the floating window (it needs `rex` and touches nothing of yours); `mise run brew:local` builds the formula from `HEAD`, installs it through a throwaway tap, runs the end-to-end test against the installed library, and removes everything it added (`-- --fetch-only` skips the install, which otherwise builds with Homebrew's `go`). The Lua tests stub Rex and Git. The Go tests use real Git repositories in temporary directories and a fake Rex server; Rex is not required. Pushing a `vX.Y.Z` tag that matches `version` in `amber.lua` publishes binaries for macOS and Linux on arm64 and x86-64 plus a source archive, then commits the matching `Formula/amber-rex.rb` to `main` (generated by `scripts/formula.sh`; do not edit it by hand). `mise run cli:dist` builds the same binaries locally into `dist/`, and `mise run cli:go -- <args>` runs any `go` command in `cli/`. See [docs/architecture.md](docs/architecture.md).

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

Plugin authors: to type the `ctx` argument of `setup` as `AmberPluginContext`, see [Editor types](docs/plugin-authoring.md#editor-types).

## Migrating from RPM

Amber was previously called Rex Plugin Manager (RPM). This is a clean break with no compatibility aliases:

- Load `amber.lua` from `~/.local/share/rex/amber` and call `amber.setup`.
- Use the `amber` command (or the `amber_*` actions) instead of the `rpm_*` actions.
- Rename `rpm-lock.json` to `amber-lock.json`. Amber does not read the old name, so an unrenamed lockfile is ignored and new installs would record fresh commits.
- The installer environment variable is now `AMBER_INSTALL_DIR`.
- Stale `.rpm-*` and `<plugin>.rpm-lock` directories are not recognized; delete them.

`install.sh` leaves an existing RPM install untouched and prints these steps when it finds one.

## Inspiration

[lazy.nvim](https://github.com/folke/lazy.nvim) for specs, [TPM](https://github.com/tmux-plugins/tpm) for Git-based installs.

## License

[Apache License 2.0](LICENSE).
