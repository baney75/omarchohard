#!/usr/bin/env bash
# Container install test (run by tests/container/run.sh install, as a non-root
# user in a clean Arch container). Builds all three channels into a release
# tree, serves it over HTTP, then for each channel in a fresh HOME:
#   curl .../install.sh | bash -s -- --channel C
#   omarchohard install, doctor, file handler defaults
#   channel nightly, channel dev, channel stable (each checked by version)
#   uninstall leaves no omarchohard-*.desktop
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
cp -a /src "$work/src"
rb=$work/release-base
echo "-- building release tree"
"$work/src/scripts/release-base.sh" "$rb"

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$rb" >"$work/http.log" 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT
base=http://127.0.0.1:$port
for _ in $(seq 50); do
  curl -fs "$base/install.sh" >/dev/null && break
  sleep 0.1
done

declare -A want=(
  [stable]=$(cat "$rb/latest/download/omarchohard.version")
  [nightly]=$(cat "$rb/download/nightly/omarchohard.version")
  [dev]=$(cat "$rb/download/dev/omarchohard.version")
)
declare -A fixture_app=(["test.docx"]=word ["test.xlsx"]=excel ["test.pptx"]=powerpoint)

stubs=$work/stubs
mkdir -p "$stubs"
printf '#!/bin/sh\nexit 0\n' >"$stubs/chromium"
chmod +x "$stubs/chromium"

expect_version() {
  local got
  got=$(omarchohard version)
  [[ $got == "omarchohard $1" ]] || fail "expected version $1, got '$got'"
  echo "   version: $1"
}

for channel in stable nightly dev; do
  echo "-- channel $channel"
  (
    export HOME=$work/home-$channel
    mkdir -p "$HOME"
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
    export PATH=$HOME/.local/bin:$stubs:$PATH
    export OMARCHOHARD_RELEASE_BASE=$base OMARCHOHARD_NO_UWSM=1 NO_COLOR=1

    curl -fsSL "$base/install.sh" | bash -s -- --channel "$channel"
    expect_version "${want[$channel]}"
    grep -qx "channel=$channel" "$HOME/.config/omarchohard/config" || fail "config channel is not $channel"
    printf 'browser=chromium\n' >>"$HOME/.config/omarchohard/config"

    omarchohard install >/dev/null 2>&1 || fail "omarchohard install"
    omarchohard doctor || fail "doctor after install"

    for f in "${!fixture_app[@]}"; do
      type=$(xdg-mime query filetype "$work/src/tests/fixtures/$f")
      default=$(xdg-mime query default "$type")
      [[ $default == "omarchohard-${fixture_app[$f]}.desktop" ]] || fail "$f ($type) opens with '$default'"
      echo "   $f -> $default"
    done

    for next in nightly dev stable; do
      omarchohard channel "$next" >/dev/null 2>&1 || fail "channel $next"
      expect_version "${want[$next]}"
    done
    omarchohard doctor >/dev/null 2>&1 || fail "doctor after channel switches"

    omarchohard uninstall >/dev/null 2>&1 || fail "uninstall"
    left=$(find "$HOME/.local/share/applications" -name 'omarchohard-*.desktop' 2>/dev/null)
    [[ -z $left ]] || fail "uninstall left: $left"
    echo "   uninstall: no omarchohard-*.desktop left"
  )
done
echo "install-test: all three channels passed"
