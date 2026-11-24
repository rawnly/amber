#!/bin/sh
# End-to-end test: a scratch Rex server, local Git origins standing in for
# GitHub, and the real bin/amber. Touches nothing outside a temporary
# directory; your Rex server, config, and lockfile are never used.
#   usage: mise run e2e
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# AMBER_DIR points the test at another Amber library, e.g. a Homebrew install's
# libexec (scripts/brew-local.sh does that).
amber_dir=${AMBER_DIR:-$root}
amber_bin=$amber_dir/bin/amber

if ! command -v rex >/dev/null 2>&1; then
  printf 'Error: the e2e test needs the rex command\n' >&2
  exit 1
fi
if [ ! -x "$amber_bin" ]; then
  printf 'Error: %s is missing; run mise run cli:build\n' "$amber_bin" >&2
  exit 1
fi

# Unix socket paths are short on macOS, so stay under /tmp.
E=$(mktemp -d /tmp/amber-e2e.XXXXXX)
server_pid=
cleanup() {
  status=$?
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ] && [ -f "$E/server.log" ]; then
    printf '\n--- scratch server log (last lines)\n' >&2
    tail -n 20 "$E/server.log" >&2
  fi
  rm -rf "$E"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# Everything below talks to the scratch server and never to yours.
unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$E/rex.sock"
# Git: no user config, and github.com URLs resolve to local bare repositories.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.com
export GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.com
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$E/git/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/

step() { printf '\n== %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
expect() {
  case $2 in
  *"$1"*) ;;
  *)
    printf 'FAIL: expected "%s" in:\n%s\n' "$1" "$2" >&2
    exit 1
    ;;
  esac
}
expect_re() {
  printf '%s' "$2" | grep -Eq "$1" || {
    printf 'FAIL: expected /%s/ in:\n%s\n' "$1" "$2" >&2
    exit 1
  }
}
amber() { "$amber_bin" "$@"; }
# Runs a command that must succeed; its output is left in $out.
run_ok() {
  out=$("$@" 2>&1) || {
    printf 'FAIL: %s\n%s\n' "$*" "$out" >&2
    exit 1
  }
  printf '%s\n' "$out"
}

write_plugin() { # dir module revision
  mkdir -p "$1/lua/$2"
  cat >"$1/lua/$2/init.lua" <<EOF
local M = {}

function M.setup()
  rex.action({
    name = "$2_ping",
    title = "$2 ping",
    run = function()
      return { from = "$2", rev = "$3" }
    end,
  })
end

return M
EOF
}

publish() { # work-dir message [tag]
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  git -C "$1" push -q origin HEAD:main
  if [ -n "${3:-}" ]; then
    git -C "$1" tag "$3"
    git -C "$1" push -q origin "$3"
  fi
}

new_origin() { # owner/repo
  mkdir -p "$E/git/${1%/*}" "$E/work/${1%/*}"
  git init -q --bare -b main "$E/git/$1.git"
  git clone -q "$E/git/$1.git" "$E/work/$1" 2>/dev/null
  git -C "$E/work/$1" checkout -q -B main
}

step "origins"
new_origin alice/hello
write_plugin "$E/work/alice/hello" hello 1
publish "$E/work/alice/hello" "hello 1" v1.0.0
new_origin bob/tools
write_plugin "$E/work/bob/tools" tools 1
printf 'built.txt\n' >"$E/work/bob/tools/.gitignore"
publish "$E/work/bob/tools" "tools 1"

step "scratch Rex server"
cat >"$E/init.lua" <<EOF
local amber = dofile("$amber_dir/amber.lua")
amber.setup({
  root = "$E/plugins",
  lockfile = "$E/amber-lock.json",
  plugins = {
    { "alice/hello", main = "hello", version = "^1.0.0" },
    { "bob/tools", main = "tools", build = "echo built > built.txt" },
    { "carol/off", main = "off", enabled = false },
  },
})
EOF
mkdir -p "$E/state"
rex server run --listen "unix://$E/rex.sock" --state-dir "$E/state" --restore=false \
  --config "$E/init.lua" >"$E/server.log" 2>&1 &
server_pid=$!
i=0
until rex --autostart=false server status >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 50 ] || fail "the scratch Rex server did not start"
  sleep 0.2
done

step "ls before installing"
run_ok amber ls
expect "alice/hello" "$out"
expect "not installed" "$out"
expect "disabled" "$out"

step "install, build, and reload"
run_ok amber install
expect "installed" "$out"
expect "Reloaded Rex config" "$out"
[ -f "$E/plugins/alice/hello/.git/HEAD" ] || fail "alice/hello was not cloned"
[ ! -e "$E/plugins/carol" ] || fail "a disabled plugin was cloned"
[ -f "$E/plugins/bob/tools/built.txt" ] || fail "the build step did not run"
grep -q '"built"' "$E/amber-lock.json" || fail "the lockfile has no built commit"
run_ok amber ls
expect "loaded" "$out"
run_ok rex "do" hello_ping --json
expect_re '"rev": ?"1"' "$out"

step "outdated and update"
write_plugin "$E/work/alice/hello" hello 2
publish "$E/work/alice/hello" "hello 2" v1.1.0
run_ok amber outdated
expect "new commit" "$out"
expect "up to date" "$out"
run_ok amber update
expect "updated" "$out"
grep -q "$(git -C "$E/work/alice/hello" rev-parse HEAD)" "$E/amber-lock.json" || fail "update did not rewrite the lock entry"
run_ok rex "do" hello_ping --json
expect_re '"rev": ?"2"' "$out"

step "restore"
git -C "$E/plugins/alice/hello" checkout -q --detach v1.0.0
run_ok amber restore alice/hello
expect "restored" "$out"
[ "$(git -C "$E/plugins/alice/hello" rev-parse HEAD)" = "$(git -C "$E/work/alice/hello" rev-parse HEAD)" ] || fail "restore did not return to the locked commit"

step "clean"
mkdir -p "$E/plugins/alice/.amber-AbCd1234" "$E/plugins/dave/stray"
git init -q "$E/plugins/dave/stray"
run_ok amber clean --dry-run
expect "orphan" "$out"
expect "temp" "$out"
[ -d "$E/plugins/dave/stray" ] || fail "--dry-run removed something"
run_ok amber clean --yes
[ ! -e "$E/plugins/dave/stray" ] || fail "clean left the orphan"
[ ! -e "$E/plugins/alice/.amber-AbCd1234" ] || fail "clean left the temporary clone"
[ -d "$E/plugins/alice/hello" ] || fail "clean removed a declared plugin"

step "doctor"
run_ok amber doctor
expect "Amber library" "$out"

step "actions need a Rex session"
if out=$(rex "do" amber_update 2>&1); then
  fail "amber_update opened a pane without a session"
fi
expect "no Rex session" "$out"

step "the amber action opens the floating window"
rex new e2e >/dev/null
rex "do" amber -s e2e --json >/dev/null
block=$(rex session inspect e2e --json | sed -n 's/.*"focused_block_id": *"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$block" ] || fail "cannot find the new pane"
i=0
screen=
while :; do
  screen=$(rex capture -s e2e -b "$block" 2>&1 || true)
  case $screen in
  *"Total: 3 plugins"*) break ;;
  esac
  i=$((i + 1))
  [ "$i" -le 50 ] || fail "the window did not render; the pane shows:
$screen"
  sleep 0.2
done
expect "alice/hello" "$screen"
expect "bob/tools" "$screen"
rex send -s e2e -b "$block" q
i=0
while rex session inspect e2e --json | grep -q floating; do
  i=$((i + 1))
  [ "$i" -le 25 ] || fail "q did not close the floating pane"
  sleep 0.2
done
rex kill e2e >/dev/null 2>&1 || true

printf '\ne2e passed\n'
