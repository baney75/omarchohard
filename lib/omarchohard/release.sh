# shellcheck shell=bash
# Release channels and self-update.
#
#   stable   the newest tagged release (vX.Y.Z)
#   nightly  a daily build of main that passed the full test suite
#   dev      every push to main that passed CI
#
# Each channel publishes the same three files:
#   omarchohard.tar.gz  omarchohard.tar.gz.sha256  omarchohard.version

OH_CHANNELS=(stable nightly dev)
OH_RELEASES_DIR=$OH_DATA_DIR/releases
OH_CURRENT=$OH_DATA_DIR/current

oh_release_base() { printf '%s\n' "${OMARCHOHARD_RELEASE_BASE:-https://github.com/$OH_REPO/releases}"; }

oh_channel_url() {
  local channel=$1 file=$2 base
  base=$(oh_release_base)
  case $channel in
  stable) printf '%s/latest/download/%s\n' "$base" "$file" ;;
  nightly | dev) printf '%s/download/%s/%s\n' "$base" "$channel" "$file" ;;
  *) return 1 ;;
  esac
}

oh_channel_valid() {
  local c
  for c in "${OH_CHANNELS[@]}"; do [[ $1 == "$c" ]] && return 0; done
  return 1
}

oh_fetch() { curl -fsSL --retry 2 --connect-timeout 10 -o "$2" "$1"; }

oh_self_managed() { [[ $OH_ROOT == "$OH_RELEASES_DIR"/* ]]; }

oh_channel() {
  oh_config_load
  local want=${1:-}
  if [[ -z $want ]]; then
    printf 'channel: %s\nversion: %s\n' "$(oh_config_get channel)" "$(oh_version)"
    return 0
  fi
  oh_channel_valid "$want" || oh_die "unknown channel '$want' (use stable, nightly or dev)"
  oh_update --channel "$want"
}

# The config keeps the old channel until the new channel's build is installed,
# so a failed download or checksum leaves everything as it was.
oh_update() {
  oh_config_load
  local check=0 channel='' latest tmp dest
  while (($#)); do
    case $1 in
    --check) check=1 ;;
    --channel)
      channel=${2:?--channel needs stable, nightly or dev}
      shift
      ;;
    *) oh_die "unknown update option: $1" ;;
    esac
    shift
  done
  [[ -n $channel ]] || channel=$(oh_config_get channel)
  oh_channel_valid "$channel" || oh_die "config has an unknown channel '$channel'"

  if ! oh_self_managed && [[ -z ${OMARCHOHARD_FORCE_SELF_UPDATE:-} ]]; then
    ((check)) || oh_channel_commit "$channel"
    oh_say "omarchohard at $OH_ROOT was installed by a package manager."
    oh_say "Update it there: the AUR package 'omarchohard' follows stable, 'omarchohard-git' follows dev."
    return 0
  fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN
  oh_fetch "$(oh_channel_url "$channel" omarchohard.version)" "$tmp/version" ||
    oh_die "could not reach the $channel channel at $(oh_release_base)"
  latest=$(tr -d '[:space:]' <"$tmp/version")
  [[ $latest =~ ^[0-9A-Za-z.+_-]+$ ]] || oh_die "the $channel channel returned a bad version: $latest"
  if [[ $latest == "$(oh_version)" ]]; then
    ((check)) || oh_channel_commit "$channel"
    oh_ok "up to date: $latest ($channel)"
    return 0
  fi
  if ((check)); then
    echo "update available: $(oh_version) -> $latest ($channel)"
    return 0
  fi

  oh_fetch "$(oh_channel_url "$channel" omarchohard.tar.gz)" "$tmp/omarchohard.tar.gz" || oh_die "download failed"
  oh_fetch "$(oh_channel_url "$channel" omarchohard.tar.gz.sha256)" "$tmp/sha256" || oh_die "checksum download failed"
  (cd "$tmp" && printf '%s  omarchohard.tar.gz\n' "$(cut -d' ' -f1 sha256)" | sha256sum -c --quiet -) ||
    oh_die "checksum mismatch; nothing was changed"

  mkdir -p "$OH_RELEASES_DIR"
  dest=$OH_RELEASES_DIR/$latest
  rm -rf "$dest.partial"
  mkdir -p "$dest.partial"
  tar -xzf "$tmp/omarchohard.tar.gz" -C "$dest.partial" --strip-components=1
  [[ -x $dest.partial/bin/omarchohard ]] || oh_die "release archive is missing bin/omarchohard"
  rm -rf "$dest"
  mv "$dest.partial" "$dest"
  ln -sfn "$dest" "$OH_CURRENT.new"
  mv -T "$OH_CURRENT.new" "$OH_CURRENT"
  oh_release_prune
  oh_channel_commit "$channel"
  oh_ok "updated to $latest ($channel)"

  # Re-apply launchers and handlers with the new release's app table.
  if [[ -f $OH_STATE_DIR/manifest ]]; then
    "$OH_CURRENT/bin/omarchohard" install >/dev/null 2>&1 || oh_warn "re-applying launchers failed; run: omarchohard install"
  fi
}

oh_channel_commit() {
  [[ $(oh_config_get channel) == "$1" && -f $OH_CONFIG ]] && return 0
  oh_config_set channel "$1"
  oh_ok "channel set to $1"
}

# Keep the current release and the two before it.
oh_release_prune() {
  local current keep=3 n=0 dir
  current=$(readlink -f "$OH_CURRENT")
  while IFS= read -r dir; do
    [[ $dir == "$current" ]] && continue
    n=$((n + 1))
    ((n < keep)) || rm -rf -- "$dir"
  done < <(find "$OH_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}
