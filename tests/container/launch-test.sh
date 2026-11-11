#!/usr/bin/env bash
# Launch smoke test (run by tests/container/run.sh launch). Starts a headless
# sway and real Chromium, runs `omarchohard launch APP` for each app and waits
# for a window whose app_id contains the app's host. Prints ms to window.
#
# Chromium cannot use its sandbox in an unprivileged container, so this passes
# --no-sandbox through OMARCHOHARD_BROWSER_FLAGS, a test-only hook.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  [[ -f ${work:-}/sway.log ]] && tail -n 20 "$work/sway.log" >&2
  exit 1
}

work=$(mktemp -d)
export HOME=$work/home XDG_RUNTIME_DIR=$work/run
mkdir -p "$HOME/.config/omarchohard"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
export OMARCHOHARD_NO_UWSM=1 NO_COLOR=1
export OMARCHOHARD_BROWSER_FLAGS='--no-sandbox --ozone-platform=wayland --disable-gpu --disable-dev-shm-usage --password-store=basic'

printf 'output HEADLESS-1 resolution 1920x1080\n' >"$work/sway.conf"
sway -c "$work/sway.conf" >"$work/sway.log" 2>&1 &
sway_pid=$!
trap 'pkill -u "$(id -u)" chromium 2>/dev/null || true; kill "$sway_pid" 2>/dev/null || true' EXIT

for _ in $(seq 100); do
  sock=$(compgen -G "$XDG_RUNTIME_DIR/sway-ipc.*.sock" | head -n1 || true)
  wl=$(compgen -G "$XDG_RUNTIME_DIR/wayland-[0-9]" | head -n1 || true)
  [[ -n $sock && -n $wl ]] && break
  sleep 0.1
done
[[ -n $sock && -n $wl ]] || fail "sway did not start"
export SWAYSOCK=$sock WAYLAND_DISPLAY=${wl##*/}
swaymsg -t get_version >/dev/null || fail "swaymsg cannot reach sway"
echo "-- sway $(swaymsg -t get_version -r | jq -r .human_readable), $(chromium --version)"

oh=/src/bin/omarchohard
printf 'browser=chromium\n' >"$HOME/.config/omarchohard/config"
"$oh" install >/dev/null 2>&1 || fail "omarchohard install"

app_ids() { swaymsg -t get_tree -r | jq -r '.. | objects | select(.app_id? != null) | .app_id'; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }

for app in word excel powerpoint outlook onenote teams onedrive; do
  host=$app.cloud.microsoft
  start=$(now_ms)
  "$oh" launch "$app" || fail "launch $app"
  found=''
  while (($(now_ms) - start < 30000)); do
    found=$(app_ids | grep -F "$host" | head -n1 || true)
    [[ -n $found ]] && break
    sleep 0.02
  done
  [[ -n $found ]] || fail "$app: no window with app_id containing $host after 30 s (have: $(app_ids | tr '\n' ' '))"
  printf '   %-10s %5d ms  %s\n' "$app" "$(($(now_ms) - start))" "$found"
done
echo "launch-test: all 7 apps mapped a window"
