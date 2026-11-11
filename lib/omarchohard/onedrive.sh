# shellcheck shell=bash
# OneDrive on disk.
#
# rclone (default): a FUSE mount with a full local cache. Files appear at once,
# open from cache after the first read, and saves upload within seconds.
# abraunegg: the `onedrive` client keeps a complete two-way copy on disk, for
# full offline use. The web apps save to OneDrive directly, so either client
# brings their edits back down to the same folder.

OH_ONEDRIVE_UNIT=omarchohard-onedrive.service

oh_onedrive_root() {
  local client dir
  client=$(oh_config_get onedrive_client)
  dir=$(oh_config_get onedrive_dir)
  [[ -n $client && -d $dir ]] || return 0
  readlink -f -- "$dir"
}

oh_onedrive_web_url() {
  local rel=$1 root
  root=$(oh_config_get onedrive_web_root)
  [[ -n $root ]] || return 1
  printf '%s/%s?web=1\n' "${root%/}" "$(oh_urlencode_path "$rel")"
}

# Wait (up to 60 s) until a file under the OneDrive folder exists remotely.
# The rclone mount answers on a private socket in the user's runtime dir
# (mode 0700), so status can show the live upload queue.
oh_onedrive_rc() {
  local sock=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchohard-rclone.sock
  [[ -S $sock ]] && oh_have rclone || return 1
  rclone rc --unix-socket "$sock" "$@" 2>/dev/null
}

# "in progress queued", or nothing when the mount is not answering.
oh_onedrive_queue() {
  local stats
  stats=$(oh_onedrive_rc vfs/stats) || return 1
  jq -r '"\(.diskCache.uploadsInProgress // 0) \(.diskCache.uploadsQueued // 0)"' <<<"$stats" 2>/dev/null
}

# Pull remote changes now and wait for local saves to finish uploading.
oh_onedrive_sync_now() {
  local q i
  case $(oh_config_get onedrive_client) in
  rclone)
    oh_onedrive_rc vfs/refresh recursive=true >/dev/null || oh_die "the OneDrive mount is not running: omarchohard onedrive start"
    for ((i = 0; i < 120; i++)); do
      q=$(oh_onedrive_queue) || break
      [[ $q == "0 0" ]] && break
      ((i % 5)) || oh_say "uploading: ${q% *} in progress, ${q#* } queued"
      sleep 1
    done
    oh_ok "OneDrive is in sync"
    ;;
  abraunegg) oh_run onedrive --sync && oh_ok "OneDrive is in sync" ;;
  *) oh_die "OneDrive is not set up: omarchohard onedrive setup" ;;
  esac
}

oh_onedrive_wait_uploaded() {
  local rel=$1 remote i q
  remote=$(oh_config_get onedrive_remote)
  case $(oh_config_get onedrive_client) in
  rclone)
    oh_have rclone || return 0
    for ((i = 0; i < 60; i++)); do
      # Uploaded once the queue is empty (when the mount answers) and the file is listed.
      q=$(oh_onedrive_queue) || q="0 0"
      [[ $q == "0 0" ]] && rclone lsf --files-only "$remote:$rel" >/dev/null 2>&1 && return 0
      sleep 1
    done
    oh_warn "OneDrive has not confirmed the upload yet; the document may take a moment to appear"
    ;;
  abraunegg) sleep 5 ;;
  esac
}

# Suggest the OneDrive for work or school web root from an email address:
# you@school.edu -> https://school-my.sharepoint.com/personal/you_school_edu/Documents
oh_onedrive_guess_root() {
  local email=$1 user domain tenant
  user=${email%@*}
  domain=${email#*@}
  tenant=${domain%%.*}
  printf 'https://%s-my.sharepoint.com/personal/%s_%s/Documents\n' "$tenant" "${user//./_}" "${domain//./_}"
}

oh_onedrive_set_web_root() {
  local url=${1%/}
  [[ $url =~ ^https://[a-zA-Z0-9.-]+/ ]] || oh_die "the OneDrive web address must start with https://"
  url=${url%%\?*}
  [[ $url == *sharepoint.com/personal/*/Documents ]] ||
    oh_warn "expected an address like https://school-my.sharepoint.com/personal/you_school_edu/Documents"
  oh_config_set onedrive_web_root "$url"
  oh_ok "OneDrive web address set: $url"
}

oh_onedrive_rclone_unit() {
  local dir=$1 remote=$2 rclone_bin fusermount cache
  rclone_bin=$(command -v rclone)
  cache=$(oh_config_get onedrive_cache_size)
  [[ $cache =~ ^[0-9]+[MG]$ ]] || cache=20G
  fusermount=$(command -v fusermount3 || command -v fusermount || echo fusermount3)
  mkdir -p "$OH_UNIT_DIR"
  cat >"$OH_UNIT_DIR/$OH_ONEDRIVE_UNIT" <<EOF
[Unit]
Description=omarchohard: OneDrive at $dir (rclone)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/usr/bin/mkdir -p $dir
ExecStartPre=/usr/bin/rm -f %t/omarchohard-rclone.sock
ExecStart=$rclone_bin mount $remote: $dir --vfs-cache-mode full --vfs-cache-max-age 8760h --vfs-cache-max-size $cache --vfs-cache-min-free-space 2G --vfs-write-back 2s --vfs-read-ahead 16M --buffer-size 16M --transfers 8 --dir-cache-time 30s --poll-interval 30s --vfs-fast-fingerprint --rc --rc-addr unix://%t/omarchohard-rclone.sock --rc-no-auth
ExecStop=$fusermount -uz $dir
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
}

oh_onedrive_setup() {
  local client=rclone dir remote email guess answer
  dir=$(oh_config_get onedrive_dir)
  remote=$(oh_config_get onedrive_remote)
  while (($#)); do
    case $1 in
    --client)
      client=${2:?--client needs rclone or abraunegg}
      shift
      ;;
    --dir)
      dir=${2:?--dir needs a folder}
      shift
      ;;
    *) oh_die "unknown onedrive setup option: $1" ;;
    esac
    shift
  done
  dir=${dir/#\~/$HOME}
  case $client in
  rclone)
    if ! oh_have rclone; then
      oh_have omarchy && oh_run omarchy pkg add rclone fuse3 || oh_die "install rclone first: sudo pacman -S rclone fuse3"
    fi
    if ! rclone listremotes 2>/dev/null | grep -qx "$remote:"; then
      oh_say "Your browser will open for the Microsoft sign-in. Approve access, then come back here."
      oh_run rclone config create "$remote" onedrive config_type=onedrive ||
        oh_die "rclone sign-in did not finish. See docs/troubleshooting.md#onedrive-sign-in (some schools require admin approval)."
      mkdir -p "$OH_STATE_DIR" && : >"$OH_STATE_DIR/rclone-remote-created"
    fi
    oh_onedrive_rclone_unit "$dir" "$remote"
    ;;
  abraunegg)
    if ! oh_have onedrive; then
      oh_have omarchy && oh_run omarchy pkg aur add onedrive-abraunegg || oh_die "install the onedrive client first: yay -S onedrive-abraunegg"
    fi
    mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/onedrive"
    local conf=${XDG_CONFIG_HOME:-$HOME/.config}/onedrive/config
    if [[ ! -f $conf ]]; then
      printf 'sync_dir = "%s"\n' "$dir" >"$conf"
      oh_manifest_add "$conf"
    fi
    oh_say "The onedrive client prints a sign-in link. Open it, sign in, and paste back the address it lands on."
    oh_run onedrive --sync --verbose || oh_die "onedrive first sync failed. See docs/troubleshooting.md#onedrive-sign-in"
    mkdir -p "$OH_UNIT_DIR"
    cat >"$OH_UNIT_DIR/$OH_ONEDRIVE_UNIT" <<EOF
[Unit]
Description=omarchohard: OneDrive at $dir (abraunegg onedrive)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v onedrive || echo /usr/bin/onedrive) --monitor
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    ;;
  *) oh_die "unknown OneDrive client: $client (use rclone or abraunegg)" ;;
  esac
  oh_config_set onedrive_client "$client"
  oh_config_set onedrive_dir "$dir"
  oh_manifest_add "$OH_UNIT_DIR/$OH_ONEDRIVE_UNIT"
  oh_run systemctl --user daemon-reload
  oh_run systemctl --user enable --now "$OH_ONEDRIVE_UNIT"

  if [[ -z $(oh_config_get onedrive_web_root) ]]; then
    email=$(oh_config_get email)
    guess=''
    [[ -n $email ]] && guess=$(oh_onedrive_guess_root "$email")
    oh_say ""
    oh_say "Last step: tell omarchohard your OneDrive web address so files open in place."
    oh_say "Open OneDrive (omarchohard launch onedrive), then copy the address up to and including /Documents."
    if [[ -t 0 ]]; then
      read -r -p "OneDrive address${guess:+ [$guess]}: " answer
      answer=${answer:-$guess}
      [[ -n $answer ]] && oh_onedrive_set_web_root "$answer"
    else
      oh_say "Then run: omarchohard onedrive web-root <address>"
    fi
  fi
  oh_ok "OneDrive is at $dir"
}

oh_onedrive_remove() {
  local quiet=0 remote
  [[ ${1:-} == --quiet ]] && quiet=1
  remote=$(oh_config_get onedrive_remote)
  systemctl --user disable --now "$OH_ONEDRIVE_UNIT" >/dev/null 2>&1 || true
  rm -f "$OH_UNIT_DIR/$OH_ONEDRIVE_UNIT"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [[ -f $OH_STATE_DIR/rclone-remote-created ]] && oh_have rclone; then
    rclone config delete "$remote" >/dev/null 2>&1 || true
    rm -f "$OH_STATE_DIR/rclone-remote-created"
  fi
  oh_config_set onedrive_client ""
  ((quiet)) || oh_ok "OneDrive service removed; files already on disk were left in place"
}

oh_onedrive_status() {
  local client dir web
  client=$(oh_config_get onedrive_client)
  dir=$(oh_config_get onedrive_dir)
  web=$(oh_config_get onedrive_web_root)
  printf 'client:   %s\n' "${client:-not set up}"
  printf 'folder:   %s\n' "$dir"
  printf 'service:  %s\n' "$(systemctl --user is-active "$OH_ONEDRIVE_UNIT" 2>/dev/null || echo inactive)"
  if [[ $client == rclone ]]; then
    printf 'mounted:  %s\n' "$(mountpoint -q "$dir" 2>/dev/null && echo yes || echo no)"
    local q
    if q=$(oh_onedrive_queue) && [[ -n $q ]]; then
      if [[ $q == "0 0" ]]; then printf 'sync:     up to date (saves upload after 2 s, changes from other devices appear within 30 s)\n'; else
        printf 'sync:     %s uploading, %s queued\n' "${q% *}" "${q#* }"
      fi
    fi
  fi
  printf 'web root: %s\n' "${web:-not set (omarchohard onedrive web-root URL)}"
}

oh_onedrive() {
  oh_config_load
  local action=${1:-status}
  (($#)) && shift
  case $action in
  setup) oh_onedrive_setup "$@" ;;
  status) oh_onedrive_status ;;
  web-root) oh_onedrive_set_web_root "${1:?usage: omarchohard onedrive web-root URL}" ;;
  guess) oh_onedrive_guess_root "${1:?usage: omarchohard onedrive guess you@school.edu}" ;;
  sync) oh_onedrive_sync_now ;;
  start) oh_run systemctl --user start "$OH_ONEDRIVE_UNIT" ;;
  stop) oh_run systemctl --user stop "$OH_ONEDRIVE_UNIT" ;;
  remove) oh_onedrive_remove "$@" ;;
  *) oh_die "usage: omarchohard onedrive setup|status|sync|web-root|start|stop|remove" ;;
  esac
}
