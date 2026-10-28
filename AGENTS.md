# Agent guide

## Project

Rex Plugin Manager (RPM) is a Lua 5.1 plugin manager loaded by the Rex server's configuration. Read `docs/architecture.md` for the execution model and current limitations, and `README.md` for the user-facing contract.

- `rex_plugin_manager.lua`: public entry point and configuration setup.
- `rpm/spec.lua`: plugin spec validation and normalization.
- `rpm/loader.lua`: Rex action registration and Lua module loading.
- `rpm/git.lua`: installation, updates, and version resolution.
- `rpm/lock.lua`: validated lockfile reads and serialized atomic writes.
- `rpm/util.lua`: shared command and filesystem helpers.
- `types/rex.lua`: partial editor-only Rex API declarations.
- `tests/test.lua` and `scripts/test.sh`: tests and temporary fixtures.

## Development

Use the pinned mise tools: `mise install`, then `mise run check`. Run `mise run fmt` to format Lua and `mise run test` for the tests alone. The tests stub Rex and Git; they do not verify real network operations or live Rex behavior. When changing Rex integration, also use `rex config check` with a temporary configuration if Rex is available, and report what was or was not tested.

Write idiomatic Lua 5.1, use local functions and descriptive snake_case names, and keep modules focused. Maintain Lua Language Server annotations for public options and APIs. In documentation examples, prefer a `---@type TypeName` annotation above the relevant declaration or field rather than an inline cast when the language server supports it; do not claim unverified editor behavior.

## Design constraints

- Config load, reload, and `rex config check` execute plugin setup but must not install or update plugins. Installation is explicitly requested through `rpm_install`.
- Rex runs config on the server. Use `rex.exec` with argument arrays for subprocesses; `os.execute` and `io.popen` are unavailable in Rex. Check process-start errors and nonzero exit status.
- Plugin setup registers actions and bindings at config load; operations requiring a live session or client belong in callbacks. Respect Rex action deadlines.
- Prefer `rex/lua/` when present, otherwise `lua/`; do not silently fall back to `lua/` when `rex/lua/` exists. Keep Lua module-name collisions and `package.loaded` semantics in mind.
- Local `path` plugins are externally managed. Disabled plugins are not loaded or managed. Validate untrusted names and paths and never overwrite user changes during Git operations.
- Lock entries are authoritative for manual installs and restores until an explicit update. Preserve unrelated entries, reject malformed lockfiles, and never restore a dirty checkout.
- Plugins are trusted Lua code, not sandboxed. Do not imply otherwise.
- Update tests, type annotations, and documentation when changing the public contract. Avoid introducing compatibility guarantees or features absent from the implementation.

The smart-splits backend example lives in a separate repository; do not assume changes there are committed or published, and do not modify it unless the task calls for it.
