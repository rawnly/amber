# Architecture

Amber is a Lua 5.1 module loaded by the Rex server configuration. It validates plugin specifications, loads plugin Lua modules, reads lock state, reports status, and runs builds containing Lua-function steps. The local Go CLI performs install, update, restore, shell builds, and clean operations. The entry point is `amber.lua`; `amber/spec.lua` normalizes specs, `amber/lock.lua` reads/writes lock data for Lua builds, `amber/loader.lua` loads modules, `amber/build.lua` runs build steps, and `amber/util.lua` contains command and filesystem helpers.

## Execution model

```text
Rex config load / check / reload
  └─ amber.setup(config)
       ├─ validate and normalize plugin specifications
       ├─ register CLI pane actions, amber_info, amber_lua_build, amber_status
       └─ load enabled entry points, in declaration order

Rex action (amber_install/update/restore/build/outdated/clean/amber)
  └─ open centered floating pane running <Amber dir>/bin/amber <command>
       └─ local Go CLI manages Git and lockfile changes

amber_info -> normalized Lua configuration and load state
amber_lua_build -> server-side build steps and lock recording
```

Configuration loading never installs or updates checkouts. Rex also executes configuration during `rex config check`, so plugin setup code runs during checks. Plugins installed or updated through the CLI take effect on the next `rex config reload`.

## Configuration and loading

`setup` accepts `root`, `lockfile`, `cli`, and an ordered `plugins` list. Specs may declare `opts`, `enabled`, `path`, `main`, `version`, `subdir`, and `build`; see the README for the public spec contract. Amber validates names and paths, logs and skips invalid specifications and duplicate identities/module names/install locations, and derives GitHub HTTPS URLs. Managed checkouts live under `<root>/<owner>/<repo>` or a sanitized subdir-specific location. Local paths are externally managed.

For each enabled plugin, Amber resolves modules from `rex/lua` when present, otherwise `lua`, within its checkout or subdirectory. It registers a scoped searcher and calls `require(main).setup(opts, ctx)`. Disabled plugins are not loaded. Missing modules and setup failures are recorded for `amber_status` and `amber_info`.

At load, Amber reads the lockfile and warns about checkout drift, version mismatch, and unbuilt plugins. It does not write the lockfile for Git operations; the CLI owns Git and lockfile changes. `amber_status` reads lock data and local Git metadata without fetching.

## CLI actions

User-facing Rex actions open the CLI in a floating Rex layer. The default binary is `<Amber directory>/bin/amber`; `cli` can override it with an absolute path. Targeted actions validate the requested plugin and reject unknown, disabled, or local plugins. A live Rex session is required; otherwise the error directs the user to run the CLI in a terminal.

The CLI runs on the local machine and owns install, update, restore, shell build, clean, and lockfile writes. `amber_info` supplies normalized configuration to the CLI. `amber_lua_build` is reserved for build declarations containing Lua functions: it checks the locked commit, runs all build steps under the action budget, and records `built` in a second lock transaction.

## Build steps

Build declarations normalize to ordered shell-command and Lua-function steps. The CLI runs shell-only builds locally. When a declaration contains Lua-function steps, it invokes `amber_lua_build` so the Rex server can execute the function steps; all steps run in order. The Lua action requires an installed managed checkout and lock entry, verifies that HEAD equals the locked commit, and records the successful build only if the lock entry remains unchanged. Config loading gates plugin setup until the locked commit has been built. Builds are trusted code running with the relevant machine's privileges.

## Lockfile and versions

The lockfile records exact commits, declared versions, and the last built commit for plugins with build steps. Lua reads the lockfile at setup and status time. CLI commands perform installation, update, restore, and lockfile writes. Local plugins are never managed. Lock read failures are surfaced in `amber_info` and `amber_status`; config loading does not repair malformed files.

## Development and verification

`mise run check` runs formatting, shell lint, Lua tests, Go checks, Lua diagnostics, and syntax validation. Tests stub Rex and Git; they do not prove live Rex pane behavior or network Git operations.
