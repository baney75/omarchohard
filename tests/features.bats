#!/usr/bin/env bats
# App selection, guided setup, agent probes, sharing and sync, in a sandboxed HOME.

load test_helper

setup() { oh_sandbox; }

onedrive_rclone() {
  mkdir -p "$HOME/OneDrive/Docs"
  printf 'onedrive_client=rclone\nonedrive_dir=%s/OneDrive\nonedrive_web_root=https://contoso-my.sharepoint.com/personal/me/Documents\n' "$HOME" \
    >>"$XDG_CONFIG_HOME/omarchohard/config"
}

@test "install --apps puts only the chosen apps in place, plus Microsoft 365 home" {
  run "$OH" install --apps teams,word
  [ "$status" -eq 0 ]
  [ -f "$APPS/omarchohard-teams.desktop" ]
  [ -f "$APPS/omarchohard-word.desktop" ]
  [ -f "$APPS/omarchohard-m365.desktop" ]
  [ ! -e "$APPS/omarchohard-excel.desktop" ]
  [ ! -e "$APPS/omarchohard-outlook.desktop" ]
  [ "$(mime_default x-scheme-handler/msteams)" = omarchohard-teams.desktop ]
  [ "$(mime_default application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)" != omarchohard-excel.desktop ]
  grep -qx 'apps=word,teams' "$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" doctor
  [ "$status" -eq 0 ]
}

@test "install --apps rejects an unknown app" {
  run "$OH" install --apps word,clippy
  [ "$status" -ne 0 ]
  [[ $output == *"unknown app 'clippy'"* ]]
}

@test "remove hands an app's file types back, and add brings it back" {
  dummy_app oldteams
  xdg-mime default oldteams.desktop x-scheme-handler/msteams
  oh_install_quiet
  [ "$(mime_default x-scheme-handler/msteams)" = omarchohard-teams.desktop ]

  run "$OH" remove teams
  [ "$status" -eq 0 ]
  [ ! -e "$APPS/omarchohard-teams.desktop" ]
  [ ! -e "$XDG_DATA_HOME/icons/hicolor/scalable/apps/omarchohard-teams.svg" ]
  [ "$(mime_default x-scheme-handler/msteams)" = oldteams.desktop ]
  [ "$(mime_default x-scheme-handler/mailto)" = omarchohard-outlook.desktop ]
  run "$OH" doctor
  [ "$status" -eq 0 ]

  run "$OH" add Teams
  [ "$status" -eq 0 ]
  [ -f "$APPS/omarchohard-teams.desktop" ]
  [ "$(mime_default x-scheme-handler/msteams)" = omarchohard-teams.desktop ]
  grep -qx 'apps=all' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "remove keeps Microsoft 365 home" {
  oh_install_quiet
  run "$OH" remove m365
  [ "$status" -ne 0 ]
  [ -f "$APPS/omarchohard-m365.desktop" ]
}

@test "setup --yes installs everything with no questions" {
  run "$OH" setup --yes --browser chromium --isolated --onedrive none --prewarm off
  [ "$status" -eq 0 ]
  for id in word excel powerpoint outlook onenote teams onedrive m365; do
    [ -f "$APPS/omarchohard-$id.desktop" ]
  done
  [ -f "$APPS/omarchohard-setup.desktop" ]
  grep -qx 'profile=isolated' "$XDG_CONFIG_HOME/omarchohard/config"
  [ ! -s "$HOME/chromium.log" ]
  run "$OH" doctor
  [ "$status" -eq 0 ]
}

@test "setup --yes --apps installs just Teams" {
  run "$OH" setup --yes --browser chromium --apps teams --onedrive none
  [ "$status" -eq 0 ]
  [ -f "$APPS/omarchohard-teams.desktop" ]
  [ ! -e "$APPS/omarchohard-word.desktop" ]
}

@test "setup reads plain answers when gum is missing" {
  export OMARCHOHARD_NO_GUM=1
  answers=$BATS_TEST_TMPDIR/answers
  # web apps, browser 1, own profile, no email, apps 3 and 6 (PowerPoint, Teams), mailto yes, no sign-in, OneDrive not now, no prewarm, no Word
  printf '1\n1\n2\n\n3 6\ny\nn\n3\nn\nn\n' >"$answers"
  OMARCHOHARD_TTY=$answers run "$OH" setup
  [ "$status" -eq 0 ]
  [ -f "$APPS/omarchohard-powerpoint.desktop" ]
  [ -f "$APPS/omarchohard-teams.desktop" ]
  [ ! -e "$APPS/omarchohard-word.desktop" ]
  grep -qx 'profile=isolated' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "probe --json is valid JSON with recommendations and what needs a person" {
  run "$OH" probe --json
  [ "$status" -eq 0 ]
  jq -e '.recommend.profile.value and .recommend.onedrive_cache_size.value and .device.threads > 0' <<<"$output"
  jq -e '.config.apps == "all"' <<<"$output"
  [ "$(jq '.needs_person | length' <<<"$output")" -eq 2 ]
}

@test "optimize prints a plan and changes nothing without --apply" {
  before=$(cat "$XDG_CONFIG_HOME/omarchohard/config")
  run "$OH" optimize
  [ "$status" -eq 0 ]
  [[ $output == *onedrive_cache_size* ]]
  [ "$(cat "$XDG_CONFIG_HOME/omarchohard/config")" = "$before" ]
  run "$OH" optimize --apply
  [ "$status" -eq 0 ]
  grep -Eq '^onedrive_cache_size=[0-9]+G$' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "addins explains Office Add-ins and opens the app" {
  OMARCHOHARD_DRY_RUN=1 run "$OH" addins excel
  [ "$status" -eq 0 ]
  [[ $output == *"Add-ins"* ]]
  [[ $output == *"excel.cloud.microsoft"* ]]
}

@test "share --link asks OneDrive for a link anyone can view on a personal account" {
  onedrive_rclone
  printf 'x' >"$HOME/OneDrive/Docs/Plan.pdf"
  OMARCHOHARD_DRY_RUN=1 run "$OH" share --link "$HOME/OneDrive/Docs/Plan.pdf"
  [ "$status" -eq 0 ]
  [[ $output == *"rclone link omarchohard-onedrive:Docs/Plan.pdf --onedrive-link-scope anonymous --onedrive-link-type view"* ]]
}

@test "share --link --edit on a school account limits the link to the organization" {
  onedrive_rclone
  printf 'email=me@school.edu\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  printf 'x' >"$HOME/OneDrive/Docs/Notes.docx"
  OMARCHOHARD_DRY_RUN=1 run "$OH" share --link --edit "$HOME/OneDrive/Docs/Notes.docx"
  [ "$status" -eq 0 ]
  [[ $output == *"--onedrive-link-scope organization --onedrive-link-type edit"* ]]
}

@test "share copies a file from outside OneDrive in first" {
  onedrive_rclone
  mkdir -p "$HOME/Downloads"
  printf 'x' >"$HOME/Downloads/Budget.xlsx"
  OMARCHOHARD_DRY_RUN=1 run "$OH" share --link "$HOME/Downloads/Budget.xlsx"
  [ "$status" -eq 0 ]
  [[ $output == *"would copy: $HOME/Downloads/Budget.xlsx -> $HOME/OneDrive/Omarchohard/Budget.xlsx"* ]]
  [[ $output == *"omarchohard-onedrive:Omarchohard/Budget.xlsx"* ]]
}

@test "share without --link opens an Office file in its app to share by name" {
  onedrive_rclone
  printf 'x' >"$HOME/OneDrive/Docs/Talk.pptx"
  run "$OH" share "$HOME/OneDrive/Docs/Talk.pptx"
  [ "$status" -eq 0 ]
  grep -q 'Docs/Talk.pptx?web=1' "$HOME/chromium.log"
}

@test "share needs OneDrive set up" {
  printf 'x' >"$HOME/a.docx"
  run "$OH" share "$HOME/a.docx"
  [ "$status" -ne 0 ]
  [[ $output == *"onedrive setup"* ]]
}

@test "install adds Files right-click scripts when Nautilus is present, and uninstall removes them" {
  stub nautilus 'exit 0'
  oh_install_quiet
  scripts=$XDG_DATA_HOME/nautilus/scripts
  [ -x "$scripts/Share with OneDrive" ]
  [ -x "$scripts/Copy OneDrive link" ]
  [ -x "$scripts/Open in Microsoft 365" ]
  grep -q 'share --link "\$@"' "$scripts/Copy OneDrive link"
  oh_install_quiet
  [ "$(sort "$XDG_STATE_HOME/omarchohard/manifest" | uniq -d)" = "" ]
  "$OH" uninstall >/dev/null
  [ ! -e "$scripts/Share with OneDrive" ]
}

@test "onedrive sync refreshes the mount and waits for uploads" {
  command -v python3 >/dev/null || skip "python3 is needed to open a unix socket"
  onedrive_rclone
  export XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run
  mkdir -p "$XDG_RUNTIME_DIR"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$XDG_RUNTIME_DIR/omarchohard-rclone.sock"
  # shellcheck disable=SC2016
  stub rclone 'printf "%s\n" "$*" >>"$HOME/rclone.log"; case "$*" in *vfs/stats*) echo "{\"diskCache\":{\"uploadsInProgress\":0,\"uploadsQueued\":0}}" ;; *) echo "{}" ;; esac'
  run "$OH" onedrive sync
  [ "$status" -eq 0 ]
  [[ $output == *"in sync"* ]]
  grep -q 'vfs/refresh recursive=true' "$HOME/rclone.log"
}

@test "launchers use the installer's link even when ~/.local/bin is not on PATH" {
  mkdir -p "$HOME/.local/bin"
  ln -s "$OH" "$HOME/.local/bin/omarchohard"
  PATH=${PATH//$HOME\/.local\/bin:/} run "$OH" install
  [ "$status" -eq 0 ]
  grep -qx "Exec=$HOME/.local/bin/omarchohard open --app word %U" "$APPS/omarchohard-word.desktop"
}

# rclone link that works for one scope only.
link_only_for() {
  # shellcheck disable=SC2016
  stub rclone "printf '%s\n' \"\$*\" >>\"\$HOME/rclone.log\"
case \"\$*\" in link*'--onedrive-link-scope $1 '*) echo https://contoso-my.sharepoint.com/:w:/g/x ;; link*) exit 1 ;; esac"
}

@test "share --link never widens an organization link to anyone when it fails" {
  onedrive_rclone
  printf 'x' >"$HOME/OneDrive/Docs/Plan.docx"
  link_only_for anonymous
  run "$OH" share --link --org "$HOME/OneDrive/Docs/Plan.docx"
  [ "$status" -ne 0 ]
  [[ $output != *"https://"* ]]
  [[ $output == *"--anyone"* ]]
  run grep -q 'link-scope anonymous' "$HOME/rclone.log"
  [ "$status" -ne 0 ]
}

@test "share --link --anyone narrows to an organization link when anyone links are off" {
  onedrive_rclone
  printf 'x' >"$HOME/OneDrive/Docs/Plan.docx"
  link_only_for organization
  run "$OH" share --link --anyone "$HOME/OneDrive/Docs/Plan.docx"
  [ "$status" -eq 0 ]
  [[ $output == *"people in your organization"* ]]
  grep -q 'link-scope anonymous' "$HOME/rclone.log"
}

@test "import stops instead of looping when the copy cannot be moved into OneDrive" {
  onedrive_rclone
  stub rclone 'exit 0'
  stub mv 'exit 1'
  printf 'one\n' >"$HOME/Report.docx"
  run timeout 10 "$OH" share "$HOME/Report.docx"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ]
  [[ $output == *"could not copy"* ]]
  run find "$HOME/OneDrive" -name '.*'
  [ -z "$output" ]
}

# The patterns office.ps1 matches the signer with, run through grep -E
# (the same syntax for these patterns as .NET).
signer_ok() {
  local subject=$1 issuer=$2 pats
  mapfile -t pats < <(grep -o "notmatch '[^']*'" "$BATS_TEST_DIRNAME/../share/omarchohard/vm/office.ps1" | sed "s/^notmatch '//; s/'\$//")
  [ "${#pats[@]}" -eq 3 ]
  printf '%s\n' "$subject" | grep -qE -- "${pats[0]}" &&
    printf '%s\n' "$issuer" | grep -qE -- "${pats[1]}" &&
    printf '%s\n' "$issuer" | grep -qE -- "${pats[2]}"
}

@test "the VM runs setup.exe only when Microsoft signed it" {
  ms='O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
  signer_ok "CN=Microsoft Corporation, $ms" "CN=Microsoft Code Signing PCA 2011, $ms"
  ! signer_ok "CN=Evil, O=Microsoft Corporation Evil Ltd, C=US" "CN=Microsoft Code Signing PCA 2011, $ms" || false
  ! signer_ok "CN=Evil, OU=O=Microsoft Corporation, O=Evil" "CN=Microsoft Code Signing PCA 2011, $ms" || false
  ! signer_ok "CN=Microsoft Corporation, $ms" "CN=Some CA, O=Microsoft Corporation, C=US" || false
  ! signer_ok "CN=Microsoft Corporation, $ms" "CN=Microsoft Code Signing PCA 2011, O=Evil" || false
}

@test "share --link falls back to an organization link when anyone links are off" {
  onedrive_rclone
  printf 'x' >"$HOME/OneDrive/Docs/Plan.docx"
  link_only_for organization
  run "$OH" share --link "$HOME/OneDrive/Docs/Plan.docx"
  [ "$status" -eq 0 ]
  [[ $output == *"people in your organization"* ]]
}

@test "setup --yes without --shared or --isolated keeps the isolated profile" {
  printf 'profile=isolated\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" setup --yes --browser chromium --onedrive none --prewarm off
  [ "$status" -eq 0 ]
  grep -qx 'profile=isolated' "$XDG_CONFIG_HOME/omarchohard/config"
  grep -qx 'StartupWMClass=chrome-word.cloud.microsoft__-Omarchohard' "$APPS/omarchohard-word.desktop"
}

@test "setup keeps going and runs the final check when the OneDrive sign-in fails" {
  # shellcheck disable=SC2016
  stub rclone 'case "$1" in config) exit 1 ;; esac; exit 0'
  run "$OH" setup --yes --browser chromium --onedrive rclone
  [ "$status" -eq 0 ]
  [[ $output == *"rclone sign-in did not finish"* ]]
  [[ $output == *"OneDrive is not set up yet"* ]]
  [[ $output == *"Checking everything"* ]]
}

@test "optimize --apply restarts the OneDrive mount only when the cache size changes" {
  cache=$("$OH" probe --json | jq -r .recommend.onedrive_cache_size.value)
  want=$("$OH" probe --json | jq -r .recommend.prewarm.value)
  printf 'profile=isolated\nonedrive_client=rclone\nonedrive_cache_size=%s\n' "$cache" >>"$XDG_CONFIG_HOME/omarchohard/config"
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  : >"$XDG_CONFIG_HOME/systemd/user/omarchohard-onedrive.service"
  # Make prewarm differ from the recommendation, so optimize changes something.
  if [ "$want" = off ]; then
    # shellcheck disable=SC2016
    stub systemctl 'printf "%s\n" "$*" >>"$HOME/systemctl.log"; exit 0'
  fi
  run "$OH" optimize --apply
  [ "$status" -eq 0 ]
  [[ $output == *"prewarm"* ]]
  run grep -q 'restart omarchohard-onedrive' "$HOME/systemctl.log"
  [ "$status" -ne 0 ]
}

@test "two imports of different files with the same name keep both" {
  onedrive_rclone
  stub rclone 'exit 0'
  mkdir -p "$HOME/a" "$HOME/b"
  printf 'one\n' >"$HOME/a/Report.docx"
  printf 'two\n' >"$HOME/b/Report.docx"
  "$OH" open "$HOME/a/Report.docx" >/dev/null 2>&1 &
  "$OH" open "$HOME/b/Report.docx" >/dev/null 2>&1 &
  wait
  dir=$HOME/OneDrive/Omarchohard
  [ "$(cat "$dir/Report.docx" "$dir/Report (1).docx" | sort | tr '\n' ' ')" = "one two " ]
  [ -z "$(find "$dir" -name '.omarchohard-import.*')" ]
}

@test "setup --prewarm off finishes when no user manager is running" {
  stub systemctl 'echo "Failed to connect to user scope bus" >&2; exit 1'
  run "$OH" setup --yes --browser chromium --isolated --onedrive none --prewarm off
  [ "$status" -eq 0 ]
  [[ $output == *"Checking everything"* ]]
}

@test "setup --yes without --tier keeps the web apps and never touches a VM" {
  # shellcheck disable=SC2016
  stub docker 'printf "%s\n" "$*" >>"$HOME/docker.log"'
  run "$OH" setup --yes --browser chromium --onedrive none --prewarm off
  [ "$status" -eq 0 ]
  [[ $output == *"Office: the web apps"* ]]
  [ ! -e "$HOME/docker.log" ]
  [ ! -e "$XDG_DATA_HOME/omarchohard/vm" ]
}

@test "setup --tier desktop runs the desktop install last and still sets up the web apps" {
  run "$OH" setup --yes --tier desktop --browser chromium --onedrive none --prewarm off
  # This test machine has no KVM or FreeRDP, so the desktop install stops.
  [ "$status" -eq 1 ]
  [[ $output == *"Office: desktop Office"*"6 of 6  OneDrive"*"Checking this machine for the desktop tier"*"this machine is not ready for a Windows VM"*"desktop Office did not finish; the web apps work meanwhile"* ]]
  [ -f "$APPS/omarchohard-teams.desktop" ]
  [ -f "$APPS/omarchohard-word.desktop" ]
  run "$OH" setup --yes --tier windows
  [ "$status" -eq 1 ]
  [[ $output == *"--tier takes desktop or web"* ]]
}

@test "interactive setup explains both tiers and recommends the web apps with the reason" {
  answers=$BATS_TEST_TMPDIR/answers
  printf '1\n1\n2\n\n\ny\nn\n3\nn\nn\n' >"$answers"
  OMARCHOHARD_NO_GUM=1 OMARCHOHARD_TTY=$answers run "$OH" setup
  [ "$status" -eq 0 ]
  [[ $output == *"Desktop Office is not recommended here: "*"FreeRDP 3 is missing"* ]]
  [[ $output == *"1) Web apps: open instantly and stay light (recommended)"* ]]
  [[ $output == *"2) Desktop Office: the real Windows apps (add-ins, macros, offline, Office's own updates); one-time install of about 45 minutes; needs KVM, 16 GB of memory and about 80 GB of disk"* ]]
  # Choosing desktop anyway runs its install at the end.
  printf '2\n1\n2\n\n\ny\nn\n3\nn\nn\n' >"$answers"
  OMARCHOHARD_NO_GUM=1 OMARCHOHARD_TTY=$answers run "$OH" setup
  [ "$status" -eq 1 ]
  [[ $output == *"Checking this machine for the desktop tier"* ]]
}

@test "probe --json recommends a tier and reports open_with and the desktop install" {
  run "$OH" probe --json
  [ "$status" -eq 0 ]
  jq -e '.recommend.tier.value == "web" and (.recommend.tier.why | test("FreeRDP 3"))' <<<"$output"
  jq -e '.config.open_with == "web" and .desktop_installed == false' <<<"$output"
}
