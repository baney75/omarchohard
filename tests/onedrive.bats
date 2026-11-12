#!/usr/bin/env bats
# OneDrive setup writes systemd units; sync reports what it could confirm.

load test_helper

setup() {
  oh_sandbox
  UNIT=$XDG_CONFIG_HOME/systemd/user/omarchohard-onedrive.service
  # shellcheck disable=SC2016
  stub rclone 'printf "%s\n" "$*" >>"$HOME/rclone.log"; case "$1" in listremotes) echo omarchohard-onedrive: ;; esac; exit 0'
}

@test "onedrive setup quotes a folder with a space and a percent sign for systemd" {
  run "$OH" onedrive setup --dir "$HOME/One Drive 100%" </dev/null
  [ "$status" -eq 0 ]
  q="\"$HOME/One Drive 100%%\""
  grep -qxF "ExecStartPre=/usr/bin/mkdir -p $q" "$UNIT"
  grep -qF "ExecStart=\"$(command -v rclone)\" mount omarchohard-onedrive: $q --vfs-cache-mode full" "$UNIT"
  grep -qF -- "-uz $q" "$UNIT"
  grep -qxF "Description=omarchohard: OneDrive at $HOME/One Drive 100%% (rclone)" "$UNIT"
  grep -qxF "onedrive_dir=$HOME/One Drive 100%" "$XDG_CONFIG_HOME/omarchohard/config"
  if command -v systemd-analyze >/dev/null && [ -d /run/systemd/system ]; then
    systemd-analyze --user verify "$UNIT"
  fi
}

@test "onedrive setup refuses a remote that could add flags, before writing anything" {
  for remote in 'x --rc-addr=127.0.0.1:5572' '--rc' 'my remote'; do
    printf 'browser=chromium\nonedrive_remote=%s\n' "$remote" >"$XDG_CONFIG_HOME/omarchohard/config"
    run "$OH" onedrive setup </dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"rclone remote name"* ]]
    [ ! -e "$UNIT" ]
    [ ! -e "$HOME/rclone.log" ]
  done
}

@test "onedrive setup refuses a folder with a line break or a relative path" {
  run "$OH" onedrive setup --dir "$HOME/a
ExecStartPre=/bin/touch $HOME/pwned" </dev/null
  [ "$status" -eq 1 ]
  [ ! -e "$UNIT" ]
  run "$OH" onedrive setup --dir OneDrive </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"absolute path"* ]]
  [ ! -e "$UNIT" ]
  run grep -q '^onedrive_dir=' "$XDG_CONFIG_HOME/omarchohard/config"
  [ "$status" -ne 0 ]
}

@test "onedrive setup over a configured client: same settings restart it, a new client or folder is refused" {
  "$OH" onedrive setup </dev/null >/dev/null 2>&1
  : >"$HOME/systemctl.log"
  run "$OH" onedrive setup </dev/null
  [ "$status" -eq 0 ]
  grep -qx -- '--user restart omarchohard-onedrive.service' "$HOME/systemctl.log"
  run "$OH" onedrive setup --client abraunegg </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"run omarchohard onedrive remove first"* ]]
  run "$OH" onedrive setup --dir "$HOME/Elsewhere" </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"run omarchohard onedrive remove first"* ]]
  grep -qxF "onedrive_dir=$HOME/OneDrive" "$XDG_CONFIG_HOME/omarchohard/config"
}

sync_socket() {
  command -v python3 >/dev/null || skip "python3 is needed to open a unix socket"
  printf 'onedrive_client=rclone\nonedrive_dir=%s/OneDrive\n' "$HOME" >>"$XDG_CONFIG_HOME/omarchohard/config"
  mkdir -p "$HOME/OneDrive"
  export XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run
  mkdir -p "$XDG_RUNTIME_DIR"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$XDG_RUNTIME_DIR/omarchohard-rclone.sock"
  stub sleep 'exit 0'
}

@test "onedrive sync fails when uploads are still queued after the wait" {
  sync_socket
  # shellcheck disable=SC2016
  stub rclone 'case "$*" in *vfs/stats*) echo "{\"diskCache\":{\"uploadsInProgress\":1,\"uploadsQueued\":2}}" ;; *) echo "{}" ;; esac'
  run "$OH" onedrive sync
  [ "$status" -eq 1 ]
  [[ $output == *"still uploading 3 files"* ]]
  [[ $output != *"in sync"* ]]
}

@test "onedrive sync fails when the mount stops answering" {
  sync_socket
  # shellcheck disable=SC2016
  stub rclone 'case "$*" in *vfs/stats*) exit 1 ;; *) echo "{}" ;; esac'
  run "$OH" onedrive sync
  [ "$status" -eq 1 ]
  [[ $output == *"stopped answering"* ]]
  [[ $output != *"in sync"* ]]
}
