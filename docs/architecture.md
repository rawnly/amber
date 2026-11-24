# Architecture

Amber has two halves that share one lockfile:

- **The Lua library** (`amber.lua`, `amber/*.lua`), loaded by the Rex server's configuration. It validates specs, loads plugins, reads the lockfile to warn about drift, registers Amber's Rex actions, and runs build steps written as Lua functions.
- **The `amber` command** (`cli/`, Go), run on the Rex server machine. It installs, updates, restores, builds, checks, and cleans plugins with Git, writes the lockfile, and shows progress in a terminal window modelled on lazy.nvim's.

The command learns the configuration from the library through the `amber_info` action, over Rex's control API. Neither half parses the other's code.

## Execution model

```text
Rex config load / check / reload
  └─ amber.setup(config)
       ├─ validate and normalize plugin specifications       amber/spec.lua
       ├─ register actions: amber, amber_install, amber_update, amber_restore, amber_build,
       │   amber_outdated, amber_clean (open the command), amber_info, amber_lua_build, amber_status
       └─ load enabled entry points, in declaration order    amber/loader.lua
            └─ require(main).setup(opts, ctx)

Rex action, e.g. amber_update [plugin=owner/repo]
  └─ rex.session.new_layer: a floating pane at [0.125, 0.125, 0.75, 0.75]
       └─ <cli> update [plugin]          (the pane closes when the command exits)

amber <command>                          (a terminal, or the pane above)
  ├─ dial Rex: $REX_SERVER or the local socket, WebSocket rex.control.v1
  ├─ client.action amber_info  → root, lockfile, normalized plugins, load statuses
  ├─ Git and shell builds, several plugins at once          cli/internal/engine
  ├─ client.action amber_lua_build plugin=…  (only for builds with a Lua function step)
  └─ server.config_reload once anything changed, then amber_info again for load statuses
```

Configuration loading never installs or updates. Rex also executes the configuration during `rex config check`, so plugin setup code runs during checks. Plugins execute as Lua code with the server user's privileges; Amber is not a sandbox.

## Lua library

`setup` accepts `root`, `lockfile`, `cli`, and an ordered `plugins` list; `install` may be omitted or `"manual"`. Each element is an `owner/repo` string or a table whose first element is that name, with:

| Field | Purpose |
| --- | --- |
| `opts` | Table passed to the plugin's `setup`; defaults to an empty table. |
| `enabled` | Defaults to true. False skips loading and rejects targeted actions. |
| `path` | Absolute path to an externally managed local checkout. |
| `main` | Lua module name; defaults to the repository name. |
| `version` | Git ref or supported semver constraint for managed checkouts; incompatible with `path`. |
| `subdir` | Repository subdirectory the plugin loads from; requires `main`. |
| `build` | Shell command, function, or list of them run after install or update; rejected with `path`. `false` disables it. |

Every plugin has a unique identity: `owner/repo`, or `owner/repo@subdir` for subdir specs, which keys the lockfile, status, and per-plugin targets. Amber validates names, module names, and subdir paths, logs and skips invalid specs, duplicate identities, enabled duplicate main modules, and duplicate install locations across all non-local specs (enabled or disabled), and derives a GitHub HTTPS URL. Managed checkouts live at `<root>/<owner>/<repo>`, or `<root>/<owner>/<repo>--<subdir with / and symbols mapped to ->` for subdir specs; the default root is `$XDG_DATA_HOME/rex/plugins` or `~/.local/share/rex/plugins`.

For every enabled plugin, Amber chooses the module tree inside the checkout (inside `<dir>/<subdir>` for subdir plugins), preferring `rex/lua` when present, otherwise `lua`, never falling back to the checkout root. It registers a searcher scoped to the main module namespace and calls `require(main).setup(opts, ctx)` inside `pcall`; `ctx` carries `name`, `dir`, `module_dir`, the locked `commit`, and a `data_dir` that Amber names but does not create. A missing module is a warning; a load or setup failure is logged as an error and Amber continues. Lua's module cache is shared, so unrelated module-name collisions remain possible.

At load, Amber reads the lockfile and warns when a versioned checkout differs from its locally resolved version, when the checkout differs from its lock entry, or when the declared version changed since it was locked. A plugin with a build step whose lock entry lacks `built == commit` is not set up (`unbuilt`). Config load never writes the lockfile and never fetches.

The pane actions validate the optional `plugin` argument (unknown, disabled, and local plugins are errors), require the configured binary to exist, and require `ctx.session_id`; without a session, the error names the terminal command to run instead. `amber_status` keeps reporting load status, errors, commit, lock match, build state, and version match without fetching.

## The `amber` command

`cli/` is a Go module with no runtime dependencies beyond Git and `sh`:

| Package | Role |
| --- | --- |
| `internal/rex` | Minimal client for the control API: endpoint resolution, hello/welcome, concurrent requests matched by id, events skipped. Only `client.action`, `server.config_reload`, and `server.version`. |
| `internal/amber` | The `amber_info` contract. Accepts `{}` for empty lists, since Lua cannot tell them from objects. |
| `internal/engine` | Git, version resolution, lockfile transactions, builds, checks, and cleaning. |
| `internal/ui` | The Bubble Tea plugin window, plain-text output, `list` and `doctor` reports. |
| `internal/cli` | Cobra commands and `self-update`. |

Reloading works only over the local Unix socket, which is why the command runs on the server machine. The Rex actions open it there, with `REX_SERVER` naming the server that launched the pane.

### Installation and updates

Every operation on a checkout takes a per-plugin guard, the directory `<dir>.amber-lock`, so two Amber processes never touch one checkout at once. Within one process, the window runs up to `--jobs` plugins (default 4) in parallel.

To install, Amber treats a checkout containing `.git/HEAD` as installed and refuses an existing destination that is not one. It clones into a unique sibling `.amber-XXXXXXXX`, checks out the locked commit when there is a lock entry, else the resolved version when one is declared, and moves the clone into place with an exclusive rename (`RENAME_EXCL` on macOS, `RENAME_NOREPLACE` on Linux, check-then-rename under the guard elsewhere). Failures remove the temporary clone.

An unversioned checkout on a branch updates with `git pull --ff-only`. A versioned checkout fetches tags and checks out the resolved ref detached. An unversioned detached checkout, for example after a restore, must be clean; Amber fetches, reads `refs/remotes/origin/HEAD`, and advances only when the current commit is its ancestor. Restore needs a lock entry, installs a missing checkout at the locked commit, refuses dirty checkouts, and checks out the locked commit detached. Amber never resets or discards local changes.

Network Git commands set `GIT_TERMINAL_PROMPT=0` and stream `--progress` output to the window; they time out after 10 minutes, local Git commands after one. `outdated` fetches and computes the ref an update would use (the resolved version, the branch upstream, or `origin/HEAD`) without checking anything out or touching the lockfile.

### Version resolution

Without `version`, the default branch is used. `^x.y.z` and `~x.y.z` select the highest matching stable `x.y.z` or `vx.y.z` tag among local tags, with caret rules for major version zero. Other values are exact refs: tags win over remote branches, branches resolve to `origin/<branch>`, and anything else (a commit) is used as is. Updates fetch tags before resolving. Prereleases and broader semver expressions are not supported.

### Lockfile

The default `amber-lock.json` sits next to Rex's configuration. It stores `format: 1` and a map of plugin identities to `commit`, the declared `version`, and for plugins with a build step the `built` commit. Both halves validate it the same way (40- or 64-character lowercase hex commits) and refuse to overwrite a malformed file.

Writes happen inside a transaction: an in-process mutex plus the guard directory `<lockfile>.lock` (the command waits up to ten seconds for it; the Lua library fails at once), a re-read inside the guard, a write to a unique `<lockfile>.tmp.*` sibling, and a rename. The JSON uses two-space indentation and sorted keys, matching the Lua writer. The command does Git work under the per-plugin guard and records the result in a short transaction afterwards, so the lockfile guard is never held during network or build work.

Install records an entry only when none exists. Update replaces the entry and keeps `built` only when the commit did not change. Restore never changes the lock. Unrelated entries are retained; `clean --lock` is the only operation that drops entries, and only for undeclared plugins. A failed lock write after Git changed a checkout returns an error; the two are not one transaction.

### Build steps

After install, update, or restore, Amber builds when the plugin has steps and the lock entry's `built` differs from its `commit`; `amber build` always builds. A build first checks that `HEAD` equals the locked commit and refuses a drifted checkout. Shell-only builds run each step as `sh -c` in `module_dir` with `AMBER_PLUGIN_NAME`, `AMBER_PLUGIN_DIR`, `AMBER_PLUGIN_MODULE_DIR`, and `AMBER_PLUGIN_DATA_DIR`, up to 30 minutes per step, streaming output; the first failure stops the build. A second transaction records `built` only if the entry still locks the built commit.

Lua functions can only run inside Rex, so a declaration with any function step is built entirely by the `amber_lua_build` action: it checks the entry and `HEAD`, runs every step through `amber/build.lua` within a roughly 23-second action budget, and records `built` the same way. A failed build leaves the checkout and lock entry recorded and the plugin unbuilt, so the build can be retried.

### Cleaning

`clean` scans `<root>/<owner>/` without following symlinks. It offers temporary clones (`.amber-XXXXXXXX`), leftover per-plugin guards (`*.amber-lock`), checkouts that no spec declares (enabled or disabled, so a disabled plugin's checkout is kept), the lockfile guard, and with `--lock` lock entries of undeclared plugins. Each item is checked again immediately before removal.

### Self-update and releases

A `vX.Y.Z` tag that matches `version` in `amber.lua` publishes `amber-<os>-<arch>` binaries and a `checksums.txt`. `install.sh` and `amber self-update` download the binary for the platform, verify its SHA-256 checksum, and check out the same tag in the library directory, so the command and library always match; `doctor` reports a mismatch. `self-update` refuses a library checkout with local changes or on a branch other than `main`.

The release also attaches a source archive, `amber-X.Y.Z.tar.gz`, made with `git archive`, and a second job runs `scripts/formula.sh` with that file's SHA-256 and commits `Formula/amber-rex.rb` to `main`. The formula therefore pins the checksum of the uploaded file, not of a GitHub-generated archive. The repository doubles as its own tap (`brew tap rawnly/amber https://github.com/rawnly/amber`). The formula is named `amber-rex` and declares a conflict with Homebrew's `amber`, which also installs `bin/amber`. It builds the command from the archive with `go` into `libexec/bin/amber` next to `amber.lua`, `amber/`, and `types/`, so the default `cli` path works and the stable `opt/amber-rex/libexec/amber.lua` path survives upgrades. A binary inside a Homebrew `Cellar` refuses `self-update` and `doctor` points at `brew upgrade amber-rex`.

## Development and verification

`mise.toml` pins Lua 5.1, StyLua, Lua Language Server, ShellCheck, shfmt, Lefthook, typos, and Go. `mise run check` runs formatting checks (StyLua, shfmt, gofmt), ShellCheck, the Lua tests (`scripts/test.sh`, which stubs Rex and Git), the installer tests, `go vet` and `go test`, Lua Language Server diagnostics, and `luac`. The Go engine tests use real Git repositories in temporary directories; the control client is tested against a fake WebSocket server; the window is tested by driving its model with a fake backend. None of these prove live Rex behaviour. Two tasks outside `check` do: `mise run e2e` (`scripts/e2e.sh`) starts a scratch Rex server (its own socket, config, and state, with `REX_SERVER` set to that socket so its panes inherit it) and runs the real `bin/amber` against local Git repositories that stand in for GitHub through `GIT_CONFIG_*` `insteadOf` rewriting; it covers install, build, reload, outdated, update, restore, clean, doctor, the session error, and the floating window. `mise run brew:local` (`scripts/brew-local.sh`) builds the formula from `HEAD`, audits and installs it through a throwaway local tap with a private trust list, checks the Cellar layout and the `self-update` refusal, runs the end-to-end test with `AMBER_DIR` pointing at the installed library, and removes the install, the tap, and any dependency it added.

Current non-goals include dependency resolution, lazy loading, service or daemon management, arbitrary remote URLs, and Windows support.
