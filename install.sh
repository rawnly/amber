#!/bin/sh
set -eu

repo='https://github.com/rawnly/amber.git'

if [ -z "${HOME:-}" ]; then
  printf '%s\n' 'Error: HOME is not set.' >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' 'Error: Git is required. Install Git and retry.' >&2
  exit 1
fi

install_dir=${AMBER_INSTALL_DIR:-"$HOME/.local/share/rex/amber"}
case "$install_dir" in
/*) ;;
*)
  printf '%s\n' 'Error: AMBER_INSTALL_DIR must be an absolute path.' >&2
  exit 1
  ;;
esac
case "$install_dir" in
/ | */ | */. | */..)
  printf '%s\n' 'Error: AMBER_INSTALL_DIR must name an installation directory.' >&2
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

printf '\nAmber installed at %s\n' "$install_dir"
printf '%s\n' 'Add Amber to your Rex config and declare your plugins:'
printf '  %s/amber.lua\n' "$install_dir"
printf '%s\n' 'See https://github.com/rawnly/amber#installation for the configuration example.'
printf '%s\n' 'The installer does not modify your Rex config or install plugins.'

old_dir=${RPM_INSTALL_DIR:-"$HOME/.local/share/rex/rpm"}
if [ -e "$old_dir/rex_plugin_manager.lua" ]; then
  printf '\nFound a previous Rex Plugin Manager (RPM) install at %s. Amber does not touch it.\n' "$old_dir"
  printf '%s\n' 'To migrate:'
  printf '%s\n' '  1. Point your Rex config at the new amber.lua and rename rpm.setup to amber.setup.'
  printf '%s\n' '  2. Rename the lockfile rpm-lock.json to amber-lock.json (Amber does not read the old name).'
  printf '%s\n' '  3. Use amber_install, amber_update, amber_restore and amber_status instead of rpm_*.'
  printf '%s\n' '  4. Delete the old directory and any leftover .rpm-* directories once Amber works.'
fi
