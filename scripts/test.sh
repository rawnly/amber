#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/alice/example/.git"
printf 'ref: refs/heads/main\n' > "$fixture/alice/example/.git/HEAD"
printf '%s\n' 'return { setup = function(opts) _G.plugin_message = opts.message end }' > "$fixture/alice/example/init.lua"
lua tests/test.lua "$fixture"
