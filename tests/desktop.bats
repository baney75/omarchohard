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
  # dockur downloads the Windows image over 16 connections, not 4.
  grep -qxF '      CONNECTIONS: "16"' "$compose"
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
  # The plain-text password automatic sign-in used is removed.
  grep -qxF 'reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f' "$bat"
  grep -qxF 'powercfg /hibernate off' "$bat"
  # The disk is slimmed by a SYSTEM task started once Office is in, so the
  # sign-out does not wait for it.
  grep -qxF '  /TR "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\OEM\slim.ps1 -Log C:\OEM\slim.log"' "$bat"
  grep -qF 'schtasks /Create /F /TN "omarchohard-slim" /SC ONSTART /RU SYSTEM /RL HIGHEST ^' "$bat"
  slim=$(grep -nxF 'schtasks /Run /TN "omarchohard-slim"' "$bat" | cut -d: -f1)
  [ -n "$slim" ] && [ "$office" -lt "$slim" ]
  [ "$(grep -c 'slim.ps1' "$bat")" -eq 1 ]
  cmp "$OH_REPO_ROOT/share/omarchohard/vm/slim.ps1" "$XDG_DATA_HOME/omarchohard/vm/oem/slim.ps1"
  # Seen live: Windows kept a cached listing of the inbox and never saw a
  # request, so the SMB client cache is off before anything opens the share.
  smb=$(grep -n 'Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileNotFoundCacheLifetime 0 -FileInfoCacheLifetime 0 -Force' "$bat" | cut -d: -f1)
  [ -n "$smb" ] && [ "$smb" -lt "$office" ]
  # Ready is written only after automatic sign-in is off, right before the
  # sign-out, so desktop wait never adds the apps while the console holds
  # the session; office.ps1 itself says only "installed".
  ready=$(grep -n "Write-OfficeStatus 'ready'" "$bat" | cut -d: -f1)
  [ -n "$ready" ] && [ "$reg" -lt "$ready" ] && [ "$ready" -eq $(($(wc -l <"$bat") - 1)) ]
  grep -qxF "Write-OfficeStatus 'installed'" "$BATS_TEST_DIRNAME/../share/omarchohard/vm/office.ps1"
  [ "$(grep -cF "Write-OfficeStatus 'ready'" "$BATS_TEST_DIRNAME/../share/omarchohard/vm/office.ps1")" -eq 0 ]
  # Signing out is the last thing it does.
  [ "$(tail -n 1 "$bat")" = 'shutdown /l /f' ]
}

@test "when WinApps cannot connect, desktop wait says to sign out of Windows once" {
  vm_stub
  rdp_listen
  office_status ready
  wa=$XDG_DATA_HOME/omarchohard/winapps
  mkdir -p "$wa"
  # shellcheck disable=SC2016 # $HOME is for the stub's shell
  printf '#!/bin/sh\necho try >>"$HOME/setup.tries"\necho "REMOTE DESKTOP PROTOCOL FAILURE"\nexit 14\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
  export OMARCHOHARD_DESKTOP_POLL=0
  run "$OH" desktop wait
  [ "$status" -eq 1 ]
  [[ $output == *"sign out of Windows once at http://127.0.0.1:8006 (Start, your name, Sign out)"* ]]
  # The console signs out a moment after Office is ready: three tries first.
  [ "$(wc -l <"$HOME/setup.tries")" -eq 3 ]
  # Any other failure gets no such advice.
  printf '#!/bin/sh\nexit 5\n' >"$wa/setup.sh"
  run "$OH" desktop wait
  [ "$status" -eq 1 ]
  [[ $output != *"Sign out"* ]]
}

OFFICE_V=16.0.20527.20196

@test "the Office prefetch downloads the ODT source layout, the big file in 8 byte ranges, and writes ready" {
  office_cdn "$OFFICE_V"
  run "$OH" desktop office-prefetch
  [ "$status" -eq 0 ]
  src=$XDG_DATA_HOME/omarchohard/vm/office-src
  [ "$(cat "$src/ready")" = "$OFFICE_V" ]
  [ ! -e "$src/failed" ]
  # Exactly the files ODT reads for this version, each byte for byte.
  [ "$(cd "$src" && find Office -type f | sort)" = "$(office_src_files "$OFFICE_V" | sort)" ]
  while IFS= read -r f; do cmp "$HOME/cdn/$f" "$src/$f"; done < <(office_src_files "$OFFICE_V")
  [ "$(grep -cE "^GET [0-9]+-[0-9]+ $OFFICE_CDN/Office/Data/$OFFICE_V/stream.x64.x-none.dat$" "$HOME/curl.log")" -eq 8 ]
  [ "$(grep -cE "^GET [0-9]+-[0-9]+ " "$HOME/curl.log")" -eq 8 ]
  # The CDN host only, over HTTPS only, and no redirect followed.
  run grep -v " $OFFICE_CDN/" "$HOME/curl.log"
  [ "$status" -ne 0 ]
  [ "$(grep -c -- '--proto =https' "$HOME/curl.args")" -eq "$(wc -l <"$HOME/curl.args")" ]
  run grep -E -- '(^| )(-L|--location)( |$)' "$HOME/curl.args"
  [ "$status" -ne 0 ]
  [[ $(cat "$src/progress") == "complete: Office $OFFICE_V, "* ]]
  [ -z "$(find "$src" -name '*.tmp' -o -name '*.part*')" ]
}

@test "a file that does not come to its Content-Length makes the prefetch write failed, never ready" {
  office_cdn "$OFFICE_V"
  printf '999\n' >"$HOME/cdn/Office/Data/$OFFICE_V/s640.cab.len"
  run "$OH" desktop office-prefetch
  [ "$status" -eq 1 ]
  src=$XDG_DATA_HOME/omarchohard/vm/office-src
  [ ! -e "$src/ready" ]
  grep -qF "Office/Data/$OFFICE_V/s640.cab came to" "$src/failed"
  grep -qF 'not the 999 the CDN gave as its Content-Length' "$src/failed"
  [ ! -e "$src/Office/Data/$OFFICE_V/s640.cab" ]
}

@test "a complete copy of the current Office is reused with no new download, and an older one is removed" {
  office_cdn "$OFFICE_V"
  run "$OH" desktop office-prefetch
  [ "$status" -eq 0 ]
  src=$XDG_DATA_HOME/omarchohard/vm/office-src
  mkdir -p "$src/Office/Data/16.0.1.1"
  : >"$src/Office/Data/16.0.1.1/stream.x64.x-none.dat"
  : >"$src/Office/Data/v64_16.0.1.1.cab"
  rm -f "$HOME/curl.log"
  run "$OH" desktop office-prefetch
  [ "$status" -eq 0 ]
  [ "$(cat "$src/ready")" = "$OFFICE_V" ]
  # Only the version check is fetched; the rest is HEAD requests.
  [ "$(grep '^GET' "$HOME/curl.log")" = "GET $OFFICE_CDN/Office/Data/v64.cab" ]
  [ "$(grep -c '^HEAD' "$HOME/curl.log")" -eq 6 ]
  [ ! -e "$src/Office/Data/16.0.1.1" ]
  [ ! -e "$src/Office/Data/v64_16.0.1.1.cab" ]
  [ "$(cd "$src" && find Office -type f | sort)" = "$(office_src_files "$OFFICE_V" | sort)" ]
}

@test "desktop install points Windows at the host's Office copy and downloads it in a user service" {
  stub docker 'exit 0'
  stub git 'exit 0'
  office_cdn "$OFFICE_V"
  # The unit is told the folders even when this shell leaves them to their
  # defaults, or it would get the user manager's own (seen on the test host).
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME "$OH" desktop install --force
  vm=$XDG_DATA_HOME/omarchohard/vm
  # shellcheck disable=SC1003 # one backslash ends the line's last folder
  [ "$(cat "$vm/oem/office-source.txt")" = '\\host.lan\Data\.local\share\omarchohard\vm\office-src' ]
  grep -qx -- --user "$HOME/systemd-run.log"
  grep -qx -- --unit=omarchohard-office-prefetch "$HOME/systemd-run.log"
  grep -qx -- "--setenv=HOME=$HOME" "$HOME/systemd-run.log"
  grep -qx -- "--setenv=XDG_DATA_HOME=$HOME/.local/share" "$HOME/systemd-run.log"
  grep -qx -- "--setenv=XDG_CONFIG_HOME=$HOME/.config" "$HOME/systemd-run.log"
  [ "$(tail -n2 "$HOME/systemd-run.log")" = "$(printf 'desktop\noffice-prefetch')" ]
  # The install itself downloads nothing.
  [ ! -e "$HOME/curl.log" ]
  # A VM disk already there does not run the first-boot scripts again, so
  # there is nothing to download for.
  : >"$vm/storage/data.img"
  rm -f "$HOME/systemd-run.log"
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  [ ! -e "$vm/oem/office-source.txt" ]
  [ ! -e "$HOME/systemd-run.log" ]
}

# shellcheck disable=SC2016 # PowerShell's own $ in the expected text
@test "office.ps1 installs from the host's copy when it is ready, and from the CDN when that fails" {
  ps=$BATS_TEST_DIRNAME/../share/omarchohard/vm/office.ps1
  grep -qxF 'if (Test-Path C:\OEM\office-source.txt) {' "$ps"
  grep -qxF '      if (Test-Path "$dir\ready") {' "$ps"
  grep -qxF '      if (Test-Path "$dir\failed") {' "$ps"
  grep -qxF '      } elseif (((Get-Date) - $changed).TotalSeconds -ge 120) {' "$ps"
  # Growth comes from a folder listing; a file read over the share stays
  # cached in Windows, so the progress file is never what it watches.
  grep -qF 'Get-ChildItem -LiteralPath "$dir\Office" -Recurse -File' "$ps"
  [ "$(grep -cF '$dir\progress' "$ps")" -eq 0 ]
  grep -qF 'SourcePath=`"$([Security.SecurityElement]::Escape($sourcePath))`" Version=`"$sourceVersion`" AllowCdnFallback=`"True`"' "$ps"
  # The local run first; when it fails, one more run with no SourcePath.
  local_run=$(grep -nxF '  $code = Invoke-OfficeSetup $source $version' "$ps" | cut -d: -f1)
  guard=$(grep -nxF 'if (-not $installed) {' "$ps" | cut -d: -f1)
  cdn_run=$(grep -nxF '  $code = Invoke-OfficeSetup' "$ps" | cut -d: -f1)
  # Separate checks: a failure before the last of an && list fails no test.
  [ -n "$local_run" ]
  [ -n "$guard" ]
  [ "$local_run" -lt "$guard" ]
  [ "$cdn_run" -eq $((guard + 1)) ]
  grep -qxF '  if ($code -eq 0 -and (Get-OfficeInfo).version) {' "$ps"
  # The signature check and status writes stay, and the log names the source.
  grep -qF 'Get-AuthenticodeSignature "$work\setup.exe"' "$ps"
  [ "$(grep -n 'Get-AuthenticodeSignature' "$ps" | cut -d: -f1)" -lt "$local_run" ]
  grep -qxF "Write-OfficeStatus 'installing-office'" "$ps"
  grep -qxF "Write-OfficeStatus 'installed'" "$ps"
  grep -qxF 'Write-Output "office: installed $product on channel $channel from $from"' "$ps"
  grep -qF 'Write-Output "office: installing $product from Microsoft'"'"'s CDN"' "$ps"
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

compress_stubs() {
  vm=$XDG_DATA_HOME/omarchohard/vm
  mkdir -p "$vm/storage"
  printf 'windows disk\n' >"$vm/storage/data.img"
  fs_is btrfs
  stub df 'printf "Avail\n99999999\n"'
  # Set up, as compress wants, with the VM running until compose stops it.
  stub winapps 'exit 0'
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  : >"$vm/compose.yaml"
  echo running >"$HOME/vm.state"
  # shellcheck disable=SC2016
  stub docker 'case "$1" in info) ;; inspect) cat "$HOME/vm.state" ;; *) printf "docker %s\n" "$*" >>"$HOME/vm.log"
  [[ $* == *" stop" ]] && echo "${RESTART_STATE:-exited}" >"$HOME/vm.state" || true ;; esac'
  # shellcheck disable=SC2016
  stub chattr 'printf "chattr %s\n" "$*" >>"$HOME/vm.log"'
  # A file whose compression property is set reports it, as btrfs does.
  # shellcheck disable=SC2016
  stub btrfs "printf 'btrfs %s\n' \"\$*\" >>\"\$HOME/vm.log\"
case \"\$1 \$2\" in
'property get') grep -qxF \"\$3\" \"\$HOME/zstd\" 2>/dev/null && echo compression=zstd ;;
'property set') printf '%s\n' \"\$3\" >>\"\$HOME/zstd\" ;;
'filesystem defragment') exit \${DEFRAG_RC:-0} ;;
esac"
}

@test "desktop compress stops the VM, rewrites its disk compressed, and starts it again" {
  compress_stubs
  run "$OH" desktop compress
  [ "$status" -eq 0 ]
  img=$vm/storage/data.img tmp=$vm/storage/data.img.compress
  [ "$(cat "$img")" = 'windows disk' ]
  [ ! -e "$tmp" ]
  grep -v 'property get' "$HOME/vm.log" >"$HOME/steps"
  printf '%s\n' "docker compose -f $vm/compose.yaml stop" "chattr -C -- $tmp" \
    "btrfs property set $tmp compression zstd" "btrfs filesystem defragment -czstd -- $tmp" \
    "docker compose -f $vm/compose.yaml up -d" | diff - "$HOME/steps"
  # The renamed file keeps its property, so a second run changes nothing.
  printf '%s\n' "$img" >>"$HOME/zstd"
  rm "$HOME/vm.log"
  run "$OH" desktop compress
  [ "$status" -eq 0 ]
  [[ $output == *"already compressed"* ]]
  [ "$(grep -c '^docker' "$HOME/vm.log")" -eq 0 ]
}

@test "a failed desktop compress leaves the disk as it was and starts the VM again" {
  compress_stubs
  DEFRAG_RC=1 run "$OH" desktop compress
  [ "$status" -ne 0 ]
  [[ $output == *"the disk is unchanged"* ]]
  [ "$(cat "$vm/storage/data.img")" = 'windows disk' ]
  [ ! -e "$vm/storage/data.img.compress" ]
  [ "$(tail -n 1 "$HOME/vm.log")" = "docker compose -f $vm/compose.yaml up -d" ]
}

@test "desktop compress keeps the old disk when the VM started again during the copy" {
  compress_stubs
  RESTART_STATE=running run "$OH" desktop compress
  [ "$status" -ne 0 ]
  [[ $output == *"started during the copy"* ]]
  [ ! -e "$vm/storage/data.img.compress" ]
  run grep -qxF "$vm/storage/data.img" "$HOME/zstd"
  [ "$status" -ne 0 ]
}

@test "the first idle pause after slim compresses the disk once, instead of pausing" {
  compress_stubs
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\nAUTOPAUSE="on"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  stub pgrep 'exit 1'
  # Before Windows says slim is done, an idle VM is paused as before.
  run "$OH" desktop autopause
  [ "$status" -eq 0 ]
  grep -qx "docker compose -f $vm/compose.yaml pause" "$HOME/vm.log"
  [ ! -e "$HOME/zstd" ]
  rm "$HOME/vm.log"
  mkdir -p "$INBOX"
  : >"$INBOX/slim-done"
  run "$OH" desktop autopause
  [ "$status" -eq 0 ]
  grep -qx "btrfs filesystem defragment -czstd -- $vm/storage/data.img.compress" "$HOME/vm.log"
  [ "$(tail -n 1 "$HOME/vm.log")" = "docker compose -f $vm/compose.yaml up -d" ]
  [ "$(grep -c ' pause$' "$HOME/vm.log")" -eq 0 ]
  [ ! -e "$INBOX/slim-done" ]
}

@test "opening an app while the idle timer compresses the disk starts the VM, which keeps the old disk" {
  vm_stub
  freerdp_stub
  mkdir -p "$XDG_CONFIG_HOME/winapps" "$XDG_DATA_HOME/omarchohard/vm/storage"
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  : >"$HOME/Notes.docx"
  printf 'exited 0\n' >"$HOME/vm.state"
  run "$OH" desktop run "$HOME/Notes.docx"
  [ "$status" -ne 0 ]
  [[ $output == *"start it with: omarchohard desktop up"* ]]
  : >"$XDG_DATA_HOME/omarchohard/vm/storage/data.img.compress"
  run "$OH" desktop run "$HOME/Notes.docx"
  grep -q "compose -f $XDG_DATA_HOME/omarchohard/vm/compose.yaml up -d" "$HOME/docker.log"
}

@test "desktop compress waits until desktop Office is set up" {
  compress_stubs
  rm "$XDG_CONFIG_HOME/winapps/winapps.conf"
  run "$OH" desktop compress
  [ "$status" -ne 0 ]
  [[ $output == *"not set up yet"* ]]
  [ ! -e "$HOME/vm.log" ]
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
# A local RDP port. By default it answers a connection request the way
# Windows does; `rdp_listen proxy` accepts and hangs up, like Docker's proxy
# before Windows listens.
rdp_listen() {
  python3 -c 'import socket,sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c = s.accept()[0]
    if sys.argv[2] != "proxy":
        c.recv(64); c.sendall(bytes.fromhex("0300001300d0000012340002000800000000"))
    c.close()' "$BATS_TEST_TMPDIR/rdp.port" "${1:-rdp}" 3>&- &
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

@test "the host's Office copy is deleted once Office is installed, unless its download still runs" {
  vm_stub
  src=$XDG_DATA_HOME/omarchohard/vm/office-src
  mkdir -p "$src/Office/Data"
  office_status installing-office
  phase >/dev/null
  [ -d "$src" ]
  stub systemctl 'exit 0'
  office_status installed
  phase >/dev/null
  [ -d "$src" ]
  stub systemctl 'exit 3'
  phase >/dev/null
  [ ! -e "$src" ]
  # A failed install no longer reads it either.
  mkdir -p "$src/Office/Data"
  office_status failed
  phase >/dev/null
  [ ! -e "$src" ]
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
  office_status installed
  [ "$(phase)" = installing-office ]
  [[ $("$OH" desktop status --json | jq -r .detail) == *"finishing its first start"* ]]
  office_status ready
  [ "$(phase)" = starting ]
  # Docker's proxy takes the connection before Windows listens: not ready.
  rdp_listen proxy
  [ "$(phase)" = starting ]
  [ "$("$OH" desktop status --json | jq -r .rdp)" = false ]
  kill "$RDP_PID"
  rm "$BATS_TEST_TMPDIR/rdp.port"
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
  # Like WinApps: exit 3 over its own earlier install.
  printf '#!/bin/sh\necho "$PWD $*" >>"$HOME/setup.log"\ncase "$*" in *--uninstall*) rm -f "$HOME/.local/bin/winapps"; exit 0 ;; esac\n[ -e "$HOME/.local/bin/winapps" ] && exit 3\nprintf "#!/bin/sh\\n" >"$HOME/.local/bin/winapps"\nchmod +x "$HOME/.local/bin/winapps"\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
  OMARCHOHARD_DESKTOP_POLL=0.1 run "$OH" desktop install --force --wait
  [ "$status" -eq 0 ]
  [[ $output == *"downloading-windows"*"installing-windows"*"ready"* ]]
  [ "$(cat "$HOME/setup.log")" = "$wa --user --setupAllOfficiallySupportedApps" ]
  [ -f "$XDG_DATA_HOME/omarchohard/vm/oem/office-info.ps1" ]
  grep -qx 'open_with=desktop' "$XDG_CONFIG_HOME/omarchohard/config"
  # A reinstalled VM: WinApps' earlier install goes first, or setup stops.
  rm "$HOME/setup.log"
  run "$OH" desktop apps
  [ "$status" -eq 0 ]
  printf '%s\n' "$wa --user" "$wa --user --uninstall" "$wa --user" | diff - "$HOME/setup.log"
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
  # WinApps for every launch here, even where FreeRDP is installed; the agent
  # tests turn it back on.
  printf 'desktop_agent=off\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
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
 {"class":"Microsoft Excel","title":"Bakery Budget.xlsx - Microsoft Excel","address":"0x3"},
 {"class":"Microsoft Excel","title":"Spring Launch.pptx - Microsoft PowerPoint","address":"0x6"},
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
  # Live RemoteApp titles name the app in full: "Bakery Budget.xlsx - Microsoft Excel".
  run "$OH" open --app powerpoint
  focused 0x6
  # With only the web app and the marker open, Word starts.
  printf '[{"class":"chrome-word.cloud.microsoft__-Default","title":"Microsoft Word","address":"0x9"},{"class":"Microsoft Word","title":"RemoteApp Marker Window","address":"0x1"}]' >"$HOME/clients.json"
  run "$OH" open --app word
  [ "$output" = 'would run: winapps word-o365' ]
  run "$OH" open --app powerpoint
  [ "$output" = 'would run: winapps powerpoint-o365' ]
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
  # These tests cover the explorer RemoteApp, used without the agent.
  printf 'desktop_agent=off\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
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
  # The host's CUPS printers show in Windows.
  grep -qxF /printer "$HOME/rdp.args"
  # shellcheck disable=SC2016
  [ "$(cat "$HOME/rdp.stdin")" = 's3cr$t pw' ]
  run grep -F 's3cr' "$HOME/rdp.args"
  [ "$status" -ne 0 ]
  # The paused VM was woken first.
  grep -qx 'unpause WinApps' "$HOME/docker.log"
}

@test "WinApps, its setup and FreeRDP run with Kerberos off for the local VM, and nothing else does" {
  desktop_preferred
  vm_stub
  # shellcheck disable=SC2016
  stub winapps 'printf "%s %s\n" "${KRB5_CONFIG:-unset}" "$*" >>"$HOME/winapps.log"'
  run "$OH" open --app word
  cp "$FIXTURES/test.docx" "$HOME/Notes.docx"
  run "$OH" open --app word "$HOME/Notes.docx"
  for _ in $(seq 50); do
    [ "$(wc -l <"$HOME/winapps.log" 2>/dev/null)" = 2 ] && break
    sleep 0.1
  done
  [ "$(cat "$HOME/winapps.log")" = "$(printf '/dev/null word-o365\n/dev/null word-o365 %s' "$HOME/Notes.docx")" ]
  # shellcheck disable=SC2016
  stub xfreerdp3 'printf "%s\n" "${KRB5_CONFIG:-unset}" >"$HOME/rdp.env"; cat >/dev/null'
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\nRDP_IP="127.0.0.1"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  run "$OH" desktop run "$HOME/Notes.docx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/rdp.env" ] && break
    sleep 0.1
  done
  [ "$(cat "$HOME/rdp.env")" = /dev/null ]
  wa=$XDG_DATA_HOME/omarchohard/winapps
  mkdir -p "$wa"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\necho "${KRB5_CONFIG:-unset}" >"$HOME/setup.env"\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
  run "$OH" desktop apps
  [ "$(cat "$HOME/setup.env")" = /dev/null ]
  # The web apps' browser does not get it.
  # shellcheck disable=SC2016
  stub chromium 'printf "%s\n" "${KRB5_CONFIG:-unset}" >"$HOME/browser.env"'
  run "$OH" open --app teams
  for _ in $(seq 50); do
    [ -s "$HOME/browser.env" ] && break
    sleep 0.1
  done
  [ "$(cat "$HOME/browser.env")" = unset ]
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
  : >"$HOME/Budget, 2026.xlam"
  run "$OH" desktop run "$HOME/Budget, 2026.xlam"
  [ "$status" -eq 1 ]
  [[ $output == *"comma"* ]]
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
  winapps_launchers word-o365
  run "$OH" desktop apps
  [ "$status" -eq 0 ]
  # WinApps' own entry goes through omarchohard, keeping its name and types.
  grep -qx "Exec=$OH desktop open word %F" "$APPS/word-o365.desktop"
  grep -qx 'Name=word-o365' "$APPS/word-o365.desktop"
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

# WinApps' setup.sh, answering nothing.
winapps_setup_stub() {
  wa=$XDG_DATA_HOME/omarchohard/winapps
  mkdir -p "$wa"
  printf '#!/bin/sh\nexit 0\n' >"$wa/setup.sh"
  chmod +x "$wa/setup.sh"
}

@test "adding the desktop apps loads Hyprland rules through one line in hyprland.lua, and uninstall takes out only that line" {
  oh_install_quiet
  winapps_setup_stub
  # A dotfiles-managed config: hyprland.lua is a symlink.
  mkdir -p "$HOME/dotfiles" "$XDG_CONFIG_HOME/hypr"
  printf -- '-- mine\no.window("^grok-bot$", { workspace = "special:scratchpad silent" })\n' >"$HOME/dotfiles/hyprland.lua"
  cp "$HOME/dotfiles/hyprland.lua" "$BATS_TEST_TMPDIR/before"
  conf=$XDG_CONFIG_HOME/hypr/hyprland.lua
  ln -s "$HOME/dotfiles/hyprland.lua" "$conf"
  line='pcall(dofile, os.getenv("HOME") .. "/.config/hypr/omarchohard.lua") -- omarchohard'
  run "$OH" desktop apps
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$conf")" = "$line" ]
  [ "$(head -n 2 "$conf")" = "$(cat "$BATS_TEST_TMPDIR/before")" ]
  [ -L "$conf" ]
  rules=$XDG_CONFIG_HOME/hypr/omarchohard.lua
  grep -qxF 'o.window({ title = "^RemoteApp Marker Window$" }, { workspace = "special:omarchohard silent", no_focus = true })' "$rules"
  grep -qxF 'o.window({ title = "^(.+ - (Microsoft )?Word|Microsoft Word)$" }, { tag = "-default-opacity", opacity = "1 1" })' "$rules"
  grep -qxF 'o.window({ title = "^(.+- (Microsoft )?Outlook|Outlook)$" }, { tag = "-default-opacity", opacity = "1 1" })' "$rules"
  [ "$(grep -c 'opacity = "1 1"' "$rules")" -eq 5 ]
  # The guarded line runs and loads all six rules, where Lua is at hand.
  if command -v lua5.4 >/dev/null; then
    printf 'o = { window = function() n = (n or 0) + 1 end }\n%s\nassert(n == 6)\n' "$line" >"$BATS_TEST_TMPDIR/load.lua"
    lua5.4 "$BATS_TEST_TMPDIR/load.lua"
  fi
  # Twice adds nothing.
  run "$OH" desktop apps
  [ "$(grep -cxF "$line" "$conf")" -eq 1 ]
  run "$OH" uninstall
  [ "$status" -eq 0 ]
  cmp "$conf" "$BATS_TEST_TMPDIR/before"
  [ -L "$conf" ]
  [ ! -e "$rules" ]
}

@test "with hyprland.conf instead of the Lua config, no Hyprland file is touched and doctor warns" {
  oh_install_quiet
  vm_stub
  winapps_setup_stub
  mkdir -p "$XDG_CONFIG_HOME/hypr"
  printf 'windowrule = float, class:^(kitty)$\n' >"$XDG_CONFIG_HOME/hypr/hyprland.conf"
  run "$OH" desktop apps
  [ "$status" -eq 0 ]
  [[ $output == *"uses hyprland.conf, not the Lua config"* ]]
  [ "$(ls "$XDG_CONFIG_HOME/hypr")" = hyprland.conf ]
  run "$OH" doctor --json
  [[ $(check "$output" 'hyprland rules') == "warn Hyprland uses hyprland.conf"* ]]
  # With the Lua config the rules load, and doctor says so.
  : >"$XDG_CONFIG_HOME/hypr/hyprland.lua"
  run "$OH" doctor --json
  [[ $(check "$output" 'hyprland rules') == "warn not loaded"* ]]
  "$OH" desktop apps
  run "$OH" doctor --json
  [ "$(check "$output" 'hyprland rules')" = "ok $XDG_CONFIG_HOME/hypr/omarchohard.lua" ]
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

@test "only Microsoft 365 changes channel; other editions are refused, and the VM checks the change took" {
  vm_stub
  mkdir -p "$XDG_CONFIG_HOME/omarchohard"
  printf 'desktop_office=2024\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" desktop update --channel monthly
  [ "$status" -eq 1 ]
  [[ $output == *"only Microsoft 365"* ]]
  [ -z "$(ls -A "$INBOX")" ]
  grep -qF 'channel not changed: this Office edition stays on its own channel' "$BATS_TEST_DIRNAME/../share/omarchohard/vm/inbox.ps1"
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
  # Mid-install, RDP not answering is expected: warn, never "restart the VM".
  office_status installing-office
  run "$OH" doctor --json
  [[ $(check "$output" 'desktop RDP') == "warn no answer on 127.0.0.1:3389 yet"* ]]
  office_status failed 'setup.exe exited with code 17'
  run "$OH" doctor --json
  [ "$status" -eq 1 ]
  [ "$(check "$output" 'desktop Office')" = "fail did not install: setup.exe exited with code 17" ]
}

@test "with no status file, RDP up means ready only on a VM made before 0.2.0" {
  vm_stub
  rdp_listen
  stub winapps 'exit 0'
  winapps_launchers word-o365 excel-o365 powerpoint-o365 outlook-o365 onenote-o365
  printf '❯ Booting Windows using QEMU v10.1.2...\n' >"$HOME/vm.log"
  # A new VM, launchers left from an earlier one: Office is not in yet.
  printf 'services:\n  windows:\n    volumes:\n      - ./storage:/storage\n' >"$XDG_DATA_HOME/omarchohard/vm/compose.yaml"
  [ "$(phase)" = installing-windows ]
  printf 'services:\n  windows:\n    volumes:\n      - data:/storage\n' >"$XDG_DATA_HOME/omarchohard/vm/compose.yaml"
  [ "$(phase)" = ready ]
}

@test "the inbox task finishes a first boot that was cut short" {
  local ps=$BATS_TEST_DIRNAME/../share/omarchohard/vm/inbox.ps1
  grep -qF "if (\$known.phase -in 'installing-office', 'installed') {" "$ps"
  grep -qF "Where-Object { \$_.CommandLine -match 'install\\.bat|office\\.ps1' }" "$ps"
  grep -qF "Set-ItemProperty \$winlogon AutoAdminLogon '0'" "$ps"
  grep -qF "Remove-ItemProperty \$winlogon DefaultPassword" "$ps"
  grep -qF "Write-OfficeStatus 'failed' 'the Office install was interrupted" "$ps"
  # ready before the console sign-out, as in install.bat.
  [ "$(grep -nF "Write-OfficeStatus 'ready'" "$ps" | tail -n1 | cut -d: -f1)" -lt "$(grep -nF 'logoff console' "$ps" | cut -d: -f1)" ]
}

@test "a reinstall after remove --delete-vm starts fresh: no stale status, and setup sees no VM" {
  vm_stub
  office_status failed 'setup.exe exited with code 17'
  # remove --delete-vm asks in a terminal; script(1) gives it one.
  command -v script >/dev/null || skip "script(1) is not installed"
  printf 'DELETE\n' | script -qec "$OH desktop remove --delete-vm" /dev/null >/dev/null 2>&1
  [ ! -e "$INBOX/office-status.json" ]
  [ ! -e "$XDG_DATA_HOME/omarchohard/vm/compose.yaml" ]
  # A status file left beside an empty disk folder goes on install too.
  office_status failed 'old'
  install_stubs
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  [ ! -e "$INBOX/office-status.json" ]
}

agent_on() {
  desktop_preferred
  sed -i '/^desktop_agent=off$/d' "$XDG_CONFIG_HOME/omarchohard/config"
  # shellcheck disable=SC2016
  # A connection whose first.cmd claims its request, as its move line does,
  # and whose agent then beats once, as agent.ps1 does when it starts.
  # shellcheck disable=SC2016
  stub xfreerdp3 'printf "%s\n" "$@" >"$HOME/rdp.args"; cat >"$HOME/rdp.stdin"; a=$XDG_STATE_HOME/omarchohard/agent; for r in "$a"/*.go; do [ -f "$r" ] && mv "$r" "$HOME/claimed"; done; : >"$a/agent.beat"; sleep 0.5'
  # shellcheck disable=SC2016
  stub docker 'case "$1" in inspect) echo running ;; esac; exit 0'
  AGENT=$XDG_STATE_HOME/omarchohard/agent
  mkdir -p "$AGENT" "$HOME/Documents"
}

# Stand in for agent.ps1: claim the first request by renaming it, and keep it.
fake_agent() {
  (
    for _ in $(seq 100); do
      for r in "$AGENT"/*.go; do
        [ -f "$r" ] || continue
        mv "$r" "$r.run" && cp "$r.run" "$BATS_TEST_TMPDIR/request" && rm -f "$r.run"
        exit 0
      done
      sleep 0.1
    done
  ) 3>&- &
}

@test "with the agent up, opening a file is one request file: no new RDP connection, no WinApps" {
  agent_on
  printf '1\n' >"$AGENT/agent.beat"
  : >"$HOME/Documents/Plan, 100%.docx"
  fake_agent
  run "$OH" open "$HOME/Documents/Plan, 100%.docx"
  wait
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/request")" = "$(printf 'word\t%s' '\\tsclient\home\Documents\Plan, 100%.docx')" ]
  [ ! -e "$HOME/rdp.args" ]
  [ ! -e "$HOME/winapps.log" ]
  [ -z "$(ls "$AGENT"/*.go 2>/dev/null)" ]
}

@test "a request the agent leaves is taken back, so it never runs twice" {
  agent_on
  printf '1\n' >"$AGENT/agent.beat"
  # A holder that holds the lock but whose agent never answers.
  exec {lk}>"$AGENT/holder.lock"
  flock -n "$lk"
  run "$OH" desktop open word
  exec {lk}>&-
  [ "$status" -eq 0 ]
  [ -z "$(ls "$AGENT"/*.go 2>/dev/null)" ]
  [ "$(cat "$HOME/winapps.log")" = word-o365 ]
}

@test "the hidden connection passes /printer once, whether or not winapps.conf's RDP_FLAGS has it" {
  agent_on
  for f in '/cert:tofu /sound /microphone +home-drive' '/cert:tofu /sound /microphone +home-drive /printer'; do
    rm -f "$HOME/rdp.args" "$AGENT/agent.beat"
    printf 'RDP_FLAGS="%s"\n' "$f" >>"$XDG_CONFIG_HOME/winapps/winapps.conf"
    run "$OH" desktop open word
    [ "$status" -eq 0 ]
    for _ in $(seq 50); do
      [ -s "$HOME/rdp.args" ] && break
      sleep 0.1
    done
    [ "$(grep -cx /printer "$HOME/rdp.args")" -eq 1 ]
    sleep 1
  done
}

@test "with no agent, the first open starts one hidden connection: password on stdin, app and agent in first.cmd, the monitor's scale" {
  agent_on
  # shellcheck disable=SC2016
  stub hyprctl 'case "$1" in
getoption) echo "{\"option\": \"xwayland:force_zero_scaling\", \"bool\": true, \"set\": true}" ;;
monitors) echo "[{\"focused\":false,\"scale\":1.25},{\"focused\":true,\"scale\":1.6}]" ;;
*) exit 1 ;;
esac'
  : >"$HOME/Documents/Budget 100%.xlsx"
  run "$OH" desktop open excel "$HOME/Documents/Budget 100%.xlsx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/rdp.stdin" ] && break
    sleep 0.1
  done
  [ "$(cat "$HOME/rdp.stdin")" = pw ]
  [ "$(grep -c pw "$HOME/rdp.args")" -eq 0 ]
  grep -qx /from-stdin:force "$HOME/rdp.args"
  grep -qx /scale-desktop:160 "$HOME/rdp.args"
  grep -qx /scale-device:140 "$HOME/rdp.args"
  grep -qx +home-drive "$HOME/rdp.args"
  # Added outside RDP_FLAGS, so a winapps.conf written before it gets it too.
  grep -qx +clipboard "$HOME/rdp.args"
  [ "$(grep -cx /printer "$HOME/rdp.args")" -eq 1 ]
  grep -qxF '/app:program:C:\Windows\System32\conhost.exe,name:omarchohard,cmd:--headless cmd.exe /c \\tsclient\home\.local\state\omarchohard\agent\first.cmd' "$HOME/rdp.args"
  first=$AGENT/first.cmd
  [ "$(cat "$HOME/claimed")" = "$(printf 'excel\t%s' '\\tsclient\home\Documents\Budget 100%.xlsx')" ]
  # first.cmd starts the app only when it claims the request itself.
  q='\\tsclient\home\.local\state\omarchohard\agent'
  n=$(sed -n 3p "$first" | sed -E 's/^move "[^"]*\\([0-9]+-[0-9]+[.]go)" .*/\1/')
  [ "$(sed -n 3p "$first")" = "$(printf 'move "%s\\%s" "%s\\%s.first" >nul 2>&1 && start "" excel "%s"\r' "$q" "$n" "$q" "$n" '\\tsclient\home\Documents\Budget 100%%.xlsx')" ]
  [ "$(sed -n 4p "$first")" = "$(printf 'del "%s\\%s.first" >nul 2>&1\r' "$q" "$n")" ]
  [ "$(sed -n 5p "$first")" = "$(printf 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" -Queue "%s" -Warm "word,excel,powerpoint"\r' '\\tsclient\home\.local\share\omarchohard\vm\agent.ps1' '\\tsclient\home\.local\state\omarchohard\agent')" ]
  cmp "$OH_REPO_ROOT/share/omarchohard/vm/agent.ps1" "$XDG_DATA_HOME/omarchohard/vm/agent.ps1"
  [ ! -e "$HOME/winapps.log" ]
  # The holder lets go once FreeRDP ends.
  for _ in $(seq 50); do
    flock -n "$AGENT/holder.lock" true && break
    sleep 0.1
  done
  flock -n "$AGENT/holder.lock" true
}

@test "a connection that ends before the agent beats opens the app through WinApps, and no warm apps means no -Warm" {
  agent_on
  printf 'desktop_warm=\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  # shellcheck disable=SC2016
  stub xfreerdp3 'cat >/dev/null; exit 131'
  run "$OH" desktop open word
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/winapps.log")" = word-o365 ]
  [ -z "$(ls "$AGENT"/*.go "$AGENT"/*.late 2>/dev/null)" ]
  [ "$(sed -n 5p "$AGENT/first.cmd")" = "$(printf 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" -Queue "%s"\r' '\\tsclient\home\.local\share\omarchohard\vm\agent.ps1' '\\tsclient\home\.local\state\omarchohard\agent')" ]
}

@test "a stopped VM opens the app through WinApps, which says why" {
  agent_on
  # shellcheck disable=SC2016
  stub docker 'case "$1" in inspect) echo exited ;; esac; exit 0'
  run "$OH" desktop open excel
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/winapps.log")" = excel-o365 ]
  [ ! -e "$HOME/rdp.args" ]
}

@test "desktop_agent=off, or a state folder outside home, keeps every launch on WinApps" {
  agent_on
  printf 'desktop_agent=off\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" desktop open powerpoint
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/winapps.log")" = powerpoint-o365 ]
  sed -i '/^desktop_agent=off$/d' "$XDG_CONFIG_HOME/omarchohard/config"
  XDG_STATE_HOME=$BATS_TEST_TMPDIR/state run "$OH" desktop open onenote
  [ "$status" -eq 0 ]
  [ "$(tail -n1 "$HOME/winapps.log")" = onenote-o365 ]
  [ ! -e "$HOME/rdp.args" ]
}

@test "the agent takes only host paths and Office links, and warms apps only once Office is signed in" {
  local ps=$OH_REPO_ROOT/share/omarchohard/vm/agent.ps1
  grep -qF "if (\$Path -notmatch '^\\\\\\\\tsclient\\\\(home|media)\\\\' -or (\$Path -split '\\\\') -contains '..') {" "$ps"
  grep -qF "if (\$arg -notmatch '^(ms-(word|excel|powerpoint)|onenote):') { throw \"refused link: \$arg\" }" "$ps"
  grep -qF "[IO.File]::Move(\$f, \"\$f.run\")" "$ps"
  grep -qF "if (-not \$Warm -or -not (Test-OfficeSignedIn)) { return }" "$ps"
  grep -qF "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND LicenseStatus=1" "$ps"
  grep -qF 'try { Start-WarmApps } catch {' "$ps"
  grep -qF "\$si.UseShellExecute = \$true" "$ps"
  grep -qF "New-Object Threading.Mutex(\$true, 'Local\\omarchohard-agent', [ref]\$created)" "$ps"
}

@test "a cold desktop run opens the file through explorer, so a .bat window closes when it ends" {
  agent_on
  : >"$HOME/Documents/fix it.bat"
  run "$OH" desktop run "$HOME/Documents/fix it.bat"
  [ "$status" -eq 0 ]
  [[ $(sed -n 3p "$AGENT/first.cmd") == *"$(printf ' && explorer.exe "%s"\r' '\\tsclient\home\Documents\fix it.bat')" ]]
  for _ in $(seq 50); do
    flock -n "$AGENT/holder.lock" true && break
    sleep 0.1
  done
}

@test "a request nobody claims after the beat opens through WinApps and leaves nothing queued" {
  agent_on
  # An agent that beats but never runs the request: the old way a session
  # that was only disconnected lost it.
  # shellcheck disable=SC2016
  stub xfreerdp3 'cat >/dev/null; : >"$XDG_STATE_HOME/omarchohard/agent/agent.beat"; sleep 7'
  SECONDS=0
  run "$OH" desktop open word
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/winapps.log")" = word-o365 ]
  [ -z "$(ls "$AGENT"/*.go "$AGENT"/*.late 2>/dev/null)" ]
  [ "$SECONDS" -lt 10 ]
  for _ in $(seq 100); do
    flock -n "$AGENT/holder.lock" true && break
    sleep 0.1
  done
}

current_beat() {
  printf '1 %s\n' "$(sha256sum <"$OH_REPO_ROOT/share/omarchohard/vm/agent.ps1" | cut -d' ' -f1)" >"$AGENT/agent.beat"
}

@test "desktop slim hands slim.ps1 to the agent and prints each step until done" {
  agent_on
  current_beat
  (
    for _ in $(seq 100); do
      for r in "$AGENT"/*.go; do
        [ -f "$r" ] || continue
        mv "$r" "$BATS_TEST_TMPDIR/request"
        log=$AGENT/$(cut -f2 "$BATS_TEST_TMPDIR/request")
        printf '\xef\xbb\xbfstart: 27.21 GB used on C:\r\napps: 0.80 GB freed\r\n' >"$log"
        sleep 1.5
        printf 'done: 20.00 GB used, 7.21 GB freed\r\n' >>"$log"
        exit 0
      done
      sleep 0.1
    done
  ) 3>&- &
  run "$OH" desktop slim
  wait $!
  [ "$status" -eq 0 ]
  re=$'^slim\tslim-[0-9]+[.]log$'
  [[ $(cat "$BATS_TEST_TMPDIR/request") =~ $re ]]
  cmp "$OH_REPO_ROOT/share/omarchohard/vm/slim.ps1" "$XDG_DATA_HOME/omarchohard/vm/slim.ps1"
  [[ $output == *"  start: 27.21 GB used on C:"* ]]
  [[ $output == *"  apps: 0.80 GB freed"* ]]
  [[ $output == *"  done: 20.00 GB used, 7.21 GB freed"* ]]
  [ "$(grep -c 'start:' <<<"$output")" -eq 1 ]
}

@test "desktop slim stops at once when Windows refuses it" {
  agent_on
  current_beat
  printf 'old line\n' >"$AGENT/agent.log"
  (
    for _ in $(seq 100); do
      for r in "$AGENT"/*.go; do
        [ -f "$r" ] || continue
        rm -f "$r"
        printf 'error slim\t%s : refused log name\n' x >>"$AGENT/agent.log"
        exit 0
      done
      sleep 0.1
    done
  ) 3>&- &
  SECONDS=0
  run "$OH" desktop slim
  wait $!
  [ "$status" -ne 0 ]
  [[ $output == *"Windows refused it:"*"refused log name"* ]]
  [ "$SECONDS" -lt 10 ]
}

@test "desktop slim fails when another slim is already running in Windows" {
  agent_on
  current_beat
  (
    for _ in $(seq 100); do
      for r in "$AGENT"/*.go; do
        [ -f "$r" ] || continue
        log=$AGENT/$(cut -f2 "$r")
        rm -f "$r"
        printf '\xef\xbb\xbfbusy: a slim is already running in Windows\r\n' >"$log"
        exit 0
      done
      sleep 0.1
    done
  ) 3>&- &
  SECONDS=0
  run "$OH" desktop slim
  wait $!
  [ "$status" -ne 0 ]
  [[ $output == *"  busy: a slim is already running in Windows"* ]]
  [ "$SECONDS" -lt 10 ]
}

@test "the agent reports a slim that ends before it finishes" {
  local ps=$OH_REPO_ROOT/share/omarchohard/vm/agent.ps1
  # shellcheck disable=SC2016 # PowerShell text, matched as written
  grep -qF 'if ($p.ExitCode -ne 0) { Write-AgentLog "error slim`t$($jobs[$p]) : slim ended with exit code $($p.ExitCode) before it finished" }' "$ps"
}

@test "the agent stays while any window is open, then signs its session out" {
  local ps=$OH_REPO_ROOT/share/omarchohard/vm/agent.ps1
  # shellcheck disable=SC2016 # PowerShell text, matched as written
  grep -qF '[bool](Get-Process | Where-Object { $_.SessionId -eq $session -and $_.MainWindowHandle -ne 0 -and $shell -notcontains $_.ProcessName })' "$ps"
  # shellcheck disable=SC2016 # PowerShell text, matched as written
  grep -qF 'if (Test-InUse) { $last = $now }' "$ps"
  # The sign-out comes last, after the beat is gone, and only with no window.
  [ "$(tail -n4 "$ps")" = "$(printf '%s\n' 'if (-not (Test-SessionWindow)) {' "  Write-AgentLog 'signing the session out'" '  logoff.exe' '}')" ]
}

@test "an agent from before an upgrade gets no slim request" {
  agent_on
  printf '1\n' >"$AGENT/agent.beat"
  run "$OH" desktop slim
  [ "$status" -ne 0 ]
  [[ $output == *"older than this omarchohard"* ]]
  [ -z "$(ls "$AGENT"/*.go 2>/dev/null)" ]
}

@test "with no agent, desktop slim starts one with no app and the request waiting in the queue" {
  agent_on
  # shellcheck disable=SC2016
  stub xfreerdp3 'cat >/dev/null; a=$XDG_STATE_HOME/omarchohard/agent; mv "$a"/*.go "$HOME/queued"; : >"$a/agent.beat"; printf "done\n" >"$a/$(cut -f2 "$HOME/queued")"; sleep 0.5'
  run "$OH" desktop slim
  [ "$status" -eq 0 ]
  re=$'^slim\tslim-[0-9]+[.]log$'
  [[ $(cat "$HOME/queued") =~ $re ]]
  [ "$(sed -n 3p "$AGENT/first.cmd" | cut -d' ' -f1)" = powershell.exe ]
  [ ! -e "$HOME/winapps.log" ]
}

@test "a cold slim whose connection fails leaves no request for the next agent" {
  agent_on
  # shellcheck disable=SC2016
  stub xfreerdp3 'cat >/dev/null; exit 131'
  run "$OH" desktop slim
  [ "$status" -ne 0 ]
  [ -z "$(ls "$AGENT"/*.go "$AGENT"/*.late 2>/dev/null)" ]
}

@test "slim.ps1 keeps Office, its sign-in, Teams and the Store, runs one at a time, spares fresh temp files, and trims" {
  local ps=$OH_REPO_ROOT/share/omarchohard/vm/slim.ps1
  [ "$(grep -cE "'(Microsoft\.Office\.Desktop|MSTeams|Microsoft\.WindowsStore|Microsoft\.DesktopAppInstaller)'" "$ps")" -eq 0 ]
  # Office's sign-in, shared by every Office app, runs through these.
  [ "$(grep -ciE 'AAD\.BrokerPlugin|AccountsControl|CloudExperienceHost|TokenBroker|wlidsvc|IdentityCache|OneAuth' "$ps")" -eq 0 ]
  grep -qF "New-Object Threading.Mutex(\$true, 'Global\\omarchohard-slim', [ref]\$created)" "$ps"
  grep -qF "Where-Object LastWriteTime -LT \$day" "$ps"
  [ "$(grep -c 'AppData.Local.Temp' "$ps")" -eq 1 ]
  grep -qF 'Optimize-Volume -DriveLetter C -ReTrim' "$ps"
  grep -qF "Write-Step (\"done:" "$ps"
  grep -qF "WriteAllText(\$beat, \"\$PID \$self\")" "$OH_REPO_ROOT/share/omarchohard/vm/agent.ps1"
}

@test "opening an app arms an idle-pause timer of its own, so a killed holder cannot keep the VM running" {
  vm_stub
  freerdp_stub
  # shellcheck disable=SC2016
  stub systemd-run 'printf "%s\n" "$@" >"$HOME/systemd-run.args"'
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\nAUTOPAUSE="on"\nAUTOPAUSE_TIME="300"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  : >"$HOME/Notes.docx"
  printf 'paused 0\n' >"$HOME/vm.state"
  run "$OH" desktop run "$HOME/Notes.docx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/systemd-run.args" ] && break
    sleep 0.1
  done
  grep -qx -- --unit=omarchohard-autopause "$HOME/systemd-run.args"
  grep -qx -- --on-active=300s "$HOME/systemd-run.args"
  grep -qx -- --on-unit-inactive=300s "$HOME/systemd-run.args"
  grep -qx -- "--setenv=HOME=$HOME" "$HOME/systemd-run.args"
  grep -qx -- "--setenv=XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "$HOME/systemd-run.args"
  [ "$(tail -n2 "$HOME/systemd-run.args")" = "$(printf 'desktop\nautopause')" ]
}

@test "the idle-pause timer pauses the VM only when no FreeRDP is connected, then stops itself" {
  vm_stub
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf 'RDP_USER="ada"\nRDP_PASS="pw"\nAUTOPAUSE="on"\n' >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  # A FreeRDP connected to the VM, as far as its command line goes.
  sh -c 'sleep 30; :' rdp /v:127.0.0.1:3389 3>&- &
  rdp=$!
  run "$OH" desktop autopause
  [ "$status" -eq 0 ]
  run grep -c pause "$HOME/docker.log"
  [ "$output" = 0 ] || [ "$status" -ne 0 ]
  kill "$rdp"
  wait "$rdp" 2>/dev/null || true
  run "$OH" desktop autopause
  [ "$status" -eq 0 ]
  grep -q 'pause' "$HOME/docker.log"
  grep -qx -- '--user stop omarchohard-autopause.timer' "$HOME/systemctl.log"
  # With no VM config left, the timer stops instead of firing forever.
  rm "$HOME/systemctl.log" "$XDG_CONFIG_HOME/winapps/winapps.conf"
  run "$OH" desktop autopause
  [ "$status" -eq 0 ]
  grep -qx -- '--user stop omarchohard-autopause.timer' "$HOME/systemctl.log"
}
