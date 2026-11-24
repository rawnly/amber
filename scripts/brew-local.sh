#!/bin/sh
# Builds the Homebrew formula from committed HEAD, installs it through a
# throwaway local tap, checks the install (including the end-to-end test
# against the installed library), and removes everything it added.
#   usage: mise run brew:local [-- --fetch-only]
# --fetch-only stops after the audit and the download check, so nothing is
# installed. A full run installs Homebrew's go as a build dependency if it is
# missing, and uninstalls it again afterwards.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fetch_only=0
case ${1:-} in
--fetch-only) fetch_only=1 ;;
'') ;;
*)
  printf 'usage: %s [--fetch-only]\n' "$0" >&2
  exit 2
  ;;
esac

if ! command -v brew >/dev/null 2>&1; then
  printf 'Error: this needs Homebrew\n' >&2
  exit 1
fi
tap=rawnly/amber-local
if brew tap | grep -qx "$tap"; then
  printf 'Error: the tap %s already exists; run brew untap %s first\n' "$tap" "$tap" >&2
  exit 1
fi
if brew list --formula | grep -qx 'amber-rex\|amber'; then
  printf 'Error: amber or amber-rex is already installed with Homebrew; uninstall it first\n' >&2
  exit 1
fi
version=$(sed -n 's/^local M = { version = "\(.*\)" }$/\1/p' "$root/amber.lua")
[ -n "$version" ] || {
  printf 'Error: cannot read the version from amber.lua\n' >&2
  exit 1
}
if [ -n "$(git -C "$root" status --porcelain)" ]; then
  printf 'Note: uncommitted changes are not included; the formula is built from HEAD.\n'
fi

# Keep brew from touching anything else: no updates, no cleanup of other
# formulae, no upgrades of dependencies, and a private trust list.
T=$(mktemp -d)
X=$(mktemp -d)
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALL_UPGRADE=1
export XDG_CONFIG_HOME=""

installed=0
tapped=0
cleanup() {
  status=$?
  trap - EXIT
  if [ "$installed" = 1 ]; then
    brew uninstall --formula amber-rex >/dev/null 2>&1 || true
  fi
  if [ "$tapped" = 1 ]; then
    brew untap "$tap" >/dev/null 2>&1 || true
  fi
  if [ -f "$T/before" ]; then
    brew list --formula | sort >"$T/after"
    # Dependencies this run installed, dependents first; brew refuses to
    # remove one that something else still needs.
    for _ in 1 2 3; do
      for formula in $(comm -13 "$T/before" "$T/after"); do
        if brew uninstall --formula "$formula" >/dev/null 2>&1; then
          printf 'Removed %s, which this run installed.\n' "$formula"
        fi
      done
      brew list --formula | sort >"$T/after"
    done
  fi
  rm -rf "$T" "$X"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

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

printf '== formula for v%s from HEAD\n' "$version"
git -C "$root" archive --format=tar.gz --prefix="amber-$version/" -o "$T/amber-$version.tar.gz" HEAD
sha=$(shasum -a 256 "$T/amber-$version.tar.gz" | cut -d ' ' -f 1)
mkdir -p "$T/tap/Formula"
sh "$root/scripts/formula.sh" "$version" "$sha" |
  sed "s#^  url .*#  url \"file://$T/amber-$version.tar.gz\"#" >"$T/tap/Formula/amber-rex.rb"
git -C "$T/tap" init -q
git -C "$T/tap" add -A
git -C "$T/tap" -c user.name=amber -c user.email=amber@example.com commit -q -m formula
brew list --formula | sort >"$T/before"
brew tap "$tap" "$T/tap" >/dev/null
tapped=1
brew trust --tap "$tap" >/dev/null

printf '== audit\n'
brew audit --strict "$tap/amber-rex" || fail "brew audit found problems"
printf '== fetch\n'
brew fetch --formula "$tap/amber-rex" >/dev/null || fail "brew cannot fetch the formula"
if [ "$fetch_only" = 1 ]; then
  printf '\nbrew:local passed (fetch only, nothing installed)\n'
  exit 0
fi

printf '== install (builds with go)\n'
installed=1
brew install --build-from-source "$tap/amber-rex"
brew test "$tap/amber-rex"

printf '== layout\n'
prefix=$(brew --prefix)
libexec=$prefix/opt/amber-rex/libexec
for path in amber.lua amber/spec.lua types/amber.lua bin/amber; do
  [ -e "$libexec/$path" ] || fail "$libexec/$path is missing"
done
[ -x "$prefix/bin/amber" ] || fail "$prefix/bin/amber is not on the Homebrew path"
out=$("$prefix/bin/amber" --version)
expect "amber version v$version" "$out"
if out=$("$prefix/bin/amber" self-update 2>&1); then
  fail "self-update ran on a Homebrew install"
fi
expect "brew upgrade amber-rex" "$out"
out=$(brew info "$tap/amber-rex")
expect "$libexec/amber.lua" "$out"

printf '== end to end against the installed library\n'
AMBER_DIR=$libexec sh "$root/scripts/e2e.sh"

printf '\nbrew:local passed\n'
