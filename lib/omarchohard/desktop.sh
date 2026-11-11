# shellcheck shell=bash
# Desktop tier (experimental): real Microsoft Office in a Windows VM, each app
# shown as its own Linux window through WinApps (KVM + FreeRDP RemoteApp).
#
# Layout:
#   $OH_DATA_DIR/winapps         pinned WinApps checkout
#   $OH_DATA_DIR/vm/compose.yaml dockur/windows VM definition
#   $OH_DATA_DIR/vm/oem          first-boot scripts copied into C:\OEM
#   $OH_DATA_DIR/vm-inbox        one-shot requests the VM applies (activation)
#
# Product keys are never put on a command line, in the config, or in a log.
# They are read from a file or a hidden prompt, written to a 0600 request file
# that the VM reads and deletes, and the host deletes it again afterward.

OH_WINAPPS_REF=0b950dc4b823a759015c549a46c35aaaf31c77c0
OH_VM_DIR=$OH_DATA_DIR/vm
OH_WINAPPS_DIR=$OH_DATA_DIR/winapps
OH_VM_INBOX=$OH_DATA_DIR/vm-inbox
OH_WINAPPS_CONF=${XDG_CONFIG_HOME:-$HOME/.config}/winapps/winapps.conf

declare -gA OH_OFFICE_PRODUCT=(
  [m365]=O365ProPlusRetail
  ["m365-home"]=O365HomePremRetail
  [2024]=ProPlus2024Retail
  [home2024]=HomeStudent2024Retail
  [2021]=ProPlus2021Retail
)

declare -gA OH_WINAPPS_APP=(
  [word]=word-o365 [excel]=excel-o365 [powerpoint]=powerpoint-o365
  [outlook]=outlook-o365 [onenote]=onenote-o365
)

oh_desktop_engine() {
  if oh_have docker && docker info >/dev/null 2>&1; then
    echo docker
  elif oh_have podman; then
    echo podman
  else
    return 1
  fi
}

oh_desktop_compose() {
  local engine
  engine=$(oh_desktop_engine) || oh_die "Docker or Podman is required"
  if [[ $engine == podman ]]; then
    oh_run podman-compose -f "$OH_VM_DIR/compose.yaml" "$@"
  else
    oh_run docker compose -f "$OH_VM_DIR/compose.yaml" "$@"
  fi
}

oh_mem_kib() { awk -v k="$1" '$1 == k":" { print $2 }' /proc/meminfo; }

# Preflight. Prints each result; returns 1 if the host cannot run the VM well.
oh_desktop_check() {
  local bad=0 total avail free_gb engine
  total=$(($(oh_mem_kib MemTotal) / 1048576))
  avail=$(($(oh_mem_kib MemAvailable) / 1048576))
  free_gb=$(($(df --output=avail -k "$HOME" | tail -n1) / 1048576))

  if [[ -r /dev/kvm && -w /dev/kvm ]]; then oh_ok "KVM: /dev/kvm is usable"; else
    oh_err "KVM: /dev/kvm is missing or not writable (enable virtualization in firmware; join the kvm group)"
    bad=1
  fi
  if engine=$(oh_desktop_engine); then oh_ok "container engine: $engine"; else
    oh_err "container engine: install Docker (omarchy install docker) or Podman"
    bad=1
  fi
  if oh_have xfreerdp3 || oh_have xfreerdp || oh_have sdl-freerdp3; then oh_ok "FreeRDP found"; else
    oh_err "FreeRDP 3 is missing: omarchy pkg add freerdp"
    bad=1
  fi
  if ((total >= 16)); then oh_ok "memory: ${total} GiB total"; else
    oh_err "memory: ${total} GiB total; the VM needs 4 GiB on a host with at least 16 GiB"
    bad=1
  fi
  if ((avail >= 6)); then oh_ok "memory free now: ${avail} GiB"; else
    oh_err "memory free now: ${avail} GiB; close something first (the VM takes 4 GiB, Windows needs headroom)"
    bad=1
  fi
  if ((free_gb >= 80)); then oh_ok "disk free: ${free_gb} GB"; else
    oh_err "disk free: ${free_gb} GB; Windows plus Office needs about 80 GB"
    bad=1
  fi
  ((bad == 0))
}

oh_desktop_install() {
  local windows=11e office=m365 ram=4G force=0 user pass engine
  while (($#)); do
    case $1 in
    --windows)
      windows=${2:?--windows needs 11e (free evaluation) or 11 (your own license)}
      shift
      ;;
    --office)
      office=${2:?--office needs one of: ${!OH_OFFICE_PRODUCT[*]}}
      shift
      ;;
    --ram)
      ram=${2:?--ram needs a size like 4G}
      shift
      ;;
    --force) force=1 ;;
    *) oh_die "unknown desktop install option: $1" ;;
    esac
    shift
  done
  [[ $windows == 11e || $windows == 11 || $windows == 10e || $windows == 10 ]] || oh_die "--windows must be 11e, 11, 10e or 10"
  [[ -n ${OH_OFFICE_PRODUCT[$office]:-} ]] || oh_die "--office must be one of: ${!OH_OFFICE_PRODUCT[*]}"
  [[ $ram =~ ^[0-9]+G$ ]] || oh_die "--ram must look like 4G"

  oh_say "Checking this machine for the desktop tier:"
  if ! oh_desktop_check; then
    ((force)) || oh_die "this machine is not ready for a Windows VM (use --force to try anyway)"
    oh_warn "continuing because of --force"
  fi
  engine=$(oh_desktop_engine)

  # Pinned WinApps.
  if [[ ! -d $OH_WINAPPS_DIR/.git ]]; then
    oh_run git clone --quiet https://github.com/winapps-org/winapps.git "$OH_WINAPPS_DIR"
  fi
  oh_run git -C "$OH_WINAPPS_DIR" fetch --quiet origin "$OH_WINAPPS_REF"
  oh_run git -C "$OH_WINAPPS_DIR" checkout --quiet "$OH_WINAPPS_REF"

  # A local-only Windows account for RDP. The VM listens on 127.0.0.1 only.
  user=omarchohard
  if [[ -f $OH_WINAPPS_CONF ]]; then
    oh_warn "keeping your existing $OH_WINAPPS_CONF"
    pass=$(sed -n 's/^RDP_PASS="\(.*\)"$/\1/p' "$OH_WINAPPS_CONF")
    user=$(sed -n 's/^RDP_USER="\(.*\)"$/\1/p' "$OH_WINAPPS_CONF")
  else
    pass=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    mkdir -p "${OH_WINAPPS_CONF%/*}"
    (
      umask 077
      cat >"$OH_WINAPPS_CONF" <<EOF
# Written by omarchohard. Local VM account; the VM is reachable only from this machine.
RDP_USER="$user"
RDP_PASS="$pass"
RDP_DOMAIN=""
RDP_IP="127.0.0.1"
VM_NAME="WinApps"
WAFLAVOR="$engine"
RDP_SCALE="100"
REMOVABLE_MEDIA="/run/media"
RDP_FLAGS="/cert:tofu /sound /microphone +home-drive"
DEBUG="true"
AUTOPAUSE="on"
AUTOPAUSE_TIME="300"
FREERDP_COMMAND=""
EOF
    )
  fi

  # VM definition and first-boot scripts.
  mkdir -p "$OH_VM_DIR/oem" "$OH_VM_INBOX"
  chmod 700 "$OH_VM_INBOX"
  cp "$OH_WINAPPS_DIR"/oem/* "$OH_VM_DIR/oem/" 2>/dev/null || true
  [[ -f $OH_VM_DIR/oem/install.bat && ! -f $OH_VM_DIR/oem/winapps-install.bat ]] &&
    mv "$OH_VM_DIR/oem/install.bat" "$OH_VM_DIR/oem/winapps-install.bat"
  cp "$OH_SHARE/vm/install.bat" "$OH_SHARE/vm/office.ps1" "$OH_SHARE/vm/inbox.ps1" "$OH_VM_DIR/oem/"
  printf '%s\n' "${OH_OFFICE_PRODUCT[$office]}" >"$OH_VM_DIR/oem/office-product.txt"
  [[ $OH_VM_INBOX == "$HOME"/* ]] || oh_die "the VM inbox must be under your home folder (it is shared with the VM)"
  # shellcheck disable=SC1003 # '\\' is one backslash to tr
  printf '%s\n' "${OH_VM_INBOX#"$HOME"/}" | tr '/' '\\' >"$OH_VM_DIR/oem/inbox-path.txt"
  sed -e "s|@VERSION@|$windows|" -e "s|@RAM@|$ram|" -e "s|@USER@|$user|" -e "s|@PASS@|$pass|" \
    "$OH_SHARE/vm/compose.yaml.in" >"$OH_VM_DIR/compose.yaml"
  chmod 600 "$OH_VM_DIR/compose.yaml"

  oh_config_set desktop_office "$office"
  oh_desktop_compose up -d
  oh_say ""
  oh_ok "Windows is installing itself in the VM. This takes 20 to 40 minutes."
  oh_say "Watch it at http://127.0.0.1:8006 . Office installs right after Windows."
  oh_say "When Word appears in the VM, run: omarchohard desktop apps"
}

# Register the Office apps as Linux launchers through WinApps.
oh_desktop_apps() {
  [[ -x $OH_WINAPPS_DIR/setup.sh ]] || oh_die "run omarchohard desktop install first"
  oh_say "WinApps now scans the VM and lists the apps it found. Choose the Office apps."
  oh_run "$OH_WINAPPS_DIR/setup.sh" --user
  oh_say ""
  oh_say "To open local files in desktop Office instead of the web apps:"
  oh_say "  omarchohard desktop prefer on"
}

oh_desktop_ready() {
  oh_have winapps && [[ -f $OH_WINAPPS_CONF && -f $OH_VM_DIR/compose.yaml ]]
}

oh_desktop_open_file() {
  local app=$1 file=$2 wa
  wa=${OH_WINAPPS_APP[$app]:-}
  [[ -n $wa ]] || oh_die "no desktop app for $app"
  [[ $file == "$HOME"/* || $file == /run/media/* ]] ||
    oh_die "desktop Office can open files under $HOME or /run/media only"
  oh_spawn winapps "$wa" "$file"
}

oh_desktop_open_url() {
  local uri=$1 app
  case $uri in
  ms-word:*) app=word ;;
  ms-excel:*) app=excel ;;
  ms-powerpoint:*) app=powerpoint ;;
  *) app=onenote ;;
  esac
  oh_spawn winapps "${OH_WINAPPS_APP[$app]}"
}

# Read a key without echoing it. Accepts XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.
oh_desktop_read_key() {
  local file=$1 label=$2 key
  if [[ -n $file ]]; then
    [[ -r $file ]] || oh_die "cannot read $file"
    key=$(tr -d '[:space:]' <"$file")
  else
    [[ -t 0 ]] || oh_die "no terminal to ask for the $label; pass a key file"
    read -r -s -p "$label (input hidden): " key
    printf '\n' >&2
  fi
  key=${key^^}
  [[ $key =~ ^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$ ]] || oh_die "that is not a 25-character product key"
  printf '%s' "$key"
}

oh_desktop_request() {
  local action=$1 key=${2:-} id req result i
  id=$(date +%s)-$RANDOM
  req=$OH_VM_INBOX/$id.request
  result=$OH_VM_INBOX/$id.result
  mkdir -p "$OH_VM_INBOX"
  (
    umask 077
    jq -cn --arg a "$action" --arg k "$key" '{action:$a,key:$k}' >"$req.tmp"
    mv "$req.tmp" "$req"
  )
  oh_say "Sent to the VM; waiting for Windows to apply it (up to 3 minutes)..."
  for ((i = 0; i < 180; i++)); do
    if [[ -f $result ]]; then
      rm -f "$req"
      cat "$result"
      rm -f "$result"
      return 0
    fi
    sleep 1
  done
  rm -f "$req"
  oh_die "the VM did not answer. Is it running? (omarchohard desktop up)"
}

oh_desktop_activate() {
  local office_file='' windows_file='' status=0 key
  while (($#)); do
    case $1 in
    --key-file | --office-key-file)
      office_file=${2:?needs a file}
      shift
      ;;
    --windows-key-file)
      windows_file=${2:?needs a file}
      shift
      ;;
    --windows) windows_file=- ;;
    --status) status=1 ;;
    *) oh_die "unknown activate option: $1" ;;
    esac
    shift
  done
  [[ -d $OH_VM_DIR ]] || oh_die "run omarchohard desktop install first"
  if ((status)); then
    oh_desktop_request status
    return
  fi
  if [[ -n $windows_file ]]; then
    [[ $windows_file == - ]] && windows_file=''
    key=$(oh_desktop_read_key "$windows_file" "Windows product key")
    oh_desktop_request windows-key "$key"
    key=''
    return
  fi
  oh_say "Microsoft 365 (school, work or personal subscription) activates by signing in:"
  oh_say "open Word from the launcher and sign in. Use a product key only for a bought Office 2021 or 2024."
  key=$(oh_desktop_read_key "$office_file" "Office product key")
  oh_desktop_request office-key "$key"
  key=''
}

oh_desktop_prefer() {
  case ${1:-} in
  on)
    oh_desktop_ready || oh_die "desktop Office is not set up yet (omarchohard desktop apps)"
    oh_config_set open_with desktop
    oh_ok "local Office files now open in desktop Office"
    ;;
  off)
    oh_config_set open_with web
    oh_ok "local Office files now open in the web apps"
    ;;
  *) oh_die "usage: omarchohard desktop prefer on|off" ;;
  esac
}

oh_desktop_remove() {
  local delete_vm=0 answer
  [[ ${1:-} == --delete-vm ]] && delete_vm=1
  [[ -f $OH_VM_DIR/compose.yaml ]] || {
    oh_ok "desktop tier is not installed"
    return 0
  }
  if ((delete_vm)); then
    [[ -t 0 ]] || oh_die "--delete-vm asks for confirmation; run it in a terminal"
    read -r -p "This deletes the Windows VM disk and everything in it. Type DELETE to confirm: " answer
    [[ $answer == DELETE ]] || oh_die "not deleted"
    oh_desktop_compose down -v
  else
    oh_desktop_compose down
  fi
  oh_config_set open_with web
  if ((delete_vm)); then oh_ok "desktop tier removed and the VM disk deleted"; else oh_ok "desktop tier stopped; the VM disk is kept"; fi
  oh_dim "WinApps launchers can be removed with: $OH_WINAPPS_DIR/setup.sh --user --uninstall"
}

oh_desktop_doctor() {
  [[ -f $OH_VM_DIR/compose.yaml ]] || return 0
  if ! oh_have winapps; then
    oh_doc warn "desktop Office" "VM defined but WinApps launchers are not installed (omarchohard desktop apps)"
    return 0
  fi
  local engine state
  engine=$(oh_desktop_engine 2>/dev/null) || {
    oh_doc fail "desktop Office" "no container engine"
    return 0
  }
  state=$("$engine" inspect -f '{{.State.Status}}' WinApps 2>/dev/null || echo missing)
  case $state in
  running) oh_doc ok "desktop Office" "VM running" ;;
  exited | paused) oh_doc warn "desktop Office" "VM is $state (omarchohard desktop up)" ;;
  *) oh_doc fail "desktop Office" "VM container is $state" ;;
  esac
}

oh_desktop() {
  oh_config_load
  local action=${1:-check}
  (($#)) && shift
  case $action in
  check) oh_desktop_check ;;
  install) oh_desktop_install "$@" ;;
  up) oh_desktop_compose up -d ;;
  down) oh_desktop_compose stop ;;
  apps) oh_desktop_apps ;;
  activate) oh_desktop_activate "$@" ;;
  prefer) oh_desktop_prefer "$@" ;;
  remove) oh_desktop_remove "$@" ;;
  *) oh_die "usage: omarchohard desktop check|install|up|down|apps|activate|prefer|remove" ;;
  esac
}
