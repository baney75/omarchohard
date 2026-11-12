# shellcheck shell=bash
# Install and uninstall: desktop entries, icons, file and URL handlers.

OH_MANIFEST=$OH_STATE_DIR/manifest

# A stable path for Exec= lines: the PATH entry when it points at this copy,
# so an update that swaps the release directory keeps launchers working.
# The installer's link counts even when ~/.local/bin is not on PATH.
oh_bin_path() {
  local candidate
  for candidate in "$(command -v omarchohard 2>/dev/null || true)" "$HOME/.local/bin/omarchohard"; do
    if [[ -n $candidate && $(readlink -f "$candidate") == "$OH_SELF" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$OH_SELF"
}

oh_manifest_add() {
  mkdir -p "$OH_STATE_DIR"
  grep -qxF -- "$1" "$OH_MANIFEST" 2>/dev/null || printf '%s\n' "$1" >>"$OH_MANIFEST"
}

oh_icon_install() {
  local id=$1 dest
  dest=$OH_ICON_DIR/scalable/apps/omarchohard-$id.svg
  mkdir -p "${dest%/*}"
  cp "$OH_SHARE/icons/$id.svg" "$dest"
  oh_manifest_add "$dest"
}

oh_desktop_entry_write() {
  local id=$1 bin=$2 file name mimes schemes mime_line='' scheme wmclass
  file=$OH_APPS_DIR/$(oh_app_desktop_id "$id")
  name=$(oh_app_name "$id")
  mimes=$(oh_app_mimes "$id")
  schemes=$(oh_app_schemes "$id")
  [[ -n $mimes ]] && mime_line+="$mimes;"
  for scheme in ${schemes//;/ }; do
    # With mail=0 Outlook does not offer itself for mailto at all.
    [[ $scheme == mailto && $(oh_config_get mail) == 0 ]] && continue
    mime_line+="x-scheme-handler/$scheme;"
  done
  wmclass=$(oh_window_class_regex "$(oh_app_url "$id")")
  wmclass=chrome-${wmclass#'(^|-)'}
  wmclass=${wmclass//\\/}
  [[ $(oh_config_get profile) == isolated ]] || wmclass+=-Default
  mkdir -p "$OH_APPS_DIR"
  {
    printf '[Desktop Entry]\n'
    printf 'Version=1.0\nType=Application\n'
    printf 'Name=%s\n' "$name"
    printf 'GenericName=Microsoft %s\n' "$name"
    printf 'Comment=%s\n' "$(oh_app_comment "$id")"
    printf 'Exec=%s open --app %s %%U\n' "$(oh_desktop_exec_arg "$bin")" "$id"
    printf 'Icon=omarchohard-%s\n' "$id"
    printf 'Terminal=false\nStartupNotify=true\n'
    printf 'StartupWMClass=%s\n' "$wmclass"
    printf 'Categories=%s\n' "$(oh_app_categories "$id")"
    printf 'Keywords=Microsoft;Office;365;%s;\n' "$name"
    [[ -n $mime_line ]] && printf 'MimeType=%s\n' "$mime_line"
    printf 'X-Omarchohard-App=%s\n' "$id"
  } >"$file"
  oh_manifest_add "$file"
}

# Remember the handler a MIME type had before we took it, once.
oh_mime_backup() {
  local mime=$1 previous
  mkdir -p "$OH_STATE_DIR"
  awk -F'\t' -v m="$mime" '$1 == m { found = 1 } END { exit !found }' "$OH_MIME_BACKUP" 2>/dev/null && return 0
  # Only the user's own explicit choice is saved. A system default stays a
  # system default, so restoring it means removing our line, not pinning it.
  previous=$(oh_mimeapps_user_default "$mime")
  [[ $previous == omarchohard-* ]] && previous=''
  printf '%s\t%s\n' "$mime" "$previous" >>"$OH_MIME_BACKUP"
}

oh_mime_claim() {
  local id=$1 desktop mime
  desktop=$(oh_app_desktop_id "$id")
  shift
  for mime in "$@"; do
    [[ -n $mime ]] || continue
    oh_mime_backup "$mime"
    xdg-mime default "$desktop" "$mime"
  done
}

oh_mimeapps_file() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"; }

# The first desktop id the user's mimeapps.list sets for a type, if any.
oh_mimeapps_user_default() {
  local list
  list=$(oh_mimeapps_file)
  [[ -f $list ]] || return 0
  awk -v m="$1" '
    /^\[/ { inside = ($0 == "[Default Applications]") ; next }
    inside && index($0, m "=") == 1 { v = substr($0, length(m) + 2); sub(/;.*/, "", v); print v; exit }
  ' "$list"
}

# Hand types back from one desktop id: drop it from those types' lines in
# mimeapps.list, then restore the saved handler only where the user's list
# still gave the type to us (a newer choice of their own stays). The types'
# backup lines go too, so a later claim saves the user's choice at that time.
oh_mime_release_types() {
  local desktop=$1 list tmp mime previous types
  shift
  types=$(
    IFS=';'
    printf ';%s;' "$*"
  )
  local -a ours=()
  for mime in "$@"; do
    [[ $(oh_mimeapps_user_default "$mime") == "$desktop" ]] && ours+=("$mime")
  done
  list=$(oh_mimeapps_file)
  if [[ -f $list ]] && grep -qF "$desktop" "$list"; then
    tmp=$(mktemp "${list%/*}/.mimeapps.XXXXXX")
    awk -v d="$desktop" -v types="$types" '
      {
        i = index($0, "=")
        key = substr($0, 1, i - 1)
        if (i < 2 || !index(types, ";" key ";")) { print; next }
        v = substr($0, i + 1)
        n = split(v, p, ";")
        out = ""
        for (k = 1; k <= n; k++) if (p[k] != "" && p[k] != d) out = out (out == "" ? "" : ";") p[k]
        if (out != "") print key "=" out (v ~ /;$/ ? ";" : "")
      }' "$list" >"$tmp"
    mv "$tmp" "$list"
  fi
  [[ -f $OH_MIME_BACKUP ]] || return 0
  tmp=$(mktemp "$OH_STATE_DIR/.mime-backup.XXXXXX")
  while IFS=$'\t' read -r mime previous; do
    [[ -n $mime ]] || continue
    if [[ $types != *";$mime;"* ]]; then
      printf '%s\t%s\n' "$mime" "$previous" >>"$tmp"
    elif [[ -n $previous && " ${ours[*]} " == *" $mime "* ]]; then
      xdg-mime default "$previous" "$mime" 2>/dev/null || true
    fi
  done <"$OH_MIME_BACKUP"
  mv "$tmp" "$OH_MIME_BACKUP"
}

# Hand one app's types back.
oh_mime_release() {
  local id=$1 mime
  local -a types=()
  [[ -n $(oh_app_mimes "$id") ]] && IFS=';' read -r -a types <<<"$(oh_app_mimes "$id")"
  for mime in $(oh_app_schemes "$id" | tr ';' ' '); do types+=("x-scheme-handler/$mime"); done
  ((${#types[@]})) || return 0
  oh_mime_release_types "$(oh_app_desktop_id "$id")" "${types[@]}"
}

# Take an app off this machine: launcher, icon and file types.
oh_app_uninstall() {
  local id=$1 file icon
  file=$OH_APPS_DIR/$(oh_app_desktop_id "$id")
  icon=$OH_ICON_DIR/scalable/apps/omarchohard-$id.svg
  [[ -e $file || -e $icon ]] || return 0
  rm -f -- "$file" "$icon"
  oh_mime_release "$id"
  oh_dim "removed $(oh_app_name "$id")"
}

# omarchohard add APP... | remove APP...
oh_apps_change() {
  oh_config_load
  local verb=$1 id cur new=''
  shift
  (($#)) || oh_die "usage: omarchohard $verb APP...   (apps: $(oh_app_ids | grep -vx m365 | tr '\n' ' '))"
  cur=$(oh_enabled_apps | tr '\n' ' ')
  for id in "$@"; do
    id=${id,,}
    oh_app_require "$id"
    [[ $verb == remove && $id == m365 ]] && oh_die "Microsoft 365 home stays; it opens every other app"
  done
  for id in $(oh_app_ids); do
    case $verb in
    add) [[ " $cur " == *" $id "* || " ${*,,} " == *" $id "* ]] && new+=${new:+,}$id ;;
    remove) [[ " $cur " == *" $id "* && " ${*,,} " != *" $id "* ]] && new+=${new:+,}$id ;;
    esac
  done
  [[ $new == "$(oh_app_ids | paste -sd, -)" ]] && new=all
  oh_install --apps "$new"
}

# Strip every omarchohard-*.desktop reference from mimeapps.list and drop
# keys left empty, then put back the handlers we saved, for the types the
# user's list still gave to omarchohard.
oh_mime_restore() {
  local list mime previous tmp
  local -a ours=()
  [[ -f $OH_MIME_BACKUP ]] && while IFS=$'\t' read -r mime previous; do
    [[ -n $mime && $(oh_mimeapps_user_default "$mime") == omarchohard-* ]] && ours+=("$mime")
  done <"$OH_MIME_BACKUP"
  list=$(oh_mimeapps_file)
  if [[ -f $list ]]; then
    tmp=$(mktemp "${list%/*}/.mimeapps.XXXXXX")
    sed -E 's/omarchohard-[a-z0-9]+\.desktop;?//g' "$list" | grep -v -E '^[^=[]+=$' >"$tmp" || true
    mv "$tmp" "$list"
  fi
  [[ -f $OH_MIME_BACKUP ]] || return 0
  while IFS=$'\t' read -r mime previous; do
    [[ -n $mime && -n $previous && " ${ours[*]} " == *" $mime "* ]] || continue
    xdg-mime default "$previous" "$mime" 2>/dev/null || true
  done <"$OH_MIME_BACKUP"
  rm -f "$OH_MIME_BACKUP"
}

oh_install() {
  oh_config_load
  local isolated=0 mail prewarm=0 bin id mimes schemes scheme apps=
  mail=$(oh_config_get mail)
  [[ $mail == 0 ]] || mail=1
  local -a claim
  while (($#)); do
    case $1 in
    --isolated) isolated=1 ;;
    --no-mail) mail=0 ;;
    --prewarm) prewarm=1 ;;
    --apps)
      [[ -n ${2:-} ]] || oh_die "--apps needs a list, like word,excel,teams or all"
      apps=$(oh_apps_parse "$2") || exit 1
      shift
      ;;
    --apps=*) apps=$(oh_apps_parse "${1#--apps=}") || exit 1 ;;
    --desktop)
      oh_desktop install
      return
      ;;
    *) oh_die "unknown install option: $1" ;;
    esac
    shift
  done
  oh_have xdg-mime || oh_die "xdg-mime is missing. Install xdg-utils: omarchy pkg add xdg-utils"
  oh_browser_bin >/dev/null || oh_die "no Chromium-based browser found. Install one: omarchy pkg add chromium"
  ((isolated)) && oh_config_set profile isolated
  [[ -n $apps ]] && oh_config_set apps "$apps"
  [[ $(oh_config_get mail) == "$mail" ]] || oh_config_set mail "$mail"
  [[ -f $OH_CONFIG ]] || oh_config_set channel "$(oh_config_get channel)"

  bin=$(oh_bin_path)
  for id in $(oh_app_ids); do
    oh_app_enabled "$id" || oh_app_uninstall "$id"
  done
  for id in $(oh_enabled_apps); do
    oh_icon_install "$id"
    oh_desktop_entry_write "$id" "$bin"
    mimes=$(oh_app_mimes "$id")
    schemes=$(oh_app_schemes "$id")
    claim=()
    [[ -n $mimes ]] && IFS=';' read -r -a claim <<<"$mimes"
    for scheme in ${schemes//;/ }; do
      [[ $scheme == mailto && $mail == 0 ]] && continue
      claim+=("x-scheme-handler/$scheme")
    done
    ((${#claim[@]})) && oh_mime_claim "$id" "${claim[@]}"
    oh_ok "$(oh_app_name "$id")"
  done
  # mail=0 after an install with mail: give mailto back.
  [[ $mail == 0 ]] && oh_mime_release_types "$(oh_app_desktop_id outlook)" x-scheme-handler/mailto
  oh_setup_entry_write "$bin"
  oh_nautilus_scripts_write "$bin"
  # The desktop tier's "Open in Windows", kept pointing at this copy.
  [[ -f $OH_APPS_DIR/$OH_ADDIN_ENTRY ]] && oh_desktop_addin_entry_write
  oh_refresh_desktop_db
  ((prewarm)) && oh_prewarm on
  oh_say ""
  oh_say "Installed. Next:"
  oh_say "  omarchohard login            sign in once with your school or work account"
  oh_say "  omarchohard onedrive setup   put your OneDrive on disk so files open from Files"
  oh_say "  omarchohard doctor           check everything"
}

oh_uninstall() {
  oh_config_load
  local purge=0 path abraunegg_conf kept=""
  [[ ${1:-} == --purge ]] && purge=1
  abraunegg_conf=${XDG_CONFIG_HOME:-$HOME/.config}/onedrive/config
  # Stop the services before their unit files go, or they keep running.
  # OneDrive first: it stops the run before anything is removed.
  oh_onedrive_stop_or_die
  oh_prewarm off >/dev/null 2>&1 || true
  if ((purge)); then
    oh_onedrive remove --quiet || oh_warn "OneDrive was not fully removed; check: omarchohard onedrive status"
  elif [[ -n $(oh_config_get onedrive_client) ]]; then
    oh_config_set onedrive_client ""
  fi
  if [[ -f $OH_MANIFEST ]]; then
    while IFS= read -r path; do
      # The abraunegg config stays unless --purge, like the rclone remote, and
      # stays on record so a later --purge still removes it.
      if [[ $path == "$abraunegg_conf" ]] && ((! purge)); then
        kept=$path
        continue
      fi
      case $path in
      # A line omarchohard added to a file of yours: only that line goes.
      hypr-line:*) oh_hypr_line_remove "${path#hypr-line:}" ;;
      ?*) rm -f -- "$path" ;;
      esac
    done <"$OH_MANIFEST"
    rm -f "$OH_MANIFEST"
    [[ -z $kept ]] || printf '%s\n' "$kept" >"$OH_MANIFEST"
  fi
  rm -f "$OH_APPS_DIR"/omarchohard-*.desktop "$OH_ICON_DIR"/scalable/apps/omarchohard-*.svg
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  oh_mime_restore
  oh_refresh_desktop_db
  if ((purge)); then
    rm -rf -- "$OH_CONFIG_DIR" "$OH_DATA_DIR/browser" "$OH_STATE_DIR"
    oh_ok "removed launchers, handlers, config, state and the isolated browser profile"
    if [[ -f $OH_VM_DIR/compose.yaml ]]; then
      oh_warn "the desktop tier's Windows VM was kept, with its password in $OH_VM_DIR/compose.yaml and $OH_WINAPPS_CONF"
      oh_say "Remove it with: omarchohard desktop remove --delete-vm"
    fi
  else
    oh_ok "removed launchers and handlers; restored your previous defaults"
    oh_dim "config kept in $OH_CONFIG_DIR (use --purge to remove it too)"
  fi
}
