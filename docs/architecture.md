# Architecture

Rex Plugin Manager (RPM) is a Lua 5.1 module loaded by the Rex server's configuration. It turns plugin declarations into local paths, loads their Rex-side Lua entry points, and registers actions for installing, updating, restoring, and inspecting GitHub repositories. The entry point is `rex_plugin_manager.lua`; `rpm/spec.lua` validates specs, `rpm/git.lua` handles Git operations, `rpm/lock.lua` manages the lockfile, `rpm/loader.lua` registers actions and loads plugins, and `rpm/util.lua` contains shared command and filesystem helpers.

## Execution model

```text
Rex config load / check / reload
  └─ rpm.setup(config)
       ├─ validate and normalize plugin specifications
       ├─ register rpm_install, rpm_update, rpm_restore, and rpm_status actions
       └─ load enabled entry points, in declaration order
            └─ require(main).setup(opts)

Later: rex do rpm_install [plugin=owner/repo]
       rex do rpm_update  [plugin=owner/repo]
       rex do rpm_restore [plugin=owner/repo]
       rex do rpm_status
  └─ Rex invokes the corresponding registered action
       └─ RPM runs Git and filesystem commands via rex.exec
```

Configuration loading never installs or updates checkouts. Rex also executes the configuration during `rex config check`, so plugin setup code runs during checks. Plugins installed or updated through actions take effect on the next `rex config reload`.

Rex configuration runs on the server machine. RPM, local plugin paths, Git, and installed checkouts must therefore be available there, not merely on the client. Plugins execute as Lua code with the server user's privileges; RPM is not a sandbox.

## Configuration and normalized plugins

`setup` accepts `root`, `lockfile`, and an ordered `plugins` list. `install` may be omitted or `"manual"`; any other value is logged as an error and setup stops. Each element is either an `owner/repo` string or a table whose first element is that name. A table can also specify:

| Field | Purpose |
| --- | --- |
| `opts` | Table passed to the plugin's `setup`; defaults to an empty table. |
| `enabled` | Defaults to true. False skips loading and rejects install/update actions. |
| `path` | Absolute path to an externally managed local checkout. |
| `main` | Lua module name; defaults to the repository name. |
| `version` | Git ref or supported semver constraint for managed checkouts; incompatible with `path`. |

All plugins, including local ones, have an `owner/repo` identity. RPM validates names and module names, logs and skips invalid specifications and duplicate identities or enabled main module names, and derives a GitHub HTTPS URL for each name. For managed plugins, the default root is `$XDG_DATA_HOME/rex/plugins` or `~/.local/share/rex/plugins`; the checkout is `<root>/<owner>/<repo>`. `root` overrides that location. A local `path` bypasses this layout and is never installed or updated by RPM.

RPM keeps both an ordered list for loading and a name-indexed table for action lookup. These are built anew each time `setup` runs. Plugin modules must return a table containing `setup(opts)`; version and author fields in that module are not required. `version` in the manager's specification controls the checkout, not plugin metadata.

## Loading and errors

For every enabled plugin, RPM chooses `rex/lua` when present, otherwise `lua`, checks for the main module there, registers a searcher scoped to the main module namespace, and invokes `require(main).setup(opts)` inside `pcall`. It never falls back to `lua` when `rex/lua` exists. A missing module produces a warning; a load or setup failure is logged as an error, and RPM continues to the next plugin. Lua's global module cache and namespace are shared, so unrelated module-name collisions remain possible. Disabled plugins do not load or produce missing-entry warnings. Configuration validation errors, such as duplicate names or an invalid version, are logged and the offending spec is skipped.

Loading checks the module file and warns when a versioned managed checkout differs from its locally resolved version. Changing a version declaration does not switch an existing checkout until an update action is run; comparison does not fetch from the remote. Plugins register their Rex actions and bindings during config load; their own action callbacks run later.

## Installation and updates

The install action accepts an optional `plugin` name; without one it processes enabled managed plugins sequentially and returns per-plugin results. The update and restore actions also accept optional names and process all enabled managed plugins when omitted. Named actions reject unknown, disabled, and externally managed plugins. Actions share a 23-second budget for Git operations, leaving time before Rex's 30-second action deadline for cleanup. Exhausted or timed-out operations return an error; retry or target plugins individually. Actions return a reminder to reload; command failures, including failures in bulk installs, become action errors.

For installation, RPM:

1. Treats a checkout containing `.git/HEAD` as already installed; refuses an existing destination that is not such a checkout.
2. Creates the owner directory and a unique temporary sibling directory.
3. Runs `git clone` into that directory, then optionally checks out the requested version.
4. Moves the completed clone into its final location without intentionally replacing an existing destination.

Failed clones and checkouts trigger temporary-directory cleanup. A sibling lock directory serializes RPM installs of the same plugin. An interruption can leave a `.rpm-*` directory or `.rpm-lock` directory behind; inspect and remove stale locks manually. The implementation relies on the platform's `mktemp`, `mv`, and `rm` commands; its temporary-directory move is not a general-purpose transactional package store.

For updates, an unversioned checkout uses `git pull --ff-only`. A versioned checkout fetches tags and checks out the selected ref in detached HEAD state. Git reports conflicts or other failures; RPM does not reset working-tree changes. For an unversioned detached checkout, RPM requires a clean worktree, fetches the origin default branch, and only advances when the current commit is its ancestor.

`rex.exec` receives an argument vector rather than a shell command. RPM checks both process startup errors and exit status; network Git operations set `GIT_TERMINAL_PROMPT=0`. Individual Git operations have a 20-second timeout, but Rex actions also have their own deadline, so a multi-command operation can still be interrupted by Rex.

## Version resolution

Without `version`, Git's default branch is used. Exact tags take precedence over remote branch names, and branch names resolve to `origin/<branch>`. `rpm_status` compares the checked-out commit with the locally resolved version without fetching. `^x.y.z` and `~x.y.z` select the highest matching stable `x.y.z` or `vx.y.z` tag among locally available tags, applying caret or tilde bounds. Updates fetch tags before resolving again. Prerelease tags and broader lazy.nvim semver expressions are not supported. The lockfile pins resolved commits across installs; a range can resolve to a newer tag on an explicit update.

## Lockfile

The default `rpm-lock.json` is next to Rex's configuration, with an absolute-path override in `setup`. It stores a format version and a map of plugin identities to exact Git commits and their declared version. Configuration loads only read it. Manual install uses an existing lock entry or records the resulting checkout when no entry exists; update replaces the entry after a successful checkout. Restore uses locked commits and refuses dirty working trees. Local and disabled plugins are skipped in bulk operations, and unrelated lock entries are retained.

Operations serialize lockfile read-modify-write with a sibling `.lock` directory. Writes use a unique temporary sibling and rename. A crash can leave the guard behind; operators must verify no action is running before removing it. A failed lock write after Git changed a checkout leaves that checkout changed and returns an error; the filesystem and Git update are not a single transaction. Restore checks out detached commits, and can fail if a locked commit is no longer available.

## Development and verification

`mise.toml` pins Lua 5.1, StyLua, Lua Language Server, ShellCheck, shfmt, Lefthook, and typos. `mise run check` runs formatting checks (StyLua, shfmt), ShellCheck, the tests (`scripts/test.sh` and `scripts/test-install.sh`), Lua Language Server diagnostics, and Lua syntax validation with `luac`; `scripts/test.sh` creates a temporary fixture for `tests/test.lua`. Tests stub Rex APIs and Git responses, so they do not prove live Git operations or Rex pane behavior. The README documents setup and task commands.

Current non-goals include dependency resolution, lazy loading, uninstall, arbitrary remote URLs, and Windows support. These are not implied by the current module contract.
