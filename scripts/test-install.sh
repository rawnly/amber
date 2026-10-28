#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin" "$fixture/home"

cat >"$fixture/bin/git" <<'EOF'
#!/bin/sh
[ "$1" = clone ] && [ "$2" = -- ] && [ "$3" = https://github.com/rawnly/rpm.git ]
[ "${GIT_TERMINAL_PROMPT:-}" = 0 ]
[ "${FAIL_CLONE:-0}" != 1 ] || exit 1
printf '%s\n' cloned > "$4/rex_plugin_manager.lua"
EOF
chmod +x "$fixture/bin/git"
export HOME="$fixture/home" PATH="$fixture/bin:/usr/bin:/bin"
unset RPM_INSTALL_DIR

sh "$root/install.sh" >"$fixture/output"
test -f "$HOME/.local/share/rex/rpm/rex_plugin_manager.lua"
test ! -e "$HOME/.config/rex/init.lua"
if sh "$root/install.sh" >"$fixture/output" 2>&1; then
  echo 'installer overwrote an existing directory' >&2
  exit 1
fi
test "$(cat "$HOME/.local/share/rex/rpm/rex_plugin_manager.lua")" = cloned

RPM_INSTALL_DIR="$fixture/custom path" sh "$root/install.sh" >"$fixture/output"
test -f "$fixture/custom path/rex_plugin_manager.lua"
if RPM_INSTALL_DIR=relative sh "$root/install.sh" >"$fixture/output" 2>&1; then
  echo 'installer accepted a relative path' >&2
  exit 1
fi
if FAIL_CLONE=1 RPM_INSTALL_DIR="$fixture/failed" sh "$root/install.sh" >"$fixture/output" 2>&1; then
  echo 'installer reported success after clone failure' >&2
  exit 1
fi
printf '%s\n' 'Installer tests passed'
