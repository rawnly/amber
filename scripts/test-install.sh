#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin" "$fixture/home"

cat >"$fixture/bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = -C ]; then
  [ "$3" = checkout ] && [ "$5" = --detach ] || exit 1
  printf '%s\n' "$6" >"$2/checked-out"
  exit 0
fi
[ "$1" = clone ] && [ "$2" = -- ] && [ "$3" = https://github.com/rawnly/amber.git ]
[ "${GIT_TERMINAL_PROMPT:-}" = 0 ]
[ "${FAIL_CLONE:-0}" != 1 ] || exit 1
printf '%s\n' cloned > "$4/amber.lua"
EOF
chmod +x "$fixture/bin/git"
export HOME="$fixture/home" PATH="$fixture/bin:/usr/bin:/bin"
unset AMBER_INSTALL_DIR
# No release by default; the CLI download is tested on its own below.
export AMBER_RELEASE_URL="file://$fixture/no-release"

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
grep -q 'mise run cli:build' "$fixture/output"
test ! -e "$fixture/migrated/bin/amber"

# A release: the binary is verified, installed, and the checkout moved to its tag.
case $(uname -s) in Darwin) os=darwin ;; *) os=linux ;; esac
case $(uname -m) in x86_64 | amd64) arch=amd64 ;; *) arch=arm64 ;; esac
release="$fixture/release"
mkdir -p "$release"
printf '%s\n' '#!/bin/sh' 'echo "amber version v9.9.9"' >"$release/amber-$os-$arch"
if command -v sha256sum >/dev/null 2>&1; then
  sum=$(sha256sum "$release/amber-$os-$arch" | cut -d ' ' -f 1)
else
  sum=$(shasum -a 256 "$release/amber-$os-$arch" | cut -d ' ' -f 1)
fi
printf '%s  %s\n' "$sum" "amber-$os-$arch" >"$release/checksums.txt"
AMBER_RELEASE_URL="file://$release" AMBER_INSTALL_DIR="$fixture/released" sh "$root/install.sh" >"$fixture/output"
test -x "$fixture/released/bin/amber"
test "$(cat "$fixture/released/checked-out")" = v9.9.9
grep -q 'add .*/bin to your PATH' "$fixture/output"

# A tampered binary is rejected and nothing is installed.
printf '%s\n' tampered >>"$release/amber-$os-$arch"
AMBER_RELEASE_URL="file://$release" AMBER_INSTALL_DIR="$fixture/tampered" sh "$root/install.sh" >"$fixture/output" 2>&1
test ! -e "$fixture/tampered/bin/amber"
grep -q 'checksum mismatch' "$fixture/output"
printf '%s\n' 'Installer tests passed'
