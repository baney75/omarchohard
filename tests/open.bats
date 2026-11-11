#!/usr/bin/env bats
# Routing of files, web links and URL schemes. Dry run: commands are printed,
# nothing is launched.

load test_helper

WEB_ROOT=https://contoso-my.sharepoint.com/personal/me_contoso_com/Documents

setup() {
  oh_sandbox
  export OMARCHOHARD_DRY_RUN=1
}

with_onedrive() {
  mkdir -p "$HOME/OneDrive"
  cat >>"$XDG_CONFIG_HOME/omarchohard/config" <<CONF
onedrive_client=rclone
onedrive_dir=$HOME/OneDrive
onedrive_web_root=$WEB_ROOT
CONF
}

# The --app=URL argument of the last browser command in $output, unquoted.
app_url() {
  grep -o -- '--app=[^ ]*' <<<"$output" | tail -n1 | sed 's/^--app=//; s/\\//g'
}

@test "xdg-open routes .docx, .xlsx and .pptx to Word, Excel and PowerPoint" {
  oh_install_quiet
  run xdg-open "$FIXTURES/test.docx"
  [ "$status" -eq 0 ]
  [ "$(app_url)" = https://word.cloud.microsoft/ ]
  run xdg-open "$FIXTURES/test.xlsx"
  [ "$status" -eq 0 ]
  [ "$(app_url)" = https://excel.cloud.microsoft/ ]
  run xdg-open "$FIXTURES/test.pptx"
  [ "$status" -eq 0 ]
  [ "$(app_url)" = https://powerpoint.cloud.microsoft/ ]
}

@test "xdg-open of a fixture inside OneDrive opens it in place" {
  oh_install_quiet
  with_onedrive
  cp "$FIXTURES/test.xlsx" "$HOME/OneDrive/Budget.xlsx"
  run xdg-open "$HOME/OneDrive/Budget.xlsx"
  [ "$status" -eq 0 ]
  [ "$(app_url)" = "$WEB_ROOT/Budget.xlsx?web=1" ]
}

@test "mailto maps to an Outlook compose link" {
  oh_install_quiet
  run xdg-open 'mailto:ada@example.com?subject=Hi%20there&body=See%20you'
  [ "$status" -eq 0 ]
  [ "$(app_url)" = 'https://outlook.office.com/mail/deeplink/compose?to=ada@example.com&subject=Hi%20there&body=See%20you' ]
  run "$OH" open 'mailto:bob@example.com'
  [ "$(app_url)" = 'https://outlook.office.com/mail/deeplink/compose?to=bob@example.com' ]
}

@test "msteams links map to teams.microsoft.com" {
  oh_install_quiet
  run xdg-open 'msteams:/l/meetup-join/19%3ameeting_abc%40thread.v2/0'
  [ "$status" -eq 0 ]
  [ "$(app_url)" = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0' ]
  run "$OH" open 'msteams://teams.microsoft.com/l/chat/0/0?users=ada@example.com'
  [ "$(app_url)" = 'https://teams.microsoft.com/l/chat/0/0?users=ada@example.com' ]
}

@test "ms-word, ms-excel and ms-powerpoint ofe links open the document's web address" {
  oh_install_quiet
  run xdg-open 'ms-word:ofe|u|https://contoso.sharepoint.com/sites/team/Shared%20Documents/Plan.docx'
  [ "$status" -eq 0 ]
  [ "$(app_url)" = 'https://contoso.sharepoint.com/sites/team/Shared%20Documents/Plan.docx' ]
  run "$OH" open 'ms-excel:ofv|u|https://contoso.sharepoint.com/b.xlsx'
  [ "$(app_url)" = 'https://contoso.sharepoint.com/b.xlsx' ]
  run "$OH" open 'ms-powerpoint:ofe|u|https://contoso.sharepoint.com/c.pptx'
  [ "$(app_url)" = 'https://contoso.sharepoint.com/c.pptx' ]
}

@test "an Office link that is not https is refused" {
  run "$OH" open 'ms-word:ofe|u|file:///etc/passwd'
  [ "$status" -eq 1 ]
  [[ $output == *"unsupported Office link"* ]]
}

@test "OneDrive in-place address encodes space, # and e-acute" {
  with_onedrive
  mkdir -p "$HOME/OneDrive/My Docs #1"
  cp "$FIXTURES/test.docx" "$HOME/OneDrive/My Docs #1/résumé.docx"
  run "$OH" open "$HOME/OneDrive/My Docs #1/résumé.docx"
  [ "$status" -eq 0 ]
  [ "$(app_url)" = "$WEB_ROOT/My%20Docs%20%231/r%C3%A9sum%C3%A9.docx?web=1" ]
}

@test "a file outside OneDrive is copied into OneDrive/Omarchohard (dry run)" {
  with_onedrive
  mkdir -p "$HOME/Downloads"
  cp "$FIXTURES/test.pptx" "$HOME/Downloads/Talk Notes.pptx"
  run "$OH" open "$HOME/Downloads/Talk Notes.pptx"
  [ "$status" -eq 0 ]
  [[ $output == *"would copy: $HOME/Downloads/Talk Notes.pptx -> $HOME/OneDrive/Omarchohard/Talk Notes.pptx"* ]]
  [ "$(app_url)" = "$WEB_ROOT/Omarchohard/Talk%20Notes.pptx?web=1" ]
  # Dry run copies nothing.
  [ ! -e "$HOME/OneDrive/Omarchohard" ]
}

@test "a real outside-file copy leaves the original untouched and avoids clobbering" {
  unset OMARCHOHARD_DRY_RUN
  with_onedrive
  stub rclone 'exit 0'
  mkdir -p "$HOME/Downloads" "$HOME/OneDrive/Omarchohard"
  cp "$FIXTURES/test.docx" "$HOME/Downloads/Report.docx"
  printf 'different\n' >"$HOME/OneDrive/Omarchohard/Report.docx"
  before=$(sha256sum <"$HOME/Downloads/Report.docx")
  run "$OH" open "$HOME/Downloads/Report.docx"
  [ "$status" -eq 0 ]
  [ "$(sha256sum <"$HOME/Downloads/Report.docx")" = "$before" ]
  cmp "$HOME/Downloads/Report.docx" "$HOME/OneDrive/Omarchohard/Report (1).docx"
  [ "$(cat "$HOME/OneDrive/Omarchohard/Report.docx")" = different ]
  # The stub browser was started with the copy's address.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$HOME/chromium.log" ] && break
    sleep 0.2
  done
  grep -qF -- "--app=$WEB_ROOT/Omarchohard/Report%20%281%29.docx?web=1" "$HOME/chromium.log"
}

@test "without OneDrive set up, a local file opens the app and says how to fix it" {
  run "$OH" open "$FIXTURES/test.docx"
  [ "$status" -eq 0 ]
  [[ $output == *"omarchohard onedrive setup"* ]]
  [ "$(app_url)" = https://word.cloud.microsoft/ ]
}

@test "file:// URIs are decoded before routing" {
  with_onedrive
  mkdir -p "$HOME/OneDrive/A B"
  cp "$FIXTURES/test.xlsx" "$HOME/OneDrive/A B/x.xlsx"
  run "$OH" open "file://$HOME/OneDrive/A%20B/x.xlsx"
  [ "$status" -eq 0 ]
  [ "$(app_url)" = "$WEB_ROOT/A%20B/x.xlsx?web=1" ]
}

@test "launch uses the test-only browser flags hook" {
  OMARCHOHARD_BROWSER_FLAGS='--no-sandbox --ozone-platform=wayland' run "$OH" launch teams
  [ "$status" -eq 0 ]
  [[ $output == *"--no-sandbox --ozone-platform=wayland --no-first-run"*"--app=https://teams.cloud.microsoft/"* ]]
}

@test "launch of an unknown app fails with the app list" {
  run "$OH" launch notepad
  [ "$status" -eq 1 ]
  [[ $output == *"unknown app 'notepad'"*word* ]]
}
