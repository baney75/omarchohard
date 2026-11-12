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
  (
    for _ in $(seq 100); do
      for r in "$INBOX"/*.request; do
        [ -f "$r" ] || continue
        cp "$r" "$BATS_TEST_TMPDIR/seen.json"
        rm -f "$r"
        printf 'Office: licensed\n' >"${r%.request}.result"
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

@test "with desktop Office preferred, open --app raises the app's window or starts it" {
  desktop_preferred
  export OMARCHOHARD_DRY_RUN=1
  # shellcheck disable=SC2016
  stub hyprctl 'case "$1" in clients) echo "[{\"class\":\"Microsoft Word 2\",\"address\":\"0x1\"},{\"class\":\"Microsoft Word\",\"address\":\"0x2\"}]" ;; esac'
  run "$OH" open --app word
  [ "$status" -eq 0 ]
  [ "$output" = 'would run: hyprctl dispatch hl.dsp.focus({ window = "address:0x2" })' ]
  run "$OH" open --app excel
  [ "$output" = 'would run: winapps excel-o365' ]
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
