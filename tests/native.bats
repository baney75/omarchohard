#!/usr/bin/env bats
# Native tier: Office under wine-altars. No Wine runs: wine, wineserver,
# curl, ssh, docker, tailscale and ip are stubs, and seeds are small tar.zst
# files with a fake prefix in them.

load test_helper

setup() {
  oh_sandbox
  export XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  NATIVE=$XDG_DATA_HOME/omarchohard/native
  WINE=$XDG_DATA_HOME/omarchohard/wine
  PREFIX=$NATIVE/prefix
  OFFICE="$PREFIX/drive_c/Program Files/Microsoft Office/root/Office16"
  SEEDNAME=seed-O365ProPlusRetail-16.0.20527.20196.tar.zst
  # bubblewrap that logs its arguments and runs the command after `--`.
  # shellcheck disable=SC2016 # expanded by the stub
  stub bwrap 'printf "%s\n" "$*" >>"$HOME/bwrap.log"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"'
}

# The sandbox is opt-in.
sandbox_on() { export OMARCHOHARD_NATIVE_SANDBOX=1; }

teardown() {
  [ -z "${FAKE_APP:-}" ] || kill "$FAKE_APP" 2>/dev/null || true
}

# A wine-altars tree whose wine and wineserver only log their arguments.
fake_wine() {
  mkdir -p "$WINE/bin"
  # shellcheck disable=SC2016 # expanded by the stub
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$HOME/wine.log"\n' >"$WINE/bin/wine"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$HOME/wineserver.log"\n' >"$WINE/bin/wineserver"
  chmod +x "$WINE/bin/wine" "$WINE/bin/wineserver"
  printf 'v11.19-altars.1\n' >"$WINE/.omarchohard-release"
}

# Office's Click-to-Run section of system.reg, as the fork writes it.
c2r_reg() {
  printf 'WINE REGISTRY Version 2\n\n%s 1794587717\n' '[Software\\Microsoft\\Office\\ClickToRun\\Configuration]'
  printf '"Platform"="x64"\n"ProductReleaseIds"="%s"\n"VersionToReport"="%s"\n\n' "$1" "$2"
}

# make_seed FILE [PRODUCT] [VERSION]: a seed holding a prefix with Word.
make_seed() {
  local out=$1 product=${2:-O365ProPlusRetail} version=${3:-16.0.20527.20196} d
  d=$(mktemp -d "$BATS_TEST_TMPDIR/seed.XXXXXX")
  mkdir -p "$d/prefix/drive_c/Program Files/Microsoft Office/root/Office16"
  : >"$d/prefix/drive_c/Program Files/Microsoft Office/root/Office16/WINWORD.EXE"
  : >"$d/prefix/drive_c/Program Files/Microsoft Office/root/Office16/EXCEL.EXE"
  c2r_reg "$product" "$version" >"$d/prefix/system.reg"
  mkdir -p "${out%/*}"
  tar -C "$d" -cf - prefix | zstd -q -c >"$out"
  rm -rf "$d"
}

# An installed native tier, as a seeded install leaves it.
fake_installed() {
  fake_wine
  mkdir -p "$OFFICE"
  : >"$OFFICE/WINWORD.EXE"
  c2r_reg O365ProPlusRetail 16.0.20527.20196 >"$PREFIX/system.reg"
  : >"$NATIVE/install-done"
}

sha() { sha256sum "$1" | awk '{ print $1 }'; }

# A curl that answers http:// seed links from ~/served by file name.
curl_serving() {
  mkdir -p "$HOME/served"
  # shellcheck disable=SC2016 # expanded by the stub
  stub curl 'printf "%s\n" "$*" >>"$HOME/curl.log"
for a; do url=$a; done
case $url in
http://*/seed*.tar.zst) exec cat "$HOME/served/${url##*/}" ;;
*) exit 22 ;;
esac'
}

# A docker for the remote sign-in: `run` makes the X socket and reads the
# password file, as the container does.
docker_signin() {
  # shellcheck disable=SC2016 # expanded by the stub
  stub docker 'printf "%s\n" "$*" >>"$HOME/docker.log"
case "$1" in
inspect) exit 1 ;;
run)
  for a; do case $a in *:/tmp/.X11-unix) sock=${a%:/tmp/.X11-unix} ;; *:/run/omarchohard) pw=${a%:/run/omarchohard} ;; esac; done
  cp "$pw/pw" "$HOME/seen-pw" && rm -f "$pw/pw"
  python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$sock/X0"
  echo container-id ;;
esac
exit 0'
  # shellcheck disable=SC2016
  stub curl 'printf "%s\n" "$*" >>"$HOME/curl.log"; exit 0'
}

@test "native seed refuses without a seed file" {
  run "$OH" native seed --stdout
  [ "$status" -eq 1 ]
  [[ $output == *"no seed file in $NATIVE"*"a signed-in prefix is never packed"* ]]
  run "$OH" native seed --path
  [ "$status" -eq 1 ]
  run "$OH" native seed serve
  [ "$status" -eq 1 ]
  [[ $output == *"no seed file to serve"* ]]
}

@test "native seed sends the stored seed file and never packs the live prefix" {
  fake_installed
  printf 'stand-in for a signed-in registry\n' >"$PREFIX/user.reg"
  printf 'the stored seed\n' >"$NATIVE/$SEEDNAME"
  # shellcheck disable=SC2016
  stub tar 'printf "%s\n" "$*" >>"$HOME/tar.log"; exit 1'
  # shellcheck disable=SC2016
  stub zstd 'printf "%s\n" "$*" >>"$HOME/zstd.log"; exit 1'
  "$OH" native seed --stdout >"$BATS_TEST_TMPDIR/out"
  cmp "$BATS_TEST_TMPDIR/out" "$NATIVE/$SEEDNAME"
  [ ! -e "$HOME/tar.log" ]
  [ ! -e "$HOME/zstd.log" ]
  run "$OH" native seed --path
  [ "$output" = "$NATIVE/$SEEDNAME" ]
}

@test "native install --from ssh:HOST streams the seed, keeps it with its SHA256 and opens files natively" {
  fake_wine
  make_seed "$BATS_TEST_TMPDIR/remote.tar.zst"
  # shellcheck disable=SC2016
  stub ssh 'printf "%s\n" "$*" >>"$HOME/ssh.log"; exec cat "'"$BATS_TEST_TMPDIR"'/remote.tar.zst"'
  run "$OH" native install --from ssh:laptop --yes
  [ "$status" -eq 0 ]
  [ -f "$OFFICE/WINWORD.EXE" ]
  grep -qF -- '-o BatchMode=yes laptop' "$HOME/ssh.log"
  grep -qF 'omarchohard native seed --stdout' "$HOME/ssh.log"
  cmp "$NATIVE/$SEEDNAME" "$BATS_TEST_TMPDIR/remote.tar.zst"
  [ "$(cat "$NATIVE/$SEEDNAME.sha256")" = "$(sha "$NATIVE/$SEEDNAME")" ]
  [ ! -e "$NATIVE/.incoming" ]
  [ ! -e "$NATIVE/.seed.part" ]
  grep -qx 'open_with=native' "$XDG_CONFIG_HOME/omarchohard/config"
  # Selawik stands in for Segoe UI: five fonts, one registry import.
  for f in selawk selawkb selawkl selawksb selawksl; do
    cmp "$PREFIX/drive_c/windows/Fonts/$f.ttf" "$OH_REPO_ROOT/share/omarchohard/fonts/selawik/$f.ttf"
  done
  [ "$(grep -c '^reg import Z:.*\\.fonts\.reg$' "$HOME/wine.log")" -eq 1 ]
  [ ! -e "$NATIVE/.fonts.reg" ]
  # A rerun with Office in place changes nothing and calls no one.
  rm "$HOME/ssh.log" "$HOME/wine.log"
  run "$OH" native install --yes
  [ "$status" -eq 0 ]
  [[ $output == *"already installed"* ]]
  [ ! -e "$HOME/ssh.log" ]
  [ ! -e "$HOME/wine.log" ]
  run "$OH" native status --json
  [ "$status" -eq 0 ]
  jq -e '.prefix.present and .office.version == "16.0.20527.20196" and .office.product == "O365ProPlusRetail"
    and .office.plans == "school or enterprise" and (.office.apps | index("word")) != null
    and .seed.bytes > 0 and (.seed.sha256 | length) == 64 and .remote_signin == false and .open_with == "native"' <<<"$output"
  run "$OH" native status
  [[ $output == *"AADSTS53000, 53001 or 53003 mean your organization requires a managed Windows device"* ]]
}

@test "an install that stopped after Word is redone from scratch, never counted as installed" {
  fake_wine
  make_seed "$BATS_TEST_TMPDIR/s.tar.zst"
  # Word is in place, but the install stopped before its last steps.
  mkdir -p "$OFFICE" "$NATIVE/office-src"
  : >"$OFFICE/WINWORD.EXE"
  : >"$PREFIX/stopped-here"
  : >"$NATIVE/office-src/kept"
  run "$OH" native install
  [ "$status" -eq 1 ]
  [[ $output == *"an earlier install stopped before it finished"* ]]
  [ -e "$PREFIX/stopped-here" ]
  run "$OH" native install --from "$BATS_TEST_TMPDIR/s.tar.zst" --yes
  [ "$status" -eq 0 ]
  [[ $output != *"already installed"* ]]
  [[ $output == *"stopped before it finished; removing it and installing again"* ]]
  [ ! -e "$PREFIX/stopped-here" ]
  [ -f "$OFFICE/WINWORD.EXE" ]
  [ -f "$NATIVE/$SEEDNAME" ]
  [ -e "$NATIVE/office-src/kept" ]
  [ -f "$NATIVE/install-done" ]
  run "$OH" native install --yes
  [ "$status" -eq 0 ]
  [[ $output == *"already installed"* ]]
}

@test "a bad SHA256 on the Wine download aborts before anything is extracted" {
  make_seed "$BATS_TEST_TMPDIR/s.tar.zst"
  # shellcheck disable=SC2016
  stub curl 'while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done; echo tampered >"$out"'
  # shellcheck disable=SC2016
  stub tar 'printf "%s\n" "$*" >>"$HOME/tar.log"; exit 1'
  run "$OH" native install --from "$BATS_TEST_TMPDIR/s.tar.zst" --yes
  [ "$status" -eq 1 ]
  [[ $output == *"has SHA256 "*", not the pinned 41158b0f0a158b6effee7e7ce7621daafa8b5bc62cdf076aa6505b56393cd382; it was deleted and nothing was extracted"* ]]
  [ ! -e "$HOME/tar.log" ]
  [ ! -e "$WINE" ]
  [ ! -e "$PREFIX" ]
  [ -z "$(find "$NATIVE" -name '*.part')" ]
}

@test "the plan picks the Office product, and shared computers are for school and enterprise only" {
  fake_wine
  stub bsdtar 'exit 0'
  declare -A want=([personal]=O365HomePremRetail [family]=O365HomePremRetail [school]=O365ProPlusRetail
    [business]=O365BusinessRetail [enterprise]=O365ProPlusRetail)
  for plan in personal family school business enterprise; do
    OMARCHOHARD_DRY_RUN=1 run "$OH" native install --yes --plan "$plan"
    [ "$status" -eq 0 ]
    [[ $output == *"Installing Microsoft 365 16.0.0.0 (${want[$plan]})"* ]]
  done
  OMARCHOHARD_DRY_RUN=1 run "$OH" native install --yes
  [ "$status" -eq 0 ]
  [[ $output == *"No --plan given: installing Microsoft 365 Personal and Family (personal)"*"(O365HomePremRetail)"* ]]
  for plan in personal family business; do
    run "$OH" native install --yes --plan "$plan" --shared-computer
    [ "$status" -eq 1 ]
    [[ $output == *"--shared-computer is for --plan school or enterprise"* ]]
  done
  for plan in school enterprise; do
    OMARCHOHARD_DRY_RUN=1 run "$OH" native install --yes --plan "$plan" --shared-computer
    [ "$status" -eq 0 ]
  done
  run "$OH" native install --yes --plan teams
  [ "$status" -eq 1 ]
  [[ $output == *"--plan takes personal, family, school, business, enterprise, not teams"* ]]
}

@test "Word's first start on a hidden screen returns and stops Xvfb, which never exits by itself" {
  fake_wine
  mkdir -p "$OFFICE"
  : >"$OFFICE/WINWORD.EXE"
  # An Xvfb that makes its socket and runs until it is stopped.
  # shellcheck disable=SC2016 # expanded by the stub
  stub Xvfb 'mkdir -p /tmp/.X11-unix
exec python3 -c "
import os, signal, socket, sys, time
path = \"/tmp/.X11-unix/X\" + sys.argv[1].lstrip(\":\")
s = socket.socket(socket.AF_UNIX)
s.bind(path)
open(os.environ[\"HOME\"] + \"/xvfb.pid\", \"w\").write(str(os.getpid()))
def stop(*_):
    os.unlink(path)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(1)
" "$1"'
  # shellcheck disable=SC2016 # expanded by the inner bash
  run timeout 20 bash -c 'set -euo pipefail; OH_ROOT=$1 OH_LIB=$1/lib/omarchohard OH_SHARE=$1/share/omarchohard
    for m in common apps browser integrate open onedrive release doctor desktop native setup agent share; do source "$OH_LIB/$m.sh"; done
    OMARCHOHARD_NATIVE_ABSORB=0 oh_native_step_absorb' _ "$OH_REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ $output == *"Word's first start is done"* ]]
  grep -qF WINWORD.EXE "$HOME/wine.log"
  run kill -0 "$(cat "$HOME/xvfb.pid")"
  [ "$status" -ne 0 ]
}

@test "the ODT configuration carries the product, and SharedComputerLicensing only when asked" {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run bash -c 'set -euo pipefail; OH_ROOT=$1 OH_LIB=$1/lib/omarchohard OH_SHARE=$1/share/omarchohard
    for m in common apps browser integrate open onedrive release doctor desktop native setup agent share; do source "$OH_LIB/$m.sh"; done
    oh_native_odt_config 16.0.1.2 O365BusinessRetail 0; echo ===; oh_native_odt_config 16.0.1.2 O365ProPlusRetail 1' _ "$OH_REPO_ROOT"
  [ "$status" -eq 0 ]
  first=${output%%===*} second=${output#*===}
  [[ $first == *'<Product ID="O365BusinessRetail">'* && $first == *'Version="16.0.1.2" AllowCdnFallback="FALSE"'* ]]
  [[ $first != *SharedComputerLicensing* ]]
  [[ $second == *'<Product ID="O365ProPlusRetail">'* && $second == *'<Property Name="SharedComputerLicensing" Value="1" />'* ]]
}

@test "a seed for another plan is refused, by its contents and by its name, and nothing is kept" {
  fake_wine
  make_seed "$BATS_TEST_TMPDIR/home.tar.zst" O365HomePremRetail
  run "$OH" native install --yes --plan school --from "$BATS_TEST_TMPDIR/home.tar.zst"
  [ "$status" -eq 1 ]
  [[ $output == *"holds O365HomePremRetail (Microsoft 365 personal or family), but --plan school needs O365ProPlusRetail"* ]]
  [ ! -e "$PREFIX" ]
  [ -z "$(find "$NATIVE" -name 'seed-*')" ]
  [ ! -e "$NATIVE/.incoming" ]
  [ ! -e "$NATIVE/.seed.part" ]
  # A seed's name carries its product, so that is refused before any copying.
  cp "$BATS_TEST_TMPDIR/home.tar.zst" "$BATS_TEST_TMPDIR/seed-O365HomePremRetail-16.0.20527.20196.tar.zst"
  # shellcheck disable=SC2016
  stub zstd 'printf "%s\n" "$*" >>"$HOME/zstd.log"; exit 1'
  run "$OH" native install --yes --plan enterprise --from "$BATS_TEST_TMPDIR/seed-O365HomePremRetail-16.0.20527.20196.tar.zst"
  [ "$status" -eq 1 ]
  [[ $output == *"holds O365HomePremRetail"*"--plan enterprise needs O365ProPlusRetail"* ]]
  [ ! -e "$HOME/zstd.log" ]
}

@test "plain http seeds come only from private addresses and only with a matching --sha256" {
  fake_wine
  curl_serving
  make_seed "$HOME/served/$SEEDNAME"
  good=$(sha "$HOME/served/$SEEDNAME")
  link=http://192.168.1.5:6090/0123456789abcdef0123456789abcdef/$SEEDNAME
  run "$OH" native install --yes --from "$link"
  [ "$status" -eq 1 ]
  [[ $output == *"a plain http:// seed needs --sha256"* ]]
  [ ! -e "$HOME/curl.log" ]
  run "$OH" native install --yes --from "http://8.8.8.8:6090/x/$SEEDNAME" --sha256 "$good"
  [ "$status" -eq 1 ]
  [[ $output == *"only from a private address"*"not 8.8.8.8"* ]]
  run "$OH" native install --yes --from "http://evil.example/x/$SEEDNAME" --sha256 "$good"
  [ "$status" -eq 1 ]
  [[ $output == *"not evil.example"* ]]
  run "$OH" native install --yes --from "ftp://192.168.1.5/$SEEDNAME" --sha256 "$good"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/curl.log" ]
  # A changed download is deleted: no seed kept, no prefix.
  bad=$(printf '%064d' 0)
  run "$OH" native install --yes --from "$link" --sha256 "$bad"
  [ "$status" -eq 1 ]
  [[ $output == *"has SHA256 $good, not the $bad given; nothing was kept"* ]]
  [ ! -e "$PREFIX" ]
  [ -z "$(find "$NATIVE" -name 'seed-*' -o -name '.seed.part' -o -name .incoming)" ]
  run "$OH" native install --yes --from "$link" --sha256 "$good"
  [ "$status" -eq 0 ]
  [ -f "$OFFICE/WINWORD.EXE" ]
  [ "$(cat "$NATIVE/$SEEDNAME.sha256")" = "$good" ]
  grep -qF -- '--proto =http' "$HOME/curl.log"
  run grep -E -- '(^| )-L( |$)' "$HOME/curl.log"
  [ "$status" -ne 0 ]
  # Tailnet addresses and names, and the other private ranges, may serve too.
  for host in 100.101.2.3 laptop.tail1234.ts.net 10.0.0.9 172.20.1.1 169.254.3.4; do
    run "$OH" native install --yes --from "http://$host:6090/x/$SEEDNAME"
    [[ $output == *"needs --sha256"* ]]
  done
  for host in 172.32.0.1 100.128.0.1 192.169.0.1 ts.net.evil.example; do
    run "$OH" native install --yes --from "http://$host:6090/x/$SEEDNAME" --sha256 "$good"
    [[ $output == *"not $host"* ]]
  done
}

@test "remote sign-in refuses without Tailscale and starts nothing" {
  fake_installed
  # shellcheck disable=SC2016 # expanded by the stub
  stub docker 'printf "%s\n" "$*" >>"$HOME/docker.log"; exit 0'
  stub tailscale 'exit 1'
  run "$OH" native signin --remote
  [ "$status" -eq 1 ]
  [[ $output == *"Tailscale is not up"*"--lan"* ]]
  [ ! -e "$HOME/docker.log" ]
  [ ! -e "$HOME/systemd-run.log" ]
}

@test "remote sign-in binds only the tailnet address, and the link carries a session password no command line shows" {
  fake_installed
  docker_signin
  # shellcheck disable=SC2016
  stub tailscale 'case "$1 $2" in
"ip -4") echo 100.64.1.2 ;;
"status --json") echo "{\"Self\":{\"DNSName\":\"lab-07.tail1234.ts.net.\",\"HostName\":\"lab-07\"}}" ;;
*) exit 1 ;;
esac'
  run "$OH" native signin --remote --minutes 3 --email ada@school.edu
  [ "$status" -eq 0 ]
  last=$(printf '%s\n' "$output" | tail -n1)
  # The tailnet name, and the password in the fragment, which browsers never send.
  [[ $last =~ ^Sign\ in\ here:\ http://lab-07\.tail1234\.ts\.net:6080/#pw=([A-Za-z0-9]{8})\&device=lab-07$ ]]
  pw=${BASH_REMATCH[1]}
  [[ $output == *"sign in as ada@school.edu"* ]]
  [ "$(cat "$HOME/seen-pw")" = "$pw" ]
  grep -qF -- '-p 100.64.1.2:6080:6080' "$HOME/docker.log"
  run grep -E -- '-p (0\.0\.0\.0:)?[0-9]+:' "$HOME/docker.log"
  [ "$status" -ne 0 ]
  run grep -rF -- "$pw" "$HOME/docker.log" "$HOME/systemd-run.log" "$HOME/curl.log"
  [ "$status" -ne 0 ]
  grep -qx 'signin-watch' "$HOME/systemd-run.log"
  grep -qx '3' "$HOME/systemd-run.log"
  [ ! -e "$XDG_RUNTIME_DIR/omarchohard-signin/pw/pw" ]
}

@test "--lan binds the LAN address for the seed server only; the sign-in page refuses a plain LAN" {
  fake_installed
  docker_signin
  # shellcheck disable=SC2016
  stub ip '[ "$1 $2 $3" = "-4 route get" ] && echo "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.20 uid 1000"'
  stub tailscale 'echo 100.64.1.2'
  # The password typed on the page would cross a plain LAN unencrypted.
  run "$OH" native signin --remote --lan --port 6081
  [ "$status" -eq 1 ]
  [[ $output == *"remote sign-in works only over Tailscale"* ]]
  [ ! -e "$HOME/docker.log" ]
  run "$OH" setup --tier native --yes --remote-signin --lan
  [ "$status" -eq 1 ]
  [[ $output == *"remote sign-in works only over Tailscale"* ]]

  make_seed "$NATIVE/$SEEDNAME"
  OMARCHOHARD_DRY_RUN=1 run "$OH" native seed serve --lan
  [ "$status" -eq 0 ]
  [[ $output == *"seed-serve.py 192.168.1.20 6090 "*"/$SEEDNAME 3600"* ]]
  [[ $(printf '%s\n' "$output" | tail -n1) == "--from http://192.168.1.20:6090/<token>/$SEEDNAME --sha256 $(sha "$NATIVE/$SEEDNAME")" ]]
  [[ $output != *0.0.0.0* ]]
  [ ! -e "$NATIVE/$SEEDNAME.sha256" ]
  OMARCHOHARD_DRY_RUN=1 run "$OH" native seed serve --minutes 5
  [ "$status" -eq 0 ]
  [[ $output == *"seed-serve.py 100.64.1.2 6090 "*"/$SEEDNAME 300"* ]]
  # A machine with no private LAN address is refused, not bound wide.
  # shellcheck disable=SC2016
  stub ip '[ "$1 $2 $3" = "-4 route get" ] && echo "1.1.1.1 dev eth0 src 203.0.113.9 uid 1000"'
  run "$OH" native seed serve --lan
  [ "$status" -eq 1 ]
  [[ $output == *"no private LAN address found (got '203.0.113.9')"* ]]
}

@test "the seed server answers only its token path, for the given time" {
  printf 'seed bytes\n' >"$BATS_TEST_TMPDIR/$SEEDNAME"
  port=$((20000 + RANDOM % 20000))
  tok=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
  OH_SEED_TOKEN=short run python3 "$OH_REPO_ROOT/share/omarchohard/native-remote/seed-serve.py" 127.0.0.1 "$port" "$BATS_TEST_TMPDIR/$SEEDNAME" 5
  [ "$status" -ne 0 ]
  OH_SEED_TOKEN=$tok python3 "$OH_REPO_ROOT/share/omarchohard/native-remote/seed-serve.py" 127.0.0.1 "$port" "$BATS_TEST_TMPDIR/$SEEDNAME" 3 2>"$BATS_TEST_TMPDIR/serve.log" &
  pid=$!
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" && break
    sleep 0.1
  done
  [ "$(curl -fsS "http://127.0.0.1:$port/$tok/$SEEDNAME")" = "seed bytes" ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/$tok/other.tar.zst")" = 404 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/0000/$SEEDNAME")" = 404 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:$port/$tok/$SEEDNAME")" = 200 ]
  wait "$pid"
  run grep -F -- "$tok" "$BATS_TEST_TMPDIR/serve.log"
  [ "$status" -ne 0 ]
  run curl -s "http://127.0.0.1:$port/$tok/$SEEDNAME"
  [ "$status" -ne 0 ]
}

@test "the sign-in page takes the password from the fragment, drops it, and fits only the shared window" {
  page=$OH_REPO_ROOT/share/omarchohard/native-remote/index.html
  grep -qF "import RFB from './core/rfb.js'" "$page"
  grep -qF "new URLSearchParams(location.hash.slice(1))" "$page"
  grep -qF "history.replaceState(null, '', location.pathname)" "$page"
  grep -qF '<meta name="referrer" content="no-referrer">' "$page"
  grep -qF 'prefers-color-scheme' "$page"
  # Never scaled above the real size.
  grep -qF 'Math.min(aw / c.width, ah / c.height, 1)' "$page"
  run grep -E 'location\.search|password=' "$page"
  [ "$status" -ne 0 ]
  entry=$OH_REPO_ROOT/share/omarchohard/native-remote/entry.sh
  # shellcheck disable=SC2016 # a literal line of entry.sh
  grep -qF 'x11vnc -display :0 -R "clip:$clip"' "$entry"
  grep -qF -- '-passwdfile rm:/run/omarchohard/pw' "$entry"
  run grep -iE 'openbox|vnc\.html|/usr/share/novnc 6080' "$entry"
  [ "$status" -ne 0 ]
  # The page in a browser: tests/live/signin-page.cjs, against a live session.
}

@test "dry run prints the plan and changes nothing" {
  # shellcheck disable=SC2016
  stub ssh 'printf "%s\n" "$*" >>"$HOME/ssh.log"'
  # shellcheck disable=SC2016
  stub curl 'printf "%s\n" "$*" >>"$HOME/curl.log"'
  stub bsdtar 'exit 0'
  before=$(cat "$XDG_CONFIG_HOME/omarchohard/config")
  OMARCHOHARD_DRY_RUN=1 run "$OH" native install --yes --from ssh:laptop
  [ "$status" -eq 0 ]
  [[ $output == *"would run: curl "*"wine-altars-linux-x86_64.tar.xz"* ]]
  [[ $output == *"would run: ssh -o BatchMode=yes laptop "*"| tee "*"| zstd -dcq | tar "* ]]
  OMARCHOHARD_DRY_RUN=1 run "$OH" native install --yes --plan business
  [ "$status" -eq 0 ]
  [[ $output == *"wineboot -u"* ]]
  [[ $output == *"setup.exe /configure"* ]]
  [[ $output == *"would run: cp -f -- "*"/fonts/selawik/"*".ttf"* ]]
  [ ! -e "$NATIVE" ]
  [ ! -e "$WINE" ]
  [ ! -e "$HOME/ssh.log" ]
  [ ! -e "$HOME/curl.log" ]
  [ "$(cat "$XDG_CONFIG_HOME/omarchohard/config")" = "$before" ]
}

@test "native run opens files as Wine paths and keeps Wine warm" {
  fake_installed
  mkdir -p "$HOME/Documents/My Docs"
  cp "$FIXTURES/test.docx" "$HOME/Documents/My Docs/Report.docx"
  DISPLAY=:9 run "$OH" native run word "$HOME/Documents/My Docs/Report.docx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/wine.log" ] && break
    sleep 0.1
  done
  home=$(readlink -f "$HOME")
  winpath="Z:${home//\//\\}\\Documents\\My Docs\\Report.docx"
  grep -qF "Office16/WINWORD.EXE $winpath" "$HOME/wine.log"
  grep -qx -- '-p600' "$HOME/wineserver.log"
  grep -qx 'idle-watch' "$HOME/systemd-run.log"
  run "$OH" native run word
  [ "$status" -eq 1 ]
  [[ $output == *"DISPLAY is not set"* ]]
  DISPLAY=:9 run "$OH" native run teams
  [ "$status" -eq 1 ]
}

@test "with open_with=native, open goes through native Office and Teams stays a web app" {
  fake_installed
  printf 'open_with=native\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  cp "$FIXTURES/test.docx" "$HOME/Report.docx"
  DISPLAY=:9 run "$OH" open "$HOME/Report.docx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/wine.log" ] && break
    sleep 0.1
  done
  grep -qF 'WINWORD.EXE Z:' "$HOME/wine.log"
  [ ! -e "$HOME/chromium.log" ]
  DISPLAY=:9 run "$OH" open --app teams
  [ "$status" -eq 0 ]
  grep -qF teams "$HOME/chromium.log"
}

@test "setup --tier native --json: two at once install once, the sign-in is last, and a rerun reports ready" {
  fake_wine
  make_seed "$BATS_TEST_TMPDIR/remote.tar.zst"
  # shellcheck disable=SC2016
  stub ssh 'printf "%s\n" "$*" >>"$HOME/ssh.log"; sleep 1; exec cat "'"$BATS_TEST_TMPDIR"'/remote.tar.zst"'
  args=(setup --yes --tier native --from ssh:laptop --browser chromium --onedrive none --prewarm off --email ada@school.edu --json)
  "$OH" "${args[@]}" >"$BATS_TEST_TMPDIR/a.json" 2>"$BATS_TEST_TMPDIR/a.err" &
  "$OH" "${args[@]}" >"$BATS_TEST_TMPDIR/b.json" 2>"$BATS_TEST_TMPDIR/b.err"
  wait
  [ "$(wc -l <"$HOME/ssh.log")" -eq 1 ]
  states=$(cat "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json" | jq -r .state | sort | paste -sd,)
  [ "$states" = "needs_signin,ready" ]
  for f in a b; do
    [ "$(wc -l <"$BATS_TEST_TMPDIR/$f.json")" -eq 1 ]
    jq -e '(.seconds | type) == "number" and .tier == "native" and .email == "ada@school.edu" and has("signin_url")' "$BATS_TEST_TMPDIR/$f.json"
  done
  # The one that installed ends with the sign-in step.
  for f in a b; do
    if [ "$(jq -r .state "$BATS_TEST_TMPDIR/$f.json")" = needs_signin ]; then
      tail -n1 "$BATS_TEST_TMPDIR/$f.err" | grep -q '^Sign in next: .*ada@school.edu'
    fi
  done
  [ -f "$APPS/omarchohard-teams.desktop" ]
  grep -qx 'open_with=native' "$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" "${args[@]}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n1 | jq -r .state)" = ready ]
  [ "$(wc -l <"$HOME/ssh.log")" -eq 1 ]
}

@test "setup --tier native --remote-signin prints the sign-in link last" {
  fake_wine
  make_seed "$BATS_TEST_TMPDIR/remote.tar.zst"
  # shellcheck disable=SC2016
  stub ssh 'exec cat "'"$BATS_TEST_TMPDIR"'/remote.tar.zst"'
  docker_signin
  stub tailscale 'echo 100.64.1.2'
  run "$OH" setup --yes --tier native --from ssh:laptop --browser chromium --onedrive none --prewarm off --remote-signin
  [ "$status" -eq 0 ]
  [[ $(printf '%s\n' "$output" | tail -n1) =~ ^Sign\ in\ here:\ http://100\.64\.1\.2:6080/#pw=[A-Za-z0-9]{8}\&device=[A-Za-z0-9.-]+$ ]]
  rm -rf "$NATIVE/setup-done"
  run "$OH" native uninstall --yes
  make_seed "$BATS_TEST_TMPDIR/remote.tar.zst"
  fake_wine
  run "$OH" setup --yes --tier native --from ssh:laptop --browser chromium --onedrive none --prewarm off --remote-signin --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | tail -n1 | jq -e '.state == "needs_signin" and (.signin_url | test("^http://100\\.64\\.1\\.2:6080/#pw=[A-Za-z0-9]{8}&device="))'
}

@test "setup --json reports failed when the native install fails or an option is wrong" {
  fake_wine
  stub ssh 'exit 255'
  run "$OH" setup --yes --tier native --from ssh:laptop --browser chromium --onedrive none --prewarm off --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -n1 | jq -r .state)" = failed ]
  [ ! -e "$NATIVE/setup-done" ]
  run "$OH" setup --yes --tier web --from ssh:laptop --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -n1 | jq -r .state)" = failed ]
}

@test "native uninstall asks first and removes Office, the seed and Wine" {
  fake_installed
  printf 'open_with=native\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" native uninstall
  [ "$status" -eq 1 ]
  [ -d "$PREFIX" ]
  run "$OH" native uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -e "$NATIVE" ]
  [ ! -e "$WINE" ]
  grep -qx 'open_with=web' "$XDG_CONFIG_HOME/omarchohard/config"
}

# The bwrap line that started EXE.
box_line() { grep -F -- "$1" "$HOME/bwrap.log" | tail -n1; }

@test "with the sandbox on, Office runs in it: home hidden, only its folders writable, /tmp its own, processes shared" {
  sandbox_on
  fake_installed
  mkdir -p "$HOME/Documents" "$HOME/Elsewhere" "$HOME/OneDrive stand-in" "$HOME/.ssh" "$PREFIX/dosdevices"
  cp "$FIXTURES/test.docx" "$HOME/Documents/Report.docx"
  printf 'onedrive_dir=%s\n' "$HOME/OneDrive stand-in" >>"$XDG_CONFIG_HOME/omarchohard/config"
  DISPLAY=:9 run "$OH" native run word "$HOME/Documents/Report.docx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/wine.log" ] && break
    sleep 0.1
  done
  grep -qxF "$HOME/Documents/Report.docx" <(sed -n 's/^.*WINWORD.EXE Z://p' "$HOME/wine.log" | tr '\134' /)
  [[ $output != *"opens a copy"* ]]
  line=$(box_line WINWORD.EXE)
  tmp=$XDG_STATE_HOME/omarchohard/native/tmp
  [[ $line == "--ro-bind / / --dev-bind /dev /dev "* ]]
  [[ $line == *" --tmpfs $HOME "* ]]
  [[ $line == *" --tmpfs $XDG_RUNTIME_DIR "* ]] || [[ $XDG_RUNTIME_DIR != /run/user/* ]]
  [[ $line == *" --bind $tmp /tmp "* ]]
  [[ $line == *" --ro-bind $WINE $WINE "* ]]
  [[ $line == *" --bind $PREFIX $PREFIX "* ]]
  [[ $line == *" --bind $HOME/Documents $HOME/Documents "* ]]
  [[ $line == *" --bind $HOME/OneDrive stand-in $HOME/OneDrive stand-in "* ]]
  [[ $line == *" --setenv OH_NATIVE_BOX app --unshare-ipc --die-with-parent --new-session -- env "* ]]
  [[ $line != *"--unshare-pid"* && $line != *"--unshare-all"* && $line != *"--unshare-net"* ]]
  [[ $line != *"--bind $HOME $HOME"* && $line != *"$HOME/.ssh"* ]]
  [ "$(stat -c %a "$tmp")" = 700 ]
  # The Wine server opens files for the apps, so it runs in the same
  # sandbox (and /tmp, where every app finds its socket), and outlives the
  # command that starts it.
  server=$(box_line -p600)
  [ "${server%% --setenv*}" = "${line%% --setenv*}" ]
  [[ $server == *" --tmpfs $HOME "* && $server == *" --bind $tmp /tmp "* ]]
  [[ $server == *" --setenv OH_NATIVE_BOX app --unshare-ipc --new-session -- env WINEPREFIX=$PREFIX "* ]]
  [[ $server != *"--dev-bind / /"* && $server != *"--die-with-parent"* ]]
  # OneDrive is drive O:.
  [ "$(readlink "$PREFIX/dosdevices/o:")" = "$HOME/OneDrive stand-in" ]
  # A file outside Office's folders, in the home folder itself or in /tmp,
  # opens as a copy in Office's own /tmp: its folder is never bound, since
  # that could be the whole home or the shared /tmp.
  for f in "$HOME/notes.docx" "$HOME/Elsewhere/Report.docx" "$BATS_TEST_TMPDIR/Invoice.docx"; do
    cp "$FIXTURES/test.docx" "$f"
    rm -f "$HOME/bwrap.log" "$HOME/wine.log"
    DISPLAY=:9 run "$OH" native run word "$f"
    [ "$status" -eq 0 ]
    [[ $output == *"${f##*/} is outside the folders Office can reach"*"opens a copy"* ]]
    for _ in $(seq 50); do
      [ -s "$HOME/wine.log" ] && break
      sleep 0.1
    done
    sed -n 's/^.*WINWORD.EXE Z://p' "$HOME/wine.log" | tr '\134' / | grep -qxE "/tmp/opened/[A-Za-z0-9]{6}/${f##*/}"
    cmp "$f" "$(find "$tmp/opened" -name "${f##*/}" | tail -n1)"
    line=$(box_line WINWORD.EXE)
    [[ $line != *"--bind $HOME $HOME"* && $line != *"--bind ${f%/*} "* && $line != *"--bind /tmp /tmp"* ]]
  done
  # Without OneDrive, no O:; with the sandbox off, no bwrap.
  printf 'onedrive_dir=%s\n' "$HOME/none" >>"$XDG_CONFIG_HOME/omarchohard/config"
  rm "$HOME/bwrap.log" "$HOME/wine.log"
  OMARCHOHARD_NATIVE_SANDBOX=0 DISPLAY=:9 run "$OH" native run word
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/wine.log" ] && break
    sleep 0.1
  done
  [ ! -e "$PREFIX/dosdevices/o:" ]
  [ ! -e "$HOME/bwrap.log" ]
}

@test "by default Office runs as plain Wine, with no bwrap, and opens a file anywhere in place" {
  fake_installed
  # shellcheck disable=SC2016
  stub notify-send 'printf "%s\n" "$*" >>"$HOME/notify.log"'
  cp "$FIXTURES/test.docx" "$HOME/notes.docx"
  DISPLAY=:9 run "$OH" native run word "$HOME/notes.docx"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/wine.log" ] && break
    sleep 0.1
  done
  home=$(readlink -f "$HOME")
  grep -qF "Office16/WINWORD.EXE Z:${home//\//\\}\\notes.docx" "$HOME/wine.log"
  grep -qx -- '-p600' "$HOME/wineserver.log"
  [[ $output != *"opens a copy"* ]]
  [ ! -e "$HOME/bwrap.log" ]
  [ ! -e "$HOME/notify.log" ]
  [ ! -e "$XDG_STATE_HOME/omarchohard/native/tmp/opened" ]
}

@test "with the sandbox on, a copy opened with no terminal (a file manager) is also a desktop notification" {
  sandbox_on
  fake_installed
  # shellcheck disable=SC2016
  stub notify-send 'printf "%s\n" "$*" >>"$HOME/notify.log"'
  mkdir -p "$HOME/Documents"
  cp "$FIXTURES/test.docx" "$HOME/Documents/Report.docx"
  DISPLAY=:9 run "$OH" native run word "$HOME/Documents/Report.docx"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/notify.log" ]
  cp "$FIXTURES/test.docx" "$HOME/notes.docx"
  DISPLAY=:9 run "$OH" native run word "$HOME/notes.docx" </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"opens a copy"* ]]
  grep -qF -- '-a omarchohard -u critical Office opened a copy of notes.docx notes.docx is outside Documents' "$HOME/notify.log"
  grep -qF 'Save it into one of them to keep your changes.' "$HOME/notify.log"
}

@test "the prefix is 700, the seed and its SHA256 600, and install turns on the weekly update timer" {
  fake_wine
  make_seed "$BATS_TEST_TMPDIR/in/$SEEDNAME"
  run "$OH" native install --from "$BATS_TEST_TMPDIR/in/$SEEDNAME" --yes
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$PREFIX")" = 700 ]
  [ "$(stat -c %a "$NATIVE/$SEEDNAME")" = 600 ]
  [ "$(stat -c %a "$NATIVE/$SEEDNAME.sha256")" = 600 ]
  units=$XDG_CONFIG_HOME/systemd/user
  grep -qx 'ConditionACPower=true' "$units/omarchohard-native-update.service"
  grep -qE '^ExecStart=".*/omarchohard" native update --auto$' "$units/omarchohard-native-update.service"
  grep -qx 'OnCalendar=weekly' "$units/omarchohard-native-update.timer"
  grep -qx 'RandomizedDelaySec=6h' "$units/omarchohard-native-update.timer"
  grep -qx 'Persistent=true' "$units/omarchohard-native-update.timer"
  grep -qx -- '--user enable --now omarchohard-native-update.timer' "$HOME/systemctl.log"
  run "$OH" native status --json
  [ "$(jq -r .update.timer <<<"$output")" = true ]
  run "$OH" native uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -e "$units/omarchohard-native-update.timer" ]
  [ ! -e "$units/omarchohard-native-update.service" ]
  grep -qx -- '--user disable --now omarchohard-native-update.timer' "$HOME/systemctl.log"
}

@test "prewarm on writes a login unit that keeps Wine warm, prewarm-run starts it, and off removes it" {
  sandbox_on
  run "$OH" native prewarm on
  [ "$status" -eq 1 ]
  [[ $output == *"not set up yet"* ]]
  fake_installed
  run "$OH" native prewarm on
  [ "$status" -eq 0 ]
  unit=$XDG_CONFIG_HOME/systemd/user/omarchohard-native-prewarm.service
  grep -qE '^ExecStart=".*/omarchohard" native prewarm-run$' "$unit"
  grep -qx 'WantedBy=graphical-session.target' "$unit"
  # Stopping the unit must not take open Office apps with it.
  grep -qx 'KillMode=process' "$unit"
  grep -qx -- '--user enable --now omarchohard-native-prewarm.service' "$HOME/systemctl.log"
  run "$OH" native prewarm-run
  [ "$status" -eq 0 ]
  grep -qx 'cmd.exe /c exit' "$HOME/wine.log"
  [ "$(head -n1 "$HOME/wineserver.log")" = -p ]
  [ "$(tail -n1 "$HOME/wineserver.log")" = -w ]
  # The persistent server starts in the apps' sandbox.
  [[ $(box_line ' -p') == *" --tmpfs $HOME "*" --setenv OH_NATIVE_BOX app --unshare-ipc --new-session -- env WINEPREFIX=$PREFIX "* ]]
  run "$OH" native prewarm off
  [ "$status" -eq 0 ]
  [ "$(grep -c -- -k "$HOME/wineserver.log")" -eq 0 ]
  [ ! -e "$unit" ]
  grep -qx -- '--user disable --now omarchohard-native-prewarm.service' "$HOME/systemctl.log"
}

@test "with open_with=native and mail on, mailto links open a new message in Outlook; with mail=0 the web app" {
  fake_installed
  : >"$OFFICE/OUTLOOK.EXE"
  printf 'open_with=native\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  DISPLAY=:9 run "$OH" open 'mailto:ada@example.com?subject=Hi'
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do
    [ -s "$HOME/wine.log" ] && break
    sleep 0.1
  done
  grep -qxF 'C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE /c ipm.note /m ada@example.com?subject=Hi' "$HOME/wine.log" ||
    grep -qF 'Office16/OUTLOOK.EXE /c ipm.note /m ada@example.com?subject=Hi' "$HOME/wine.log"
  [ ! -e "$HOME/chromium.log" ]
  printf 'mail=0\n' >>"$XDG_CONFIG_HOME/omarchohard/config"
  rm "$HOME/wine.log"
  DISPLAY=:9 run "$OH" open 'mailto:ada@example.com'
  [ "$status" -eq 0 ]
  grep -qF 'https://outlook.office.com/mail/deeplink/compose?to=ada@example.com' "$HOME/chromium.log"
  [ ! -e "$HOME/wine.log" ]
}

@test "the remote sign-in starts Word again when it closes, logs each exit, and ends with its screen" {
  fake_installed
  # shellcheck disable=SC2016
  stub docker 'printf "%s\n" "$*" >>"$HOME/docker.log"; exit 0'
  sock=$XDG_RUNTIME_DIR/omarchohard-signin/xsock/X0
  mkdir -p "${sock%/*}"
  python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$sock"
  # Word exits at once; the third time, the screen goes too (signin --stop).
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$HOME/wine.log"\n[ "$(wc -l <"$HOME/wine.log")" -ge 3 ] && rm -f "%s"\nexit 1\n' "$sock" >"$WINE/bin/wine"
  run "$OH" native signin-watch 5 "unix:$sock"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WINWORD.EXE' "$HOME/wine.log")" -eq 3 ]
  log=$XDG_STATE_HOME/omarchohard/native/signin.log
  [ "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z Word exited \(code 1\); starting it again$' "$log")" -eq 2 ]
  grep -qE 'remote sign-in started for 5 minutes$' "$log"
  grep -qE 'remote sign-in stopped$' "$log"
  grep -qx 'rm -f omarchohard-native-signin' "$HOME/docker.log"
  [ ! -e "$XDG_RUNTIME_DIR/omarchohard-signin" ]
}

# Office's Current channel at VERSION, and an ODT whose /configure moves the
# prefix to the version in its configuration.xml.
cdn_and_odt() {
  office_cdn "$1"
  mv "$STUBS/curl" "$STUBS/curl-cdn"
  # shellcheck disable=SC2016
  stub curl 'for a; do url=$a; done
case $url in
https://officecdn.microsoft.com/pr/wsus/setup.exe)
  printf "%s\n" "$*" >>"$HOME/odt.log"
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { : >"$2"; break; }; shift; done ;;
*) exec curl-cdn "$@" ;;
esac'
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$HOME/wine.log"\ncase "$*" in *"/configure "*)\n  v=$(sed -n "s/.* Version=\\"\\([0-9.]*\\)\\".*/\\1/p" "%s/dl/configuration.xml")\n  sed -i "s/\\"VersionToReport\\"=\\"[0-9.]*\\"/\\"VersionToReport\\"=\\"$v\\"/" "%s/system.reg" ;;\nesac\n' "$NATIVE" "$PREFIX" >"$WINE/bin/wine"
}

@test "native update --check compares with the Current channel and changes nothing" {
  fake_installed
  printf 'kept\n' >"$NATIVE/$SEEDNAME"
  office_cdn 16.0.20527.20196
  run "$OH" native update --check
  [ "$status" -eq 0 ]
  [[ $output == *"Office 16.0.20527.20196 is current"* ]]
  office_cdn 16.0.20600.20010
  run "$OH" native update --check
  [ "$status" -eq 0 ]
  [[ $output == *"Office 16.0.20600.20010 is out; this device has 16.0.20527.20196"* ]]
  [ ! -e "$NATIVE/office-src" ]
  [ ! -e "$HOME/wine.log" ]
  run "$OH" native status --json
  [ "$(jq -r .update.installed <<<"$output")" = 16.0.20527.20196 ]
  [ "$(jq -r .update.latest <<<"$output")" = 16.0.20600.20010 ]
  [ "$(jq -r .update.available <<<"$output")" = true ]
  [ "$(jq -r .seed.older_than_office <<<"$output")" = false ]
  run "$OH" native status
  [[ $output == *"update available: Office 16.0.20600.20010 (omarchohard native update)"* ]]
}

@test "native update installs the newer Office in place, keeps the seed, and says the seed is older" {
  fake_installed
  printf 'pre-sign-in seed\n' >"$NATIVE/$SEEDNAME"
  cp "$NATIVE/$SEEDNAME" "$BATS_TEST_TMPDIR/seed.before"
  cdn_and_odt 16.0.20600.20010
  run "$OH" native update
  [ "$status" -eq 0 ]
  [[ $output == *"Office updated to 16.0.20600.20010"* ]]
  grep -qF 'Version="16.0.20600.20010"' "$NATIVE/dl/configuration.xml"
  grep -qF '<Product ID="O365ProPlusRetail">' "$NATIVE/dl/configuration.xml"
  grep -qF 'setup.exe /configure Z:' "$HOME/wine.log"
  grep -qF '"VersionToReport"="16.0.20600.20010"' "$PREFIX/system.reg"
  # The seed is the same file; the live prefix was never packed.
  cmp "$NATIVE/$SEEDNAME" "$BATS_TEST_TMPDIR/seed.before"
  [ "$(find "$NATIVE" -maxdepth 1 -name 'seed-*.tar.zst' | wc -l)" -eq 1 ]
  [ ! -e "$NATIVE/office-src" ]
  run "$OH" native status --json
  [ "$(jq -r .update.installed <<<"$output")" = 16.0.20600.20010 ]
  [ "$(jq -r .update.result <<<"$output")" = "updated to 16.0.20600.20010" ]
  [ "$(jq -r .seed.version <<<"$output")" = 16.0.20527.20196 ]
  [ "$(jq -r .seed.older_than_office <<<"$output")" = true ]
}

@test "native update waits while an Office app is open, and the timer's run asks Microsoft at most once in 6 days" {
  fake_installed
  office_cdn 16.0.20600.20010
  # A process that looks like this prefix's Word.
  WINEPREFIX=$PREFIX sh -c 'sleep 60; :' "$OFFICE/WINWORD.EXE" &
  FAKE_APP=$!
  sleep 0.3
  run "$OH" native update
  [ "$status" -eq 1 ]
  [[ $output == *"close Word, Excel, PowerPoint, Outlook and OneNote first"* ]]
  run "$OH" native update --auto
  [ "$status" -eq 0 ]
  run "$OH" native status --json
  [ "$(jq -r .update.result <<<"$output")" = "skipped: Office was open (16.0.20600.20010 is waiting)" ]
  run grep -qs configure "$HOME/wine.log"
  [ "$status" -ne 0 ]
  kill "$FAKE_APP"
  FAKE_APP=''
  # Current, and checked today: the timer's run does not ask again.
  office_cdn 16.0.20527.20196
  run "$OH" native update --check
  rm -f "$HOME/curl.log"
  run "$OH" native update --auto
  [ "$status" -eq 0 ]
  [[ $output == *"next check 6 days after that"* ]]
  [ ! -e "$HOME/curl.log" ]
}

# A process that looks like this prefix's Wine server (pgrep -x wineserver).
fake_server() {
  mkdir -p "$BATS_TEST_TMPDIR/fake"
  printf '#!/bin/sh\nwhile :; do sleep 0.2; done\n' >"$BATS_TEST_TMPDIR/fake/wineserver"
  chmod +x "$BATS_TEST_TMPDIR/fake/wineserver"
  WINEPREFIX=$PREFIX "$BATS_TEST_TMPDIR/fake/wineserver" &
  FAKE_APP=$!
  printf '%s\n' "$FAKE_APP" >"$HOME/server.pid"
  sleep 0.3
}

@test "native update stops a Wine server left running (and prewarm) first, and waits when it will not stop" {
  fake_installed
  cdn_and_odt 16.0.20600.20010
  fake_server
  # A server -k cannot reach: no update runs under it.
  run "$OH" native update
  [ "$status" -eq 1 ]
  [[ $output == *"Office's Wine server (pid $FAKE_APP) did not stop"* ]]
  run grep -qs configure "$HOME/wine.log"
  [ "$status" -ne 0 ]
  run "$OH" native update --auto
  [ "$status" -eq 0 ]
  run "$OH" native status --json
  [ "$(jq -r .update.result <<<"$output")" = "skipped: Office's Wine server was running (16.0.20600.20010 is waiting)" ]
  run grep -qs configure "$HOME/wine.log"
  [ "$status" -ne 0 ]
  # One -k stops, with prewarm on: prewarm stops first and starts again after.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$HOME/wineserver.log"\n[ "$1" = -k ] && kill "$(cat "$HOME/server.pid")" 2>/dev/null\nexit 0\n' >"$WINE/bin/wineserver"
  # shellcheck disable=SC2016
  stub systemctl 'printf "%s\n" "$*" >>"$HOME/systemctl.log"; exit 0'
  rm -f "$HOME/wineserver.log" "$HOME/systemctl.log"
  run "$OH" native update
  [ "$status" -eq 0 ]
  [[ $output == *"Office updated to 16.0.20600.20010"* ]]
  [ "$(head -n1 "$HOME/wineserver.log")" = -k ]
  grep -qF 'setup.exe /configure Z:' "$HOME/wine.log"
  [ "$(grep -n -- '--user stop omarchohard-native-prewarm.service' "$HOME/systemctl.log" | cut -d: -f1)" -lt "$(grep -n -- '--user start omarchohard-native-prewarm.service' "$HOME/systemctl.log" | cut -d: -f1)" ]
}
