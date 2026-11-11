# shellcheck shell=bash
# `omarchohard doctor`: every check can fail. Exit 0 only when all required
# checks pass; optional parts that are not set up are warnings.

OH_DOC_FAILS=0
OH_DOC_WARNS=0
OH_DOC_JSON=0
OH_DOC_ROWS=()

oh_doc() {
  local level=$1 name=$2 detail=${3:-}
  case $level in
  ok) ((OH_DOC_JSON)) || oh_ok "$name${detail:+ ($detail)}" ;;
  warn)
    OH_DOC_WARNS=$((OH_DOC_WARNS + 1))
    ((OH_DOC_JSON)) || oh_warn "$name${detail:+: $detail}"
    ;;
  fail)
    OH_DOC_FAILS=$((OH_DOC_FAILS + 1))
    ((OH_DOC_JSON)) || oh_err "$name${detail:+: $detail}"
    ;;
  esac
  OH_DOC_ROWS+=("$level"$'\t'"$name"$'\t'"$detail")
}

oh_doctor_app() {
  local id=$1 name desktop file exec_bin mimes mime scheme current
  name=$(oh_app_name "$id")
  desktop=$(oh_app_desktop_id "$id")
  file=$OH_APPS_DIR/$desktop

  if [[ ! -f $file ]]; then
    oh_doc fail "$name launcher" "missing $file (run: omarchohard install)"
    return
  fi
  if oh_have desktop-file-validate && ! desktop-file-validate "$file" >/dev/null 2>&1; then
    oh_doc fail "$name launcher" "$(desktop-file-validate "$file" 2>&1 | head -n1)"
    return
  fi
  exec_bin=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$file" | head -n1)
  if [[ ! -x $exec_bin ]]; then
    oh_doc fail "$name launcher" "Exec points at $exec_bin, which is not executable"
    return
  fi
  if [[ ! -f $OH_ICON_DIR/scalable/apps/omarchohard-$id.svg ]]; then
    oh_doc fail "$name icon" "missing omarchohard-$id.svg"
    return
  fi

  local -a want=()
  mimes=$(oh_app_mimes "$id")
  [[ -n $mimes ]] && IFS=';' read -r -a want <<<"$mimes"
  for scheme in $(oh_app_schemes "$id" | tr ';' ' '); do
    [[ $scheme == mailto && $(oh_config_get mail) == 0 ]] && continue
    want+=("x-scheme-handler/$scheme")
  done
  for mime in "${want[@]}"; do
    current=$(xdg-mime query default "$mime" 2>/dev/null || true)
    if [[ $current != "$desktop" ]]; then
      oh_doc fail "$name handler" "$mime opens with '${current:-nothing}', not $desktop"
      return
    fi
  done
  local n=${#want[@]}
  if ((n == 0)); then
    oh_doc ok "$name" "launcher"
  else
    oh_doc ok "$name" "$n file and link type$( ((n == 1)) || echo s)"
  fi
}

oh_doctor() {
  oh_config_load
  [[ ${1:-} == --json ]] && OH_DOC_JSON=1
  local bin id root

  # Core tools.
  if bin=$(oh_browser_bin 2>/dev/null); then
    oh_doc ok "browser" "$bin, $(oh_config_get profile) profile"
  else
    oh_doc fail "browser" "no Chromium-based browser (omarchy pkg add chromium)"
  fi
  oh_have xdg-mime && oh_doc ok "xdg-utils" || oh_doc fail "xdg-utils" "xdg-mime is missing"
  oh_have hyprctl && oh_doc ok "Hyprland" "launch-or-focus enabled" || oh_doc warn "Hyprland" "not found; apps open but cannot focus an existing window"
  oh_channel_valid "$(oh_config_get channel)" && oh_doc ok "channel" "$(oh_config_get channel), $(oh_version)" ||
    oh_doc fail "channel" "unknown channel '$(oh_config_get channel)'"

  # Apps, launchers, icons, handlers.
  for id in $(oh_enabled_apps); do
    oh_doctor_app "$id"
  done

  # OneDrive (optional until set up, required once set up).
  if [[ -z $(oh_config_get onedrive_client) ]]; then
    oh_doc warn "OneDrive" "not set up; local files cannot open in place (omarchohard onedrive setup)"
  else
    root=$(oh_config_get onedrive_dir)
    if ! systemctl --user is-active --quiet "$OH_ONEDRIVE_UNIT" 2>/dev/null; then
      oh_doc fail "OneDrive" "$OH_ONEDRIVE_UNIT is not running (omarchohard onedrive start)"
    elif [[ $(oh_config_get onedrive_client) == rclone ]] && ! mountpoint -q "$root"; then
      oh_doc fail "OneDrive" "$root is not mounted"
    else
      oh_doc ok "OneDrive" "$(oh_config_get onedrive_client) at $root"
    fi
    [[ -n $(oh_config_get onedrive_web_root) ]] && oh_doc ok "OneDrive web address" ||
      oh_doc fail "OneDrive web address" "not set; files cannot open in place (omarchohard onedrive web-root URL)"
  fi

  # Prewarm (optional).
  if [[ -f $OH_UNIT_DIR/$OH_PREWARM_UNIT ]]; then
    systemctl --user is-active --quiet "$OH_PREWARM_UNIT" 2>/dev/null && oh_doc ok "prewarm" "browser resident" ||
      oh_doc fail "prewarm" "$OH_PREWARM_UNIT is enabled but not running"
  fi

  # Desktop tier (optional).
  oh_desktop_doctor

  if ((OH_DOC_JSON)); then
    local row level name detail first=1
    printf '{"version":"%s","fails":%d,"warnings":%d,"checks":[' "$(oh_version)" "$OH_DOC_FAILS" "$OH_DOC_WARNS"
    for row in "${OH_DOC_ROWS[@]}"; do
      IFS=$'\t' read -r level name detail <<<"$row"
      ((first)) || printf ','
      first=0
      jq -cn --arg l "$level" --arg n "$name" --arg d "$detail" '{level:$l,name:$n,detail:$d}' | tr -d '\n'
    done
    printf ']}\n'
  else
    oh_say ""
    if ((OH_DOC_FAILS)); then
      oh_err "$OH_DOC_FAILS check(s) failed, $OH_DOC_WARNS warning(s)"
    else
      oh_ok "all required checks passed, $OH_DOC_WARNS warning(s)"
    fi
  fi
  ((OH_DOC_FAILS == 0))
}
