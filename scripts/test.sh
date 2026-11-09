#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/alice/example/.git" "$fixture/alice/example/lua/example" "$fixture/carol/shared/.git" "$fixture/carol/shared/rex/lua/shared" "$fixture/carol/shared/lua/shared" "$fixture/bob" "$fixture/temporary/.git" "$fixture/temporary/lua/new" "$fixture/locked/.git" "$fixture/locked/lua/pinned" \
  "$fixture/elly/utility--panes-tools/.git" "$fixture/elly/utility--panes-tools/panes/tools/lua/tools" \
  "$fixture/elly/utility--panes-bells/.git" "$fixture/elly/utility--panes-bells/panes/bells/lua/bells" \
  "$fixture/local-mono/panes/tools/lua/tools" \
  "$fixture/temporary2/.git" "$fixture/temporary2/panes/bells/lua/bells" \
  "$fixture/temporary3/.git" "$fixture/temporary4/.git"
printf 'ref: refs/heads/main\n' >"$fixture/alice/example/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/carol/shared/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/temporary/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/elly/utility--panes-tools/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/elly/utility--panes-bells/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/temporary2/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/temporary3/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/temporary4/.git/HEAD"
printf 'ref: refs/heads/main\n' >"$fixture/locked/.git/HEAD"
printf '%s\n' 'return { setup = function() end }' >"$fixture/locked/lua/pinned/init.lua"
printf '%s\n' 'return { setup = function() end }' >"$fixture/temporary/lua/new/init.lua"
printf '%s\n' 'return { setup = function(opts) _G.plugin_message = opts.message end }' >"$fixture/alice/example/lua/example/init.lua"
printf '%s\n' 'return "user"' >"$fixture/keys.lua"
printf '%s\n' 'return "plugin"' >"$fixture/alice/example/lua/keys.lua"
printf '%s\n' 'return { setup = function() _G.shared_source = "rex" end }' >"$fixture/carol/shared/rex/lua/shared/init.lua"
printf '%s\n' 'return { setup = function() _G.subdir_message = "installed" end }' >"$fixture/elly/utility--panes-tools/panes/tools/lua/tools/init.lua"
printf '%s\n' 'return { setup = function() _G.subdir_message = "bells" end }' >"$fixture/elly/utility--panes-bells/panes/bells/lua/bells/init.lua"
printf '%s\n' 'return { setup = function() _G.subdir_message = "local" end }' >"$fixture/local-mono/panes/tools/lua/tools/init.lua"
printf '%s\n' 'return { setup = function() end }' >"$fixture/temporary2/panes/bells/lua/bells/init.lua"
printf '%s\n' 'return { setup = function() _G.shared_source = "nvim" end }' >"$fixture/carol/shared/lua/shared/init.lua"
lua tests/test.lua "$fixture"
