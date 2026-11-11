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
