#!/bin/sh
# Xvfb on :0 with no window manager, x11vnc on it for this container only,
# and the sign-in page on port 6080. The one-time password is read from
# /run/omarchohard/pw, which x11vnc deletes once it has read it (rm:), so it
# is never on a command line.
set -eu
screen=${OH_SCREEN:-1000x720x24}
Xvfb :0 -screen 0 "$screen" -nolisten tcp -nolisten local >/tmp/xvfb.log 2>&1 &
i=0
while [ ! -S /tmp/.X11-unix/X0 ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || {
    echo "Xvfb did not start" >&2
    exit 1
  }
  sleep 0.1
done
x11vnc -display :0 -localhost -rfbport 5900 -passwdfile rm:/run/omarchohard/pw \
  -forever -shared -quiet -noxdamage >/tmp/x11vnc.log 2>&1 &

# Share only the topmost window that is at least 300x200 and is not Word's
# main window or one of Office's hidden helpers: the sign-in dialog, then
# Microsoft's sign-in window, so a phone shows it full size.
follow() {
  last=''
  while sleep 0.5; do
    clip=''
    for id in $(xwininfo -display :0 -root -children 2>/dev/null | awk '/^ +0x/ { print $1 }'); do
      info=$(xwininfo -display :0 -id "$id" 2>/dev/null) || continue
      printf '%s\n' "$info" | grep -q 'Map State: IsViewable' || continue
      printf '%s\n' "$info" | grep -qE '"(Microsoft Word|Default IME|OfficePowerManagerWindow|HardwareMonitorWindow)"' && continue
      geo=$(printf '%s\n' "$info" | awk '
        /Absolute upper-left X:/ { x = $4 } /Absolute upper-left Y:/ { y = $4 }
        /^  Width:/ { w = $2 } /^  Height:/ { h = $2 }
        END { if (w >= 300 && h >= 200) printf "%dx%d+%d+%d", w, h, x, y }')
      [ -z "$geo" ] || clip=$geo
    done
    [ -n "$clip" ] || clip=${screen%x*}+0+0
    if [ "$clip" != "$last" ]; then
      x11vnc -display :0 -R "clip:$clip" >/dev/null 2>&1 || true
      last=$clip
    fi
  done
}
follow &
exec websockify --web /usr/local/share/omarchohard/web 6080 127.0.0.1:5900
