#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
sha=$(printf 'a%.0s' $(seq 1 64))

sh "$root/scripts/formula.sh" 1.2.3 "$sha" >"$fixture/amber-rex.rb"
grep -q '^class AmberRex < Formula$' "$fixture/amber-rex.rb"
grep -q 'releases/download/v1.2.3/amber-1.2.3.tar.gz' "$fixture/amber-rex.rb"
grep -q "sha256 \"$sha\"" "$fixture/amber-rex.rb"
grep -q 'conflicts_with "amber"' "$fixture/amber-rex.rb"
if grep -q '@VERSION@\|@SHA256@' "$fixture/amber-rex.rb"; then
  echo 'formula still has placeholders' >&2
  exit 1
fi
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$fixture/amber-rex.rb" >/dev/null
fi

for bad in "v1.2.3 $sha" "1.2 $sha" "1.2.3;x $sha" "1.2.3 ${sha}0" "1.2.3 $(printf 'A%.0s' $(seq 1 64))" "1.2.3"; do
  # shellcheck disable=SC2086
  if sh "$root/scripts/formula.sh" $bad >/dev/null 2>&1; then
    printf 'formula.sh accepted: %s\n' "$bad" >&2
    exit 1
  fi
done
printf '%s\n' 'Formula tests passed'
