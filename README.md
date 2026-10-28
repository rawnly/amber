# Rex Plugin Manager

RPM installs GitHub Lua plugins on the machine running the Rex server and loads them from your Rex config.

- Plugin specs in Lua, in the style of lazy.nvim.
- Semver versions and a lockfile for reproducible installs.
- An agent skill for writing RPM plugins.

## Quick start

Requires Git, a POSIX shell, and macOS or Linux. Run on the Rex server machine.

```sh
curl -fsSL https://raw.githubusercontent.com/rawnly/rpm/main/install.sh | sh
```

This clones RPM to `~/.local/share/rex/rpm`. It does not touch your Rex config and refuses to overwrite an existing directory. To inspect it first, download `install.sh` and run `sh install.sh`. To use another absolute path, run `RPM_INSTALL_DIR=/absolute/path sh install.sh`.

Add to your Rex config (`~/.config/rex/init.lua` by default):

```lua
local rpm = dofile(os.getenv("HOME") .. "/.local/share/rex/rpm/rex_plugin_manager.lua")

rpm.setup({
  plugins = {
    { "rawnly/smart-splits-backend-rex", main = "smart-splits-rex", opts = { resize_amount = 3 } },
  },
})
```

This registers the Rex actions of [smart-splits-backend-rex](https://github.com/rawnly/smart-splits-backend-rex). It adds no key bindings. For Neovim you also need its Neovim plugin; see its README.

Config load and `rex config check` never install anything. Install explicitly, then reload:

```sh
rex config reload
rex do rpm_install
rex config reload
```

The first reload registers RPM's actions. The second loads the installed plugins.

## Commands

Run with `rex do <action>`. Add `plugin=owner/repo` to target one plugin. Without it, an action covers all enabled, managed plugins, one after another. Reload after install, update, or restore.

| Action | What it does |
| --- | --- |
| `rpm_install` | Clones missing plugins. Uses the locked commit if one exists. Records new commits in the lockfile. |
| `rpm_update` | Resolves the newest commit or version, checks it out, rewrites the lock entry. Unversioned: `git pull --ff-only`. Versioned: fetch tags, check out detached. Never resets local changes. |
| `rpm_restore` | Checks out the locked commit (detached). Refuses dirty checkouts. Fails if the commit is unavailable. |
| `rpm_status` | Shows load status, errors, path, commit, lock match, and version match. Does not fetch. |

`rpm_status` takes no `plugin` argument. Load failures also go to `rex.log`; see [Rex logs](https://www.superlogical.com/rex/docs/linux/shared-server#logs).

## Plugin spec

A plugin is `"owner/repo"` or a table whose first element is that name. Unknown options are rejected.

| Option | Default | Meaning |
| --- | --- | --- |
| `main` | repo name without trailing `.rex` | Lua module to `require`. Dots map to directories. |
| `opts` | `{}` | Table passed to `setup`. |
| `version` | default branch | Tag, commit, branch, `^1.2.3`, or `~1.2.3`. Not allowed with `path`. |
| `path` | none | Absolute path to a local checkout. Never installed, updated, or locked. |
| `enabled` | `true` | `false` skips loading and rejects actions for it. |

Options for `rpm.setup` itself:

| Option | Default | Meaning |
| --- | --- | --- |
| `root` | `$XDG_DATA_HOME/rex/plugins`, else `~/.local/share/rex/plugins` | Absolute install directory. Plugins go in `<root>/<owner>/<repo>`. No `~` expansion. |
| `lockfile` | `rpm-lock.json` next to `$REX_CONFIG`, else `$XDG_CONFIG_HOME/rex/rpm-lock.json`, else `~/.config/rex/rpm-lock.json` | Absolute file path on the server. |
| `plugins` | `{}` | Ordered list of specs. Plugins load in this order. |

Invalid specs, duplicate plugins, and duplicate enabled `main` names are logged and skipped.

For development, point `path` at a local checkout:

```lua
{ "rawnly/smart-splits-backend-rex", path = "/absolute/path/to/smart-splits-backend-rex", main = "smart-splits-rex" }
```

## Versions and lockfile

```lua
{ "alice/rex-projects", version = "v1.2.0" },    -- exact tag, commit, or branch
{ "bob/rex-workspaces", version = "^1.2.0" },    -- highest stable 1.x.y tag
{ "carol/rex-tools", version = "~1.2.0" },       -- highest stable 1.2.x tag
```

- `^` and `~` need three numeric parts. They match `1.2.3` and `v1.2.3` tags. Prereleases and wildcards are not supported.
- Tags win over branches of the same name. Branches resolve to `origin/<branch>`.
- Changing `version` does not move an existing checkout. Run `rpm_update`.

RPM records exact commits in the lockfile. The file is JSON and safe to commit. The lock is authoritative: `rpm_install` and `rpm_restore` use it until you run `rpm_update`. Install never replaces an existing entry. Unrelated entries are kept and nothing is pruned.

```sh
rex do rpm_restore                           # all enabled managed plugins
rex do rpm_restore plugin=owner/repo         # one plugin
rex config reload
```

Config load only reads the lockfile to warn about drift. A malformed lockfile makes actions fail; RPM never overwrites it.

## Writing a plugin

RPM looks for the module in `rex/lua/` if that directory exists, otherwise `lua/`. It never falls back to `lua/` when `rex/lua/` exists. The module must return a table with `setup(opts)`. `setup` runs on every config load, so register actions and bindings there.

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
- Plugins are trusted Lua code with the Rex server's privileges. They are not sandboxed.
- Config checks run `setup` too. Avoid side effects beyond configuration.

Install the [authoring skill](.agents/skills/rex-plugin-authoring/SKILL.md) for your agent:

```sh
npx skills add rawnly/rpm --skill rex-plugin-authoring
```

## Limitations

- Alpha. Expect changes.
- macOS and Linux only. Needs `git`, `mkdir`, `mktemp`, `mv`, `rm`.
- GitHub `owner/repo` only. No other Git URLs.
- No dependency resolution.
- No lazy loading.
- No uninstall. Remove the declaration and delete the directory yourself.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Interrupted install left `.rpm-*` directories or `<plugin>.rpm-lock` | They are not treated as installed. Confirm no install is running, then delete them and retry. |
| Lockfile guard `<lockfile>.lock` left behind | Confirm no RPM action is running, delete the directory, retry. |
| "action time budget exhausted" | Rex actions have a short deadline, so RPM stops after about 23 seconds. Retry, or target plugins with `plugin=owner/repo`. |
| Git fails on auth | Prompts are disabled (`GIT_TERMINAL_PROMPT=0`). Use credentials that work non-interactively. |
| Lockfile error | The file is corrupt. Fix or remove it. RPM will not overwrite it. |
| Checkout changed but lock write failed | Inspect the checkout and lockfile before retrying. |
| `checkout differs from lockfile` warning | Run `rpm_restore`. It refuses dirty checkouts. |

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
  "workspace.library": ["/home/you/.local/share/rex/rpm/types"],
  "diagnostics.globals": ["rex"]
}
```

Annotate the result of `dofile` with `---@type RpmModule`. `types/rex.lua` covers only the Rex API RPM uses.

## Inspiration

[lazy.nvim](https://github.com/folke/lazy.nvim) for specs, [TPM](https://github.com/tmux-plugins/tpm) for Git-based installs.

## License

[Apache License 2.0](LICENSE).
