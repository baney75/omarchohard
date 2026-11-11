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
