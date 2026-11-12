# shellcheck shell=bash
# Desktop tier (experimental): real Microsoft Office in a Windows VM, each app
# shown as its own Linux window through WinApps (KVM + FreeRDP RemoteApp).
#
# Layout:
#   $OH_DATA_DIR/winapps         pinned WinApps checkout
#   $OH_DATA_DIR/vm/compose.yaml dockur/windows VM definition
#   $OH_DATA_DIR/vm/storage      the VM disk (a named volume before 0.2.0)
#   $OH_DATA_DIR/vm/oem          first-boot scripts copied into C:\OEM
#   $OH_DATA_DIR/vm-inbox        one-shot requests the VM applies (activation)
#
# Product keys are never put on a command line, in the config, or in a log.
# They are read from a file or a hidden prompt, written to a 0600 request file
# that the VM reads and deletes, and the host deletes it again afterward.
#
# The VM shares the whole home folder (dockur's /shared), so Windows can read
# every file under ~, config files included. See docs/desktop-tier.md.

OH_WINAPPS_REF=0b950dc4b823a759015c549a46c35aaaf31c77c0
OH_VM_DIR=$OH_DATA_DIR/vm
OH_WINAPPS_DIR=$OH_DATA_DIR/winapps
OH_VM_INBOX=$OH_DATA_DIR/vm-inbox
OH_WINAPPS_CONF=${XDG_CONFIG_HOME:-$HOME/.config}/winapps/winapps.conf
OH_VM_NAME=WinApps
OH_OFFICE_STATUS=$OH_VM_INBOX/office-status.json

declare -gA OH_OFFICE_PRODUCT=(
  [m365]=O365ProPlusRetail
  ["m365-home"]=O365HomePremRetail
  [2024]=ProPlus2024Retail
  [home2024]=Home2024Retail
  [homebusiness2024]=HomeBusiness2024Retail
  [2021]=ProPlus2021Retail
)

declare -gA OH_WINAPPS_APP=(
  [word]=word-o365 [excel]=excel-o365 [powerpoint]=powerpoint-o365
  [outlook]=outlook-o365 [onenote]=onenote-o365
)
# Office update channels: the name omarchohard takes, and Office's own name.
declare -gA OH_OFFICE_CHANNELS=([current]=Current [monthly]=MonthlyEnterprise ["semi-annual"]=SemiAnnual)

# The window title of each app: "Report.docx - Word", or the app's own name
# while no document is open. Not the window class: every new FreeRDP
# RemoteApp connection takes over all windows of the Windows session, so once
# Excel opens, Word's window has the class "Microsoft Excel" too (seen live,
# 2026-11-12). The Hyprland rules in omarchohard.lua use the same titles.
declare -gA OH_WINAPPS_TITLE=(
  [word]='^(.+ - Word|Microsoft Word)$'
  [excel]='^(.+ - Excel|Microsoft Excel)$'
  [powerpoint]='^(.+ - PowerPoint|Microsoft PowerPoint)$'
  [outlook]='^(.+- Outlook|Outlook)$'
  [onenote]='^(.+ - OneNote|OneNote)$'
)
# The hidden window each RemoteApp session keeps open.
OH_RDP_MARKER='RemoteApp Marker Window'

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

# The WinApps settings omarchohard uses, from winapps.conf. Parsed in bash so
# the password never reaches argv. Returns 1 when there is no winapps.conf.
declare -gA OH_WA=()
oh_winapps_conf_load() {
  local line key value
  OH_WA=([RDP_USER]=omarchohard [RDP_PASS]='' [RDP_DOMAIN]='' [RDP_IP]=127.0.0.1 [RDP_PORT]=3389)
  [[ -f $OH_WINAPPS_CONF ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
    RDP_USER=\"*\" | RDP_PASS=\"*\" | RDP_DOMAIN=\"*\" | RDP_IP=\"*\" | RDP_PORT=\"*\")
      key=${line%%=*} value=${line#*=\"} value=${value%\"}
      OH_WA[$key]=$value
      ;;
    RDP_PORT=[0-9]*) OH_WA[RDP_PORT]=${line#RDP_PORT=} ;;
    esac
  done <"$OH_WINAPPS_CONF"
}

oh_mem_kib() { awk -v k="$1" '$1 == k":" { print $2 }' /proc/meminfo; }

# Preflight. Prints each result; returns 1 if the host cannot run the VM well.
oh_desktop_check() {
  local bad=0 total avail free_gb engine
  # MiB: the kernel keeps some memory back, so a 16 GB machine shows about 15.4 GiB.
  total=$(($(oh_mem_kib MemTotal) / 1024))
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
  if ((total >= 15360)); then oh_ok "memory: $(((total + 512) / 1024)) GiB total"; else
    oh_err "memory: $(((total + 512) / 1024)) GiB total; the VM needs 4 GiB on a host with at least 16 GiB"
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

# A value inside a YAML double-quoted string that compose reads: escape \ and ",
# and $ is compose interpolation.
oh_compose_str() {
  local s=$1 bs=\\
  s=${s//"$bs"/"$bs$bs"}
  s=${s//\"/"$bs\""}
  s=${s//\$/\$\$}
  printf '%s' "$s"
}

# dockur warns that Windows Setup can fail when /storage is on btrfs,
# Omarchy's default, as copy-on-write fragments the disk image. chattr +C on
# the empty folder makes every file created in it later no-COW; it does not
# change files already there, so it runs only before the disk image exists.
oh_desktop_storage() {
  local dir=$OH_VM_DIR/storage
  mkdir -p "$dir"
  [[ $(stat -f -c %T "$dir" 2>/dev/null) == btrfs && -z $(ls -A "$dir") ]] || return 0
  oh_run chattr +C "$dir" 2>/dev/null ||
    oh_warn "could not turn off copy-on-write on $dir (chattr +C); Windows Setup can fail on btrfs"
}

oh_desktop_install() {
  local windows=11e office=m365 ram=4G force=0 wait=0 legacy=0 user pass engine tpl
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
    --wait) wait=1 ;;
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
  if oh_winapps_conf_load; then
    oh_warn "keeping your existing $OH_WINAPPS_CONF"
    user=${OH_WA[RDP_USER]} pass=${OH_WA[RDP_PASS]}
  else
    user=omarchohard
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
  cp "$OH_SHARE/vm/install.bat" "$OH_SHARE/vm/office.ps1" "$OH_SHARE/vm/office-info.ps1" "$OH_SHARE/vm/inbox.ps1" "$OH_VM_DIR/oem/"
  printf '%s\n' "${OH_OFFICE_PRODUCT[$office]}" >"$OH_VM_DIR/oem/office-product.txt"
  [[ $OH_VM_INBOX == "$HOME"/* ]] || oh_die "the VM inbox must be under your home folder (it is shared with the VM)"
  # shellcheck disable=SC1003 # '\\' is one backslash to tr
  printf '%s\n' "${OH_VM_INBOX#"$HOME"/}" | tr '/' '\\' >"$OH_VM_DIR/oem/inbox-path.txt"
  # A VM made before 0.2.0 keeps its disk in the named volume "data"; new
  # installs keep it in a folder next to compose.yaml.
  [[ -f $OH_VM_DIR/compose.yaml ]] && grep -qxF '      - data:/storage' "$OH_VM_DIR/compose.yaml" && legacy=1
  # Built in bash, not sed, so the password is never in a process's arguments.
  tpl=$(<"$OH_SHARE/vm/compose.yaml.in")
  tpl=${tpl//@VERSION@/"$windows"}
  tpl=${tpl//@RAM@/"$ram"}
  tpl=${tpl//@USER@/"$(oh_compose_str "$user")"}
  tpl=${tpl//@PASS@/"$(oh_compose_str "$pass")"}
  if ((legacy)); then
    tpl=${tpl//'      - ./storage:/storage'/'      - data:/storage'}
    tpl=${tpl/$'\nservices:'/$'\nvolumes:\n  data:\nservices:'}
    oh_dim "keeping the VM disk in its docker volume (made before omarchohard 0.2.0)"
  else
    oh_desktop_storage
  fi
  (
    umask 077
    printf '%s\n' "$tpl" >"$OH_VM_DIR/compose.yaml"
  )
  chmod 600 "$OH_VM_DIR/compose.yaml"

  oh_config_set desktop_office "$office"
  oh_desktop_compose up -d
  oh_say ""
  oh_ok "Windows is installing itself in the VM. With Office, this takes about 45 minutes."
  oh_say "Watch it at http://127.0.0.1:8006 . Office installs right after Windows."
  if ((wait)); then
    oh_desktop_wait
  else
    oh_say "Follow it, and add the apps when Office is ready, with: omarchohard desktop wait"
  fi
}

# Where the install is, from the container's state, its log, the RDP port and
# office-status.json (written by office.ps1 in the VM). Sets OH_VM_PHASE to one
# of not-installed downloading-windows installing-windows installing-office
# starting ready failed stopped paused, with OH_VM_DETAIL saying more.
oh_desktop_phase() {
  local engine state code line logs found=''
  OH_VM_PHASE=not-installed OH_VM_DETAIL='' OH_VM_STATE=missing OH_RDP_UP=0
  oh_desktop_office_load || true
  if [[ ! -f $OH_VM_DIR/compose.yaml ]]; then
    OH_VM_DETAIL="set it up with: omarchohard desktop install --wait"
    return 0
  fi
  if ! engine=$(oh_desktop_engine 2>/dev/null); then
    OH_VM_PHASE=failed OH_VM_DETAIL="no container engine; install Docker (omarchy install docker) or Podman"
    return 0
  fi
  state=$("$engine" inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$OH_VM_NAME" 2>/dev/null) || state=missing
  code=${state#* } state=${state%% *}
  OH_VM_STATE=$state
  case $state in
  missing)
    OH_VM_PHASE=stopped OH_VM_DETAIL="the VM container does not exist (omarchohard desktop up)"
    return 0
    ;;
  paused)
    OH_VM_PHASE=paused OH_VM_DETAIL="paused while idle; it resumes when you open an app"
    return 0
    ;;
  exited | dead)
    if [[ $code == 0 ]]; then
      OH_VM_PHASE=stopped OH_VM_DETAIL="start it with: omarchohard desktop up"
    else
      line=$("$engine" logs --tail 20 "$OH_VM_NAME" 2>&1 | grep -F 'ERROR' | tail -n1 || true)
      OH_VM_PHASE=failed OH_VM_DETAIL="the VM stopped with code $code${line:+: $(oh_desktop_log_text "$line")}"
    fi
    return 0
    ;;
  running | restarting | created) ;;
  *)
    OH_VM_PHASE=failed OH_VM_DETAIL="the VM container is $state"
    return 0
    ;;
  esac
  oh_desktop_rdp_up && OH_RDP_UP=1

  case $OH_OFFICE_PHASE in
  failed)
    OH_VM_PHASE=failed OH_VM_DETAIL="Office did not install: ${OH_OFFICE_ERROR:-no reason given}; see C:\OEM\office.log in the VM (http://127.0.0.1:8006)"
    return 0
    ;;
  installing-office)
    OH_VM_PHASE=installing-office OH_VM_DETAIL="Office is downloading and installing in the VM"
    return 0
    ;;
  ready)
    if ((OH_RDP_UP)); then
      OH_VM_PHASE=ready OH_VM_DETAIL="${OH_OFFICE_VERSION:+Office $OH_OFFICE_VERSION}"
    else
      OH_VM_PHASE=starting OH_VM_DETAIL="Windows is starting; RDP does not answer yet"
    fi
    return 0
    ;;
  esac

  # No status file yet: Windows itself is still on its way. dockur's log says
  # how far: downloading and building the install image, then booting it.
  logs=$("$engine" logs --tail 300 "$OH_VM_NAME" 2>&1 || true)
  while IFS= read -r line; do
    case $line in
    *ERROR:*) found=failed OH_VM_DETAIL=$(oh_desktop_log_text "$line") ;;
    *Requesting* | *Downloading* | *Verifying* | *Extracting* | *Building* | *"Creating overlay"* | *"Adding "*)
      found=downloading-windows OH_VM_DETAIL=$(oh_desktop_log_text "$line")
      ;;
    *"Booting "* | *"started successfully"*)
      found=installing-windows OH_VM_DETAIL="Windows Setup is running in the VM; watch it at http://127.0.0.1:8006"
      ;;
    esac
  done <<<"$logs"
  # A VM made before 0.2.0 never writes office-status.json; there, launchers
  # WinApps registered mean Office was found.
  if [[ $found == installing-windows ]] && ((OH_RDP_UP)) && oh_desktop_launchers >/dev/null; then
    found=ready OH_VM_DETAIL="Office launchers are registered"
  fi
  OH_VM_PHASE=${found:-downloading-windows}
  [[ -n $found ]] || OH_VM_DETAIL="the VM is starting"
}

# One dockur log line as plain text: no colors, no leading marker.
oh_desktop_log_text() {
  local s=$1
  s=$(printf '%s' "$s" | sed -E $'s/\x1b\\[[0-9;]*m//g; s/^[^[:alnum:]]+//')
  printf '%s\n' "${s//[[:cntrl:]]/}"
}

# Something accepts connections on the RDP port. Docker's own proxy can accept
# before Windows listens, so this alone never means Windows is ready.
oh_desktop_rdp_up() {
  oh_winapps_conf_load || true
  [[ ${OH_WA[RDP_IP]} =~ ^[0-9A-Za-z.:-]+$ && ${OH_WA[RDP_PORT]} =~ ^[0-9]+$ ]] || return 1
  # shellcheck disable=SC2016 # expanded by the inner bash
  timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${OH_WA[RDP_IP]}" "${OH_WA[RDP_PORT]}" 2>/dev/null
}

# office-status.json, written in Windows. Read as data: unknown phases are
# dropped and every field is cut to one line of plain text.
oh_desktop_office_load() {
  local -a f=()
  OH_OFFICE_PHASE='' OH_OFFICE_PRODUCT='' OH_OFFICE_VERSION='' OH_OFFICE_CHANNEL='' OH_OFFICE_ERROR=''
  [[ -f $OH_OFFICE_STATUS ]] || return 1
  mapfile -t f < <(jq -r '[.phase, .product, .version, .channel, .error] | .[] | (. // "") | tostring | gsub("[[:cntrl:]]"; " ") | .[0:300]' "$OH_OFFICE_STATUS" 2>/dev/null)
  ((${#f[@]} == 5)) || return 1
  case ${f[0]} in installing-office | ready | failed) OH_OFFICE_PHASE=${f[0]} ;; esac
  OH_OFFICE_PRODUCT=${f[1]} OH_OFFICE_VERSION=${f[2]} OH_OFFICE_CHANNEL=${f[3]} OH_OFFICE_ERROR=${f[4]}
}

# The WinApps launchers for the Office apps, one path per line. Returns 1 when
# WinApps is not on PATH or registered none of them.
oh_desktop_launchers() {
  local wa found=1
  oh_have winapps || return 1
  for wa in "${OH_WINAPPS_APP[@]}"; do
    [[ -f $OH_APPS_DIR/$wa.desktop ]] && printf '%s\n' "$OH_APPS_DIR/$wa.desktop" && found=0
  done
  return "$found"
}

oh_desktop_status() {
  local json=0
  case ${1:-} in
  --json) json=1 ;;
  '') ;;
  *) oh_die "usage: omarchohard desktop status [--json]" ;;
  esac
  oh_desktop_phase
  if ((json)); then
    printf '{"phase":%s,"detail":%s,"vm":%s,"rdp":%s,"office":{"product":%s,"version":%s,"channel":%s,"error":%s},"open_with":%s}\n' \
      "$(oh_json_str "$OH_VM_PHASE")" "$(oh_json_str "$OH_VM_DETAIL")" "$(oh_json_str "$OH_VM_STATE")" \
      "$( ((OH_RDP_UP)) && echo true || echo false)" "$(oh_json_str "$OH_OFFICE_PRODUCT")" \
      "$(oh_json_str "$OH_OFFICE_VERSION")" "$(oh_json_str "$OH_OFFICE_CHANNEL")" \
      "$(oh_json_str "$OH_OFFICE_ERROR")" "$(oh_json_str "$(oh_config_get open_with)")"
    return 0
  fi
  printf 'phase: %s%s\n' "$OH_VM_PHASE" "${OH_VM_DETAIL:+ ($OH_VM_DETAIL)}"
  printf 'vm: %s\n' "$OH_VM_STATE"
  printf 'rdp: %s\n' "$( ((OH_RDP_UP)) && echo answers || echo 'no answer')"
  [[ -z $OH_OFFICE_VERSION ]] || printf 'office: %s %s, %s channel\n' "$OH_OFFICE_PRODUCT" "$OH_OFFICE_VERSION" "${OH_OFFICE_CHANNEL:-unknown}"
  printf 'open_with: %s\n' "$(oh_config_get open_with)"
}

# Print each change of phase until Office is ready, then add the apps. Stops
# after 90 minutes; Ctrl-C stops only the watching, never the VM.
oh_desktop_wait() {
  local poll=${OMARCHOHARD_DESKTOP_POLL:-10} start=$SECONDS last=''
  [[ -f $OH_VM_DIR/compose.yaml ]] || oh_die "run omarchohard desktop install first"
  trap 'oh_say ""; oh_say "Stopped watching. Windows keeps installing in the VM."; oh_say "Pick it up again with: omarchohard desktop wait"; exit 130' INT
  while :; do
    oh_desktop_phase
    if [[ $OH_VM_PHASE != "$last" ]]; then
      oh_say "$(date +%H:%M)  $OH_VM_PHASE${OH_VM_DETAIL:+: $OH_VM_DETAIL}"
      last=$OH_VM_PHASE
    fi
    case $OH_VM_PHASE in
    ready) break ;;
    failed) oh_die "the desktop install stopped: $OH_VM_DETAIL" ;;
    not-installed | stopped) oh_die "the VM is not running; start it with: omarchohard desktop up, then omarchohard desktop wait" ;;
    esac
    ((SECONDS - start < 5400)) ||
      oh_die "still $OH_VM_PHASE after 90 minutes. The VM keeps going; look at http://127.0.0.1:8006, then run: omarchohard desktop wait"
    sleep "$poll"
  done
  trap - INT
  oh_ok "Office is ready in the VM"
  oh_desktop_register
}

# Add the Office apps to the launcher through WinApps, without questions, and
# send local Office files to them.
# WinApps' setup.sh, run from its own folder, as it loads
# ./install/inquirer.sh. It exits 14 when FreeRDP cannot connect, which on a
# VM installed before 0.2.0 means Windows is still signed in at its console:
# a RemoteApp then shows "Another user is signed in" instead of the app.
oh_winapps_setup() {
  local rc=0
  (cd "$OH_WINAPPS_DIR" && oh_run ./setup.sh "$@") || rc=$?
  ((rc != 14)) ||
    oh_warn "WinApps could not open an app over RDP. If Windows is signed in on its own screen, sign out of Windows once at http://127.0.0.1:8006 (Start, your name, Sign out), then run: omarchohard desktop apps"
  return "$rc"
}

oh_desktop_register() {
  [[ -x $OH_WINAPPS_DIR/setup.sh ]] || oh_die "run omarchohard desktop install first"
  oh_say "Adding Word, Excel, PowerPoint, Outlook and OneNote to the launcher..."
  oh_winapps_setup --user --setupAllOfficiallySupportedApps ||
    oh_die "WinApps could not add the apps; try again with: omarchohard desktop apps"
  oh_desktop_addin_entry_write
  oh_refresh_desktop_db
  oh_desktop_prefer on
}

# Register the Office apps as Linux launchers through WinApps.
oh_desktop_apps() {
  [[ -x $OH_WINAPPS_DIR/setup.sh ]] || oh_die "run omarchohard desktop install first"
  oh_say "WinApps now scans the VM and lists the apps it found. Choose the Office apps."
  oh_winapps_setup --user || oh_die "WinApps did not finish; run omarchohard desktop apps again"
  oh_desktop_addin_entry_write
  oh_refresh_desktop_db
  oh_say ""
  oh_say "To open local files in desktop Office instead of the web apps:"
  oh_say "  omarchohard desktop prefer on"
}

oh_desktop_ready() {
  oh_have winapps && [[ -f $OH_WINAPPS_CONF && -f $OH_VM_DIR/compose.yaml ]]
}

# Raise the app's desktop Office window, or start the app. Returns 1 when the
# app has no desktop version (Teams, OneDrive) or the web apps are preferred,
# so the caller opens the web app instead.
oh_desktop_launch() {
  local app=$1 wa=${OH_WINAPPS_APP[$1]:-}
  [[ -n $wa && $(oh_config_get open_with) == desktop ]] && oh_desktop_ready || return 1
  oh_desktop_focus "${OH_WINAPPS_TITLE[$app]}" && return 0
  oh_spawn winapps "$wa"
}

# Raise the first desktop Office window whose title matches. A web app with
# the same title is left alone: Chromium app windows have a class with "__"
# in it (host__path), and FreeRDP's classes never do.
oh_desktop_focus() {
  local re=$1 address
  oh_have hyprctl && oh_have jq || return 1
  address=$(hyprctl clients -j 2>/dev/null | jq -r --arg re "$re" --arg marker "$OH_RDP_MARKER" \
    'first(.[] | select(.title != $marker and (.title | test($re)) and (.class | contains("__") | not))) | .address' 2>/dev/null) || return 1
  oh_focus_address "$address"
}

oh_desktop_open_file() {
  local app=$1 file=$2 wa
  wa=${OH_WINAPPS_APP[$app]:-}
  [[ -n $wa ]] || oh_die "no desktop app for $app"
  [[ $file == "$HOME"/* || $file == /run/media/* ]] ||
    oh_die "desktop Office can open files under $HOME or /run/media only"
  oh_spawn winapps "$wa" "$file"
}

# The FreeRDP 3 client, the same order oh_desktop_check accepts.
oh_desktop_freerdp() {
  local bin
  for bin in xfreerdp3 xfreerdp sdl-freerdp3; do
    oh_have "$bin" && printf '%s\n' "$bin" && return 0
  done
  return 1
}

# Windows cannot reach a paused VM over RDP; WinApps' autopause pauses it
# when idle and unpauses it on launch, so do the same.
oh_desktop_resume() {
  local engine state
  engine=$(oh_desktop_engine) || oh_die "Docker or Podman is required"
  state=$("$engine" inspect -f '{{.State.Status}}' "$OH_VM_NAME" 2>/dev/null || echo missing)
  case ${state%% *} in
  running) ;;
  paused) oh_run "$engine" unpause "$OH_VM_NAME" >/dev/null ;;
  *) oh_die "the Windows VM is $state; start it with: omarchohard desktop up" ;;
  esac
}

# Open any file under ~ or /run/media in Windows with its Windows default
# handler: an add-in (.xll .xlam .ppam .dotm .vsto) installs into Office, an
# installer (.exe .msi) runs, a document opens. It is a RemoteApp of
# explorer.exe with the file's \\tsclient path, as WinApps' own launches use.
oh_desktop_run() {
  local file=${1:-} abs win rdp
  local -a args
  [[ -n $file && $# -eq 1 ]] || oh_die "usage: omarchohard desktop run FILE"
  oh_require_line "$file" "the file name" "open it in Windows"
  [[ -e $file ]] || oh_die "no such file: $file"
  abs=$(readlink -f -- "$file")
  oh_require_line "$abs" "the file's full path" "open it in Windows"
  # shellcheck disable=SC1003 # a Windows path ends in a backslash
  case $abs in
  "$HOME"/*) win='\\tsclient\home\'${abs#"$HOME"/} ;;
  /run/media/*) win='\\tsclient\media\'${abs#/run/media/} ;;
  *) oh_die "Windows can open files under $HOME or /run/media only" ;;
  esac
  # Windows file names cannot hold ", and it would end the cmd: value early.
  [[ $abs != *\"* ]] || oh_die "Windows cannot open a path with \" in it: $abs"
  win=${win//\//\\}
  rdp=$(oh_desktop_freerdp) || oh_die "FreeRDP 3 is missing: omarchy pkg add freerdp"
  oh_winapps_conf_load || oh_die "run omarchohard desktop install first"
  oh_desktop_resume
  args=("/v:${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]}" "/u:${OH_WA[RDP_USER]}")
  [[ -z ${OH_WA[RDP_DOMAIN]} ]] || args+=("/d:${OH_WA[RDP_DOMAIN]}")
  # /from-stdin:force reads the password from stdin before connecting
  # (FreeRDP 3 client/common/cmdline.c), so it is never in an argument list.
  # WinApps itself passes /p:, which every process on the machine can read.
  args+=(/from-stdin:force /cert:tofu +home-drive)
  [[ -d /run/media ]] && args+=("/drive:media,/run/media")
  args+=("/wm-class:Microsoft Windows" "/app:program:C:\\Windows\\explorer.exe,name:Open in Windows,cmd:\"$win\"")
  if oh_dry; then
    oh_run "$rdp" "${args[@]}"
    return 0
  fi
  # printf is a builtin: the password goes into the pipe, never into argv.
  printf '%s\n' "${OH_WA[RDP_PASS]}" | setsid -f "$rdp" "${args[@]}" >/dev/null 2>&1
}

# "Open in Windows" in the Files app's Open With list, for Office add-ins.
# Written only once the desktop tier has its apps; uninstall removes it.
OH_ADDIN_MIMES='application/vnd.ms-excel.addin.macroEnabled.12;application/vnd.ms-powerpoint.addin.macroEnabled.12;application/vnd.ms-word.template.macroEnabled.12;application/x-ms-excel-xll;application/x-ms-vsto;'
OH_ADDIN_ENTRY=omarchohard-windows.desktop

oh_desktop_addin_entry_write() {
  local bin file=$OH_APPS_DIR/$OH_ADDIN_ENTRY pkg
  pkg=${XDG_DATA_HOME:-$HOME/.local/share}/mime/packages/omarchohard-addins.xml
  bin=$(oh_bin_path)
  mkdir -p "$OH_APPS_DIR" "${pkg%/*}"
  cp "$OH_SHARE/mime/omarchohard-addins.xml" "$pkg"
  oh_manifest_add "$pkg"
  {
    printf '[Desktop Entry]\nVersion=1.0\nType=Application\n'
    printf 'Name=Open in Windows\n'
    printf 'Comment=Open the file in Windows with its Windows program: add-ins, installers, documents\n'
    printf 'Exec=%s desktop run %%f\n' "$(oh_desktop_exec_arg "$bin")"
    printf 'Icon=omarchohard-m365\nTerminal=false\nNoDisplay=true\nCategories=Office;\n'
    printf 'MimeType=%s\n' "$OH_ADDIN_MIMES"
  } >"$file"
  oh_manifest_add "$file"
}

oh_desktop_addin_entry_remove() {
  rm -f -- "$OH_APPS_DIR/$OH_ADDIN_ENTRY" "${XDG_DATA_HOME:-$HOME/.local/share}/mime/packages/omarchohard-addins.xml"
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

# EXTRA, the third argument, is more JSON members built from checked words
# only (a channel name, a version number).
oh_desktop_request() {
  local action=$1 key=${2:-} extra=${3:-} id req result i
  id=$(date +%s)-$RANDOM
  req=$OH_VM_INBOX/$id.request
  result=$OH_VM_INBOX/$id.result
  mkdir -p "$OH_VM_INBOX"
  # Ctrl-C, a kill or the timeout must not leave the key in the shared folder.
  # shellcheck disable=SC2064 # expand now: req is local
  trap "rm -f -- $(printf '%q ' "$req" "$req.tmp")" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # The key is already checked to be [A-Z0-9-] and the action is a fixed word,
  # so the printf builtin writes valid JSON and no process sees the key.
  (
    umask 077
    printf '{"action":"%s","key":"%s"%s}\n' "$action" "$key" "$extra" >"$req.tmp"
    mv "$req.tmp" "$req"
  )
  oh_say "Sent to the VM; waiting for Windows to apply it (up to 3 minutes)..."
  for ((i = 0; i < 180; i++)); do
    if [[ -f $result ]]; then
      rm -f "$req"
      trap - EXIT INT TERM
      cat "$result"
      rm -f "$result"
      return 0
    fi
    sleep 1
  done
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

# Office updates itself in the VM. This asks for an update now, through the
# inbox: Office's own updater, to a set version or after moving to another
# channel when asked, and a Windows Update scan. The answer is JSON with
# Office's version, channel and a message.
oh_desktop_update() {
  local channel='' to='' extra=''
  while (($#)); do
    case $1 in
    --channel)
      channel=${2:?--channel needs current, monthly or semi-annual}
      shift
      ;;
    --to)
      to=${2:?--to needs an Office version like 16.0.19328.20100}
      shift
      ;;
    *) oh_die "unknown desktop update option: $1" ;;
    esac
    shift
  done
  [[ -z $channel || -n ${OH_OFFICE_CHANNELS[$channel]:-} ]] || oh_die "--channel must be current, monthly or semi-annual"
  [[ -z $to || $to =~ ^[0-9]+(\.[0-9]+){3}$ ]] || oh_die "--to needs an Office version like 16.0.19328.20100"
  [[ -f $OH_VM_DIR/compose.yaml ]] || oh_die "run omarchohard desktop install first"
  [[ -z $to ]] || extra+=",\"version\":\"$to\""
  if [[ -n $channel ]]; then
    oh_desktop_request channel '' ",\"channel\":\"${OH_OFFICE_CHANNELS[$channel]}\"$extra"
  else
    oh_desktop_request update '' "$extra"
  fi
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
    # The disk folder of an install made since 0.2.0. Windows' files in it
    # belong to the container's root user, but the folder is yours.
    oh_run rm -rf -- "$OH_VM_DIR/storage" 2>/dev/null ||
      oh_warn "some VM files were not deleted; remove them with: sudo rm -rf $OH_VM_DIR/storage"
  else
    oh_desktop_compose down
  fi
  oh_config_set open_with web
  oh_desktop_addin_entry_remove
  oh_refresh_desktop_db
  if ((delete_vm)); then oh_ok "desktop tier removed and the VM disk deleted"; else oh_ok "desktop tier stopped; the VM disk is kept"; fi
  oh_dim "WinApps launchers can be removed with: $OH_WINAPPS_DIR/setup.sh --user --uninstall"
}

# Desktop tier checks, once it is installed. A VM paused while idle is
# fine: WinApps wakes it when an app opens.
oh_desktop_doctor() {
  [[ -f $OH_VM_DIR/compose.yaml ]] || return 0
  local app wa have=() missing=() names
  oh_desktop_phase
  case $OH_VM_STATE in
  running | restarting | created) oh_doc ok "desktop VM" "$OH_VM_STATE" ;;
  paused) oh_doc ok "desktop VM" "paused while idle; it resumes when you open an app" ;;
  *)
    if [[ $OH_VM_PHASE == failed ]]; then oh_doc fail "desktop VM" "$OH_VM_DETAIL"; else
      oh_doc warn "desktop VM" "${OH_VM_PHASE}: $OH_VM_DETAIL"
    fi
    ;;
  esac
  case $OH_VM_PHASE in
  downloading-windows | installing-windows | installing-office | starting)
    oh_doc warn "desktop install" "$OH_VM_PHASE${OH_VM_DETAIL:+: $OH_VM_DETAIL} (follow it: omarchohard desktop wait)"
    ;;
  # A failed Office install is the "desktop Office" check below.
  failed) [[ $OH_VM_STATE != running || $OH_OFFICE_PHASE == failed ]] || oh_doc fail "desktop install" "$OH_VM_DETAIL" ;;
  esac
  if [[ $OH_VM_STATE == running ]]; then
    if ((OH_RDP_UP)); then
      oh_doc ok "desktop RDP" "${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]} answers"
    elif [[ $OH_VM_PHASE == downloading-windows || $OH_VM_PHASE == installing-windows || $OH_VM_PHASE == starting ]]; then
      oh_doc warn "desktop RDP" "no answer on ${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]} yet; Windows is still installing or starting"
    else
      oh_doc fail "desktop RDP" "no answer on ${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]} (restart the VM: omarchohard desktop down, then up)"
    fi
  fi
  if [[ $OH_OFFICE_PHASE == failed ]]; then
    oh_doc fail "desktop Office" "did not install: ${OH_OFFICE_ERROR:-no reason given}"
  elif [[ -n $OH_OFFICE_VERSION ]]; then
    oh_doc ok "desktop Office" "${OH_OFFICE_PRODUCT:+$OH_OFFICE_PRODUCT }$OH_OFFICE_VERSION, ${OH_OFFICE_CHANNEL:-unknown} channel"
  else
    oh_doc warn "desktop Office" "no version reported yet; the VM writes it once Office is installed"
  fi
  for app in word excel powerpoint outlook onenote; do
    wa=${OH_WINAPPS_APP[$app]}
    if [[ -f $OH_APPS_DIR/$wa.desktop ]]; then have+=("$(oh_app_name "$app")"); else missing+=("$(oh_app_name "$app")"); fi
  done
  if ! oh_have winapps; then
    oh_doc warn "desktop launchers" "WinApps is not on PATH (add ~/.local/bin to PATH, or run: omarchohard desktop apps)"
  elif ((${#missing[@]} == 0)); then
    names=$(printf '%s, ' "${have[@]}")
    oh_doc ok "desktop launchers" "${names%, }"
  else
    names=$(printf '%s, ' "${missing[@]}")
    oh_doc warn "desktop launchers" "missing ${names%, } (omarchohard desktop apps)"
  fi
  if [[ $(oh_config_get open_with) != desktop ]]; then
    oh_doc ok "open_with" "web; to open local files in desktop Office: omarchohard desktop prefer on"
  elif oh_desktop_ready; then
    oh_doc ok "open_with" "desktop"
  else
    oh_doc warn "open_with" "desktop, but WinApps is missing, so files open in the web apps"
  fi
}

oh_desktop() {
  oh_config_load
  local action=${1:-check}
  (($#)) && shift
  case $action in
  check) oh_desktop_check ;;
  install) oh_desktop_install "$@" ;;
  status) oh_desktop_status "$@" ;;
  wait) oh_desktop_wait ;;
  up) oh_desktop_compose up -d ;;
  down) oh_desktop_compose stop ;;
  apps) oh_desktop_apps ;;
  activate) oh_desktop_activate "$@" ;;
  run) oh_desktop_run "$@" ;;
  update) oh_desktop_update "$@" ;;
  prefer) oh_desktop_prefer "$@" ;;
  remove) oh_desktop_remove "$@" ;;
  *) oh_die "usage: omarchohard desktop check|install|status|wait|up|down|apps|run|update|activate|prefer|remove" ;;
  esac
}
