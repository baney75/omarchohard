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
  [word]='^(.+ - (Microsoft )?Word|Microsoft Word)$'
  [excel]='^(.+ - (Microsoft )?Excel|Microsoft Excel)$'
  [powerpoint]='^(.+ - (Microsoft )?PowerPoint|Microsoft PowerPoint)$'
  [outlook]='^(.+- (Microsoft )?Outlook|Outlook)$'
  [onenote]='^(.+ - (Microsoft )?OneNote|OneNote)$'
)
# The hidden window each RemoteApp session keeps open.
OH_RDP_MARKER='RemoteApp Marker Window'

# FreeRDP tries Kerberos before NTLM. With Arch's example /etc/krb5.conf
# (realm ATHENA.MIT.EDU) that costs about 0.1 s and a screen of errors on
# every connection, and the local VM has no Kerberos. Each WinApps, setup and
# FreeRDP process omarchohard starts gets KRB5_CONFIG=$OH_RDP_KRB5 in its own
# environment; nothing else changes.
OH_RDP_KRB5=/dev/null

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
  OH_WA=([RDP_USER]=omarchohard [RDP_PASS]='' [RDP_DOMAIN]='' [RDP_IP]=127.0.0.1 [RDP_PORT]=3389
    [RDP_FLAGS]='/cert:tofu /sound /microphone +home-drive /printer' [RDP_SCALE]=100 [AUTOPAUSE]=off [AUTOPAUSE_TIME]=300)
  [[ -f $OH_WINAPPS_CONF ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
    RDP_USER=\"*\" | RDP_PASS=\"*\" | RDP_DOMAIN=\"*\" | RDP_IP=\"*\" | RDP_PORT=\"*\" | RDP_FLAGS=\"*\" | RDP_SCALE=\"*\" | AUTOPAUSE=\"*\" | AUTOPAUSE_TIME=\"*\")
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

# No copy-on-write also means no btrfs compression. Once Windows is set up,
# `desktop compress` rewrites the disk image as a copy-on-write file that
# btrfs keeps zstd-compressed: on the test VM, 13 GB of data took 7.5 GB on
# disk (2026-11-12). Defragmenting with -czstd compresses every extent; the
# compression property alone left 8 GB raw, as btrfs gave up on extents it
# guessed would not shrink. Later writes are compressed when they shrink.
# The VM stops for the copy, which needs room for a second copy.
# True while the VM is still stopped: a VM started during the copy (desktop
# up) has written to the old disk, so the copy must not replace it.
oh_desktop_compress_stopped() {
  local state
  state=$("$1" inspect -f '{{.State.Status}}' "$OH_VM_NAME" 2>/dev/null) || return 0
  [[ $state == exited || $state == created ]] && return 0
  oh_warn "the VM started during the copy"
  return 1
}

oh_desktop_compress() {
  local dir=$OH_VM_DIR/storage engine state need avail
  local img=$dir/data.img tmp=$dir/data.img.compress
  (($# == 0)) || oh_die "usage: omarchohard desktop compress"
  [[ -f $img ]] || oh_die "no VM disk at $img; a VM made before 0.2.0 keeps its disk in a Docker volume"
  [[ $(stat -f -c %T "$dir" 2>/dev/null) == btrfs ]] || oh_die "the VM disk is not on btrfs, which is what compresses it"
  oh_have btrfs || oh_die "btrfs-progs is required (omarchy pkg add btrfs-progs)"
  # Stopping the VM during Windows Setup or the Office install would break it.
  oh_desktop_ready || oh_die "desktop Office is not set up yet; compress the disk once it is (omarchohard desktop wait)"
  if [[ $(btrfs property get "$img" compression 2>/dev/null) == compression=zstd ]]; then
    oh_say "The VM disk is already compressed."
    return 0
  fi
  need=$(du -k -- "$img" | cut -f1)
  avail=$(df -k --output=avail -- "$dir" | tail -n 1)
  ((avail > need + 1048576)) || oh_die "compressing the VM disk needs $((need / 1048576 + 2)) GB free in $dir"
  engine=$(oh_desktop_engine) || oh_die "Docker or Podman is required"
  state=$("$engine" inspect -f '{{.State.Status}}' "$OH_VM_NAME" 2>/dev/null) || state=missing
  case $state in
  running | paused | restarting)
    oh_say "Stopping the VM for the copy."
    [[ $state != paused ]] || oh_run "$engine" unpause "$OH_VM_NAME" >/dev/null
    oh_desktop_compose stop >/dev/null || oh_die "could not stop the VM"
    ;;
  esac
  oh_say "Compressing the VM disk. This takes a minute or two."
  # The folder is no-COW, so the new file starts no-COW: clear that while it
  # is empty, as btrfs allows only then, and compression can be set after.
  local ok=0
  rm -f -- "$tmp"
  oh_run touch -- "$tmp" && oh_run chattr -C -- "$tmp" &&
    oh_run btrfs property set "$tmp" compression zstd &&
    oh_run cp --sparse=always -- "$img" "$tmp" &&
    oh_run btrfs filesystem defragment -czstd -- "$tmp" &&
    oh_desktop_compress_stopped "$engine" &&
    oh_run mv -f -- "$tmp" "$img" && ok=1
  rm -f -- "$tmp"
  case $state in
  running | paused | restarting) oh_desktop_compose up -d >/dev/null || oh_warn "the VM did not start again: omarchohard desktop up" ;;
  esac
  ((ok)) || oh_die "compressing the VM disk failed; the disk is unchanged"
  oh_say "The VM disk is compressed."
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
RDP_SCALE="$(oh_desktop_scale)"
REMOVABLE_MEDIA="/run/media"
RDP_FLAGS="/cert:tofu /sound /microphone +home-drive /printer"
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
  cp "$OH_SHARE/vm/install.bat" "$OH_SHARE/vm/office.ps1" "$OH_SHARE/vm/office-info.ps1" "$OH_SHARE/vm/inbox.ps1" "$OH_SHARE/vm/slim.ps1" "$OH_VM_DIR/oem/"
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
    # A new disk: a status file left from an earlier VM would say "failed"
    # or "ready" before this Windows has even started.
    [[ -e $OH_VM_DIR/storage/data.img ]] || rm -f -- "$OH_OFFICE_STATUS"
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
  installed)
    OH_VM_PHASE=installing-office OH_VM_DETAIL="Office is installed; Windows is finishing its first start"
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
  # A VM made before 0.2.0 (its disk in the volume "data") never writes
  # office-status.json, so there RDP answering means Windows is up. A new VM
  # always writes it, and RDP answers there long before Office is in.
  if [[ $found == installing-windows ]] && ((OH_RDP_UP)) && grep -qxF '      - data:/storage' "$OH_VM_DIR/compose.yaml"; then
    found=ready OH_VM_DETAIL="made before omarchohard 0.2.0; it reports no Office status"
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

# Windows answers on the RDP port. Docker's own proxy accepts a connection
# before Windows listens, so this sends an RDP connection request (X.224) and
# needs the reply's TPKT header, 03 00, which only an RDP server sends.
oh_desktop_rdp_up() {
  oh_winapps_conf_load || true
  [[ ${OH_WA[RDP_IP]} =~ ^[0-9A-Za-z.:-]+$ && ${OH_WA[RDP_PORT]} =~ ^[0-9]+$ ]] || return 1
  # shellcheck disable=SC2016 # expanded by the inner bash
  timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1
    printf "\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00" >&3
    [[ $(head -c 2 <&3 | od -An -tx1 | tr -d " \n") == 0300 ]]' _ "${OH_WA[RDP_IP]}" "${OH_WA[RDP_PORT]}" 2>/dev/null
}

# office-status.json, written in Windows. Read as data: unknown phases are
# dropped and every field is cut to one line of plain text.
oh_desktop_office_load() {
  local -a f=()
  OH_OFFICE_PHASE='' OH_OFFICE_PRODUCT='' OH_OFFICE_VERSION='' OH_OFFICE_CHANNEL='' OH_OFFICE_ERROR=''
  [[ -f $OH_OFFICE_STATUS ]] || return 1
  mapfile -t f < <(jq -r '[.phase, .product, .version, .channel, .error] | .[] | (. // "") | tostring | gsub("[[:cntrl:]]"; " ") | .[0:300]' "$OH_OFFICE_STATUS" 2>/dev/null)
  ((${#f[@]} == 5)) || return 1
  case ${f[0]} in installing-office | installed | ready | failed) OH_OFFICE_PHASE=${f[0]} ;; esac
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
  local rc try
  # The first boot signs Windows out of its console a moment after Office
  # reports ready, so a first exit 14 gets two more tries.
  for try in 1 2 3; do
    rc=0
    (cd "$OH_WINAPPS_DIR" && KRB5_CONFIG=$OH_RDP_KRB5 oh_run ./setup.sh "$@") || rc=$?
    ((rc == 14 && try < 3)) || break
    oh_dim "RDP is not ready yet; trying again..."
    sleep "${OMARCHOHARD_DESKTOP_POLL:-15}"
  done
  ((rc != 14)) ||
    oh_warn "WinApps could not open an app over RDP. If Windows is signed in on its own screen, sign out of Windows once at http://127.0.0.1:8006 (Start, your name, Sign out), then run: omarchohard desktop apps"
  return "$rc"
}

# WinApps' own menu entries start a new RDP connection each; point them at
# `omarchohard desktop open`, so they go through the agent like the rest.
# Only the Exec line changes: icons, names and file types stay WinApps'.
oh_desktop_entries_route() {
  local app f exec line tmp
  exec=$(oh_desktop_exec_arg "$(oh_bin_path)")
  for app in "${!OH_WINAPPS_APP[@]}"; do
    f=$OH_APPS_DIR/${OH_WINAPPS_APP[$app]}.desktop
    [[ -f $f ]] || continue
    tmp=$(mktemp "$f.XXXXXX")
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line == Exec=* ]] && line="Exec=$exec desktop open $app %F"
      printf '%s\n' "$line"
    done <"$f" >"$tmp"
    chmod --reference="$f" -- "$tmp"
    mv -- "$tmp" "$f"
  done
}

oh_desktop_register() {
  [[ -x $OH_WINAPPS_DIR/setup.sh ]] || oh_die "run omarchohard desktop install first"
  oh_say "Adding Word, Excel, PowerPoint, Outlook and OneNote to the launcher..."
  oh_winapps_setup --user --setupAllOfficiallySupportedApps ||
    oh_die "WinApps could not add the apps; try again with: omarchohard desktop apps"
  oh_desktop_entries_route
  oh_desktop_addin_entry_write
  oh_desktop_hypr_write
  oh_refresh_desktop_db
  oh_desktop_prefer on
}

# Register the Office apps as Linux launchers through WinApps.
oh_desktop_apps() {
  [[ -x $OH_WINAPPS_DIR/setup.sh ]] || oh_die "run omarchohard desktop install first"
  oh_say "WinApps now scans the VM and lists the apps it found. Choose the Office apps."
  oh_winapps_setup --user || oh_die "WinApps did not finish; run omarchohard desktop apps again"
  oh_desktop_entries_route
  oh_desktop_addin_entry_write
  oh_desktop_hypr_write
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
  oh_agent_go "$app" && return 0
  KRB5_CONFIG=$OH_RDP_KRB5 oh_spawn winapps "$wa"
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
  oh_agent_go "$app" "$(oh_desktop_win_path "$file")" && return 0
  KRB5_CONFIG=$OH_RDP_KRB5 oh_spawn winapps "$wa" "$file"
}

# `desktop open APP [FILE...]`: always desktop Office, whatever open_with
# says. WinApps' own launchers point here, so they use the agent too.
oh_desktop_open() {
  local app=${1:-} file abs
  [[ -n ${OH_WINAPPS_APP[$app]:-} ]] || oh_die "usage: omarchohard desktop open word|excel|powerpoint|outlook|onenote [FILE...]"
  shift
  oh_desktop_ready || oh_die "desktop Office is not set up yet (omarchohard desktop install --wait)"
  if (($# == 0)); then
    oh_desktop_focus "${OH_WINAPPS_TITLE[$app]}" && return 0
    oh_agent_go "$app" && return 0
    KRB5_CONFIG=$OH_RDP_KRB5 oh_spawn winapps "${OH_WINAPPS_APP[$app]}"
    return 0
  fi
  for file in "$@"; do
    [[ $file != file://* ]] || file=$(oh_file_uri_path "$file")
    [[ -e $file ]] || oh_die "no such file: $file"
    abs=$(readlink -f -- "$file")
    oh_desktop_open_file "$app" "$abs"
  done
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
  *)
    [[ ${1:-} != --try ]] || return 1
    oh_die "the Windows VM is $state; start it with: omarchohard desktop up"
    ;;
  esac
  # In the background, so a launch never waits on systemd.
  oh_dry || (oh_desktop_autopause_arm >/dev/null 2>&1 &)
}

# Idle pause, as WinApps' autopause does, in a user timer of its own: a
# FreeRDP holder killed before its own pause (a logout, a killed terminal)
# used to leave the VM running for good. Every AUTOPAUSE_TIME seconds it
# pauses the VM if no FreeRDP is connected to it, then stops itself; opening
# an app arms it again.
OH_AUTOPAUSE_UNIT=omarchohard-autopause

oh_desktop_autopause_arm() {
  ((${#OH_WA[@]})) || oh_winapps_conf_load || return 1
  [[ ${OH_WA[AUTOPAUSE]} == on && ${OH_WA[AUTOPAUSE_TIME]} =~ ^[0-9]+$ ]] && oh_have systemd-run || return 1
  systemctl --user is-active --quiet "$OH_AUTOPAUSE_UNIT.timer" 2>/dev/null && return 0
  # The same home, config and container engine this shell sees.
  local v
  local -a env=("--setenv=HOME=$HOME" "--setenv=PATH=$PATH")
  for v in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; do
    [[ -z ${!v:-} ]] || env+=("--setenv=$v=${!v}")
  done
  systemd-run --user --quiet --collect --unit="$OH_AUTOPAUSE_UNIT" "${env[@]}" \
    --on-active="${OH_WA[AUTOPAUSE_TIME]}s" --on-unit-inactive="${OH_WA[AUTOPAUSE_TIME]}s" \
    "$(oh_bin_path)" desktop autopause
}

# `desktop autopause`, run by that timer.
oh_desktop_autopause() {
  local engine state=missing lk
  # No config or engine: nothing to pause, and the timer stops below.
  if oh_winapps_conf_load && engine=$(oh_desktop_engine); then
    state=$("$engine" inspect -f '{{.State.Status}}' "$OH_VM_NAME" 2>/dev/null) || state=missing
  fi
  if [[ ${state%% *} == running ]]; then
    # A holder holds this lock while its FreeRDP runs.
    mkdir -p "$OH_AGENT_DIR"
    exec {lk}>"$OH_AGENT_DIR/holder.lock"
    flock -n "$lk" || return 0
    # Any FreeRDP of ours connected to the VM: the holder, desktop run, WinApps.
    oh_have pgrep || return 0
    pgrep -u "$(id -u)" -f -- "/v:${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]}( |$)" >/dev/null 2>&1 && return 0
    oh_desktop_compose pause >/dev/null 2>&1 || return 0
  fi
  systemctl --user stop "$OH_AUTOPAUSE_UNIT.timer" >/dev/null 2>&1 || true
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
  win=$(oh_desktop_win_path "$abs") || oh_die "Windows can open files under $HOME or /run/media only"
  # Windows file names cannot hold ", and it would end the cmd: value early.
  [[ $abs != *\"* ]] || oh_die "Windows cannot open a path with \" in it: $abs"
  oh_agent_go run "$win" && return 0
  # Without the agent it goes in FreeRDP's /app:, which splits at commas,
  # even inside the quotes.
  [[ $abs != *,* ]] || oh_die "Windows cannot open a path with a comma in it without the agent; rename it or move it: $abs"
  rdp=$(oh_desktop_freerdp) || oh_die "FreeRDP 3 is missing: omarchy pkg add freerdp"
  oh_winapps_conf_load || oh_die "run omarchohard desktop install first"
  oh_desktop_resume
  args=("/v:${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]}" "/u:${OH_WA[RDP_USER]}")
  [[ -z ${OH_WA[RDP_DOMAIN]} ]] || args+=("/d:${OH_WA[RDP_DOMAIN]}")
  # /from-stdin:force reads the password from stdin before connecting
  # (FreeRDP 3 client/common/cmdline.c), so it is never in an argument list.
  # WinApps itself passes /p:, which every process on the machine can read.
  # /printer brings the host's CUPS printers into Windows, as in the holder.
  args+=(/from-stdin:force /cert:tofu +home-drive /printer)
  [[ -d /run/media ]] && args+=("/drive:media,/run/media")
  args+=("/wm-class:Microsoft Windows" "/app:program:C:\\Windows\\explorer.exe,name:Open in Windows,cmd:\"$win\"")
  if oh_dry; then
    oh_run "$rdp" "${args[@]}"
    return 0
  fi
  # printf is a builtin: the password goes into the pipe, never into argv.
  printf '%s\n' "${OH_WA[RDP_PASS]}" | KRB5_CONFIG=$OH_RDP_KRB5 setsid -f "$rdp" "${args[@]}" >/dev/null 2>&1
}

# The \\tsclient path Windows reaches a file under ~ or /run/media by.
oh_desktop_win_path() {
  local win
  # shellcheck disable=SC1003 # a Windows path ends in a backslash
  case $1 in
  "$HOME"/*) win='\\tsclient\home\'${1#"$HOME"/} ;;
  /run/media/*) win='\\tsclient\media\'${1#/run/media/} ;;
  *) return 1 ;;
  esac
  printf '%s\n' "${win//\//\\}"
}

# The warm agent, share/omarchohard/vm/agent.ps1. One hidden FreeRDP
# RemoteApp connection, the holder, runs it in the Windows session. Opening
# an app or a file is then a request file in $OH_AGENT_DIR that the agent
# takes within a tenth of a second, with no RDP handshake, and the window
# shows through that same connection. Measured on the test VM, 2026-11-12:
# Word with a file 1.2 s through the agent and 2.1 s through WinApps, 0.24 s
# once the agent keeps Word warm. desktop_agent=off in the config goes back
# to WinApps for every launch.
OH_AGENT_DIR=$OH_STATE_DIR/agent
OH_AGENT_PS1=$OH_DATA_DIR/vm/agent.ps1

# Windows reaches the agent's files only through \\tsclient\home, and their
# paths go in FreeRDP's /app: and in a .cmd line, so they must be plain.
oh_agent_usable() {
  local rel
  [[ $(oh_config_get desktop_agent) != off ]] && oh_desktop_freerdp >/dev/null && oh_have flock || return 1
  for rel in "${OH_AGENT_DIR#"$HOME"/}" "${OH_AGENT_PS1#"$HOME"/}"; do
    [[ $rel != /* && $rel =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  done
}

# True when the running agent is the agent.ps1 this omarchohard ships: its
# beat names the hash of the script it started from.
oh_agent_current() {
  local beat
  beat=$(cat -- "$OH_AGENT_DIR/agent.beat" 2>/dev/null) || return 1
  [[ ${beat#* } == "$(sha256sum <"$OH_SHARE/vm/agent.ps1" | cut -d' ' -f1)" ]]
}

# The agent rewrites agent.beat every 2 seconds while it can reach the folder.
oh_agent_alive() {
  local mtime
  mtime=$(stat -c %Y -- "$OH_AGENT_DIR/agent.beat" 2>/dev/null) || return 1
  (($(date +%s) - mtime <= 6))
}

# Queue one request and wait up to TENTHS tenths of a second for the agent
# to take it. The agent claims a request by renaming it, so a request taken
# back here by the same rename can never also run.
oh_agent_send() {
  local verb=$1 arg=$2 tenths=$3 f i
  f=$(oh_agent_queue "$verb" "$arg") || return 1
  for ((i = 0; i < tenths; i++)); do
    [[ -e $f ]] || return 0
    sleep 0.1
  done
  mv -- "$f" "$f.late" 2>/dev/null || return 0
  rm -f -- "$f.late"
  return 1
}

# Write one request for the agent and print its path.
oh_agent_queue() {
  local f
  f=$OH_AGENT_DIR/$(date +%s%N)-$$.go
  (
    umask 077
    printf '%s\t%s\n' "$1" "$2" >"$f.tmp"
  ) && mv -- "$f.tmp" "$f" && printf '%s\n' "$f"
}

# Start the holder with the first request in first.cmd. The app starts at
# once and the agent after it in the same hidden console, so the first
# window does not wait for PowerShell (2.0 s against 4.0 s, measured).
# The request also waits in the queue, and first.cmd claims it by the same
# rename the agent uses: a session that was only disconnected comes back
# with its agent still running and does not run first.cmd again, and that
# agent runs the request instead (lost before, seen on the test VM).
# Waits up to 30 s for the agent's first beat and then up to 5 s for the
# request to be claimed. Returns 1 when another holder holds the lock, 2
# when the holder's FreeRDP ended before the agent beat (a refused
# certificate, a wrong password) or nothing claimed the request, so WinApps
# can open it or show why.
oh_agent_start() {
  local verb=$1 arg=$2 lock start q ps warm i queued name
  exec {lock}>"$OH_AGENT_DIR/holder.lock"
  if ! flock -n "$lock"; then
    exec {lock}>&-
    return 1
  fi
  case $verb in
  word) start='start "" winword' ;;
  excel) start='start "" excel' ;;
  powerpoint) start='start "" powerpnt' ;;
  outlook) start='start "" outlook' ;;
  onenote) start='start "" onenote' ;;
  # start runs a .bat with cmd /K, which leaves its window open; explorer
  # opens a file the way the agent's Start-Process does.
  run) start='explorer.exe' ;;
  # slim waits in the queue for the agent.
  slim) start='' ;;
  *) start='start ""' ;;
  esac
  # cmd expands %NAME% even inside quotes; %% is a literal %.
  [[ -z $start || -z $arg ]] || start+=" \"${arg//%/%%}\""
  queued=$(oh_agent_queue "$verb" "$arg") || return 2
  name=${queued##*/}
  # shellcheck disable=SC1003 # a Windows path ends in a backslash
  q='\\tsclient\home\'${OH_AGENT_DIR#"$HOME"/} ps='\\tsclient\home\'${OH_AGENT_PS1#"$HOME"/}
  mkdir -p "${OH_AGENT_PS1%/*}"
  cp -f -- "$OH_SHARE/vm/agent.ps1" "$OH_AGENT_PS1"
  rm -f -- "$OH_AGENT_DIR/agent.beat"
  # Windows PowerShell drops an empty quoted argument, so no warm apps means
  # no -Warm at all.
  warm=$(oh_config_get desktop_warm | tr -cd 'a-z,')
  [[ -z $warm ]] || warm=" -Warm \"$warm\""
  {
    printf '@echo off\r\nchcp 65001 >nul\r\n'
    # move fails when the agent claimed the request first, and then the
    # app is not started twice.
    [[ -z $start ]] || printf 'move "%s\\%s" "%s\\%s.first" >nul 2>&1 && %s\r\ndel "%s\\%s.first" >nul 2>&1\r\n' \
      "${q//\//\\}" "$name" "${q//\//\\}" "$name" "$start" "${q//\//\\}" "$name"
    printf 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" -Queue "%s"%s\r\n' \
      "${ps//\//\\}" "${q//\//\\}" "$warm"
  } >"$OH_AGENT_DIR/first.cmd"
  # The holder keeps its copy of the lock; printf is a builtin, so the
  # password goes into the pipe, never into an argument list.
  printf '%s\n' "${OH_WA[RDP_PASS]}" | OH_HOLDER_LOCK=$lock setsid -f "$(oh_bin_path)" desktop holder >/dev/null 2>&1
  exec {lock}>&-
  # The holder lets go of the lock when FreeRDP ends.
  for ((i = 0; i < 300; i++)); do
    [[ -e $OH_AGENT_DIR/agent.beat ]] && break
    exec {lock}>"$OH_AGENT_DIR/holder.lock"
    if flock -n "$lock"; then
      exec {lock}>&-
      [[ -e $OH_AGENT_DIR/agent.beat ]] && break
      # Take the request back, so the next agent does not run it.
      mv -- "$queued" "$queued.late" 2>/dev/null && rm -f -- "$queued.late"
      return 2
    fi
    exec {lock}>&-
    sleep 0.1
  done
  for ((i = 0; i < 50; i++)); do
    [[ -e $queued ]] || return 0
    sleep 0.1
  done
  mv -- "$queued" "$queued.late" 2>/dev/null || return 0
  rm -f -- "$queued.late"
  return 2
}

# Open VERB [ARG] through the agent: hand it over when the agent is up, or
# start the holder with it. Returns 1 when the caller should use WinApps.
oh_agent_go() {
  local verb=$1 arg=${2:-}
  oh_agent_usable || return 1
  [[ $arg != *[$'\t\n\r"']* ]] || return 1
  oh_winapps_conf_load || return 1
  mkdir -p "$OH_AGENT_DIR"
  chmod 700 "$OH_AGENT_DIR"
  if oh_agent_alive; then
    oh_agent_send "$verb" "$arg" 30 && return 0
  fi
  # No beat: the VM may be paused, with the holder's connection waiting.
  # A stopped VM goes to WinApps, which says so.
  oh_desktop_resume --try || return 1
  oh_agent_start "$verb" "$arg"
  case $? in
  0) return 0 ;;
  2) return 1 ;;
  esac
  # A holder is starting: its agent takes the request once it is up.
  oh_agent_send "$verb" "$arg" 100
}

# `desktop slim`: shrink the VM's disk with slim.ps1, run by the agent, and
# print each step as it lands.
oh_desktop_slim() {
  local name log line n=0 i gone=0 alog=$OH_AGENT_DIR/agent.log a0
  (($# == 0)) || oh_die "usage: omarchohard desktop slim"
  oh_desktop_ready || oh_die "desktop Office is not set up yet (omarchohard desktop install --wait)"
  # An agent started before an upgrade does not know slim; it stops 15
  # minutes after the last Office window closes.
  ! oh_agent_alive || oh_agent_current ||
    oh_die "the agent in Windows is older than this omarchohard; close the desktop Office windows, wait 15 minutes, and run desktop slim again"
  name=slim-$(date +%s%N).log log=$OH_AGENT_DIR/$name
  mkdir -p "${OH_AGENT_PS1%/*}" "$OH_AGENT_DIR"
  cp -f -- "$OH_SHARE/vm/slim.ps1" "${OH_AGENT_PS1%/*}/slim.ps1"
  a0=$(wc -l <"$alog" 2>/dev/null || echo 0)
  oh_agent_go slim "$name" || oh_die "desktop slim runs through the agent, which needs FreeRDP 3 (omarchy pkg add freerdp) and desktop_agent=on"
  oh_say "Slimming the Windows VM. Removing old updates can take 30 minutes."
  for ((i = 0; i < 3600; i++)); do
    line=$(tail -n +$((a0 + 1)) -- "$alog" 2>/dev/null | grep -m1 'error slim') &&
      oh_die "Windows refused it: ${line#*error slim}"
    # The agent stops beating when Windows stops or the connection ends.
    if oh_agent_alive; then gone=0; elif ((++gone > 30)); then
      oh_die "the Windows session ended before slim finished; run desktop slim again"
    fi
    if [[ -f $log ]]; then
      while IFS= read -r line; do
        line=${line#$'\xef\xbb\xbf'}
        printf '  %s\n' "${line%$'\r'}"
      done < <(tail -n +$((n + 1)) -- "$log")
      n=$(wc -l <"$log")
      # Windows PowerShell starts a new file with a byte order mark.
      grep -qE $'^(\xef\xbb\xbf)?busy' -- "$log" && return 1
      grep -qE $'^(\xef\xbb\xbf)?done' -- "$log" && return 0
    fi
    sleep 1
  done
  oh_die "desktop slim is still running in Windows after an hour; its log: $log"
}

# The scale of the focused monitor in percent, for FreeRDP's /scale-desktop.
# Omarchy has XWayland draw at the monitor's own pixels
# (xwayland:force_zero_scaling), so Windows has to scale itself; without
# that setting Hyprland scales the window and Windows stays at 100.
oh_desktop_scale() {
  local s
  oh_have hyprctl && oh_have jq || {
    echo 100
    return
  }
  [[ $(hyprctl getoption xwayland:force_zero_scaling -j 2>/dev/null | jq -r '.int // .bool // 0' 2>/dev/null) =~ ^(1|true)$ ]] || {
    echo 100
    return
  }
  s=$(hyprctl monitors -j 2>/dev/null | jq -r 'first(.[] | select(.focused)) | .scale' 2>/dev/null) || s=''
  [[ $s =~ ^[0-9]+(\.[0-9]+)?$ ]] || s=1
  awk -v s="$s" 'BEGIN { v = int(s * 100 + 0.5); print (v < 100 ? 100 : v > 500 ? 500 : v) }'
}

# Keep RDP_SCALE in winapps.conf at the monitor's scale, so a WinApps launch
# draws at the same size. Only omarchohard's own winapps.conf is touched.
oh_winapps_scale_sync() {
  local scale=$1
  [[ -f $OH_WINAPPS_CONF && ${OH_WA[RDP_SCALE]} != "$scale" ]] || return 0
  head -n1 "$OH_WINAPPS_CONF" | grep -qF 'Written by omarchohard' || return 0
  sed -i "s/^RDP_SCALE=.*/RDP_SCALE=\"$scale\"/" "$OH_WINAPPS_CONF"
}

# `desktop holder`, started by oh_agent_start with the password on stdin and
# the holder lock on descriptor $OH_HOLDER_LOCK. Runs FreeRDP until the
# Windows session ends, then pauses the idle VM as WinApps' autopause does.
oh_desktop_holder() {
  local pass rdp pid scale cproc first f lk
  local -a args flags
  IFS= read -r pass || exit 1
  oh_winapps_conf_load || exit 1
  rdp=$(oh_desktop_freerdp) || exit 1
  scale=$(oh_desktop_scale)
  oh_winapps_scale_sync "$scale"
  read -r -a flags <<<"${OH_WA[RDP_FLAGS]}"
  args=("/v:${OH_WA[RDP_IP]}:${OH_WA[RDP_PORT]}" "/u:${OH_WA[RDP_USER]}")
  [[ -z ${OH_WA[RDP_DOMAIN]} ]] || args+=("/d:${OH_WA[RDP_DOMAIN]}")
  # /printer brings the host's CUPS printers into Windows, so Office prints
  # to them. New installs have it in RDP_FLAGS; a winapps.conf written
  # before gets it here, and FreeRDP gets it once either way.
  [[ " ${flags[*]} " == *" /printer "* ]] || flags+=(/printer)
  args+=(/from-stdin:force "${flags[@]}" +clipboard "/scale-desktop:$scale"
    "/scale-device:$((scale <= 120 ? 100 : scale <= 160 ? 140 : 180))")
  [[ -d /run/media ]] && args+=("/drive:media,/run/media")
  # shellcheck disable=SC1003 # a Windows path ends in a backslash
  first='\\tsclient\home\'${OH_AGENT_DIR#"$HOME"/}/first.cmd
  args+=("/wm-class:Microsoft Windows" "/app:program:C:\\Windows\\System32\\conhost.exe,name:omarchohard,cmd:--headless cmd.exe /c ${first//\//\\}")
  printf '%s\n' "$pass" | KRB5_CONFIG=$OH_RDP_KRB5 "$rdp" "${args[@]}" >"$OH_AGENT_DIR/holder.log" 2>&1 &
  pid=$!
  pass=''
  # WinApps' autopause pauses the VM only while no FreeRDP it knows of runs.
  cproc=$HOME/.local/share/winapps/FreeRDP_Process_$pid.cproc
  mkdir -p "${cproc%/*}" && : >"$cproc"
  wait "$pid" || true
  rm -f -- "$cproc" "$OH_AGENT_DIR/agent.beat"
  [[ -z ${OH_HOLDER_LOCK:-} ]] || exec {OH_HOLDER_LOCK}>&-
  oh_desktop_autopause_arm >/dev/null 2>&1 && return 0
  # No user systemd: pause from here, as before.
  [[ ${OH_WA[AUTOPAUSE]} == on && ${OH_WA[AUTOPAUSE_TIME]} =~ ^[0-9]+$ ]] || return 0
  sleep "${OH_WA[AUTOPAUSE_TIME]}"
  exec {lk}>"$OH_AGENT_DIR/holder.lock"
  flock -n "$lk" || return 0
  for f in "$HOME"/.local/share/winapps/FreeRDP_Process_*.cproc; do
    [[ -e $f ]] || continue
    f=${f##*_} f=${f%.cproc}
    [[ $f =~ ^[0-9]+$ && $(cat "/proc/$f/comm" 2>/dev/null) == *freerdp* ]] && return 0
  done
  oh_desktop_compose pause >/dev/null 2>&1 || true
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
    printf 'Icon=omarchohard\nTerminal=false\nNoDisplay=true\nCategories=Office;\n'
    printf 'MimeType=%s\n' "$OH_ADDIN_MIMES"
  } >"$file"
  oh_manifest_add "$file"
}

oh_desktop_addin_entry_remove() {
  rm -f -- "$OH_APPS_DIR/$OH_ADDIN_ENTRY" "${XDG_DATA_HOME:-$HOME/.local/share}/mime/packages/omarchohard-addins.xml"
}

# Hyprland window rules for desktop Office, in a file of their own that one
# guarded line in hyprland.lua loads. Only Omarchy's Lua config is edited,
# and only by adding that line; uninstall removes exactly that line.
OH_HYPR_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr
OH_HYPR_RULES=$OH_HYPR_DIR/omarchohard.lua

# The line that loads the rules. pcall keeps Hyprland's config loading when
# the file is gone.
oh_hypr_line() {
  if [[ $OH_HYPR_RULES == "$HOME/.config/hypr/omarchohard.lua" ]]; then
    printf '%s\n' 'pcall(dofile, os.getenv("HOME") .. "/.config/hypr/omarchohard.lua") -- omarchohard'
  else
    printf 'pcall(dofile, "%s") -- omarchohard\n' "$OH_HYPR_RULES"
  fi
}

oh_desktop_hypr_write() {
  local conf=$OH_HYPR_DIR/hyprland.lua line app
  if [[ ! -f $conf ]]; then
    [[ ! -f $OH_HYPR_DIR/hyprland.conf ]] ||
      oh_warn "Hyprland here uses hyprland.conf, not the Lua config; omarchohard added no window rules for desktop Office"
    return 0
  fi
  {
    printf -- '-- Written by omarchohard for desktop Office; omarchohard uninstall removes it.\n'
    printf -- '-- Matched by title: FreeRDP gives every window of the Windows session one class.\n\n'
    printf -- '-- The window each RemoteApp session keeps open: out of sight, never focused.\n'
    printf 'o.window({ title = "^%s$" }, { workspace = "special:omarchohard silent", no_focus = true })\n\n' "$OH_RDP_MARKER"
    printf -- '-- Documents opaque, not in the translucent default app style.\n'
    for app in word excel powerpoint outlook onenote; do
      printf 'o.window({ title = "%s" }, { tag = "-default-opacity", opacity = "1 1" })\n' "${OH_WINAPPS_TITLE[$app]}"
    done
  } >"$OH_HYPR_RULES"
  oh_manifest_add "$OH_HYPR_RULES"
  line=$(oh_hypr_line)
  grep -qxF -- "$line" "$conf" && return 0
  # Appended on a line of its own; nothing else in the file changes.
  [[ ! -s $conf || -z $(tail -c 1 "$conf") ]] || printf '\n' >>"$conf"
  printf '%s\n' "$line" >>"$conf"
  oh_manifest_add "hypr-line:$conf"
}

# Take our line back out of hyprland.lua. Written through the file, so a
# symlinked config stays a symlink.
oh_hypr_line_remove() {
  local conf=$1 line tmp rc=0
  line=$(oh_hypr_line)
  [[ -f $conf ]] && grep -qxF -- "$line" "$conf" || return 0
  tmp=$(mktemp)
  grep -vxF -- "$line" "$conf" >"$tmp" || rc=$?
  if ((rc > 1)); then
    rm -f "$tmp"
    oh_warn "could not remove the omarchohard line from $conf"
    return 0
  fi
  cat "$tmp" >"$conf"
  rm -f "$tmp"
}

oh_desktop_hypr_remove() {
  oh_hypr_line_remove "$OH_HYPR_DIR/hyprland.lua"
  rm -f -- "$OH_HYPR_RULES"
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
  local channel='' to='' extra='' office
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
  # Monthly and semi-annual channels exist for Microsoft 365 Apps for business
  # and enterprise only; other editions stay on the channel they came with.
  oh_config_load
  office=$(oh_config_get desktop_office)
  [[ -z $channel || -z $office || $office == m365 ]] ||
    oh_die "only Microsoft 365 (--office m365) can change channel; this VM has $office"
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
    # A reinstall starts from nothing: no old "failed" or "ready" status, and
    # no compose.yaml, which setup reads as "desktop Office is installed".
    rm -f -- "$OH_OFFICE_STATUS" "$OH_VM_DIR/compose.yaml"
    # The disk folder of an install made since 0.2.0. Windows' files in it
    # belong to the container's root user, but the folder is yours.
    oh_run rm -rf -- "$OH_VM_DIR/storage" 2>/dev/null ||
      oh_warn "some VM files were not deleted; remove them with: sudo rm -rf $OH_VM_DIR/storage"
  else
    oh_desktop_compose down
  fi
  oh_config_set open_with web
  oh_desktop_addin_entry_remove
  oh_desktop_hypr_remove
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
    elif [[ $OH_VM_PHASE == downloading-windows || $OH_VM_PHASE == installing-windows || $OH_VM_PHASE == installing-office || $OH_VM_PHASE == starting ]]; then
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
  if [[ -f $OH_HYPR_DIR/hyprland.lua ]]; then
    if [[ -f $OH_HYPR_RULES ]] && grep -qxF -- "$(oh_hypr_line)" "$OH_HYPR_DIR/hyprland.lua"; then
      oh_doc ok "hyprland rules" "$OH_HYPR_RULES"
    else
      oh_doc warn "hyprland rules" "not loaded, so Office windows are translucent and the RemoteApp marker shows (omarchohard desktop apps adds them)"
    fi
  elif [[ -f $OH_HYPR_DIR/hyprland.conf ]]; then
    oh_doc warn "hyprland rules" "Hyprland uses hyprland.conf, not the Lua config; no window rules for desktop Office"
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
  open) oh_desktop_open "$@" ;;
  holder) oh_desktop_holder ;;
  autopause) oh_desktop_autopause ;;
  slim) oh_desktop_slim "$@" ;;
  compress) oh_desktop_compress "$@" ;;
  update) oh_desktop_update "$@" ;;
  prefer) oh_desktop_prefer "$@" ;;
  remove) oh_desktop_remove "$@" ;;
  *) oh_die "usage: omarchohard desktop check|install|status|wait|up|down|apps|open|run|slim|compress|update|activate|prefer|remove" ;;
  esac
}
