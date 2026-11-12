# shellcheck shell=bash
# Shared paths, config, logging and helpers.

OH_CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/omarchohard
OH_CONFIG=$OH_CONFIG_DIR/config
OH_DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/omarchohard
OH_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchohard
OH_APPS_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/applications
OH_ICON_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor
OH_UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
OH_MIME_BACKUP=$OH_STATE_DIR/mime-backup.tsv
OH_REPO=${OMARCHOHARD_REPO:-baney75/omarchohard}

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
  OH_C_OK=$'\e[32m' OH_C_WARN=$'\e[33m' OH_C_ERR=$'\e[31m' OH_C_DIM=$'\e[2m' OH_C_OFF=$'\e[0m'
else
  OH_C_OK='' OH_C_WARN='' OH_C_ERR='' OH_C_DIM='' OH_C_OFF=''
fi

oh_say() { printf '%s\n' "$*" >&2; }
oh_ok() { printf '%s  ok%s  %s\n' "$OH_C_OK" "$OH_C_OFF" "$*" >&2; }
oh_warn() { printf '%swarn%s  %s\n' "$OH_C_WARN" "$OH_C_OFF" "$*" >&2; }
oh_err() { printf '%sfail%s  %s\n' "$OH_C_ERR" "$OH_C_OFF" "$*" >&2; }
oh_die() {
  oh_err "$*"
  exit 1
}
oh_dim() { printf '%s%s%s\n' "$OH_C_DIM" "$*" "$OH_C_OFF" >&2; }

oh_dry() { [[ ${OMARCHOHARD_DRY_RUN:-0} == 1 ]]; }

# Run a command, or print it in dry-run mode. Arguments are printed shell-quoted.
oh_run() {
  if oh_dry; then
    printf 'would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# Start a GUI process detached from this shell. setsid takes about 2 ms;
# uwsm-app took 37 to 85 ms (measured 2026-11-11), and most launches only hand
# the address to a browser that is already running and exit. Set
# OMARCHOHARD_UWSM=1 to give each new browser its own uwsm scope instead.
oh_spawn() {
  if [[ -n ${OMARCHOHARD_UWSM:-} ]] && command -v uwsm-app >/dev/null 2>&1; then
    set -- uwsm-app -- "$@"
  fi
  if oh_dry; then
    oh_run "$@"
    return 0
  fi
  setsid -f "$@" >/dev/null 2>&1 </dev/null
}

# share/omarchohard/VERSION in releases and packages; VERSION in a checkout.
oh_version() {
  local v
  v=$(cat "$OH_SHARE/VERSION" 2>/dev/null || cat "$OH_ROOT/VERSION" 2>/dev/null || true)
  printf '%s\n' "${v:-unknown}"
}

oh_have() { command -v "$1" >/dev/null 2>&1; }

# Config is plain key=value. It is parsed, never sourced, so a config file can
# not run code.
declare -gA OH_CFG=()
OH_CFG_LOADED=0
# Loaded once per run; oh_config_set keeps OH_CFG current after that.
oh_config_load() {
  ((OH_CFG_LOADED)) && return 0
  OH_CFG_LOADED=1
  OH_CFG=(
    [channel]=stable
    [browser]=auto
    [profile]=default
    [onedrive_client]=""
    [onedrive_dir]="$HOME/OneDrive"
    [onedrive_remote]=omarchohard-onedrive
    [onedrive_web_root]=""
    [outside_files]=copy
    [open_with]=web
    [email]=""
    [mail]=1
    [desktop_office]=""
    [desktop_agent]=on
    [desktop_warm]="word,excel,powerpoint"
    [onedrive_cache_size]=20G
    [apps]=all
  )
  [[ -f $OH_CONFIG ]] || return 0
  local key value
  while IFS='=' read -r key value || [[ -n $key ]]; do
    [[ $key =~ ^[[:space:]]*(#|$) ]] && continue
    key=${key//[[:space:]]/}
    [[ $key =~ ^[a-z_]+$ ]] || continue
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#\"}
    value=${value%\"}
    value=${value/#\~/$HOME}
    OH_CFG[$key]=$value
  done <"$OH_CONFIG"
}

oh_config_get() { printf '%s\n' "${OH_CFG[$1]:-}"; }

oh_config_set() {
  local key=$1 value=$2 tmp
  [[ $key =~ ^[a-z_]+$ ]] || oh_die "bad config key: $key"
  [[ $value != *$'\n'* ]] || oh_die "config values must be one line"
  mkdir -p "$OH_CONFIG_DIR"
  tmp=$(mktemp "$OH_CONFIG_DIR/.config.XXXXXX")
  if [[ -f $OH_CONFIG ]]; then
    grep -v -E "^[[:space:]]*${key}[[:space:]]*=" "$OH_CONFIG" >"$tmp" || true
  else
    # shellcheck disable=SC2016 # literal backticks in the header comment
    printf '# omarchohard config. Edit with care; see `omarchohard help`.\n' >"$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$OH_CONFIG"
  OH_CFG[$key]=$value
}

# Percent-encode for a URL path; keeps unreserved characters and "/".
oh_urlencode_path() {
  local s=$1 out='' c i
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
    [a-zA-Z0-9.~_/-]) out+=$c ;;
    *) printf -v c '%%%02X' "'$c" && out+=$c ;;
    esac
  done
  printf '%s\n' "$out"
}

oh_notify() {
  local summary=$1 body=${2:-}
  if oh_dry; then
    printf 'would notify: %s: %s\n' "$summary" "$body"
    return 0
  fi
  if oh_have notify-send; then
    notify-send -a omarchohard -i omarchohard "$summary" "$body" 2>/dev/null || true
  fi
  oh_say "$summary${body:+: $body}"
}

oh_refresh_desktop_db() {
  local mime=${XDG_DATA_HOME:-$HOME/.local/share}/mime
  oh_have update-desktop-database && update-desktop-database "$OH_APPS_DIR" >/dev/null 2>&1 || true
  oh_have gtk-update-icon-cache && gtk-update-icon-cache -q -t "$OH_ICON_DIR" >/dev/null 2>&1 || true
  # The desktop tier's add-in types; this also drops them once uninstall
  # removed the package.
  [[ -d $mime/packages ]] && oh_have update-mime-database && update-mime-database "$mime" >/dev/null 2>&1 || true
}

# A value written into a unit file must be one plain line. WHAT, the third
# argument, says what is refused instead.
oh_require_line() {
  [[ $1 != *[[:cntrl:]]* ]] || oh_die "$2 has a control character in it; refusing to ${3:-write it into a service file}"
}

# One argument of a systemd Exec line: in double quotes, with \ and " escaped,
# and % and $ doubled so systemd reads them as text, not specifiers or variables.
oh_unit_arg() {
  local s=$1 bs=\\
  s=${s//"$bs"/"$bs$bs"}
  s=${s//\"/"$bs\""}
  s=${s//'%'/%%}
  s=${s//\$/\$\$}
  printf '"%s"' "$s"
}

# One argument of a desktop entry's Exec key, quoted only when the Desktop
# Entry spec requires it. Inside quotes, " ` $ and \ take a backslash, then
# every backslash is doubled again by the string escaping of the value.
oh_desktop_exec_arg() {
  local s=$1 bs=\\
  s=${s//'%'/%%}
  case $s in
  *[[:space:]\"\'\\\<\>\~\|\&\;\$\*\?\#\(\)\`]*)
    s=${s//"$bs"/"$bs$bs"}
    s=${s//\"/"$bs\""}
    s=${s//\`/"$bs\`"}
    s=${s//\$/"$bs\$"}
    s=${s//"$bs"/"$bs$bs"}
    printf '"%s"' "$s"
    ;;
  *) printf '%s' "$s" ;;
  esac
}

# The program of a desktop entry's Exec value, with that quoting undone.
oh_desktop_exec_program() {
  local v=$1 out='' c i bs=\\
  v=${v//"$bs$bs"/"$bs"}
  if [[ $v != \"* ]]; then
    v=${v%% *}
    printf '%s\n' "${v//'%%'/%}"
    return 0
  fi
  for ((i = 1; i < ${#v}; i++)); do
    c=${v:i:1}
    case $c in
    \\) ((i += 1)) && out+=${v:i:1} ;;
    \") break ;;
    *) out+=$c ;;
    esac
  done
  printf '%s\n' "${out//'%%'/%}"
}
