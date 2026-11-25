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

# Downloads the CLI for this platform from the latest release, verifies its
# checksum, and moves the library checkout to the matching tag. Returns
# nonzero without touching bin/ when anything is missing.
install_cli() {
  case $(uname -s) in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) return 1 ;;
  esac
  case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum "$1" | cut -d ' ' -f 1; }
  elif command -v shasum >/dev/null 2>&1; then
    sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
  else
    return 1
  fi
  base=${AMBER_RELEASE_URL:-https://github.com/rawnly/amber/releases/latest/download}
  name=amber-$os-$arch
  mkdir -p "$install_dir/bin"
  download="$install_dir/bin/.amber-download"
  sums="$install_dir/bin/.amber-checksums"
  if ! curl -fsL "$base/$name" -o "$download" || ! curl -fsL "$base/checksums.txt" -o "$sums"; then
    rm -f "$download" "$sums"
    return 1
  fi
  expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$sums")
  actual=$(sha "$download")
  rm -f "$sums"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    rm -f "$download"
    printf 'Error: checksum mismatch for %s.\n' "$name" >&2
    return 1
  fi
  chmod 755 "$download"
  mv "$download" "$install_dir/bin/amber"
  version=$("$install_dir/bin/amber" --version 2>/dev/null | awk '{ print $NF }')
  case $version in
  v[0-9]*) git -C "$install_dir" checkout --quiet --detach "$version" -- 2>/dev/null ||
    printf 'Warning: could not check out %s; run amber self-update.\n' "$version" >&2 ;;
  esac
}

if install_cli; then
  cli_note="The amber command is at $install_dir/bin/amber; add $install_dir/bin to your PATH."
else
  cli_note="No prebuilt amber command for this machine; build it with mise run cli:build in $install_dir."
fi

printf '\nAmber installed at %s\n' "$install_dir"
printf '%s\n' 'Add Amber to your Rex config and declare your plugins:'
printf '  %s/amber.lua\n' "$install_dir"
printf '%s\n' 'See https://github.com/rawnly/amber#-quick-start for the configuration example.'
printf '%s\n' 'The installer does not modify your Rex config or install plugins.'
printf '%s\n' "$cli_note"

old_dir=${RPM_INSTALL_DIR:-"$HOME/.local/share/rex/rpm"}
if [ -e "$old_dir/rex_plugin_manager.lua" ]; then
  printf '\nFound a previous Rex Plugin Manager (RPM) install at %s. Amber does not touch it.\n' "$old_dir"
  printf '%s\n' 'To migrate:'
  printf '%s\n' '  1. Point your Rex config at the new amber.lua and rename rpm.setup to amber.setup.'
  printf '%s\n' '  2. Rename the lockfile rpm-lock.json to amber-lock.json (Amber does not read the old name).'
  printf '%s\n' '  3. Use amber_install, amber_update, amber_restore and amber op=status instead of rpm_*.'
  printf '%s\n' '  4. Delete the old directory and any leftover .rpm-* directories once Amber works.'
fi
