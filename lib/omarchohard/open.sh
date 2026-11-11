# shellcheck shell=bash
# Route a file, web link or URL scheme to the right app.
#
# Local files: Microsoft's web apps edit files that live in OneDrive. A file
# inside the OneDrive folder opens in place through its OneDrive address. A file
# anywhere else is copied into OneDrive/Omarchohard first (outside_files=copy),
# or opened in desktop Office when the desktop tier is set up (open_with=desktop).

oh_open() {
  oh_config_load
  local app=''
  if [[ ${1:-} == --app ]]; then
    app=${2:?--app needs an app id}
    oh_app_require "$app"
    shift 2
  fi
  if (($# == 0)); then
    [[ -n $app ]] || oh_die "usage: omarchohard open FILE|URL"
    oh_launch "$app"
    return
  fi
  local target
  for target in "$@"; do
    oh_open_one "$app" "$target"
  done
}

oh_open_one() {
  local app=$1 target=$2
  case $target in
  mailto:*) oh_app_window "$(oh_mailto_url "$target")" 0 ;;
  msteams:*) oh_app_window "https://teams.microsoft.com/${target#msteams:/}" 0 ;;
  ms-word:* | ms-excel:* | ms-powerpoint:* | onenote:*) oh_open_office_uri "$target" ;;
  https://* | http://*) oh_app_window "$target" 0 ;;
  file://*) oh_open_file "$app" "$(oh_file_uri_path "$target")" ;;
  *) oh_open_file "$app" "$target" ;;
  esac
}

oh_file_uri_path() {
  local p=${1#file://}
  p=${p#localhost}
  printf '%b\n' "${p//%/\\x}"
}

# mailto:a@b?subject=x&body=y -> Outlook compose deep link. mailto values are
# already percent-encoded, so they pass through unchanged.
oh_mailto_url() {
  local rest=${1#mailto:} to query
  to=${rest%%\?*}
  query=''
  [[ $rest == *\?* ]] && query=${rest#*\?}
  local url="https://outlook.office.com/mail/deeplink/compose?to=$to"
  [[ -n $query ]] && url+="&$query"
  printf '%s\n' "$url"
}

# Office URI scheme: ms-word:ofe|u|https://host/doc.docx (SharePoint "Open in
# app" buttons). Desktop Office takes it when installed; otherwise the web app.
oh_open_office_uri() {
  local uri=$1 url
  url=${uri#*|u|}
  [[ $url == https://* ]] || oh_die "unsupported Office link: $uri"
  if [[ $(oh_config_get open_with) == desktop ]] && oh_desktop_ready; then
    oh_desktop_open_url "$uri"
  else
    oh_app_window "$url" 0
  fi
}

oh_open_file() {
  local app=$1 file=$2 abs root rel web
  [[ -e $file ]] || oh_die "no such file: $file"
  abs=$(readlink -f -- "$file")
  [[ -n $app ]] || app=$(oh_app_for_file "$abs") || oh_die "not an Office file: $file"

  if [[ $(oh_config_get open_with) == desktop ]] && oh_desktop_ready; then
    oh_desktop_open_file "$app" "$abs"
    return
  fi

  root=$(oh_onedrive_root)
  if [[ -n $root && $abs == "$root"/* ]]; then
    rel=${abs#"$root"/}
    web=$(oh_onedrive_web_url "$rel") || oh_die "set your OneDrive web address first: omarchohard onedrive web-root URL"
    oh_app_window "$web" 0
    return
  fi

  case $(oh_config_get outside_files) in
  copy)
    if [[ -z $root ]]; then
      oh_notify "Set up OneDrive to open local files" "Run: omarchohard onedrive setup. Opening $(oh_app_name "$app") instead."
      oh_launch "$app"
      return
    fi
    oh_open_copy "$app" "$abs" "$root"
    ;;
  *)
    oh_notify "$(oh_app_name "$app") opens files from OneDrive" "Move $(basename -- "$abs") into $root, then open it again."
    oh_launch "$app"
    ;;
  esac
}

# Copy a file from outside OneDrive into OneDrive/Omarchohard, wait for it to
# upload, then open it. The original is never changed.
oh_open_copy() {
  local app=$1 abs=$2 root=$3 dir name stem ext dest web n=1
  oh_onedrive_web_url x >/dev/null || oh_die "set your OneDrive web address first: omarchohard onedrive web-root URL"
  dir=$root/Omarchohard
  name=$(basename -- "$abs")
  stem=${name%.*}
  ext=${name##*.}
  dest=$dir/$name
  if oh_dry; then
    printf 'would copy: %s -> %s\n' "$abs" "$dest"
  else
    mkdir -p "$dir"
    while [[ -e $dest ]] && ! cmp -s -- "$abs" "$dest"; do
      dest="$dir/$stem ($n).$ext"
      n=$((n + 1))
    done
    [[ -e $dest ]] || cp -- "$abs" "$dest"
    oh_onedrive_wait_uploaded "${dest#"$root"/}"
  fi
  web=$(oh_onedrive_web_url "${dest#"$root"/}")
  oh_notify "Opened a copy in OneDrive" "Edits save to OneDrive/Omarchohard/${dest##*/}. Your original is unchanged."
  oh_app_window "$web" 0
}
