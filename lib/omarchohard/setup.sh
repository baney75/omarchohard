# shellcheck shell=bash
# Guided first-run setup: which Office, browser, sign-in, OneDrive and a final
# check, one question at a time. Uses gum (Omarchy ships it) and falls back to plain
# prompts. Every answer has a safe default, and --yes takes them all.

oh_ui_gum() { oh_have gum && [[ -z ${OMARCHOHARD_NO_GUM:-} ]]; }

# Interactive when a terminal can answer. curl | bash has no stdin, so read
# answers from /dev/tty instead.
oh_ui_interactive() {
  [[ -z ${OH_SETUP_YES:-} ]] || return 1
  [[ -n ${OMARCHOHARD_TTY:-} ]] && return 0
  { : </dev/tty; } 2>/dev/null
}
# One handle for every answer, opened once, so a scripted answer file is read
# line by line and a real terminal is opened only once.
OH_TTY_FD=''
# Called in the setup shell itself, never in a $( ) subshell, so the handle lasts.
oh_ui_open() {
  [[ -n $OH_TTY_FD ]] || exec {OH_TTY_FD}<"${OMARCHOHARD_TTY:-/dev/tty}"
}

oh_ui_header() {
  if oh_ui_gum; then
    gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 6 "$@" >&2
  else
    printf '\n' >&2
    printf '  %s\n' "$@" >&2
    printf '\n' >&2
  fi
}

oh_ui_step() {
  if oh_ui_gum; then
    gum style --bold --foreground 6 --margin "1 0 0 0" "$*" >&2
  else
    printf '\n== %s\n' "$*" >&2
  fi
}

# oh_ui_confirm QUESTION [yes|no]: the default is what --yes picks.
oh_ui_confirm() {
  local question=$1 default=${2:-yes} answer
  if ! oh_ui_interactive; then
    [[ $default == yes ]]
    return
  fi
  if oh_ui_gum; then
    local flag=--default=true
    [[ $default == yes ]] || flag=--default=false
    gum confirm "$flag" "$question" <&"$OH_TTY_FD"
    return
  fi
  local hint='[Y/n]'
  [[ $default == yes ]] || hint='[y/N]'
  read -r -p "$question $hint " answer <&"$OH_TTY_FD" || answer=''
  answer=${answer:-$default}
  [[ ${answer,,} == y* ]]
}

# oh_ui_choose HEADER OPTION...: prints the chosen option; the first is the default.
oh_ui_choose() {
  local header=$1 answer i
  shift
  if ! oh_ui_interactive; then
    printf '%s\n' "$1"
    return
  fi
  if oh_ui_gum; then
    gum choose --header "$header" --selected "$1" "$@" <&"$OH_TTY_FD"
    return
  fi
  printf '%s\n' "$header" >&2
  for ((i = 1; i <= $#; i++)); do printf '  %d) %s\n' "$i" "${!i}" >&2; done
  read -r -p "Choose [1]: " answer <&"$OH_TTY_FD" || answer=''
  [[ $answer =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= $#)) || answer=1
  printf '%s\n' "${!answer}"
}

# oh_ui_pick HEADER OPTION...: several choices; prints the chosen, one per
# line. All start selected, or the comma list in OH_PICK_SELECTED. Plain
# prompts take numbers ("1 3 6"); Enter keeps the selected ones.
oh_ui_pick() {
  local header=$1 answer n selected
  shift
  selected=${OH_PICK_SELECTED-$(
    IFS=,
    printf '%s' "$*"
  )}
  if ! oh_ui_interactive; then
    for ((n = 1; n <= $#; n++)); do [[ ,$selected, == *",${!n},"* ]] && printf '%s\n' "${!n}"; done
    return 0
  fi
  if oh_ui_gum; then
    gum choose --no-limit --header "$header" --selected "$selected" "$@" <&"$OH_TTY_FD"
    return
  fi
  printf '%s\n' "$header" >&2
  for ((n = 1; n <= $#; n++)); do
    if [[ ,$selected, == *",${!n},"* ]]; then printf '  %d) %s *\n' "$n" "${!n}" >&2; else printf '  %d) %s\n' "$n" "${!n}" >&2; fi
  done
  if [[ -n ${OH_PICK_SELECTED+set} ]]; then
    read -r -p "Numbers [the ones marked *]: " answer <&"$OH_TTY_FD" || answer=''
  else
    read -r -p "Numbers to install [all]: " answer <&"$OH_TTY_FD" || answer=''
  fi
  if [[ -z ${answer//[[:space:],]/} ]]; then
    for ((n = 1; n <= $#; n++)); do [[ ,$selected, == *",${!n},"* ]] && printf '%s\n' "${!n}"; done
    return 0
  fi
  for n in ${answer//,/ }; do
    [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= $#)) && printf '%s\n' "${!n}"
  done
  return 0
}

# oh_ui_input PROMPT [PLACEHOLDER] [DEFAULT]
oh_ui_input() {
  local prompt=$1 placeholder=${2:-} default=${3:-} answer
  if ! oh_ui_interactive; then
    printf '%s\n' "$default"
    return
  fi
  if oh_ui_gum; then
    gum input --prompt "$prompt " --placeholder "$placeholder" --value "$default" <&"$OH_TTY_FD"
    return
  fi
  read -r -p "$prompt${default:+ [$default]} " answer <&"$OH_TTY_FD" || answer=''
  printf '%s\n' "${answer:-$default}"
}

# Installed Chromium-family browsers, the default browser first, as "bin|Name".
oh_setup_browsers() {
  local default bin candidate seen=' '
  default=$(xdg-settings get default-web-browser 2>/dev/null || true)
  if [[ $default =~ ^($OH_CHROMIUM_FAMILY) ]] && bin=$(oh_desktop_exec_bin "$default") && command -v "$bin" >/dev/null 2>&1; then
    bin=${bin##*/}
    printf '%s|%s (your default browser)\n' "$bin" "$(oh_browser_label "$bin")"
    seen+="$bin "
  fi
  for candidate in microsoft-edge-stable google-chrome-stable chromium brave helium-browser helium vivaldi-stable; do
    [[ $seen == *" $candidate "* ]] && continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    printf '%s|%s\n' "$candidate" "$(oh_browser_label "$candidate")"
    seen+="$candidate "
  done
}

oh_browser_label() {
  case ${1##*/} in
  microsoft-edge*) echo "Microsoft Edge" ;;
  google-chrome*) echo "Google Chrome" ;;
  chromium*) echo "Chromium" ;;
  brave*) echo "Brave" ;;
  helium*) echo "Helium" ;;
  vivaldi*) echo "Vivaldi" ;;
  *) echo "${1##*/}" ;;
  esac
}

# From the app launcher there is no terminal, so open one: Omarchy's floating
# setup window when present (logo, the wizard, then its done screen), or any
# terminal through xdg-terminal-exec.
oh_setup_gui() {
  local bin
  bin=$(oh_bin_path)
  if oh_have omarchy-launch-floating-terminal-with-presentation; then
    oh_dry && {
      oh_run omarchy-launch-floating-terminal-with-presentation "$bin" setup
      exit 0
    }
    exec omarchy-launch-floating-terminal-with-presentation "$bin" setup
  fi
  oh_have xdg-terminal-exec || oh_die "no terminal launcher found; run omarchohard setup in a terminal"
  oh_dry && {
    oh_run xdg-terminal-exec "$bin" setup --pause
    exit 0
  }
  exec xdg-terminal-exec "$bin" setup --pause
}

# The launcher entry that reopens setup.
oh_setup_entry_write() {
  local bin=$1 file=$OH_APPS_DIR/omarchohard-setup.desktop
  mkdir -p "$OH_APPS_DIR"
  {
    printf '[Desktop Entry]\nVersion=1.0\nType=Application\n'
    printf 'Name=Microsoft 365 Setup\n'
    printf 'Comment=Set up Word, Excel, PowerPoint, Outlook, Teams and OneDrive on Omarchy\n'
    printf 'Exec=%s setup --gui\n' "$(oh_desktop_exec_arg "$bin")"
    printf 'Icon=omarchohard\nTerminal=false\nCategories=Settings;Office;\n'
    printf 'Keywords=Microsoft;Office;365;OneDrive;setup;sign in;\n'
  } >"$file"
  oh_manifest_add "$file"
}

# OneDrive setup ran in a subshell and said why it stopped; this says where
# things stand now, as an earlier setup may still be in place.
oh_setup_onedrive_failed() {
  local client
  client=$(sed -n 's/^onedrive_client=//p' "$OH_CONFIG" 2>/dev/null)
  if [[ -n $client ]]; then
    oh_warn "OneDrive is unchanged: still set up with $client. To switch: omarchohard onedrive setup --client <rclone|abraunegg>"
  else
    oh_warn "OneDrive is not set up yet; try again with: omarchohard onedrive setup"
  fi
}

# Which Office: Microsoft's desktop apps on Linux (native), the real Windows
# apps in a VM, or the web apps. Prints native, desktop, web or installed
# (the desktop tier is already set up). Native is recommended when this
# machine meets its needs, then desktop when it passes oh_desktop_check.
oh_setup_tier() {
  local check why='' line choice
  local desk="Desktop Office: the real Windows apps (add-ins, macros, offline, Office's own updates); one-time install of about 20 minutes; needs KVM, 16 GB of memory and about 80 GB of disk"
  local web="Web apps: open instantly and stay light"
  local native="Native Office: Microsoft's desktop apps on Linux, no VM; about 6 minutes to install, under a minute from another device's copy; Word opens in about 4 seconds"
  if [[ -f $OH_VM_DIR/compose.yaml ]] && oh_desktop_ready; then
    echo installed
    return 0
  fi
  if [[ -z $(oh_native_missing) ]]; then
    choice=$(oh_ui_choose "Which Microsoft Office?" "$native (recommended)" "$web" "$desk") || return 1
  elif check=$(oh_desktop_check 2>&1); then
    choice=$(oh_ui_choose "Which Microsoft Office?" "$desk (recommended)" "$web" "$native") || return 1
  else
    while IFS= read -r line; do
      [[ $line == *fail* ]] && why+="${why:+; }${line#*fail"$OH_C_OFF"  }"
    done <<<"$check"
    oh_say "Desktop Office is not recommended here: $why"
    choice=$(oh_ui_choose "Which Microsoft Office?" "$web (recommended)" "$desk" "$native") || return 1
  fi
  case $choice in Native*) echo native ;; Desktop*) echo desktop ;; *) echo web ;; esac
}

# Which Microsoft 365 the person has, for the native tier: prints a plan.
oh_setup_plan() {
  local choice
  choice=$(oh_ui_choose "Which Microsoft 365 do you have?" "Personal or Family" "School" "Work, business" "Work, large organization") || return 1
  case $choice in
  School) echo school ;;
  "Work, business") echo business ;;
  "Work, large organization") echo enterprise ;;
  *) echo personal ;;
  esac
}

# The JSON line `setup --json` ends with, on the stdout it was given.
oh_setup_json() {
  local state=$1 url=${2:-} detail=${3:-}
  ((OH_SETUP_JSON_DONE)) && return 0
  OH_SETUP_JSON_DONE=1
  printf '{"state":%s,"signin_url":%s,"seconds":%s,"host":%s,"tier":%s,"email":%s,"detail":%s}\n' \
    "$(oh_json_str "$state")" "$([[ -n $url ]] && oh_json_str "$url" || echo null)" "$((SECONDS - OH_SETUP_START))" \
    "$(oh_json_str "$(uname -n)")" "$(oh_json_str "${OH_SETUP_TIER:-}")" \
    "$([[ -n ${OH_SETUP_EMAIL:-} ]] && oh_json_str "$OH_SETUP_EMAIL" || echo null)" "$(oh_json_str "$detail")" >&"$OH_SETUP_OUT"
}

# Which files open in Office: prints a `files` value. Only formats of enabled
# apps are offered; with no Word, Excel or PowerPoint, or no terminal, the
# current value stays.
oh_setup_files() {
  local ext choice label want=''
  local -a offer=() picked=()
  local -A name=([odt]="OpenDocument text" [ods]="OpenDocument spreadsheet"
    [odp]="OpenDocument presentation" [rtf]="Rich Text" [csv]="Comma-separated values")
  for ext in $OH_FILES_OTHER; do
    oh_app_enabled "${OH_EXT_APP[$ext]}" && offer+=(".$ext  ${name[$ext]}")
  done
  if ! oh_ui_interactive || ((${#offer[@]} == 0)); then
    oh_config_get files
    return 0
  fi
  local -a opts=("Microsoft Office files only (.docx, .xlsx, .pptx and their older, macro and template forms)"
    "Microsoft Office files and other formats too")
  # The current choice is the default, so Enter on a rerun keeps it.
  [[ $(oh_config_get files) == microsoft ]] || opts=("${opts[1]}" "${opts[0]}")
  choice=$(oh_ui_choose "Which files should open in Office?" "${opts[@]}") || return 1
  if [[ $choice == *only* ]]; then
    echo microsoft
    return 0
  fi
  # Formats already on start ticked; a first choice ticks them all.
  local on='' sel=''
  [[ $(oh_config_get files) == microsoft ]] || on=" $(oh_files_other | tr '\n' ' ')"
  for label in "${offer[@]}"; do
    ext=${label#.}
    ext=${ext%% *}
    [[ -z $on || $on == *" $ext "* ]] && sel+=${sel:+,}$label
  done
  # Esc in gum is a cancel, not an empty pick that would turn every format off.
  local out
  out=$(OH_PICK_SELECTED=$sel oh_ui_pick "Which other formats? (space toggles, Enter confirms)" "${offer[@]}") || return 1
  [[ -z $out ]] || mapfile -t picked <<<"$out"
  for label in "${picked[@]}"; do
    label=${label#.}
    want+=${want:+,}${label%% *}
  done
  # Formats of apps not picked this time stay as they were.
  for ext in $(oh_files_other); do
    oh_app_enabled "${OH_EXT_APP[$ext]}" || want+=${want:+,}$ext
  done
  oh_files_parse "$want"
}

oh_setup() {
  OH_CFG_LOADED=0 && oh_config_load
  local pause=0 line bin='' label choice email mail_flag=() iso_flag=() od='' answer tier='' desktop_failed=0
  local want_bin='' want_profile='' want_email='' want_mail='' want_prewarm='' want_apps='' want_files='' optimize=0
  local from='' sha='' plan='' shared=0 remote_signin=0 json=0 native_failed=0 signin_url='' signin_note='' native_prewarm=0
  local -a browsers labels native_args=()
  OH_SETUP_START=$SECONDS OH_SETUP_JSON_DONE=0
  # --json: everything for people goes to stderr, and stdout gets one JSON
  # line at the end, also when setup stops early, a bad option included.
  exec {OH_SETUP_OUT}>&1
  for line in "$@"; do [[ $line == --json ]] && json=1; done
  if ((json)); then
    exec 1>&2
    trap 'oh_setup_json failed "" "setup stopped early; the lines above say why"' EXIT
  fi
  while (($#)); do
    case $1 in
    --yes | -y) OH_SETUP_YES=1 ;;
    --pause) pause=1 ;;
    --gui) oh_setup_gui ;;
    --browser) want_bin=${2:?--browser needs a browser command, like chromium} && shift ;;
    --shared) want_profile=default ;;
    --isolated) want_profile=isolated ;;
    --email) want_email=${2:?--email needs an address} && shift ;;
    --no-mail) want_mail=0 ;;
    --onedrive) od=${2:?--onedrive needs rclone, abraunegg or none} && shift ;;
    --prewarm) want_prewarm=${2:?--prewarm needs on or off} && shift ;;
    --optimize) optimize=1 ;;
    --tier) tier=${2:?--tier needs native, desktop or web} && shift ;;
    --from) from=${2:?--from needs a seed file, ssh:HOST or a link} && shift ;;
    --sha256) sha=${2:?--sha256 needs the seed\'s SHA256} && shift ;;
    --plan) plan=${2:?--plan needs personal, family, school, business or enterprise} && shift ;;
    --shared-computer) shared=1 ;;
    --remote-signin) remote_signin=1 ;;
    --lan) oh_die "remote sign-in works only over Tailscale, which encrypts it; on a plain network the Microsoft password would cross it unencrypted. Sign in on this device instead: omarchohard native signin" ;;
    --json) json=1 ;;
    --apps)
      want_apps=$(oh_apps_parse "${2:?--apps needs a list, like word,excel,teams or all}") || exit 1
      shift
      ;;
    --files)
      want_files=$(oh_files_parse "${2:?--files needs microsoft, all or a list, like odt,csv}") || exit 1
      shift
      ;;
    *) oh_die "unknown setup option: $1 (see: omarchohard help setup)" ;;
    esac
    shift
  done
  case $od in '' | rclone | abraunegg | none) ;; *) oh_die "--onedrive takes rclone, abraunegg or none" ;; esac
  case $want_prewarm in '' | on | off) ;; *) oh_die "--prewarm takes on or off" ;; esac
  case $tier in '' | native | desktop | web) ;; *) oh_die "--tier takes native, desktop or web" ;; esac
  [[ -z $plan ]] || oh_native_plan_check "$plan"
  if [[ -n $from$sha$plan ]] || ((shared || remote_signin)); then
    [[ $tier == native ]] || oh_die "--from, --sha256, --plan, --shared-computer and --remote-signin go with --tier native"
  fi
  OH_SETUP_TIER=$tier OH_SETUP_EMAIL=$want_email

  # Native, set up once already: nothing to do. One setup at a time, so a
  # second agent on this device waits, then finds it done.
  if [[ $tier == native ]]; then
    oh_native_lock setup-native
    if [[ -f $OH_NATIVE_DONE ]] && oh_native_ready; then
      oh_ok "native Office is already set up here (omarchohard native status)"
      ((json)) && oh_setup_json ready "" "already set up; whether the person has signed in shows in Word (File, Account)"
      trap - EXIT
      return 0
    fi
  fi

  oh_ui_interactive && oh_ui_open
  oh_ui_header "omarchohard setup" "" \
    "Word, Excel, PowerPoint, Outlook, OneNote, Teams and OneDrive" \
    "as apps on Omarchy. About two minutes; every step can be undone" \
    "with: omarchohard uninstall"

  # 1. Which Office. Unattended runs without --tier keep the web apps, so a
  # script or CI never starts a 6 GB Windows download unasked.
  oh_ui_step "1 of 6  Office"
  if [[ -z $tier ]]; then
    if oh_ui_interactive; then
      tier=$(oh_setup_tier) || oh_die "setup cancelled"
    else
      tier=web
    fi
  fi
  [[ $tier == desktop && -f $OH_VM_DIR/compose.yaml ]] && oh_desktop_ready && tier=installed
  case $tier in
  installed) oh_ok "Office: desktop Office is already set up (omarchohard desktop status)" ;;
  native) oh_ok "Office: native Office, installed at the end; the web apps are set up too, for Teams" ;;
  desktop) oh_ok "Office: desktop Office, installed at the end; the web apps are set up too, for Teams" ;;
  web) oh_ok "Office: the web apps" ;;
  esac

  if [[ $tier == native && -z $plan ]] && oh_ui_interactive; then
    plan=$(oh_setup_plan) || oh_die "setup cancelled"
  fi
  if [[ $tier == native ]]; then
    # Microsoft's terms are accepted with --yes; otherwise native install asks.
    native_args=()
    [[ -z ${OH_SETUP_YES:-} ]] || native_args+=(--yes)
    [[ -z $plan ]] || native_args+=(--plan "$plan")
    [[ -z $from ]] || native_args+=(--from "$from")
    [[ -z $sha ]] || native_args+=(--sha256 "$sha")
    ((shared == 0)) || native_args+=(--shared-computer)
    [[ -z $want_email ]] || native_args+=(--email "$want_email")
  fi

  # 2. Browser. App windows need a Chromium-based browser.
  oh_ui_step "2 of 6  Browser"
  mapfile -t browsers < <(oh_setup_browsers)
  if ((${#browsers[@]} == 0)); then
    oh_say "The Microsoft apps open as app windows, which needs a Chromium-based browser."
    oh_have omarchy || oh_die "install Chromium first: sudo pacman -S chromium"
    oh_ui_confirm "Install Chromium now?" yes || oh_die "setup needs a Chromium-based browser. Run omarchohard setup again after you install one."
    oh_run omarchy pkg add chromium || oh_die "Chromium did not install"
    mapfile -t browsers < <(oh_setup_browsers)
    oh_dry && ((${#browsers[@]} == 0)) && browsers=("chromium|Chromium")
  fi
  if [[ -n $want_bin ]]; then
    command -v "$want_bin" >/dev/null 2>&1 || oh_die "browser '$want_bin' is not installed"
    bin=${want_bin##*/}
  else
    labels=()
    for line in "${browsers[@]}"; do labels+=("${line#*|}"); done
    label=$(oh_ui_choose "Which browser should run Microsoft 365?" "${labels[@]}") || oh_die "setup cancelled"
    for line in "${browsers[@]}"; do [[ ${line#*|} == "$label" ]] && bin=${line%%|*}; done
    [[ -n $bin ]] || bin=${browsers[0]%%|*}
  fi
  oh_config_set browser "$bin"
  oh_ok "browser: $(oh_browser_label "$bin")"

  case $want_profile in
  isolated) choice=Keep ;;
  default) choice=Share ;;
  *)
    if oh_ui_interactive; then
      choice=$(oh_ui_choose "How should the apps sign in?" \
        "Share this browser's sign-in and extensions (recommended)" \
        "Keep Microsoft 365 in its own profile") || oh_die "setup cancelled"
    else
      # Unattended runs keep the profile the apps are already signed in to.
      choice=Share
      [[ $(oh_config_get profile) != isolated ]] || choice=Keep
    fi
    ;;
  esac
  if [[ $choice == Keep* ]]; then
    iso_flag=(--isolated)
  elif [[ $(oh_config_get profile) == isolated ]]; then
    oh_config_set profile default
  fi

  # 3. Account. Optional; it fills in the sign-in page and the OneDrive address.
  oh_ui_step "3 of 6  Account"
  if [[ -n $want_email ]]; then
    email=$want_email
  else
    email=$(oh_ui_input "Your Microsoft email (optional):" "you@school.edu" "$(oh_config_get email)") || email=''
  fi
  email=${email//[[:space:]]/}
  if [[ -n $email ]]; then
    if [[ $email =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
      oh_config_set email "$email"
    else
      oh_warn "skipping '$email': that is not an email address"
    fi
  fi

  # 4. Launchers and file handlers.
  oh_ui_step "4 of 6  Apps and files"
  if [[ -z $want_apps ]]; then
    local -a names=() picked=()
    local id
    for id in $(oh_app_ids); do [[ $id == m365 ]] || names+=("$(oh_app_name "$id")"); done
    mapfile -t picked < <(oh_ui_pick "Which apps? (space toggles, Enter confirms)" "${names[@]}")
    want_apps=''
    for label in "${picked[@]}"; do
      for id in $(oh_app_ids); do [[ $(oh_app_name "$id") == "$label" ]] && want_apps+=${want_apps:+,}$id; done
    done
    ((${#picked[@]} == ${#names[@]})) && want_apps=all
    [[ -n $want_apps ]] || want_apps=all
  fi
  oh_config_set apps "$want_apps"
  [[ -n $want_files ]] || want_files=$(oh_setup_files) || oh_die "setup cancelled"
  oh_config_set files "$want_files"
  oh_ok "files: $(oh_files_label)"
  if [[ $want_mail == 0 ]]; then
    mail_flag=(--no-mail)
  else
    oh_ui_confirm "Open email links (mailto:) in Outlook?" yes || mail_flag=(--no-mail)
  fi
  oh_install "${iso_flag[@]}" "${mail_flag[@]}" 2>&1 | grep -v -e '^Installed. Next:' -e '^  omarchohard ' -e '^$' >&2 || true
  [[ -f $OH_MANIFEST ]] || oh_dry || oh_die "installing the launchers failed; run omarchohard install to see why"
  OH_CFG_LOADED=0 && oh_config_load

  # 5. Sign in, once, on Microsoft's own page.
  oh_ui_step "5 of 6  Sign in"
  if [[ ${iso_flag[*]} == --isolated ]]; then
    oh_say "Microsoft 365 has its own profile, so sign in once here."
  else
    oh_say "If you are already signed in to Microsoft in $(oh_browser_label "$bin"), you can skip this."
  fi
  if oh_ui_interactive && oh_ui_confirm "Open the Microsoft sign-in page now?" yes; then
    oh_login
    oh_ui_interactive && oh_ui_confirm "Finished signing in? (your school or work SSO page counts)" yes >/dev/null || true
  fi

  # 6. OneDrive on disk, so Office files open from Files.
  oh_ui_step "6 of 6  OneDrive"
  if [[ -n $(oh_config_get onedrive_client) ]]; then
    oh_ok "OneDrive is already set up ($(oh_config_get onedrive_client))"
  else
    if [[ -z $od ]]; then
      od=$(oh_ui_choose "Put OneDrive in a folder so files open from Files?" \
        "Yes, files on demand (recommended, uses rclone)" \
        "Yes, a full offline copy (uses the abraunegg OneDrive client)" \
        "Not now") || od="Not now"
      oh_ui_interactive || od="Not now"
    fi
    if [[ $od != "Not now" && $od != none ]]; then
      # A subshell, as a failed sign-in ends oh_onedrive_setup with oh_die.
      case $od in
      *rclone*) (oh_onedrive_setup --client rclone) <&"${OH_TTY_FD:-0}" || oh_setup_onedrive_failed ;;
      *abraunegg*) (oh_onedrive_setup --client abraunegg) <&"${OH_TTY_FD:-0}" || oh_setup_onedrive_failed ;;
      *) oh_dim "Later: omarchohard onedrive setup" ;;
      esac
      OH_CFG_LOADED=0 && oh_config_load
    else
      oh_dim "Later: omarchohard onedrive setup"
    fi
  fi

  # Native Office's prewarm is its own: the Wine server, not the browser.
  if [[ $tier == native ]]; then
    case $want_prewarm in
    on) native_prewarm=1 ;;
    off) oh_native_prewarm off >/dev/null 2>&1 || true ;;
    esac
  fi
  if [[ ${iso_flag[*]} == --isolated ]]; then
    case $want_prewarm in
    on) oh_prewarm on ;;
    off) oh_prewarm off >/dev/null ;;
    *)
      [[ $(oh_prewarm status 2>/dev/null) == "prewarm: on" ]] ||
        { oh_ui_confirm "Keep Microsoft 365 ready in the background, so apps open in about 0.2 s? (about 215 MB of memory)" no && oh_prewarm on; }
      ;;
    esac
  fi
  if ((optimize)); then
    oh_ui_step "Tuning for this device"
    oh_optimize --apply
  fi

  # Desktop Office last: it runs for about 20 minutes, and every question
  # above is answered by then. A subshell, as the install ends with oh_die.
  if [[ $tier == desktop ]]; then
    oh_ui_step "Desktop Office (about 20 minutes)"
    (oh_desktop_install --wait) || desktop_failed=1
    OH_CFG_LOADED=0 && oh_config_load
  fi
  if [[ $tier == native ]]; then
    oh_ui_step "Native Office (under a minute from a seed, about 6 minutes from Microsoft)"
    if (oh_native_install "${native_args[@]}"); then
      oh_dry || : >"$OH_NATIVE_DONE"
      ((native_prewarm == 0)) || oh_native_prewarm on || oh_warn "native prewarm did not start"
    else
      native_failed=1
    fi
    OH_CFG_LOADED=0 && oh_config_load
  fi

  # Finish: the same check doctor runs.
  oh_ui_step "Checking everything"
  if (oh_doctor) >/dev/null 2>&1; then
    oh_ui_header "Microsoft 365 is ready." "" \
      "Open your apps with Super + Alt + Space and type Word, Excel or Teams." \
      "Office files in Files open in the right app." \
      "" \
      "Check it any time:  omarchohard doctor" \
      "Run this again:     omarchohard setup"
    oh_notify "Microsoft 365 is ready" "Press Super + Alt + Space and type Word."
  else
    (oh_doctor) || true
    oh_warn "setup finished with problems; the lines marked fail above say what to fix"
  fi
  if [[ $tier != native ]] && oh_ui_interactive && oh_ui_confirm "Open Word now?" no; then
    oh_native_launch word || oh_desktop_launch word || oh_launch word
  fi
  if ((desktop_failed)); then
    oh_warn "desktop Office did not finish; the web apps work meanwhile. See: omarchohard desktop status"
  fi
  # The install's lock is let go first: Word and the sign-in session it
  # starts must not hold it.
  [[ -z ${OH_NATIVE_LOCK_FD:-} ]] || exec {OH_NATIVE_LOCK_FD}>&-
  if ((native_failed)); then
    oh_warn "native Office did not finish; the web apps work meanwhile. See: omarchohard native status"
  elif [[ $tier == native ]]; then
    # The sign-in is the last step, and its line the last line.
    local -a signin_args=()
    [[ -z $want_email ]] || signin_args+=(--email "$want_email")
    if ((remote_signin)); then
      if signin_url=$(oh_native_signin --remote "${signin_args[@]}"); then
        signin_url=${signin_url##*Sign in here: }
        oh_dry && signin_url=''
      else
        signin_url='' signin_note="the sign-in link could not start (the line above says why); sign in later with: omarchohard native signin --remote"
      fi
    elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && oh_native_signin "${signin_args[@]}"; then
      signin_note="the sign-in window is open on this screen"
    else
      signin_note="sign in on this screen with: omarchohard native signin, or from another device: omarchohard native signin --remote"
    fi
  fi
  if [[ $tier == native ]] && ((! native_failed)); then
    if [[ -n $signin_url ]]; then
      printf 'Sign in here: %s\n' "$signin_url"
    else
      oh_say "Sign in next: $signin_note${want_email:+ (as $want_email)}"
    fi
  fi
  if ((pause)) && oh_ui_interactive; then
    read -r -s -n 1 -p "Press any key to close." <&"$OH_TTY_FD" || true
    printf '\n' >&2
  fi
  if ((json)); then
    trap - EXIT
    if ((desktop_failed || native_failed)); then
      oh_setup_json failed "" "the install did not finish; the lines above say why"
    elif [[ $tier == native ]]; then
      oh_setup_json needs_signin "$signin_url" "$signin_note"
    else
      oh_setup_json ready
    fi
  fi
  ((desktop_failed == 0 && native_failed == 0))
}
