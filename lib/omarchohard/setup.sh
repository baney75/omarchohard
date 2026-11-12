# shellcheck shell=bash
# Guided first-run setup: browser, sign-in, OneDrive and a final check, one
# question at a time. Uses gum (Omarchy ships it) and falls back to plain
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

# oh_ui_pick HEADER OPTION...: several choices, all selected to start; prints
# one per line. Plain prompts take numbers ("1 3 6"); Enter keeps them all.
oh_ui_pick() {
  local header=$1 answer n
  shift
  if ! oh_ui_interactive; then
    printf '%s\n' "$@"
    return
  fi
  if oh_ui_gum; then
    gum choose --no-limit --header "$header" --selected "$(
      IFS=,
      printf '%s' "$*"
    )" "$@" <&"$OH_TTY_FD"
    return
  fi
  printf '%s\n' "$header" >&2
  for ((n = 1; n <= $#; n++)); do printf '  %d) %s\n' "$n" "${!n}" >&2; done
  read -r -p "Numbers to install [all]: " answer <&"$OH_TTY_FD" || answer=''
  if [[ -z ${answer//[[:space:],]/} ]]; then
    printf '%s\n' "$@"
    return
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
    printf 'Icon=omarchohard-m365\nTerminal=false\nCategories=Settings;Office;\n'
    printf 'Keywords=Microsoft;Office;365;OneDrive;setup;sign in;\n'
  } >"$file"
  oh_manifest_add "$file"
}

oh_setup() {
  OH_CFG_LOADED=0 && oh_config_load
  local pause=0 line bin='' label choice email mail_flag=() iso_flag=() od='' answer
  local want_bin='' want_profile='' want_email='' want_mail='' want_prewarm='' want_apps='' optimize=0
  local -a browsers labels
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
    --apps)
      want_apps=$(oh_apps_parse "${2:?--apps needs a list, like word,excel,teams or all}") || exit 1
      shift
      ;;
    *) oh_die "unknown setup option: $1 (see: omarchohard help setup)" ;;
    esac
    shift
  done
  case $od in '' | rclone | abraunegg | none) ;; *) oh_die "--onedrive takes rclone, abraunegg or none" ;; esac
  case $want_prewarm in '' | on | off) ;; *) oh_die "--prewarm takes on or off" ;; esac

  oh_ui_interactive && oh_ui_open
  oh_ui_header "omarchohard setup" "" \
    "Word, Excel, PowerPoint, Outlook, OneNote, Teams and OneDrive" \
    "as apps on Omarchy. About two minutes; every step can be undone" \
    "with: omarchohard uninstall"

  # 1. Browser. App windows need a Chromium-based browser.
  oh_ui_step "1 of 5  Browser"
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

  # 2. Account. Optional; it fills in the sign-in page and the OneDrive address.
  oh_ui_step "2 of 5  Account"
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

  # 3. Launchers and file handlers.
  oh_ui_step "3 of 5  Apps and files"
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
  if [[ $want_mail == 0 ]]; then
    mail_flag=(--no-mail)
  else
    oh_ui_confirm "Open email links (mailto:) in Outlook?" yes || mail_flag=(--no-mail)
  fi
  oh_install "${iso_flag[@]}" "${mail_flag[@]}" 2>&1 | grep -v -e '^Installed. Next:' -e '^  omarchohard ' -e '^$' >&2 || true
  [[ -f $OH_MANIFEST ]] || oh_dry || oh_die "installing the launchers failed; run omarchohard install to see why"
  OH_CFG_LOADED=0 && oh_config_load

  # 4. Sign in, once, on Microsoft's own page.
  oh_ui_step "4 of 5  Sign in"
  if [[ ${iso_flag[*]} == --isolated ]]; then
    oh_say "Microsoft 365 has its own profile, so sign in once here."
  else
    oh_say "If you are already signed in to Microsoft in $(oh_browser_label "$bin"), you can skip this."
  fi
  if oh_ui_interactive && oh_ui_confirm "Open the Microsoft sign-in page now?" yes; then
    oh_login
    oh_ui_interactive && oh_ui_confirm "Finished signing in? (your school or work SSO page counts)" yes >/dev/null || true
  fi

  # 5. OneDrive on disk, so Office files open from Files.
  oh_ui_step "5 of 5  OneDrive"
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
      *rclone*) (oh_onedrive_setup --client rclone) <&"${OH_TTY_FD:-0}" || oh_warn "OneDrive is not set up yet; try again with: omarchohard onedrive setup" ;;
      *abraunegg*) (oh_onedrive_setup --client abraunegg) <&"${OH_TTY_FD:-0}" || oh_warn "OneDrive is not set up yet; try again with: omarchohard onedrive setup" ;;
      *) oh_dim "Later: omarchohard onedrive setup" ;;
      esac
      OH_CFG_LOADED=0 && oh_config_load
    else
      oh_dim "Later: omarchohard onedrive setup"
    fi
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
  if oh_ui_interactive && oh_ui_confirm "Open Word now?" no; then
    oh_launch word
  fi
  if ((pause)) && oh_ui_interactive; then
    read -r -s -n 1 -p "Press any key to close." <&"$OH_TTY_FD" || true
    printf '\n' >&2
  fi
  return 0
}
