# shellcheck shell=bash
# For agents and scripts: `probe` reports what this device has and what
# omarchohard recommends for it, as JSON; `optimize` applies the recommendations.
# Nothing here signs in or reads tokens, cookies or auth files.

oh_json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}
oh_json_bool() { if "$@" >/dev/null 2>&1; then printf true; else printf false; fi; }

oh_on_battery() {
  local supply online=''
  for supply in /sys/class/power_supply/*; do
    [[ -r $supply/type && $(<"$supply/type") == Mains ]] || continue
    online=$(<"$supply/online")
    [[ $online == 1 ]] && return 1
  done
  [[ $online == 0 ]]
}

oh_default_browser_is_chromium() {
  [[ $(xdg-settings get default-web-browser 2>/dev/null || true) =~ ^($OH_CHROMIUM_FAMILY) ]]
}

oh_has_freerdp() { oh_have xfreerdp3 || oh_have xfreerdp || oh_have sdl-freerdp3; }

# Facts, gathered once per run.
oh_probe_facts() {
  P_THREADS=$(nproc 2>/dev/null || echo 1)
  P_MEM_TOTAL=$(($(oh_mem_kib MemTotal) / 1024))
  P_MEM_AVAIL=$(($(oh_mem_kib MemAvailable) / 1024))
  P_DISK_FREE=$(($(df --output=avail -k "$HOME" | tail -n1) / 1048576))
  P_BATTERY=0
  oh_on_battery && P_BATTERY=1
  P_HYPR=$(hyprctl version -j 2>/dev/null | jq -r '.tag // .version // empty' 2>/dev/null || true)
  P_OMARCHY=$(omarchy version 2>/dev/null | head -n1 || true)
}

# Recommendations from the facts. Each is set as R_<name>; R_WHY_<name> says why.
oh_probe_recommend() {
  # Sharing the everyday browser profile keeps one sign-in and its extensions,
  # and that browser is usually already running, so launches are warm (0.2 s).
  # When the default browser is not Chromium-based (Firefox), the Microsoft
  # browser is cold most of the time, so a dedicated profile kept warm wins,
  # if there is memory to spare and the machine is plugged in.
  R_PROFILE=default
  R_WHY_PROFILE="shares your browser's sign-in and extensions; launches are warm while it is open"
  R_PREWARM=off
  R_WHY_PREWARM="not needed: your default browser keeps the profile warm"
  if ! oh_default_browser_is_chromium; then
    R_PROFILE=isolated
    R_WHY_PROFILE="your default browser cannot open app windows, so Microsoft 365 gets its own Chromium profile"
    if ((P_MEM_TOTAL >= 8192 && P_MEM_AVAIL >= 2048 && ! P_BATTERY)); then
      R_PREWARM=on
      R_WHY_PREWARM="cold start 0.4 s becomes 0.2 s for about 215 MB of memory"
    else
      R_WHY_PREWARM="skipped: under 8 GiB of memory, under 2 GiB free, or on battery"
    fi
  fi

  # Files on demand unless rclone cannot mount (no FUSE).
  R_ONEDRIVE=rclone
  R_WHY_ONEDRIVE="files download when opened and upload 2 s after a save"
  if ! oh_have fusermount3 && ! oh_have rclone && ! oh_have omarchy; then
    R_ONEDRIVE=abraunegg
    R_WHY_ONEDRIVE="no FUSE mount available; keep a synced copy instead"
  fi

  # Local cache: a tenth of free disk, between 2 and 50 GiB.
  local cache=$((P_DISK_FREE / 10))
  ((cache < 2)) && cache=2
  ((cache > 50)) && cache=50
  R_CACHE="${cache}G"
  R_WHY_CACHE="a tenth of the ${P_DISK_FREE} GiB free on your home disk, kept between 2 and 50 GiB"

  # Desktop Office in a VM: only when every requirement is met.
  R_DESKTOP=no
  local -a missing=()
  [[ -r /dev/kvm && -w /dev/kvm ]] || missing+=("KVM")
  oh_desktop_engine >/dev/null 2>&1 || missing+=("Docker or Podman")
  oh_has_freerdp || missing+=("FreeRDP 3")
  ((P_MEM_TOTAL >= 16384)) || missing+=("16 GiB of memory")
  ((P_MEM_AVAIL >= 6144)) || missing+=("6 GiB free memory")
  ((P_DISK_FREE >= 80)) || missing+=("80 GB free disk")
  if ((${#missing[@]} == 0)); then
    R_DESKTOP=yes
    R_WHY_DESKTOP="this machine meets every requirement"
  else
    R_WHY_DESKTOP="missing: $(
      IFS=,
      printf '%s' "${missing[*]}" | sed 's/,/, /g'
    )"
  fi
}

oh_probe() {
  oh_config_load
  local json=0 line first=1
  [[ ${1:-} == --json ]] && json=1
  oh_probe_facts
  oh_probe_recommend
  if ((! json)); then
    printf 'device: %s threads, %s MiB memory (%s free), %s GiB disk free, %s\n' \
      "$P_THREADS" "$P_MEM_TOTAL" "$P_MEM_AVAIL" "$P_DISK_FREE" "$( ((P_BATTERY)) && echo 'on battery' || echo 'plugged in')"
    printf 'browser: %s\n' "$(oh_browser_bin 2>/dev/null || echo none)"
    printf 'recommend profile=%s     # %s\n' "$R_PROFILE" "$R_WHY_PROFILE"
    printf 'recommend prewarm=%s     # %s\n' "$R_PREWARM" "$R_WHY_PREWARM"
    printf 'recommend onedrive=%s    # %s\n' "$R_ONEDRIVE" "$R_WHY_ONEDRIVE"
    printf 'recommend cache=%s       # %s\n' "$R_CACHE" "$R_WHY_CACHE"
    printf 'desktop office: %s       # %s\n' "$R_DESKTOP" "$R_WHY_DESKTOP"
    return 0
  fi
  printf '{"version":%s,"channel":%s,' "$(oh_json_str "$(oh_version)")" "$(oh_json_str "$(oh_config_get channel)")"
  printf '"installed":%s,' "$(oh_json_bool test -f "$OH_STATE_DIR/manifest")"
  printf '"config":{"apps":%s,"browser":%s,"profile":%s,"onedrive_client":%s,"onedrive_cache_size":%s,"mail":%s,"email_set":%s,"onedrive_web_root_set":%s},' \
    "$(oh_json_str "$(oh_config_get apps)")" "$(oh_json_str "$(oh_config_get browser)")" "$(oh_json_str "$(oh_config_get profile)")" \
    "$(oh_json_str "$(oh_config_get onedrive_client)")" "$(oh_json_str "$(oh_config_get onedrive_cache_size)")" \
    "$(oh_json_str "$(oh_config_get mail)")" "$(oh_json_bool test -n "$(oh_config_get email)")" \
    "$(oh_json_bool test -n "$(oh_config_get onedrive_web_root)")"
  printf '"device":{"threads":%s,"mem_total_mib":%s,"mem_available_mib":%s,"disk_free_gib":%s,"on_battery":%s,"hyprland":%s,"omarchy":%s,' \
    "$P_THREADS" "$P_MEM_TOTAL" "$P_MEM_AVAIL" "$P_DISK_FREE" "$( ((P_BATTERY)) && echo true || echo false)" \
    "$(oh_json_str "$P_HYPR")" "$(oh_json_str "$P_OMARCHY")"
  printf '"kvm":%s,"container_engine":%s,"freerdp":%s,"rclone":%s,"fuse3":%s,"onedrive_client":%s,"gum":%s},' \
    "$(oh_json_bool test -w /dev/kvm)" "$(oh_json_str "$(oh_desktop_engine 2>/dev/null || true)")" \
    "$(oh_json_bool oh_has_freerdp)" "$(oh_json_bool oh_have rclone)" "$(oh_json_bool oh_have fusermount3)" \
    "$(oh_json_bool oh_have onedrive)" "$(oh_json_bool oh_have gum)"
  printf '"browsers":['
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    ((first)) || printf ','
    first=0
    printf '{"bin":%s,"name":%s}' "$(oh_json_str "${line%%|*}")" "$(oh_json_str "${line#*|}")"
  done < <(oh_setup_browsers)
  printf '],"recommend":{'
  printf '"profile":{"value":%s,"why":%s},' "$(oh_json_str "$R_PROFILE")" "$(oh_json_str "$R_WHY_PROFILE")"
  printf '"prewarm":{"value":%s,"why":%s},' "$(oh_json_str "$R_PREWARM")" "$(oh_json_str "$R_WHY_PREWARM")"
  printf '"onedrive_client":{"value":%s,"why":%s},' "$(oh_json_str "$R_ONEDRIVE")" "$(oh_json_str "$R_WHY_ONEDRIVE")"
  printf '"onedrive_cache_size":{"value":%s,"why":%s},' "$(oh_json_str "$R_CACHE")" "$(oh_json_str "$R_WHY_CACHE")"
  printf '"desktop_office":{"value":%s,"why":%s}' "$(oh_json_str "$R_DESKTOP")" "$(oh_json_str "$R_WHY_DESKTOP")"
  printf '},"needs_person":["Microsoft sign-in (omarchohard login)","OneDrive sign-in (omarchohard onedrive setup)"]}\n'
}

# Apply what probe recommends. Without --apply it only prints the plan.
oh_optimize() {
  oh_config_load
  local apply=0 changed=0
  [[ ${1:-} == --apply ]] && apply=1
  oh_probe_facts
  oh_probe_recommend

  oh_optimize_set() { # key value why
    local now
    now=$(oh_config_get "$1")
    if [[ $now == "$2" ]]; then
      oh_ok "$1=$2 already ($3)"
      return 0
    fi
    changed=1
    if ((apply)); then
      oh_config_set "$1" "$2"
      oh_ok "$1: ${now:-unset} -> $2 ($3)"
    else
      oh_say "would set $1: ${now:-unset} -> $2 ($3)"
    fi
  }

  oh_optimize_set onedrive_cache_size "$R_CACHE" "$R_WHY_CACHE"
  # The profile choice changes where the user is signed in, so optimize only
  # reports it; setup or `install --isolated` changes it on purpose.
  [[ $(oh_config_get profile) == "$R_PROFILE" ]] || oh_say "suggest profile=$R_PROFILE ($R_WHY_PROFILE); change it with omarchohard setup"

  if [[ $(oh_config_get profile) == isolated ]]; then
    local want=$R_PREWARM have
    have=$(oh_prewarm status 2>/dev/null | awk '{print $2}')
    if [[ $have != "$want" ]]; then
      changed=1
      if ((apply)); then oh_prewarm "$want"; else oh_say "would turn prewarm $want ($R_WHY_PREWARM)"; fi
    else
      oh_ok "prewarm $have already ($R_WHY_PREWARM)"
    fi
  fi

  # A new cache size takes effect when the mount unit is rewritten.
  if ((apply && changed)) && [[ $(oh_config_get onedrive_client) == rclone && -f $OH_UNIT_DIR/$OH_ONEDRIVE_UNIT ]]; then
    oh_onedrive_rclone_unit "$(oh_config_get onedrive_dir)" "$(oh_config_get onedrive_remote)"
    oh_run systemctl --user daemon-reload
    oh_run systemctl --user restart "$OH_ONEDRIVE_UNIT" && oh_ok "OneDrive mount restarted with the new cache size"
  fi
  if ((! apply && changed)); then
    oh_say ""
    oh_say "Apply with: omarchohard optimize --apply"
  fi
  return 0
}
