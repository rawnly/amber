#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin" "$fixture/home"

cat >"$fixture/bin/git" <<'EOF'
#!/bin/sh
[ "$1" = clone ] && [ "$2" = -- ] && [ "$3" = https://github.com/rawnly/amber.git ]
[ "${GIT_TERMINAL_PROMPT:-}" = 0 ]
[ "${FAIL_CLONE:-0}" != 1 ] || exit 1
printf '%s\n' cloned > "$4/amber.lua"
EOF
chmod +x "$fixture/bin/git"
export HOME="$fixture/home" PATH="$fixture/bin:/usr/bin:/bin"
unset AMBER_INSTALL_DIR

sh "$root/install.sh" >"$fixture/output"
test -f "$HOME/.local/share/rex/amber/amber.lua"
test ! -e "$HOME/.config/rex/init.lua"
if sh "$root/install.sh" >"$fixture/output" 2>&1; then
  echo 'installer overwrote an existing directory' >&2
  exit 1
fi
test "$(cat "$HOME/.local/share/rex/amber/amber.lua")" = cloned

AMBER_INSTALL_DIR="$fixture/custom path" sh "$root/install.sh" >"$fixture/output"
test -f "$fixture/custom path/amber.lua"
if AMBER_INSTALL_DIR=relative sh "$root/install.sh" >"$fixture/output" 2>&1; then
  echo 'installer accepted a relative path' >&2
  exit 1
fi
if FAIL_CLONE=1 AMBER_INSTALL_DIR="$fixture/failed" sh "$root/install.sh" >"$fixture/output" 2>&1; then
  echo 'installer reported success after clone failure' >&2
  exit 1
fi
mkdir -p "$HOME/.local/share/rex/rpm"
printf '%s\n' old >"$HOME/.local/share/rex/rpm/rex_plugin_manager.lua"
AMBER_INSTALL_DIR="$fixture/migrated" sh "$root/install.sh" >"$fixture/output"
grep -q 'previous Rex Plugin Manager' "$fixture/output"
test "$(cat "$HOME/.local/share/rex/rpm/rex_plugin_manager.lua")" = old
printf '%s\n' 'Installer tests passed'
