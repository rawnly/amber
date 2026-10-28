#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/alice/example/.git" "$fixture/alice/example/lua/example" "$fixture/carol/shared/rex/lua/shared" "$fixture/carol/shared/lua/shared"
printf 'ref: refs/heads/main\n' > "$fixture/alice/example/.git/HEAD"
printf '%s\n' 'return { setup = function(opts) _G.plugin_message = opts.message end }' > "$fixture/alice/example/lua/example/init.lua"
printf '%s\n' 'return { setup = function() _G.shared_source = "rex" end }' > "$fixture/carol/shared/rex/lua/shared/init.lua"
printf '%s\n' 'return { setup = function() _G.shared_source = "nvim" end }' > "$fixture/carol/shared/lua/shared/init.lua"
lua tests/test.lua "$fixture"
