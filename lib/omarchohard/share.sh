# shellcheck shell=bash
# Share a file through OneDrive, from the terminal or from Files (right-click,
# Scripts). Office documents open in their app, where Share sends to people by
# name. Any file can also get a link, copied to the clipboard.

OH_CONSUMER_DOMAINS='outlook.com|hotmail.com|live.com|msn.com|passport.com'

# Put a file into OneDrive if it is not there yet; print its OneDrive path.
# A file from outside is copied to OneDrive/Omarchohard; the original stays.
oh_onedrive_import() {
  local abs=$1 root=$2 dir name stem ext dest tmp n=1
  if [[ $abs == "$root"/* ]]; then
    printf '%s\n' "${abs#"$root"/}"
    return 0
  fi
  dir=$root/Omarchohard
  name=$(basename -- "$abs")
  stem=${name%.*}
  ext=${name##*.}
  [[ $name == *.* ]] || ext=''
  dest=$dir/$name
  if oh_dry; then
    printf 'would copy: %s -> %s\n' "$abs" "$dest" >&2
  else
    mkdir -p "$dir"
    # Copy to a temp name, then move it into the first free name without
    # replacing anything, so two imports of the same name both keep their file.
    tmp=$(mktemp "$dir/.omarchohard-import.XXXXXX")
    cp -- "$abs" "$tmp"
    chmod --reference="$abs" -- "$tmp" 2>/dev/null || true
    while :; do
      if [[ -e $dest ]]; then
        if cmp -s -- "$tmp" "$dest"; then
          rm -f -- "$tmp"
          break
        fi
      else
        mv -n -- "$tmp" "$dest" 2>/dev/null || true
        [[ -e $tmp ]] || break
      fi
      dest="$dir/$stem ($n)${ext:+.$ext}"
      n=$((n + 1))
    done
    oh_onedrive_wait_uploaded "${dest#"$root"/}"
  fi
  printf '%s\n' "${dest#"$root"/}"
}

# Work and school tenants often turn off links for anyone, so they default to
# people in the organization; personal accounts default to anyone with the link.
oh_share_scope() {
  local email
  email=$(oh_config_get email)
  if [[ -n $email && ! ${email#*@} =~ ^($OH_CONSUMER_DOMAINS)$ ]]; then
    echo organization
  else
    echo anonymous
  fi
}

oh_share() {
  oh_config_load
  local link=0 type=view scope='' file abs root rel app url
  local -a files=()
  while (($#)); do
    case $1 in
    --link) link=1 ;;
    --edit) type=edit ;;
    --anyone) scope=anonymous ;;
    --org) scope=organization ;;
    -*) oh_die "unknown share option: $1 (use --link, --edit, --anyone or --org)" ;;
    *) files+=("$1") ;;
    esac
    shift
  done
  ((${#files[@]})) || oh_die "usage: omarchohard share [--link] [--edit] [--anyone|--org] FILE..."
  root=$(oh_onedrive_root)
  [[ -n $root ]] || oh_die "set up OneDrive first: omarchohard onedrive setup"
  [[ -n $scope ]] || scope=$(oh_share_scope)

  for file in "${files[@]}"; do
    [[ -e $file ]] || oh_die "no such file: $file"
    abs=$(readlink -f -- "$file")
    rel=$(oh_onedrive_import "$abs" "$root")
    app=$(oh_app_for_file "$abs" || true)

    if ((! link)) && [[ -n $app ]] && url=$(oh_onedrive_web_url "$rel" 2>/dev/null); then
      oh_notify "Share $(basename -- "$abs")" "It opened in $(oh_app_name "$app"). Choose Share at the top right to send it to people."
      oh_app_window "$url" 0
      continue
    fi
    oh_share_link "$rel" "$type" "$scope"
  done
}

oh_share_link() {
  local rel=$1 type=$2 scope=$3 url remote other
  case $(oh_config_get onedrive_client) in
  rclone)
    remote=$(oh_config_get onedrive_remote)
    if oh_dry; then
      oh_run rclone link "$remote:$rel" --onedrive-link-scope "$scope" --onedrive-link-type "$type"
      return 0
    fi
    # The account type is a guess from the email: a tenant may turn off links
    # for anyone, and a personal account has no organization. Try the other.
    other=organization
    [[ $scope == organization ]] && other=anonymous
    url=$(rclone link "$remote:$rel" --onedrive-link-scope "$scope" --onedrive-link-type "$type" 2>/dev/null) ||
      { url=$(rclone link "$remote:$rel" --onedrive-link-scope "$other" --onedrive-link-type "$type" 2>/dev/null) && scope=$other; } ||
      oh_die "OneDrive would not make a link for $rel; your organization may limit sharing. Open it in OneDrive to share by name: omarchohard launch onedrive"
    ;;
  abraunegg)
    local -a perms=()
    [[ $type == edit ]] && perms=(--with-editing-perms)
    if oh_dry; then
      oh_run onedrive --create-share-link "$rel" "${perms[@]}"
      return 0
    fi
    url=$(onedrive --create-share-link "$rel" "${perms[@]}" 2>/dev/null | grep -o 'https://[^ ]*' | tail -n1) ||
      oh_die "the onedrive client did not return a link for $rel"
    ;;
  *) oh_die "set up OneDrive first: omarchohard onedrive setup" ;;
  esac
  [[ $url == https://* ]] || oh_die "OneDrive did not return a link for $rel"
  if oh_have wl-copy; then
    printf '%s' "$url" | wl-copy 2>/dev/null || true
  fi
  printf '%s\n' "$url"
  local who="anyone with the link"
  [[ $scope == organization ]] && who="people in your organization"
  oh_notify "Link copied" "$(basename -- "$rel"): $who can $type it."
}

# Right-click actions in Files (Nautilus runs anything in its scripts folder).
OH_NAUTILUS_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/nautilus/scripts

oh_nautilus_scripts_write() {
  local bin=$1 name action file
  oh_have nautilus || return 0
  mkdir -p "$OH_NAUTILUS_DIR"
  for name in "Share with OneDrive" "Copy OneDrive link" "Open in Microsoft 365"; do
    case $name in
    "Share with OneDrive") action="share" ;;
    "Copy OneDrive link") action="share --link" ;;
    *) action="open" ;;
    esac
    file=$OH_NAUTILUS_DIR/$name
    if [[ -e $file ]] && ! grep -qF 'Added by omarchohard' "$file"; then
      oh_warn "kept your own Files script '$name'; omarchohard did not add its own"
      continue
    fi
    printf '#!/bin/sh\n# Added by omarchohard; removed by omarchohard uninstall.\nexec %q %s "$@"\n' "$bin" "$action" >"$file"
    chmod 755 "$file"
    oh_manifest_add "$file"
  done
}
