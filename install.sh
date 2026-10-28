#!/bin/sh
set -eu

repo='https://github.com/rawnly/rpm.git'

if [ -z "${HOME:-}" ]; then
  printf '%s\n' 'Error: HOME is not set.' >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' 'Error: Git is required. Install Git and retry.' >&2
  exit 1
fi

install_dir=${RPM_INSTALL_DIR:-"$HOME/.local/share/rex/rpm"}
case "$install_dir" in
/*) ;;
*)
  printf '%s\n' 'Error: RPM_INSTALL_DIR must be an absolute path.' >&2
  exit 1
  ;;
esac
case "$install_dir" in
/ | */ | */. | */..)
  printf '%s\n' 'Error: RPM_INSTALL_DIR must name an installation directory.' >&2
  exit 1
  ;;
esac

parent=${install_dir%/*}
[ -n "$parent" ] || parent=/
mkdir -p "$parent"
if ! mkdir "$install_dir" 2>/dev/null; then
  printf 'Error: cannot create %s (it may already exist). No files were overwritten.\n' "$install_dir" >&2
  exit 1
fi

if ! GIT_TERMINAL_PROMPT=0 git clone -- "$repo" "$install_dir"; then
  printf 'Error: clone failed. Inspect and remove %s before retrying.\n' "$install_dir" >&2
  exit 1
fi

printf '\nRPM installed at %s\n' "$install_dir"
printf '%s\n' 'Add RPM to your Rex config and declare your plugins:'
printf '  %s/rex_plugin_manager.lua\n' "$install_dir"
printf '%s\n' 'See https://github.com/rawnly/rpm#installation for the configuration example.'
printf '%s\n' 'The installer does not modify your Rex config or install plugins.'
