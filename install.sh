#!/usr/bin/env bash
# omarchohard one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --channel nightly
#
# Downloads a release build, checks its sha256, unpacks it into
# ~/.local/share/omarchohard/releases/<version>, points .../current at it and
# links ~/.local/bin/omarchohard. Running it again upgrades in place.
# Everything is inside main(), so a partial download runs nothing.
set -euo pipefail

OH_REPO=${OMARCHOHARD_REPO:-baney75/omarchohard}
OH_BASE=${OMARCHOHARD_RELEASE_BASE:-https://github.com/$OH_REPO/releases}

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
  C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_OFF=$'\e[0m'
else
  C_OK='' C_WARN='' C_ERR='' C_OFF=''
fi

say() { printf '%s\n' "$*" >&2; }
ok() { printf '%s  ok%s  %s\n' "$C_OK" "$C_OFF" "$*" >&2; }
warn() { printf '%swarn%s  %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() {
  printf '%sfail%s  %s\n' "$C_ERR" "$C_OFF" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--channel stable|nightly|dev] [--yes | --install | --no-setup] [-- SETUP FLAGS]

  --channel C   release channel to install from (default: stable)
                In a terminal, the guided setup runs afterward.
  --yes         run setup with safe defaults, no questions (for agents)
  --install     only add the launchers and file handlers afterward
  --no-setup    only install the omarchohard command
  -- FLAGS      pass the rest to setup, e.g. -- --onedrive rclone --optimize

Environment: OMARCHOHARD_RELEASE_BASE overrides the release download address.
EOF
}

# Same address scheme as lib/omarchohard/release.sh.
channel_url() {
  local channel=$1 file=$2
  case $channel in
  stable) printf '%s/latest/download/%s\n' "$OH_BASE" "$file" ;;
  nightly | dev) printf '%s/download/%s/%s\n' "$OH_BASE" "$channel" "$file" ;;
  *) return 1 ;;
  esac
}

fetch() { curl -fsSL --retry 2 --connect-timeout 10 -o "$2" "$1"; }

check_deps() {
  local missing=() tool
  for tool in bash curl tar sha256sum jq xdg-mime; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]})); then
    say "Missing: ${missing[*]}"
    say "Install them with: omarchy pkg add curl tar coreutils jq xdg-utils"
    die "missing required tools"
  fi
  local browser
  for browser in chromium google-chrome-stable microsoft-edge-stable brave helium-browser helium vivaldi-stable; do
    command -v "$browser" >/dev/null 2>&1 && return 0
  done
  warn "no Chromium-family browser found; omarchohard needs one. Install it with: omarchy pkg add chromium"
}

# Set one key in the omarchohard config, in the same key=value format the CLI
# writes, without touching the other lines.
config_set() {
  local key=$1 value=$2 dir file tmp
  dir=${XDG_CONFIG_HOME:-$HOME/.config}/omarchohard
  file=$dir/config
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.config.XXXXXX")
  if [[ -f $file ]]; then
    grep -v -E "^[[:space:]]*${key}[[:space:]]*=" "$file" >"$tmp" || true
  else
    # shellcheck disable=SC2016 # literal backticks in the header comment
    printf '# omarchohard config. Edit with care; see `omarchohard help`.\n' >"$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

main() {
  local channel=stable run_install=0 run_setup=auto
  local -a setup_args=()
  while (($#)); do
    case $1 in
    --channel)
      channel=${2:-}
      shift
      ;;
    --channel=*) channel=${1#--channel=} ;;
    --install) run_install=1 run_setup=no ;;
    --no-setup) run_setup=no ;;
    --yes | -y)
      run_setup=yes
      setup_args+=(--yes)
      ;;
    --)
      shift
      run_setup=yes
      setup_args+=("$@")
      break
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
    esac
    shift
  done
  case $channel in
  stable | nightly | dev) ;;
  *) die "unknown channel '$channel' (use stable, nightly or dev)" ;;
  esac
  [[ $(id -u) != 0 ]] || die "run this as your own user, not root; it installs into your home folder"

  check_deps

  local data releases current bindir link tmp version dest
  data=${XDG_DATA_HOME:-$HOME/.local/share}/omarchohard
  releases=$data/releases
  current=$data/current
  bindir=$HOME/.local/bin
  link=$bindir/omarchohard
  # Before anything is downloaded or changed.
  if [[ -e $link && ! -L $link ]]; then
    die "$link exists and is not a symlink; move it away and run this again"
  fi

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: tmp is local to main
  trap "rm -rf '$tmp'" EXIT

  say "Fetching the $channel channel from $OH_BASE"
  fetch "$(channel_url "$channel" omarchohard.version)" "$tmp/version" ||
    die "could not reach the $channel channel at $OH_BASE"
  version=$(tr -d '[:space:]' <"$tmp/version")
  # It names a directory that is replaced with rm -rf, so no "..".
  [[ $version =~ ^[0-9A-Za-z][0-9A-Za-z.+_-]*$ && $version != *..* ]] || die "the $channel channel returned a bad version: $version"

  fetch "$(channel_url "$channel" omarchohard.tar.gz)" "$tmp/omarchohard.tar.gz" || die "download failed"
  fetch "$(channel_url "$channel" omarchohard.tar.gz.sha256)" "$tmp/sha256" || die "checksum download failed"
  (cd "$tmp" && printf '%s  omarchohard.tar.gz\n' "$(cut -d' ' -f1 sha256)" | sha256sum -c --quiet -) >/dev/null 2>&1 ||
    die "checksum mismatch; nothing was changed"
  ok "downloaded omarchohard $version, sha256 verified"

  dest=$releases/$version
  mkdir -p "$releases"
  rm -rf "$dest.partial"
  mkdir -p "$dest.partial"
  tar -xzf "$tmp/omarchohard.tar.gz" -C "$dest.partial" --strip-components=1
  [[ -x $dest.partial/bin/omarchohard ]] || die "release archive is missing bin/omarchohard"
  rm -rf "$dest"
  mv "$dest.partial" "$dest"
  ln -sfn "$dest" "$current.new"
  mv -T "$current.new" "$current"
  ok "installed to $dest"

  mkdir -p "$bindir"
  ln -sfn "$current/bin/omarchohard" "$link"
  ok "linked $link"

  config_set channel "$channel"
  ok "channel: $channel"

  case ":$PATH:" in
  *":$bindir:"*) ;;
  *)
    # shellcheck disable=SC2016 # print $HOME and $PATH literally
    warn "$bindir is not on your PATH. Add it: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >>~/.bashrc"
    ;;
  esac

  # A person at a terminal gets the guided setup. curl | bash has no stdin,
  # so setup reads answers from /dev/tty. Agents and CI pass --yes (setup with
  # defaults and any setup flags after --) or --install (launchers only).
  if [[ $run_setup == auto ]]; then
    run_setup=no
    [[ -t 1 ]] && { : </dev/tty; } 2>/dev/null && run_setup=yes
  fi
  if [[ $run_setup == yes ]]; then
    "$link" setup "${setup_args[@]}"
  elif ((run_install)); then
    "$link" install
  else
    say ""
    say "Next: omarchohard setup   (or open Microsoft 365 Setup from your apps)"
    say "Agents: omarchohard probe --json, then omarchohard setup --yes --optimize"
  fi
}

main "$@"
