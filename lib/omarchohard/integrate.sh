# shellcheck shell=bash
# Install and uninstall: desktop entries, icons, file and URL handlers.

OH_MANIFEST=$OH_STATE_DIR/manifest

# A stable path for Exec= lines: the PATH entry when it points at this copy,
# so an update that swaps the release directory keeps launchers working.
oh_bin_path() {
  local onpath
  onpath=$(command -v omarchohard 2>/dev/null || true)
  if [[ -n $onpath && $(readlink -f "$onpath") == "$OH_SELF" ]]; then
    printf '%s\n' "$onpath"
  else
    printf '%s\n' "$OH_SELF"
  fi
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
    printf 'Exec=%s open --app %s %%U\n' "$bin" "$id"
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

# Strip every omarchohard-*.desktop reference from mimeapps.list and drop
# keys left empty, then put back the handlers we saved.
oh_mime_restore() {
  local list mime previous tmp
  list=$(oh_mimeapps_file)
  if [[ -f $list ]]; then
    tmp=$(mktemp "${list%/*}/.mimeapps.XXXXXX")
    sed -E 's/omarchohard-[a-z0-9]+\.desktop;?//g' "$list" | grep -v -E '^[^=[]+=$' >"$tmp" || true
    mv "$tmp" "$list"
  fi
  [[ -f $OH_MIME_BACKUP ]] || return 0
  while IFS=$'\t' read -r mime previous; do
    [[ -n $mime && -n $previous ]] || continue
    xdg-mime default "$previous" "$mime" 2>/dev/null || true
  done <"$OH_MIME_BACKUP"
  rm -f "$OH_MIME_BACKUP"
}

oh_install() {
  oh_config_load
  local isolated=0 mail prewarm=0 bin id mimes schemes scheme
  mail=$(oh_config_get mail)
  [[ $mail == 0 ]] || mail=1
  local -a claim
  while (($#)); do
    case $1 in
    --isolated) isolated=1 ;;
    --no-mail) mail=0 ;;
    --prewarm) prewarm=1 ;;
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
  [[ $(oh_config_get mail) == "$mail" ]] || oh_config_set mail "$mail"
  [[ -f $OH_CONFIG ]] || oh_config_set channel "$(oh_config_get channel)"

  bin=$(oh_bin_path)
  for id in $(oh_app_ids); do
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
  local purge=0 path
  [[ ${1:-} == --purge ]] && purge=1
  oh_prewarm off >/dev/null 2>&1 || true
  if [[ -f $OH_MANIFEST ]]; then
    while IFS= read -r path; do
      [[ -n $path ]] && rm -f -- "$path"
    done <"$OH_MANIFEST"
    rm -f "$OH_MANIFEST"
  fi
  rm -f "$OH_APPS_DIR"/omarchohard-*.desktop "$OH_ICON_DIR"/scalable/apps/omarchohard-*.svg
  oh_mime_restore
  oh_refresh_desktop_db
  if ((purge)); then
    oh_onedrive remove --quiet || true
    rm -rf -- "$OH_CONFIG_DIR" "$OH_DATA_DIR/browser" "$OH_STATE_DIR"
    oh_ok "removed launchers, handlers, config, state and the isolated browser profile"
  else
    oh_ok "removed launchers and handlers; restored your previous defaults"
    oh_dim "config kept in $OH_CONFIG_DIR (use --purge to remove it too)"
  fi
}
