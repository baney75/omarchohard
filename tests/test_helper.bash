# shellcheck shell=bash
# shellcheck disable=SC2034 # globals for the .bats files
# Shared setup for the bats suite. Every test gets its own HOME and XDG
# directories, a stub chromium, systemctl, hyprctl and notify-send on PATH,
# and config browser=chromium. Nothing touches the real session.

OH_REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
OH=$OH_REPO_ROOT/bin/omarchohard
FIXTURES=$OH_REPO_ROOT/tests/fixtures

oh_sandbox() {
  export HOME=$BATS_TEST_TMPDIR/home
  export XDG_CONFIG_HOME=$HOME/.config
  export XDG_DATA_HOME=$HOME/.local/share
  export XDG_STATE_HOME=$HOME/.local/state
  export XDG_CACHE_HOME=$HOME/.cache
  export OMARCHOHARD_NO_UWSM=1
  export NO_COLOR=1
  # xdg-open only consults desktop entries when a display is set.
  export WAYLAND_DISPLAY=oh-test
  unset DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP OMARCHOHARD_DRY_RUN
  unset OMARCHOHARD_RELEASE_BASE OMARCHOHARD_ROOT OMARCHOHARD_BROWSER_FLAGS BROWSER
  STUBS=$BATS_TEST_TMPDIR/stubs
  APPS=$XDG_DATA_HOME/applications
  MIMEAPPS=$XDG_CONFIG_HOME/mimeapps.list
  mkdir -p "$HOME" "$STUBS" "$APPS" "$XDG_CONFIG_HOME/omarchohard"
  export PATH=$HOME/.local/bin:$STUBS:$PATH

  # shellcheck disable=SC2016 # stub bodies expand at run time
  stub chromium 'printf "%s\n" "$*" >>"$HOME/chromium.log"'
  # shellcheck disable=SC2016
  stub systemctl 'printf "%s\n" "$*" >>"$HOME/systemctl.log"; case " $* " in *" is-active "*) exit 3 ;; esac; exit 0'
  stub hyprctl 'exit 1'
  # No test starts a real user service, so no test starts a real download.
  # shellcheck disable=SC2016
  stub systemd-run 'printf "%s\n" "$@" >>"$HOME/systemd-run.log"'
  stub notify-send 'exit 0'
  printf 'browser=chromium\n' >"$XDG_CONFIG_HOME/omarchohard/config"
}

# stub NAME BODY: a shell script on PATH that runs BODY.
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# A dummy desktop entry other apps can be assigned to.
dummy_app() {
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=/bin/true %%U\n' "$1" >"$APPS/$1.desktop"
}

mime_default() { xdg-mime query default "$1"; }

# Normalize a mimeapps.list for comparison: drop blank lines, sort.
mimeapps_norm() { grep -v '^[[:space:]]*$' "$1" | sort; }

oh_install_quiet() { "$OH" install "$@" >/dev/null 2>&1; }

# Office's Current channel on Microsoft's CDN, as lib/omarchohard/desktop.sh has it.
OFFICE_CDN=https://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60

# A fake CDN in ~/cdn serving Office VERSION, with a curl that answers from
# it (HEAD, whole files and byte ranges; every call in ~/curl.log and its
# arguments in ~/curl.args) and a bsdtar that reads v64.cab as the XML it
# holds. stream.x64.x-none.dat is 33 MiB, so it comes in byte ranges. A
# FILE.len next to a file gives the size HEAD reports instead of its own.
office_cdn() {
  local v=$1 d=$HOME/cdn/Office/Data
  mkdir -p "$d/$v"
  printf '<Version>\n  <Available Build="%s" I640Version="%s" I320Version="%s" />\n</Version>\n' "$v" "$v" "$v" >"$d/v64.cab"
  printf 'cab %s\n' "$v" >"$d/v64_$v.cab"
  for f in i640.cab s640.cab s641033.cab stream.x64.en-us.dat; do printf '%s %s\n' "$f" "$v" >"$d/$v/$f"; done
  head -c $((33 * 1024 * 1024 + 5)) /dev/urandom >"$d/$v/stream.x64.x-none.dat"
  # shellcheck disable=SC2016 # expanded by the stub
  stub curl 'printf "%s\n" "$*" >>"$HOME/curl.args"
url="" out="" range="" head=0
while [ $# -gt 0 ]; do
  case $1 in
  -o) out=$2; shift ;;
  -r) range=$2; shift ;;
  -I) head=1 ;;
  https://*) url=$1 ;;
  esac
  shift
done
if [ $head = 1 ]; then echo "HEAD $url"; elif [ -n "$range" ]; then echo "GET $range $url"; else echo "GET $url"; fi >>"$HOME/curl.log"
base='"$OFFICE_CDN"'/
case $url in "$base"*) ;; *) exit 6 ;; esac
f=$HOME/cdn/${url#"$base"}
[ -f "$f" ] || exit 22
if [ $head = 1 ]; then
  len=$(cat "$f.len" 2>/dev/null || wc -c <"$f")
  printf "HTTP/2 200\r\ncontent-length: %s\r\n\r\n" "$len"
elif [ -n "$range" ]; then
  s=${range%-*} e=${range#*-}
  tail -c +$((s + 1)) "$f" | head -c $((e - s + 1)) >"$out"
else
  cat "$f" >"$out"
fi'
  # shellcheck disable=SC2016
  stub bsdtar '[ "$1" = -xOf ] && [ "$3" = VersionDescriptor.xml ] && exec cat "$2"; exit 1'
}

# The files of Office VERSION's local source, one per line.
office_src_files() {
  printf '%s\n' "Office/Data/v64_$1.cab"
  for f in i640.cab s640.cab s641033.cab stream.x64.en-us.dat stream.x64.x-none.dat; do printf 'Office/Data/%s/%s\n' "$1" "$f"; done
}
