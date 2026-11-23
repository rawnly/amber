# Agent guide

## Project

Amber is a Lua 5.1 plugin manager loaded by the Rex server's configuration, plus an `amber` command in Go that installs and updates plugins. Read `docs/architecture.md` for the execution model and current limitations, and `README.md` for the user-facing contract.

- `amber.lua`: public entry point and configuration setup.
- `amber/spec.lua`: plugin spec validation and normalization.
- `amber/loader.lua`: Lua module loading.
- `amber/git.lua`: commit and version checks for load-time warnings.
- `amber/lock.lua`: validated lockfile reads and serialized atomic writes (used by `amber_lua_build`).
- `amber/build.lua`: build steps run inside Rex, for builds with Lua functions.
- `cli/`: the Go command. `internal/rex` (control API client), `internal/amber` (`amber_info` contract), `internal/engine` (Git, lockfile, builds, clean), `internal/ui` (Bubble Tea window), `internal/cli` (commands, self-update).
- `amber/util.lua`: shared command and filesystem helpers.
- `types/rex.lua`: partial editor-only Rex API declarations.
- `tests/test.lua` and `scripts/test.sh`: Lua tests and temporary fixtures; Go tests live next to their packages.

## Development

Use the pinned mise tools: `mise install`, then `mise run check`. Run `mise run fmt` to format Lua, shell, and Go, `mise run test` for the Lua tests, `mise run cli:test` for the Go tests, and `mise run cli:build` for `bin/amber`. The Lua tests stub Rex and Git; the Go engine tests use real local Git repositories. Neither verifies live Rex behavior. To test against Rex without touching the user's server, run a scratch server (`rex server run --listen unix:///tmp/x.sock --config <scratch init.lua> --state-dir <dir> --restore=false`) with `REX_SERVER` set to that socket. When changing Rex integration, also use `rex config check` with a temporary configuration if Rex is available, and report what was or was not tested.

Write idiomatic Lua 5.1, use local functions and descriptive snake_case names, and keep modules focused. Maintain Lua Language Server annotations for public options and APIs. In documentation examples, prefer a `---@type TypeName` annotation above the relevant declaration or field rather than an inline cast when the language server supports it; do not claim unverified editor behavior.

## Design constraints

- Config load, reload, and `rex config check` execute plugin setup but must not install or update plugins. Installation is explicitly requested through `amber install` (or the `amber_install` action, which opens it).
- The Lua library and the `amber` command share the lockfile format and its `.lock` guard; change both together. The command learns the config only through `amber_info`.
- Rex runs config on the server. In Lua, use `rex.exec` with argument arrays for subprocesses; `os.execute` and `io.popen` are unavailable in Rex. Check process-start errors and nonzero exit status.
- Plugin setup registers actions and bindings at config load; operations requiring a live session or client belong in callbacks. Respect Rex action deadlines.
- Prefer `rex/lua/` when present, otherwise `lua/`; do not silently fall back to `lua/` when `rex/lua/` exists. Keep Lua module-name collisions and `package.loaded` semantics in mind.
- Local `path` plugins are externally managed. Disabled plugins are not loaded or managed. Validate untrusted names and paths and never overwrite user changes during Git operations.
- Lock entries are authoritative for manual installs and restores until an explicit update. Preserve unrelated entries, reject malformed lockfiles, and never restore a dirty checkout.
- Plugins are trusted Lua code, not sandboxed. Do not imply otherwise.
- Update tests, type annotations, and documentation when changing the public contract. Avoid introducing compatibility guarantees or features absent from the implementation.

The smart-splits backend example lives in a separate repository; do not assume changes there are committed or published, and do not modify it unless the task calls for it.
