# shellcheck shell=bash
# Browser detection, app windows, launch-or-focus and prewarm.

OH_PROFILE_NAME=Omarchohard
OH_CHROMIUM_FAMILY='google-chrome|chromium|brave|microsoft-edge|vivaldi|opera|helium|thorium|ungoogled'

# Print the executable of a desktop entry's Exec line (first word).
oh_desktop_exec_bin() {
  local id=$1 dir file
  for dir in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" "$HOME/.nix-profile/share/applications" /usr/local/share/applications /usr/share/applications; do
    file=$dir/$id
    [[ -f $file ]] || continue
    sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$file" | head -n1
    return 0
  done
  return 1
}

# Resolve the browser binary. Order: config `browser`, the default browser when
# it is Chromium based, then the first installed Chromium-family browser.
# Firefox has no app-window mode, so it is never chosen.
oh_browser_bin() {
  local choice default bin candidate
  choice=$(oh_config_get browser)
  if [[ -n $choice && $choice != auto ]]; then
    bin=$(command -v "$choice" 2>/dev/null) || oh_die "configured browser '$choice' was not found"
    printf '%s\n' "$bin"
    return 0
  fi
  default=$(xdg-settings get default-web-browser 2>/dev/null || true)
  if [[ $default =~ ^($OH_CHROMIUM_FAMILY) ]] && bin=$(oh_desktop_exec_bin "$default") && [[ -n $bin ]]; then
    command -v "$bin" 2>/dev/null && return 0
  fi
  for candidate in microsoft-edge-stable google-chrome-stable chromium brave helium-browser helium vivaldi-stable; do
    command -v "$candidate" 2>/dev/null && return 0
  done
  return 1
}

oh_browser_profile_args() {
  if [[ $(oh_config_get profile) == isolated ]]; then
    printf '%s\n' "--user-data-dir=$OH_DATA_DIR/browser" "--profile-directory=$OH_PROFILE_NAME"
  fi
}

# Window class Chromium gives an --app window: chrome-<host>__<path>-<profile>.
oh_window_class_regex() {
  local url=$1 host path re
  host=${url#*://}
  path=${host#*/}
  host=${host%%/*}
  [[ $path == "$host" ]] && path=''
  re="${host//./\\.}__${path//\//_}"
  if [[ $(oh_config_get profile) == isolated ]]; then
    re+="-$OH_PROFILE_NAME"
  fi
  printf '(^|-)%s' "$re"
}

oh_focus_existing() {
  local re=$1 address
  oh_have hyprctl && oh_have jq || return 1
  address=$(hyprctl clients -j 2>/dev/null | jq -r --arg re "$re" 'first(.[] | select(.class | test($re))) | .address' 2>/dev/null) || return 1
  [[ -n $address && $address != null ]] || return 1
  oh_run hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" >/dev/null
}

# Open URL in an app window. With focus=1, raise an existing window instead.
oh_app_window() {
  local url=$1 focus=${2:-0} bin
  local -a args
  bin=$(oh_browser_bin) || oh_die "no Chromium-based browser found. Install one: omarchy pkg add chromium"
  if ((focus)) && oh_focus_existing "$(oh_window_class_regex "$url")"; then
    return 0
  fi
  mapfile -t args < <(oh_browser_profile_args)
  # Test-only hook: extra browser flags, split on spaces (the container tests
  # pass --no-sandbox here). Not a supported setting.
  if [[ -n ${OMARCHOHARD_BROWSER_FLAGS:-} ]]; then
    local -a extra
    read -r -a extra <<<"$OMARCHOHARD_BROWSER_FLAGS"
    args+=("${extra[@]}")
  fi
  oh_spawn "$bin" "${args[@]}" --no-first-run --no-default-browser-check "--app=$url"
}

oh_launch() {
  oh_config_load
  local id=${1:-} url=${2:-}
  oh_app_require "$id"
  if [[ -n $url ]]; then
    oh_app_window "$url" 0
  else
    oh_app_window "$(oh_app_url "$id")" 1
  fi
}

oh_login() {
  oh_config_load
  local email
  email=$(oh_config_get email)
  while (($#)); do
    case $1 in
    --email)
      email=${2:?--email needs an address}
      shift
      ;;
    *) oh_die "unknown login option: $1" ;;
    esac
    shift
  done
  local url=https://m365.cloud.microsoft/
  if [[ -n $email ]]; then
    [[ $email =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || oh_die "that does not look like an email address: $email"
    oh_config_set email "$email"
    url+="?login_hint=$(oh_urlencode_path "$email")"
  fi
  oh_say "Opening Microsoft sign-in. Sign in once (your school or work SSO page will appear);"
  oh_say "every omarchohard app shares this browser profile, so they all stay signed in."
  oh_app_window "$url" 0
}

# Prewarm keeps one windowless browser resident so new app windows skip
# browser startup. Only for the isolated profile: the default profile belongs
# to the user's everyday browser, which is already resident when it is open.
OH_PREWARM_UNIT=omarchohard-prewarm.service

oh_prewarm() {
  oh_config_load
  local action=${1:-status} bin
  case $action in
  on)
    [[ $(oh_config_get profile) == isolated ]] ||
      oh_die "prewarm needs the isolated profile (omarchohard install --isolated). Your default browser profile is warm whenever the browser is open."
    bin=$(oh_browser_bin) || oh_die "no Chromium-based browser found"
    mkdir -p "$OH_UNIT_DIR"
    cat >"$OH_UNIT_DIR/$OH_PREWARM_UNIT" <<EOF
[Unit]
Description=omarchohard: keep the Microsoft 365 browser profile warm
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=$bin --user-data-dir=$OH_DATA_DIR/browser --profile-directory=$OH_PROFILE_NAME --no-first-run --no-default-browser-check --no-startup-window --keep-alive-for-test
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
    oh_run systemctl --user daemon-reload
    oh_run systemctl --user enable --now "$OH_PREWARM_UNIT"
    oh_ok "prewarm on (about 215 MB resident; apps open in about 0.2 s)"
    ;;
  off)
    oh_run systemctl --user disable --now "$OH_PREWARM_UNIT" 2>/dev/null || true
    rm -f "$OH_UNIT_DIR/$OH_PREWARM_UNIT"
    oh_run systemctl --user daemon-reload
    oh_ok "prewarm off"
    ;;
  status)
    if systemctl --user is-active --quiet "$OH_PREWARM_UNIT" 2>/dev/null; then
      echo "prewarm: on"
    else
      echo "prewarm: off"
    fi
    ;;
  *) oh_die "usage: omarchohard prewarm on|off|status" ;;
  esac
}
