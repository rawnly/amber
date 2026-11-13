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

# Prints why a directory is unusable; the later mkdir still guards against races.
check_dir() {
  case "$1" in
  /) printf 'Error: not a valid installation directory: %s\n' "$1" >&2 && return 1 ;;
  */ | */. | */..) printf 'Error: not a valid installation directory: %s\n' "$1" >&2 && return 1 ;;
  /*) ;;
  *) printf 'Error: the installation directory must be an absolute path: %s\n' "$1" >&2 && return 1 ;;
  esac
  if [ -e "$1" ]; then
    printf 'Error: %s already exists. No files were overwritten.\n' "$1" >&2
    return 1
  fi
}

# Ask only when a user is watching; stdin may be the piped script, so read from the terminal.
if [ -t 1 ] && { : </dev/tty; } 2>/dev/null; then
  bold='' dim='' accent='' reset=''
  if [ -z "${NO_COLOR:-}" ]; then
    bold=$(printf '\033[1m') dim=$(printf '\033[2m') accent=$(printf '\033[33m') reset=$(printf '\033[0m')
  fi
  ask() {
    printf '%s' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || {
      printf '\nAborted.\n' >&2
      exit 1
    }
  }

  printf '\n  %s%sAmber%s installer\n\n' "$bold" "$accent" "$reset" >/dev/tty
  printf '  %sInstall directory%s\n  %s→%s %s%s%s\n\n' "$dim" "$reset" "$accent" "$reset" "$bold" "$install_dir" "$reset" >/dev/tty
  pick_dir=1
  if check_dir "$install_dir" 2>/dev/tty; then
    while :; do
      ask "  Install here? ${dim}[Y/n]${reset} "
      case "$answer" in
      '' | [Yy] | [Yy][Ee][Ss])
        pick_dir=0
        break
        ;;
      [Nn] | [Nn][Oo]) break ;;
      esac
    done
  fi
  while [ "$pick_dir" = 1 ]; do
    ask "  ${bold}Install directory:${reset} "
    case "$answer" in
    '') continue ;;
    \~) answer=$HOME ;;
    \~/*) answer="$HOME/${answer#\~/}" ;;
    esac
    if check_dir "$answer" 2>/dev/tty; then
      install_dir=$answer
      pick_dir=0
    fi
  done
  printf '\n' >/dev/tty
fi

check_dir "$install_dir" || exit 1

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
