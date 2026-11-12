#!/usr/bin/env bats
# Desktop tier: product keys and the RDP password never reach a command line.
# No VM runs; a background job stands in for the Windows inbox task.

load test_helper

KEY=ABCDE-FGHIJ-KLMNO-PQRST-UVWXY

setup() {
  oh_sandbox
  INBOX=$XDG_DATA_HOME/omarchohard/vm-inbox
  mkdir -p "$XDG_DATA_HOME/omarchohard/vm"
  printf '%s\n' "${KEY,,}" >"$BATS_TEST_TMPDIR/key"
}

# Answer the first request like the VM would, keeping a copy of it.
fake_vm() {
  local answer=${1:-Office: licensed}
  (
    for _ in $(seq 100); do
      for r in "$INBOX"/*.request; do
        [ -f "$r" ] || continue
        cp "$r" "$BATS_TEST_TMPDIR/seen.json"
        rm -f "$r"
        printf '%s\n' "$answer" >"${r%.request}.result"
        exit 0
      done
      sleep 0.1
    done
  ) 3>&- &
}

@test "desktop activate writes the request without running jq or any process with the key" {
  # shellcheck disable=SC2016
  stub jq 'printf "%s\n" "$*" >>"$HOME/jq.log"; exit 1'
  fake_vm
  run "$OH" desktop activate --key-file "$BATS_TEST_TMPDIR/key"
  wait
  [ "$status" -eq 0 ]
  [[ $output == *"Office: licensed"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = "{\"action\":\"office-key\",\"key\":\"$KEY\"}" ]
  [ ! -e "$HOME/jq.log" ]
  [ -z "$(ls -A "$INBOX")" ]
}

@test "a stopped desktop activate deletes its request" {
  "$OH" desktop activate --key-file "$BATS_TEST_TMPDIR/key" >/dev/null 2>&1 3>&- &
  pid=$!
  for _ in $(seq 50); do
    compgen -G "$INBOX/*.request" >/dev/null && break
    sleep 0.1
  done
  compgen -G "$INBOX/*.request" >/dev/null
  kill -TERM "$pid"
  wait "$pid" || true
  [ -z "$(ls -A "$INBOX")" ]
}

@test "desktop install builds compose.yaml in bash, with the VM password intact and off sed's arguments" {
  real_sed=$(command -v sed)
  stub sed "printf '%s\n' \"\$*\" >>\"\$HOME/sed.log\"; exec $real_sed \"\$@\""
  stub docker 'exit 0'
  stub git 'exit 0'
  # A test value with the characters that broke the old sed substitution.
  # shellcheck disable=SC2016 # a literal $ in the value
  secret='p&ss|w0rd"q$x'
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf '%s="%s"\n' RDP_USER ada RDP_PASS "$secret" >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  compose=$XDG_DATA_HOME/omarchohard/vm/compose.yaml
  # shellcheck disable=SC2016 # compose escapes $ as $$
  grep -qF '"p&ss|w0rd\"q$$x"' "$compose"
  grep -qxF '      USERNAME: "ada"' "$compose"
  grep -qxF '      VERSION: "11e"' "$compose"
  [ "$(stat -c %a "$compose")" = 600 ]
  run grep -qF 'w0rd' "$HOME/sed.log"
  [ "$status" -ne 0 ]
}

@test "the first-boot script runs WinApps' TimeSync task and the inbox task with no window" {
  stub docker 'exit 0'
  stub git 'exit 0'
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  bat=$XDG_DATA_HOME/omarchohard/vm/oem/install.bat
  # The same task name as WinApps' winapps-install.bat, so it replaces it.
  grep -qF 'schtasks /Create /F /TN "TimeSync" /SC ONLOGON /RL HIGHEST ^' "$bat"
  grep -qxF '  /TR "conhost.exe --headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%windir%\TimeSync.ps1\""' "$bat"
  grep -qxF '  /TR "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\OEM\inbox.ps1"' "$bat"
  # It comes after WinApps' own script, which would otherwise create it.
  [ "$(grep -n 'call C:.OEM.winapps-install.bat' "$bat" | cut -d: -f1)" -lt "$(grep -n '/TN "TimeSync"' "$bat" | cut -d: -f1)" ]
  run grep -E '/TR "powershell' "$bat"
  [ "$status" -ne 0 ]
}

@test "the first-boot script signs out of the console after Office, with automatic sign-in off" {
  stub docker 'exit 0'
  stub git 'exit 0'
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  bat=$XDG_DATA_HOME/omarchohard/vm/oem/install.bat
  office=$(grep -n 'office.ps1' "$bat" | tail -1 | cut -d: -f1)
  reg=$(grep -nxF 'reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f' "$bat" | cut -d: -f1)
  [ -n "$reg" ] && [ "$office" -lt "$reg" ]
  # Signing out is the last thing it does.
  [ "$(tail -n 1 "$bat")" = 'shutdown /l /f' ]
}

@test "when WinApps cannot connect, desktop wait says to sign out of Windows once" {
  vm_stub
  rdp_listen
  office_status ready
  wa=$XDG_DATA_HOME/omarchohard/winapps
  mkdir -p "$wa"
  printf '#!/bin/sh\necho "REMOTE DESKTOP PROTOCOL FAILURE"\nexit 14\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
  run "$OH" desktop wait
  [ "$status" -eq 1 ]
  [[ $output == *"sign out of Windows once at http://127.0.0.1:8006 (Start, your name, Sign out)"* ]]
  # Any other failure gets no such advice.
  printf '#!/bin/sh\nexit 5\n' >"$wa/setup.sh"
  run "$OH" desktop wait
  [ "$status" -eq 1 ]
  [[ $output != *"Sign out"* ]]
}

# A filesystem type for stat -f, so the btrfs path runs anywhere.
fs_is() {
  real_stat=$(command -v stat)
  stub stat "case \"\$1\" in -f) echo $1 ;; *) exec $real_stat \"\$@\" ;; esac"
}

install_stubs() {
  stub docker 'exit 0'
  stub git 'exit 0'
  # shellcheck disable=SC2016
  stub chattr 'printf "%s\n" "$*" >>"$HOME/chattr.log"'
}

@test "desktop install keeps the VM disk in a folder, pins dockur, and turns off copy-on-write on btrfs" {
  install_stubs
  fs_is btrfs
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  vm=$XDG_DATA_HOME/omarchohard/vm
  grep -qxF '      - ./storage:/storage' "$vm/compose.yaml"
  grep -qxF '    image: ghcr.io/dockur/windows:6.06' "$vm/compose.yaml"
  run grep -E 'data:|:latest' "$vm/compose.yaml"
  [ "$status" -ne 0 ]
  [ -d "$vm/storage" ]
  [ "$(cat "$HOME/chattr.log")" = "+C $vm/storage" ]
}

@test "desktop install warns when chattr fails, and skips it off btrfs" {
  install_stubs
  stub chattr 'exit 1'
  fs_is btrfs
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  [[ $output == *"could not turn off copy-on-write"* ]]
  install_stubs
  fs_is ext2/ext3
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/chattr.log" ]
}

@test "desktop install keeps the named volume of a VM made before 0.2.0" {
  install_stubs
  fs_is btrfs
  vm=$XDG_DATA_HOME/omarchohard/vm
  printf 'volumes:\n  data:\nservices:\n  windows:\n    volumes:\n      - data:/storage\n' >"$vm/compose.yaml"
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  grep -qxF '      - data:/storage' "$vm/compose.yaml"
  grep -qxF '    image: ghcr.io/dockur/windows:6.06' "$vm/compose.yaml"
  [ "$(sed -n '/^volumes:$/{n;p}' "$vm/compose.yaml")" = '  data:' ]
  run grep -F './storage' "$vm/compose.yaml"
  [ "$status" -ne 0 ]
  [ ! -e "$vm/storage" ]
  [ ! -e "$HOME/chattr.log" ]
}

# A docker that reports the VM state in ~/vm.state and the log in ~/vm.log,
# and records every other command.
vm_stub() {
  # shellcheck disable=SC2016
  stub docker 'case "$1" in
info) exit 0 ;;
inspect) cat "$HOME/vm.state" 2>/dev/null || exit 1 ;;
logs) cat "$HOME/vm.log" 2>/dev/null; exit 0 ;;
*) printf "%s\n" "$*" >>"$HOME/docker.log" ;;
esac'
  mkdir -p "$XDG_DATA_HOME/omarchohard/vm" "$INBOX"
  : >"$XDG_DATA_HOME/omarchohard/vm/compose.yaml"
  printf 'running 0\n' >"$HOME/vm.state"
}

# Something listening where winapps.conf says RDP is, like Windows once it is up.
rdp_listen() {
  python3 -c 'import socket,sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True: s.accept()[0].close()' "$BATS_TEST_TMPDIR/rdp.port" 3>&- &
  RDP_PID=$!
  for _ in $(seq 50); do
    [ -s "$BATS_TEST_TMPDIR/rdp.port" ] && break
    sleep 0.1
  done
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\nRDP_IP="127.0.0.1"\nRDP_PORT="%s"\n' "$(cat "$BATS_TEST_TMPDIR/rdp.port")" >"$XDG_CONFIG_HOME/winapps/winapps.conf"
}

office_status() {
  printf '{"phase":"%s","product":"O365ProPlusRetail","version":"16.0.19328.20100","channel":"Current","error":"%s"}' "$1" "${2:-}" >"$INBOX/office-status.json"
}

phase() { "$OH" desktop status --json | jq -r .phase; }

teardown() {
  [ -z "${RDP_PID:-}" ] || kill "$RDP_PID" 2>/dev/null || true
}

@test "desktop status reports each install phase" {
  [ "$(phase)" = not-installed ]
  vm_stub
  printf '\e[1;34m❯ \e[1;36mDownloading Windows 11...\e[0m\n' >"$HOME/vm.log"
  [ "$(phase)" = downloading-windows ]
  [ "$("$OH" desktop status --json | jq -r .detail)" = "Downloading Windows 11..." ]
  printf '❯ Booting Windows using QEMU v10.1.2...\n' >>"$HOME/vm.log"
  [ "$(phase)" = installing-windows ]
  office_status installing-office
  [ "$(phase)" = installing-office ]
  office_status ready
  [ "$(phase)" = starting ]
  rdp_listen
  run "$OH" desktop status --json
  [ "$(jq -r '.phase, .rdp, .office.version, .office.channel' <<<"$output" | tr '\n' ' ')" = "ready true 16.0.19328.20100 Current " ]
  run "$OH" desktop status
  [[ $output == *"office: O365ProPlusRetail 16.0.19328.20100, Current channel"* ]]
  printf 'paused 0\n' >"$HOME/vm.state"
  [ "$(phase)" = paused ]
  printf 'exited 0\n' >"$HOME/vm.state"
  [ "$(phase)" = stopped ]
}

@test "desktop status reports a failed install with its reason, as plain text" {
  vm_stub
  office_status failed 'setup.exe exited with code 17\u001b[31m'
  run "$OH" desktop status --json
  [ "$(jq -r .phase <<<"$output")" = failed ]
  [[ $(jq -r .detail <<<"$output") == *"setup.exe exited with code 17 [31m"* ]]
  rm "$INBOX/office-status.json"
  printf 'exited 1\n' >"$HOME/vm.state"
  printf '\e[1;31m❯ ERROR: Failed to extract the Windows installation image!\e[0m\n' >"$HOME/vm.log"
  [ "$("$OH" desktop status --json | jq -r .detail)" = "the VM stopped with code 1: ERROR: Failed to extract the Windows installation image!" ]
}

@test "desktop install --wait prints phases until Office is ready, then adds the apps without questions" {
  rdp_listen
  stub git 'exit 0'
  # Each look at the log gets further, as the VM would.
  stub docker "case \"\$1\" in
info) exit 0 ;;
inspect) echo 'running 0' ;;
logs) n=\$(cat \"\$HOME/n\" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >\"\$HOME/n\"
  echo 'Downloading Windows 11...'
  [ \$n -ge 2 ] && echo 'Booting Windows using QEMU...'
  [ \$n -ge 3 ] && printf '{\"phase\":\"ready\",\"version\":\"16.0.1.2\"}' >\"$INBOX/office-status.json\"
  exit 0 ;;
*) printf '%s\n' \"\$*\" >>\"\$HOME/docker.log\" ;;
esac"
  wa=$XDG_DATA_HOME/omarchohard/winapps
  mkdir -p "$wa/.git" "$HOME/.local/bin"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\necho "$PWD $*" >>"$HOME/setup.log"\nprintf "#!/bin/sh\\n" >"$HOME/.local/bin/winapps"\nchmod +x "$HOME/.local/bin/winapps"\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
  OMARCHOHARD_DESKTOP_POLL=0.1 run "$OH" desktop install --force --wait
  [ "$status" -eq 0 ]
  [[ $output == *"downloading-windows"*"installing-windows"*"ready"* ]]
  [ "$(cat "$HOME/setup.log")" = "$wa --user --setupAllOfficiallySupportedApps" ]
  [ -f "$XDG_DATA_HOME/omarchohard/vm/oem/office-info.ps1" ]
  grep -qx 'open_with=desktop' "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "Ctrl-C in desktop wait leaves the VM installing and says how to resume" {
  vm_stub
  printf 'Downloading Windows 11...\n' >"$HOME/vm.log"
  # Background jobs start with SIGINT ignored; give the CLI a normal one.
  OMARCHOHARD_DESKTOP_POLL=0.1 python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$OH" desktop wait >"$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 50); do
    grep -q downloading-windows "$BATS_TEST_TMPDIR/out" && break
    sleep 0.1
  done
  kill -INT "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 130 ]
  grep -qF 'Pick it up again with: omarchohard desktop wait' "$BATS_TEST_TMPDIR/out"
  [ ! -e "$HOME/docker.log" ]
}

# Desktop Office set up and preferred, WinApps on PATH.
desktop_preferred() {
  # shellcheck disable=SC2016
  stub winapps 'printf "%s\n" "$*" >>"$HOME/winapps.log"'
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  : >"$XDG_DATA_HOME/omarchohard/vm/compose.yaml"
  printf 'open_with=desktop\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
}

@test "with desktop Office preferred, open --app raises the app's window by its title, or starts it" {
  desktop_preferred
  export OMARCHOHARD_DRY_RUN=1
  # As seen live: once Excel opened, every window of the Windows session took
  # its class, Word's too. The web app titled "Microsoft Word" is not desktop
  # Office, and the RemoteApp marker window is never an app.
  cat >"$HOME/clients.json" <<'JSON'
[{"class":"chrome-word.cloud.microsoft__-Default","title":"Microsoft Word","address":"0x9"},
 {"class":"Microsoft Excel","title":"RemoteApp Marker Window","address":"0x1"},
 {"class":"Microsoft Excel","title":"Report.docx - Word","address":"0x2"},
 {"class":"Microsoft Excel","title":"Budget.xlsx - Excel","address":"0x3"},
 {"class":"Microsoft Excel","title":"Inbox - ada@example.com - Outlook","address":"0x4"},
 {"class":"Microsoft Excel","title":"OneNote","address":"0x5"}]
JSON
  # shellcheck disable=SC2016
  stub hyprctl 'case "$1" in clients) cat "$HOME/clients.json" ;; esac'
  focused() { [ "$output" = "would run: hyprctl dispatch hl.dsp.focus({ window = \"address:$1\" })" ]; }
  run "$OH" open --app word
  [ "$status" -eq 0 ]
  focused 0x2
  run "$OH" open --app excel
  focused 0x3
  run "$OH" open --app outlook
  focused 0x4
  run "$OH" open --app onenote
  focused 0x5
  run "$OH" open --app powerpoint
  [ "$output" = 'would run: winapps powerpoint-o365' ]
  # With only the web app and the marker open, Word starts.
  printf '[{"class":"chrome-word.cloud.microsoft__-Default","title":"Microsoft Word","address":"0x9"},{"class":"Microsoft Word","title":"RemoteApp Marker Window","address":"0x1"}]' >"$HOME/clients.json"
  run "$OH" open --app word
  [ "$output" = 'would run: winapps word-o365' ]
  # Teams has no desktop version here; it stays the web app.
  run "$OH" open --app teams
  [[ $output == *"--app=https://teams.cloud.microsoft/"* ]]
  # A file always opens the file, even with Word already open.
  cp "$FIXTURES/test.docx" "$HOME/Notes.docx"
  run "$OH" open --app word "$HOME/Notes.docx"
  [ "$output" = "would run: winapps word-o365 $HOME/Notes.docx" ]
}

@test "with desktop Office preferred, the launcher and Files open desktop Office" {
  oh_install_quiet
  desktop_preferred
  # The launcher entry runs open --app word with no file.
  exec_line=$(sed -n 's/^Exec=//p' "$APPS/omarchohard-word.desktop")
  [ "${exec_line% %U}" = "$OH open --app word" ]
  "$OH" open --app word
  cp "$FIXTURES/test.xlsx" "$HOME/Budget.xlsx"
  xdg-open "$HOME/Budget.xlsx"
  for _ in $(seq 50); do
    [ "$(wc -l <"$HOME/winapps.log" 2>/dev/null)" = 2 ] && break
    sleep 0.1
  done
  [ "$(cat "$HOME/winapps.log")" = "$(printf 'word-o365\nexcel-o365 %s' "$HOME/Budget.xlsx")" ]
  [ ! -s "$HOME/chromium.log" ]
}

# A FreeRDP that records its arguments and what it read on stdin.
freerdp_stub() {
  # shellcheck disable=SC2016
  stub xfreerdp3 'for a in "$@"; do printf "%s\n" "$a"; done >"$HOME/rdp.args.tmp"; cat >"$HOME/rdp.stdin"; mv "$HOME/rdp.args.tmp" "$HOME/rdp.args"'
}

@test "desktop run opens a file in Windows through explorer, with the password only on stdin" {
  vm_stub
  freerdp_stub
  mkdir -p "$XDG_CONFIG_HOME/winapps" "$HOME/Add-ins"
  # shellcheck disable=SC2016 # a literal $ in the test password
  printf 'RDP_USER="ada"\nRDP_PASS="s3cr$t pw"\nRDP_IP="127.0.0.1"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  : >"$HOME/Add-ins/Stats Tool.xll"
  printf 'paused 0\n' >"$HOME/vm.state"
  run "$OH" desktop run "$HOME/Add-ins/Stats Tool.xll"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -f "$HOME/rdp.args" ] && break
    sleep 0.1
  done
  grep -qxF '/app:program:C:\Windows\explorer.exe,name:Open in Windows,cmd:"\\tsclient\home\Add-ins\Stats Tool.xll"' "$HOME/rdp.args"
  grep -qxF '/from-stdin:force' "$HOME/rdp.args"
  grep -qxF '/u:ada' "$HOME/rdp.args"
  grep -qxF '/v:127.0.0.1:3389' "$HOME/rdp.args"
  # shellcheck disable=SC2016
  [ "$(cat "$HOME/rdp.stdin")" = 's3cr$t pw' ]
  run grep -F 's3cr' "$HOME/rdp.args"
  [ "$status" -ne 0 ]
  # The paused VM was woken first.
  grep -qx 'unpause WinApps' "$HOME/docker.log"
}

@test "desktop run refuses files outside home and /run/media, and control characters" {
  vm_stub
  freerdp_stub
  run "$OH" desktop run /etc/hostname
  [ "$status" -eq 1 ]
  [[ $output == *"under $HOME or /run/media only"* ]]
  bad=$HOME/$'two\nlines.xll'
  : >"$bad"
  run "$OH" desktop run "$bad"
  [ "$status" -eq 1 ]
  [[ $output == *"control character"* ]]
  ln -s /etc/hostname "$HOME/link.txt"
  run "$OH" desktop run "$HOME/link.txt"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/rdp.args" ]
}

@test "Open in Windows is offered for add-ins once the desktop apps are added, and uninstall removes it" {
  oh_install_quiet
  [ ! -e "$APPS/omarchohard-windows.desktop" ]
  wa=$XDG_DATA_HOME/omarchohard/winapps
  mkdir -p "$wa"
  printf '#!/bin/sh\nexit 0\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
  desktop_preferred
  run "$OH" desktop apps
  [ "$status" -eq 0 ]
  entry=$APPS/omarchohard-windows.desktop
  grep -qx 'Name=Open in Windows' "$entry"
  grep -qx "Exec=$OH desktop run %f" "$entry"
  for t in application/vnd.ms-excel.addin.macroEnabled.12 application/vnd.ms-powerpoint.addin.macroEnabled.12 \
    application/vnd.ms-word.template.macroEnabled.12 application/x-ms-excel-xll application/x-ms-vsto; do
    grep -q "^MimeType=.*$t;" "$entry"
  done
  if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$entry"; fi
  pkg=$XDG_DATA_HOME/mime/packages/omarchohard-addins.xml
  grep -qF 'pattern="*.xll"' "$pkg"
  # A reinstall (as after omarchohard update) keeps it.
  oh_install_quiet
  [ -f "$entry" ]
  "$OH" uninstall >/dev/null 2>&1
  [ ! -e "$entry" ]
  [ ! -e "$pkg" ]
}

@test "desktop update sends a fixed-word request and prints Office's answer" {
  vm_stub
  answer='{"version":"16.0.19328.20100","channel":"Current","message":"Office update started; Windows Update is checking too"}'
  fake_vm "$answer"
  run "$OH" desktop update
  wait
  [ "$status" -eq 0 ]
  [[ $output == *"$answer"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"action":"update","key":""}' ]
  fake_vm "$answer"
  "$OH" desktop update --to 16.0.19127.20264 >/dev/null 2>&1
  wait
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"action":"update","key":"","version":"16.0.19127.20264"}' ]
  fake_vm "$answer"
  "$OH" desktop update --channel monthly --to 16.0.19127.20264 >/dev/null 2>&1
  wait
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"action":"channel","key":"","channel":"MonthlyEnterprise","version":"16.0.19127.20264"}' ]
  fake_vm "$answer"
  "$OH" desktop update --channel semi-annual >/dev/null 2>&1
  wait
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"action":"channel","key":"","channel":"SemiAnnual"}' ]
  [ -z "$(ls -A "$INBOX")" ]
}

@test "desktop update refuses an unknown channel or a malformed version and writes nothing" {
  vm_stub
  for bad in beta Current semi-annual-preview; do
    run "$OH" desktop update --channel "$bad"
    [ "$status" -eq 1 ]
  done
  for bad in 16.0.1 16.0.1.2x '16.0.1.2","action":"x' $'16.0.1.2\n'; do
    run "$OH" desktop update --to "$bad"
    [ "$status" -eq 1 ]
  done
  [ -z "$(ls -A "$INBOX")" ]
}

# shellcheck disable=SC2016 # PowerShell's own $ in the expected text
@test "the VM updates Office only on an allowed channel and version, and installs it with updates on" {
  ps=$BATS_TEST_DIRNAME/../share/omarchohard/vm
  grep -qxF "\$channels = @('Current', 'MonthlyEnterprise', 'SemiAnnual')" "$ps/inbox.ps1"
  grep -qF -- '-cnotcontains "$($req.channel)"' "$ps/inbox.ps1"
  grep -qxF "\$versionPattern = '^[0-9]+(\\.[0-9]+){3}\\z'" "$ps/inbox.ps1"
  grep -qxF "\$c2r = 'C:\\Program Files\\Common Files\\microsoft shared\\ClickToRun\\OfficeC2RClient.exe'" "$ps/inbox.ps1"
  grep -qF "@('/update', 'user', 'displaylevel=false', 'forceappshutdown=false')" "$ps/inbox.ps1"
  grep -qF '"updatetoversion=$version"' "$ps/inbox.ps1"
  grep -qF "UsoClient.exe\" -ArgumentList 'StartInteractiveScan'" "$ps/inbox.ps1"
  grep -qF "'/changesetting', \"Channel=\$(\$req.channel)\"" "$ps/inbox.ps1"
  grep -qxF '  <Updates Enabled="TRUE" Channel="$channel" />' "$ps/office.ps1"
  grep -qF "HKLM:\\SOFTWARE\\Microsoft\\Office\\ClickToRun\\Configuration" "$ps/office-info.ps1"
}

@test "omarchohard update suggests desktop update only when the desktop tier is installed" {
  run "$OH" update
  [ "$status" -eq 0 ]
  [[ $output != *"desktop update"* ]]
  : >"$XDG_DATA_HOME/omarchohard/vm/compose.yaml"
  run "$OH" update
  [ "$status" -eq 0 ]
  [[ $output == *"to update it now: omarchohard desktop update"* ]]
}

# The level and detail of check NAME in doctor --json output JSON: check JSON NAME.
check() { jq -r --arg n "$2" '.checks[] | select(.name == $n) | .level + " " + .detail' <<<"$1"; }

winapps_launchers() {
  for wa in "$@"; do printf '[Desktop Entry]\nType=Application\nName=%s\nExec=winapps %s\n' "$wa" "$wa" >"$APPS/$wa.desktop"; done
}

@test "doctor checks the desktop VM, RDP, Office version, launchers and open_with" {
  oh_install_quiet
  vm_stub
  desktop_preferred
  rdp_listen
  office_status ready
  winapps_launchers word-o365 excel-o365 powerpoint-o365 outlook-o365 onenote-o365
  run "$OH" doctor --json
  [ "$(check "$output" 'desktop VM')" = "ok running" ]
  [ "$(check "$output" 'desktop RDP')" = "ok 127.0.0.1:$(cat "$BATS_TEST_TMPDIR/rdp.port") answers" ]
  [ "$(check "$output" 'desktop Office')" = "ok O365ProPlusRetail 16.0.19328.20100, Current channel" ]
  [ "$(check "$output" 'desktop launchers')" = "ok Word, Excel, PowerPoint, Outlook, OneNote" ]
  [ "$(check "$output" 'open_with')" = "ok desktop" ]
  [ "$(jq .fails <<<"$output")" -eq 0 ]
  # Paused while idle is fine, not a warning.
  printf 'paused 0\n' >"$HOME/vm.state"
  run "$OH" doctor --json
  [ "$(check "$output" 'desktop VM')" = "ok paused while idle; it resumes when you open an app" ]
  [ "$(jq '[.checks[] | select(.name | startswith("desktop")) | select(.level != "ok")] | length' <<<"$output")" -eq 0 ]
}

@test "doctor warns while Windows starts, about missing launchers, and fails a failed Office install" {
  oh_install_quiet
  vm_stub
  office_status ready
  stub winapps 'exit 0'
  winapps_launchers excel-o365 powerpoint-o365 outlook-o365 onenote-o365
  run "$OH" doctor --json
  [[ $(check "$output" 'desktop install') == "warn starting"* ]]
  [[ $(check "$output" 'desktop RDP') == "warn no answer on 127.0.0.1:3389 yet"* ]]
  [ "$(check "$output" 'desktop launchers')" = "warn missing Word (omarchohard desktop apps)" ]
  [[ $(check "$output" 'open_with') == "ok web; "* ]]
  office_status failed 'setup.exe exited with code 17'
  run "$OH" doctor --json
  [ "$status" -eq 1 ]
  [ "$(check "$output" 'desktop Office')" = "fail did not install: setup.exe exited with code 17" ]
}
