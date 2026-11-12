#!/usr/bin/env bats
# install, doctor and uninstall in a sandboxed HOME.

load test_helper

setup() { oh_sandbox; }

snapshot() {
  (cd "$HOME" && find .local .config -type f ! -name '.config.*' -print0 | sort -z | xargs -0 sha256sum)
}

@test "install puts every launcher and icon in place" {
  run "$OH" install
  [ "$status" -eq 0 ]
  for id in word excel powerpoint outlook onenote teams onedrive m365; do
    [ -f "$APPS/omarchohard-$id.desktop" ]
    [ -f "$XDG_DATA_HOME/icons/hicolor/scalable/apps/omarchohard-$id.svg" ]
  done
  [ "$(mime_default application/vnd.openxmlformats-officedocument.wordprocessingml.document)" = omarchohard-word.desktop ]
  [ "$(mime_default x-scheme-handler/msteams)" = omarchohard-teams.desktop ]
  [ "$(mime_default x-scheme-handler/mailto)" = omarchohard-outlook.desktop ]
  # Setup carries omarchohard's own icon, not Microsoft 365's.
  cmp "$XDG_DATA_HOME/icons/hicolor/scalable/apps/omarchohard.svg" "$OH_REPO_ROOT/share/omarchohard/icons/omarchohard.svg"
  grep -qx 'Icon=omarchohard' "$APPS/omarchohard-setup.desktop"
}

@test "install twice is idempotent" {
  oh_install_quiet
  first=$(snapshot)
  oh_install_quiet
  second=$(snapshot)
  [ "$first" = "$second" ]
  # No duplicate manifest or backup lines.
  [ "$(sort "$XDG_STATE_HOME/omarchohard/manifest" | uniq -d)" = "" ]
  [ "$(cut -f1 "$XDG_STATE_HOME/omarchohard/mime-backup.tsv" | sort | uniq -d)" = "" ]
}

@test "doctor exits 0 after install" {
  oh_install_quiet
  run "$OH" doctor
  [ "$status" -eq 0 ]
  [[ $output == *"all required checks passed"* ]]
}

@test "doctor --json reports zero failures after install" {
  oh_install_quiet
  run "$OH" doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .fails <<<"$output")" = 0 ]
}

@test "the first doctor after a package update claims the types the update added" {
  oh_install_quiet
  stamp=$XDG_STATE_HOME/omarchohard/installed
  [ "$(cat "$stamp")" = "$("$OH" version | cut -d' ' -f2)" ]
  mime=application/vnd.ms-powerpoint.slideshow.macroEnabled.12
  # An install by an older version: the type it did not know yet is not ours.
  for old in 0.0.1 none; do
    if [ $old = none ]; then rm "$stamp"; else echo $old >"$stamp"; fi
    xdg-mime default org.example.viewer.desktop $mime
    run "$OH" doctor
    [ "$status" -eq 0 ]
    [ "$(mime_default $mime)" = omarchohard-powerpoint.desktop ]
    [ "$(cat "$stamp")" = "$("$OH" version | cut -d' ' -f2)" ]
  done
}

@test "doctor installs nothing for a user who never ran install" {
  run "$OH" doctor
  [ "$status" -eq 1 ]
  [ ! -e "$APPS/omarchohard-word.desktop" ]
  [ ! -e "$XDG_STATE_HOME/omarchohard/installed" ]
}

@test "doctor exits 1 when a desktop entry is removed" {
  oh_install_quiet
  rm "$APPS/omarchohard-excel.desktop"
  run "$OH" doctor
  [ "$status" -eq 1 ]
  [[ $output == *"Excel launcher"* ]]
}

@test "doctor exits 1 when an icon is removed" {
  oh_install_quiet
  rm "$XDG_DATA_HOME/icons/hicolor/scalable/apps/omarchohard-onenote.svg"
  run "$OH" doctor
  [ "$status" -eq 1 ]
  [[ $output == *"OneNote icon"* ]]
}

@test "doctor exits 1 when a handler is reassigned" {
  oh_install_quiet
  dummy_app foo
  xdg-mime default foo.desktop x-scheme-handler/msteams
  [ "$(mime_default x-scheme-handler/msteams)" = foo.desktop ]
  run "$OH" doctor
  [ "$status" -eq 1 ]
  [[ $output == *"Teams handler"*"foo.desktop"* ]]
}

@test "doctor exits 1 when Exec points at a non-executable path" {
  oh_install_quiet
  sed -i 's|^Exec=[^ ]*|Exec=/nonexistent/omarchohard|' "$APPS/omarchohard-powerpoint.desktop"
  run "$OH" doctor
  [ "$status" -eq 1 ]
  [[ $output == *"not executable"* ]]
}

@test "--no-mail leaves mailto alone and doctor still passes" {
  dummy_app thunderbird
  xdg-mime default thunderbird.desktop x-scheme-handler/mailto
  run "$OH" install --no-mail
  [ "$status" -eq 0 ]
  [ "$(mime_default x-scheme-handler/mailto)" = thunderbird.desktop ]
  run "$OH" doctor
  [ "$status" -eq 0 ]
  # A plain reinstall keeps the choice.
  oh_install_quiet
  [ "$(mime_default x-scheme-handler/mailto)" = thunderbird.desktop ]
}

@test "uninstall restores mimeapps.list and removes every launcher and icon" {
  dummy_app thunderbird
  dummy_app libreoffice-writer
  cat >"$MIMEAPPS" <<'LIST'
[Default Applications]
x-scheme-handler/mailto=thunderbird.desktop
application/vnd.openxmlformats-officedocument.wordprocessingml.document=libreoffice-writer.desktop
text/plain=nvim.desktop

[Added Associations]
text/plain=nvim.desktop;
LIST
  before=$(mimeapps_norm "$MIMEAPPS")
  oh_install_quiet
  [ "$(mime_default x-scheme-handler/mailto)" = omarchohard-outlook.desktop ]
  run "$OH" uninstall
  [ "$status" -eq 0 ]
  after=$(mimeapps_norm "$MIMEAPPS")
  diff <(echo "$before") <(echo "$after")
  [ "$(grep -c omarchohard "$MIMEAPPS")" = 0 ]
  [ -z "$(find "$XDG_DATA_HOME" -name 'omarchohard-*' -print -quit)" ]
  # Config is kept without --purge.
  [ -f "$XDG_CONFIG_HOME/omarchohard/config" ]
}

@test "uninstall --purge removes config and state" {
  oh_install_quiet
  [ -d "$XDG_STATE_HOME/omarchohard" ]
  run "$OH" uninstall --purge
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/omarchohard" ]
  [ ! -e "$XDG_STATE_HOME/omarchohard" ]
  [ -z "$(find "$XDG_DATA_HOME" -name 'omarchohard-*' -print -quit)" ]
}

@test "install --isolated uses the dedicated profile window class" {
  run "$OH" install --isolated
  [ "$status" -eq 0 ]
  grep -qx 'StartupWMClass=chrome-word.cloud.microsoft__-Omarchohard' "$APPS/omarchohard-word.desktop"
  grep -qx 'profile=isolated' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "default profile window classes match Chromium's naming" {
  oh_install_quiet
  grep -qx 'StartupWMClass=chrome-word.cloud.microsoft__-Default' "$APPS/omarchohard-word.desktop"
  grep -qx 'StartupWMClass=chrome-outlook.cloud.microsoft__mail_-Default' "$APPS/omarchohard-outlook.desktop"
}

@test "every desktop entry passes desktop-file-validate" {
  command -v desktop-file-validate >/dev/null || skip "desktop-file-validate not installed"
  oh_install_quiet
  for f in "$APPS"/omarchohard-*.desktop; do
    run desktop-file-validate "$f"
    [ "$status" -eq 0 ] || {
      echo "$f: $output"
      false
    }
  done
}

UNIT_REL=.config/systemd/user/omarchohard-onedrive.service

# onedrive setup with a stub rclone whose sign-in creates the remote, and a
# systemctl that logs whether the OneDrive unit file exists at each call.
onedrive_stubbed() {
  # shellcheck disable=SC2016
  stub rclone 'printf "%s\n" "$*" >>"$HOME/rclone.log"; exit 0'
  # shellcheck disable=SC2016
  stub systemctl 'u=$HOME/.config/systemd/user/omarchohard-onedrive.service
printf "%s unit=%s\n" "$*" "$([ -f "$u" ] && echo yes || echo no)" >>"$HOME/systemctl.log"
case " $* " in *" is-active "*) exit 3 ;; esac'
  "$OH" onedrive setup </dev/null >/dev/null 2>&1
  [ -f "$HOME/$UNIT_REL" ]
  : >"$HOME/systemctl.log"
}

@test "uninstall stops OneDrive before removing its unit, reloads systemd and keeps the sign-in" {
  oh_install_quiet
  onedrive_stubbed
  run "$OH" uninstall
  [ "$status" -eq 0 ]
  grep -qx -- '--user disable --now omarchohard-onedrive.service unit=yes' "$HOME/systemctl.log"
  grep -qx -- '--user daemon-reload unit=no' "$HOME/systemctl.log"
  [ ! -e "$HOME/$UNIT_REL" ]
  run grep -q 'config delete' "$HOME/rclone.log"
  [ "$status" -ne 0 ]
  grep -qx 'onedrive_client=' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "uninstall --purge removes OneDrive while its unit still exists, including the remote it made" {
  oh_install_quiet
  onedrive_stubbed
  run "$OH" uninstall --purge
  [ "$status" -eq 0 ]
  grep -qx -- '--user disable --now omarchohard-onedrive.service unit=yes' "$HOME/systemctl.log"
  grep -qx 'config delete omarchohard-onedrive' "$HOME/rclone.log"
  [ ! -e "$HOME/$UNIT_REL" ]
}

@test "uninstall removes nothing while OneDrive keeps running" {
  oh_install_quiet
  onedrive_stubbed
  # shellcheck disable=SC2016
  stub systemctl 'printf "%s\n" "$*" >>"$HOME/systemctl.log"; exit 0'
  run "$OH" uninstall
  [ "$status" -ne 0 ]
  [[ $output == *"still running"* ]]
  [ -e "$HOME/$UNIT_REL" ]
  [ -e "$XDG_DATA_HOME/applications/omarchohard-word.desktop" ]
  grep -qx 'onedrive_client=rclone' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "uninstall --purge deletes nothing when OneDrive will not stop" {
  oh_install_quiet
  onedrive_stubbed
  # shellcheck disable=SC2016
  stub systemctl 'printf "%s\n" "$*" >>"$HOME/systemctl.log"; case " $* " in *" disable "*) exit 1 ;; esac; exit 0'
  run "$OH" uninstall --purge
  [ "$status" -ne 0 ]
  [[ $output == *"still running"* ]]
  [ -e "$HOME/$UNIT_REL" ]
  run grep -q 'config delete' "$HOME/rclone.log"
  [ "$status" -ne 0 ]
  grep -qx 'onedrive_client=rclone' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "uninstall sees an abraunegg sync still running when the user manager is down" {
  oh_install_quiet
  printf 'onedrive_client=abraunegg\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  mkdir -p "$HOME/.config/systemd/user"
  : >"$HOME/$UNIT_REL"
  stub systemctl 'echo "Failed to connect to bus" >&2; exit 1'
  # shellcheck disable=SC2016
  stub pgrep 'case "$*" in *"-x onedrive"*) exit 0 ;; esac; exit 1'
  run "$OH" uninstall
  [ "$status" -ne 0 ]
  [[ $output == *"still running"* ]]
  [ -e "$HOME/$UNIT_REL" ]
  [ -e "$XDG_DATA_HOME/applications/omarchohard-word.desktop" ]
}

@test "uninstall keeps the abraunegg config on record so a later --purge removes it" {
  oh_install_quiet
  conf=$XDG_CONFIG_HOME/onedrive/config
  mkdir -p "${conf%/*}"
  : >"$conf"
  printf '%s\n' "$conf" >>"$XDG_STATE_HOME/omarchohard/manifest"
  run "$OH" uninstall
  [ "$status" -eq 0 ]
  [ -e "$conf" ]
  grep -qx "$conf" "$XDG_STATE_HOME/omarchohard/manifest"
  run "$OH" uninstall --purge
  [ "$status" -eq 0 ]
  [ ! -e "$conf" ]
}

@test "install --no-mail after install gives mailto back and Outlook stops offering it" {
  dummy_app thunderbird
  xdg-mime default thunderbird.desktop x-scheme-handler/mailto
  oh_install_quiet
  [ "$(mime_default x-scheme-handler/mailto)" = omarchohard-outlook.desktop ]
  grep -q 'x-scheme-handler/mailto' "$APPS/omarchohard-outlook.desktop"
  run "$OH" install --no-mail
  [ "$status" -eq 0 ]
  [ "$(mime_default x-scheme-handler/mailto)" = thunderbird.desktop ]
  run grep -q mailto "$APPS/omarchohard-outlook.desktop"
  [ "$status" -ne 0 ]
  run grep -q 'mailto=.*omarchohard' "$MIMEAPPS"
  [ "$status" -ne 0 ]
  run "$OH" doctor
  [ "$status" -eq 0 ]
}

@test "uninstall keeps a handler the user chose after install" {
  dummy_app libreoffice-writer
  dummy_app onlyoffice
  dummy_app oldteams
  docx=application/vnd.openxmlformats-officedocument.wordprocessingml.document
  xdg-mime default libreoffice-writer.desktop "$docx"
  xdg-mime default oldteams.desktop x-scheme-handler/msteams
  oh_install_quiet
  xdg-mime default onlyoffice.desktop "$docx"
  run "$OH" uninstall
  [ "$status" -eq 0 ]
  [ "$(mime_default "$docx")" = onlyoffice.desktop ]
  [ "$(mime_default x-scheme-handler/msteams)" = oldteams.desktop ]
}

@test "remove then add saves the handler the user picked in between" {
  dummy_app teams-a
  dummy_app teams-b
  xdg-mime default teams-a.desktop x-scheme-handler/msteams
  oh_install_quiet
  "$OH" remove teams >/dev/null 2>&1
  [ "$(mime_default x-scheme-handler/msteams)" = teams-a.desktop ]
  xdg-mime default teams-b.desktop x-scheme-handler/msteams
  "$OH" add teams >/dev/null 2>&1
  [ "$(mime_default x-scheme-handler/msteams)" = omarchohard-teams.desktop ]
  "$OH" remove teams >/dev/null 2>&1
  [ "$(mime_default x-scheme-handler/msteams)" = teams-b.desktop ]
}

@test "a CLI path with a space is quoted in launchers and Files scripts" {
  stub nautilus 'exit 0'
  mkdir -p "$HOME/my bin"
  ln -s "$OH" "$HOME/my bin/omarchohard"
  PATH="$HOME/my bin:$PATH" run "$HOME/my bin/omarchohard" install
  [ "$status" -eq 0 ]
  grep -qxF "Exec=\"$HOME/my bin/omarchohard\" open --app word %U" "$APPS/omarchohard-word.desktop"
  grep -qxF "Exec=\"$HOME/my bin/omarchohard\" setup --gui" "$APPS/omarchohard-setup.desktop"
  grep -qxF "exec $(printf %q "$HOME/my bin/omarchohard") share --link \"\$@\"" "$XDG_DATA_HOME/nautilus/scripts/Copy OneDrive link"
  if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$APPS/omarchohard-word.desktop"
  fi
  PATH="$HOME/my bin:$PATH" run "$HOME/my bin/omarchohard" doctor
  [ "$status" -eq 0 ]
}

@test "uninstall --purge keeps the desktop tier VM and says how to remove it" {
  mkdir -p "$XDG_DATA_HOME/omarchohard/vm"
  : >"$XDG_DATA_HOME/omarchohard/vm/compose.yaml"
  oh_install_quiet
  run "$OH" uninstall --purge
  [ "$status" -eq 0 ]
  [[ $output == *"omarchohard desktop remove --delete-vm"* ]]
  [ -f "$XDG_DATA_HOME/omarchohard/vm/compose.yaml" ]
}

@test "install keeps a Files script of the user's own with the same name" {
  stub nautilus 'exit 0'
  scripts=$XDG_DATA_HOME/nautilus/scripts
  mkdir -p "$scripts"
  printf '#!/bin/sh\necho mine\n' >"$scripts/Copy OneDrive link"
  run "$OH" install
  [ "$status" -eq 0 ]
  [[ $output == *"kept your own Files script 'Copy OneDrive link'"* ]]
  [ "$(cat "$scripts/Copy OneDrive link")" = "$(printf '#!/bin/sh\necho mine')" ]
  [ -x "$scripts/Share with OneDrive" ]
  "$OH" uninstall >/dev/null
  [ -f "$scripts/Copy OneDrive link" ]
  [ ! -e "$scripts/Share with OneDrive" ]
}
