# shellcheck shell=bash
# Native tier: Microsoft 365 desktop Office (Word, Excel, PowerPoint, Outlook,
# OneNote) on Linux itself, under wine-altars, a Wine fork that runs Office's
# own Click-to-Run installer. No VM.
#
# Layout:
#   $OH_DATA_DIR/wine                           the pinned wine-altars release
#   $OH_DATA_DIR/native/prefix                  the Wine prefix Office lives in
#   $OH_DATA_DIR/native/seed-PRODUCT-V.tar.zst  that prefix before anyone signed in
#   $OH_DATA_DIR/native/seed-....tar.zst.sha256 its SHA256
#   $OH_DATA_DIR/native/office-src              Office's install files, during a fresh install
#
# The first device installs from Microsoft; every other device copies the
# seed of one that already has it (install --from). The seed is written once,
# right after a fresh install and before any sign-in, or kept as it arrives
# with --from, so every finished device can hand it on. `native seed` only
# ever sends that file. It never packs the live prefix, so a signed-in prefix
# never leaves the device. Nothing here reads the prefix's identity or token
# stores.
#
# Seeds hold Microsoft's Office binaries. They move only between one person's
# or one organization's own devices and are never published; the license
# comes from each person's own sign-in.
#
# The setup steps follow wine-altars' scripts/office-setup.sh and
# scripts/enable-native-signin.sh at tag v11.19-altars.1
# (https://github.com/Altars3668/wine-altars, LGPL-2.1, by Altars3668):
# prefix, WebView2, Office from a local source, the two sign-in gates. They
# are redone here with omarchohard's download rules (HTTPS only, pinned
# hashes where the file is fixed) instead of running that script, which
# follows any redirect and stops a process with pkill -f.

OH_WINE_TAG=v11.19-altars.1
OH_WINE_URL=https://github.com/Altars3668/wine-altars/releases/download/$OH_WINE_TAG/wine-altars-linux-x86_64.tar.xz
OH_WINE_SHA256=41158b0f0a158b6effee7e7ce7621daafa8b5bc62cdf076aa6505b56393cd382
OH_WINE_DIR=$OH_DATA_DIR/wine
OH_WINE=$OH_WINE_DIR/bin/wine
OH_WINESERVER=$OH_WINE_DIR/bin/wineserver
OH_NATIVE_DIR=$OH_DATA_DIR/native
OH_NATIVE_PREFIX=$OH_NATIVE_DIR/prefix
OH_NATIVE_SRC=$OH_NATIVE_DIR/office-src
OH_NATIVE_OFFICE="$OH_NATIVE_PREFIX/drive_c/Program Files/Microsoft Office/root/Office16"
# Written when setup --tier native has finished once, so a rerun is a no-op.
OH_NATIVE_DONE=$OH_NATIVE_DIR/setup-done
# Written as the install's last step. Word without it is an install that
# stopped: its sign-in settings or seed may be missing.
OH_NATIVE_COMPLETE=$OH_NATIVE_DIR/install-done

# Which Microsoft 365 the person has, and the Office product it installs.
# One table, so a change of mapping is one line. Only personal and family
# (O365HomePremRetail) are proven under wine-altars so far.
declare -gA OH_NATIVE_PLANS=(
  [personal]=O365HomePremRetail
  [family]=O365HomePremRetail
  [school]=O365ProPlusRetail
  [business]=O365BusinessRetail
  [enterprise]=O365ProPlusRetail
)
OH_NATIVE_PLAN_ORDER='personal family school business enterprise'
# Shared computer activation: Microsoft supports it for these plans, not for
# Microsoft 365 Apps for business or the home plans.
# https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation
OH_NATIVE_SHARED_PLANS='school enterprise'

# The remote sign-in and the seed server: their containers and user units,
# and their ports on the tailnet (or LAN) address.
OH_NATIVE_SIGNIN=omarchohard-native-signin
OH_NATIVE_PORT=${OMARCHOHARD_SIGNIN_PORT:-6080}
OH_NATIVE_SERVE=omarchohard-native-seed
OH_NATIVE_SERVE_PORT=${OMARCHOHARD_SEED_PORT:-6090}
OH_NATIVE_IMAGE=omarchohard-native-remote

# Wine Gecko, which Wine asks for when anything falls back to its own
# browser engine. Fixed files, so pinned.
OH_GECKO_VERSION=2.47.4
declare -gA OH_GECKO_SHA256=(
  [x86_64]=e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f
  [x86]=26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6
)
# Microsoft's installers. Both are signed by Microsoft and change with every
# release, so they are not pinned. The WebView2 link redirects to Microsoft's
# download host; setup.exe does not.
OH_WEBVIEW2_URL='https://go.microsoft.com/fwlink/p/?LinkId=2124703'
OH_ODT_URL=https://officecdn.microsoft.com/pr/wsus/setup.exe
# For files whose hash is checked, or Microsoft's own: a redirect is followed,
# over HTTPS only. GitHub serves release files from another host.
OH_NATIVE_CURL=("${OH_OFFICE_CURL[@]}" -L --proto-redir "=https")
# A seed from a device on the same private network: plain HTTP, no redirect,
# and always with --sha256.
OH_NATIVE_CURL_LOCAL=(curl --proto "=http" -fsS --connect-timeout 20 --retry 3 --retry-delay 2 --speed-limit 4096 --speed-time 60)

declare -gA OH_NATIVE_EXE=(
  [word]=WINWORD.EXE [excel]=EXCEL.EXE [powerpoint]=POWERPNT.EXE
  [outlook]=OUTLOOK.EXE [onenote]=ONENOTE.EXE
)
OH_NATIVE_APPS='word excel powerpoint outlook onenote'

# The xattrs the fork keeps state in (reparse points in user.WINEREPARSE,
# user.DOSATTRIB, user.WINESHORTNAME). Without them Word does not start.
# Only user.*: btrfs.* is the file system's own, and a seed sets nothing else.
OH_NATIVE_XATTRS=(--xattrs --xattrs-include='user.*' --xattrs-exclude='btrfs.*')

# Every Wine run: the prefix, no debug output, and no menu entries or file
# types written into the person's desktop by winemenubuilder.
oh_native_env() {
  printf '%s\n' "WINEPREFIX=$OH_NATIVE_PREFIX" WINEDEBUG=-all "WINEDLLOVERRIDES=winemenubuilder.exe=d${1:+;$1}"
}

# The sandbox (bubblewrap), experimental and off unless
# OMARCHOHARD_NATIVE_SANDBOX=1. Office then runs with the whole system
# read-only and the person's home hidden from its files: only the prefix,
# Documents, Downloads, Desktop, Pictures and the OneDrive folder are there,
# writable. The network stays. Every Wine command, sandboxed or not, sees
# the same /tmp (OH_NATIVE_TMP), where Wine keeps its server socket, so all
# of them share one Wine server. It is not a security boundary yet: with no
# pid namespace (Wine's processes find each other through /proc), a process
# inside can still reach the home through /proc/PID/root of one outside.
# Off, or without a working bwrap, Office runs as plain Wine.
OH_NATIVE_TMP=$OH_STATE_DIR/native/tmp

oh_native_bwrap_ok() {
  [[ ${OMARCHOHARD_NATIVE_SANDBOX:-0} == 1 ]] && oh_have bwrap || return 1
  if [[ -z ${OH_NATIVE_BWRAP:-} ]]; then
    OH_NATIVE_BWRAP=0
    bwrap --ro-bind / / -- true >/dev/null 2>&1 && OH_NATIVE_BWRAP=1
  fi
  ((OH_NATIVE_BWRAP))
}

# The person's folders Office may use: XDG's names, else the usual ones,
# and the OneDrive folder.
oh_native_user_dirs() {
  local key d
  for key in DOCUMENTS DOWNLOAD DESKTOP PICTURES; do
    d=$(xdg-user-dir "$key" 2>/dev/null || true)
    if [[ -z $d || $d == "$HOME" ]]; then
      case $key in
      DOCUMENTS) d=$HOME/Documents ;;
      DOWNLOAD) d=$HOME/Downloads ;;
      DESKTOP) d=$HOME/Desktop ;;
      PICTURES) d=$HOME/Pictures ;;
      esac
    fi
    printf '%s\n' "$d"
  done
  d=$(oh_config_get onedrive_dir 2>/dev/null || true)
  [[ -z $d ]] || printf '%s\n' "$d"
}

# oh_native_box tmp|app|server [DIR...]: sets OH_BOX, the command prefix.
# tmp only moves /tmp (installs, and Wine server commands that start no
# server). app is the sandbox, with each DIR also bound writable. server is
# the same sandbox for the Wine server the apps use, which outlives the
# command that starts it. The server opens files for its apps, so it must
# see no more than they do.
oh_native_box() {
  local mode=$1 d uid rt=${XDG_RUNTIME_DIR:-}
  shift
  OH_BOX=()
  oh_native_bwrap_ok || return 0
  oh_dry || { mkdir -p "$OH_NATIVE_TMP" && chmod 700 "${OH_NATIVE_TMP%/*}" "$OH_NATIVE_TMP"; }
  if [[ $mode == tmp ]]; then
    OH_BOX=(bwrap --dev-bind / / --bind "$OH_NATIVE_TMP" /tmp --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix --)
    return 0
  fi
  uid=$(id -u)
  OH_BOX=(bwrap --ro-bind / / --dev-bind /dev /dev)
  for d in /home /root /mnt /media /run/media "$HOME" "/run/user/$uid"; do
    [[ -d $d ]] && OH_BOX+=(--tmpfs "$d")
  done
  OH_BOX+=(--bind "$OH_NATIVE_TMP" /tmp --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)
  # Sound, and the X authority file when there is one.
  [[ -z $rt ]] || OH_BOX+=(--ro-bind-try "$rt/pipewire-0" "$rt/pipewire-0" --ro-bind-try "$rt/pulse/native" "$rt/pulse/native")
  [[ -z ${XAUTHORITY:-} || ! -f $XAUTHORITY ]] || OH_BOX+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY")
  OH_BOX+=(--ro-bind "$OH_WINE_DIR" "$OH_WINE_DIR" --bind "$OH_NATIVE_PREFIX" "$OH_NATIVE_PREFIX")
  while IFS= read -r d; do
    [[ -n $d && -d $d ]] && OH_BOX+=(--bind "$d" "$d")
  done < <(oh_native_user_dirs)
  for d in "$@"; do
    [[ -d $d ]] && OH_BOX+=(--bind "$d" "$d")
  done
  # Marks what runs in the sandbox, so an app never uses a server from
  # outside it (oh_native_outside_server).
  OH_BOX+=(--setenv OH_NATIVE_BOX app)
  # No --unshare-pid: Wine's processes find each other through /proc.
  if [[ $mode == server ]]; then
    OH_BOX+=(--unshare-ipc --new-session --)
  else
    OH_BOX+=(--unshare-ipc --die-with-parent --new-session --)
  fi
}

oh_native_wine() {
  local -a env
  mapfile -t env < <(oh_native_env "${OH_NATIVE_OVERRIDES:-}")
  oh_native_box tmp
  oh_run "${OH_BOX[@]}" env "${env[@]}" "$OH_WINE" "$@"
}

oh_native_ws() {
  oh_native_box tmp
  oh_run "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" "$@"
}

# oh_native_ws_start ARG...: start the apps' Wine server (-p600, -p) in the
# sandbox. With one already running, it exits at once.
oh_native_ws_start() {
  oh_native_box server
  oh_run "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" "$@"
}

# Wine servers of this prefix, sandboxed or not. One pid per line.
oh_native_server_pids() {
  local pid
  for pid in $(pgrep -u "$(id -u)" -x wineserver 2>/dev/null || true); do
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF -- "WINEPREFIX=$OH_NATIVE_PREFIX" && printf '%s\n' "$pid"
  done
  return 0
}

# A Wine server for this prefix that an install or update started outside
# the sandbox. It sees the whole home, and opens files for any app that
# attaches to it.
oh_native_outside_server() {
  local pid
  oh_native_bwrap_ok || return 1
  for pid in $(oh_native_server_pids); do
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF OH_NATIVE_BOX=app || return 0
  done
  return 1
}

# Stop this prefix's Wine server and wait for it to go. Fails when one is
# still running after 5 s: one in another /tmp (started with the sandbox
# on, say, when it is now off) is out of reach of `wineserver -k`.
oh_native_server_stop() {
  local i
  [[ -n $(oh_native_server_pids) ]] || return 0
  oh_native_ws -k 2>/dev/null || true
  for ((i = 0; i < 25; i++)); do
    [[ -n $(oh_native_server_pids) ]] || return 0
    sleep 0.2
  done
  return 1
}

# Wait up to SECONDS for every process of the prefix to end, then stop the
# rest. Office leaves its Click-to-Run service running, so the wait alone may
# never end. wineserver saves the registry as it exits.
oh_native_settle() {
  oh_dry && return 0
  oh_native_box tmp
  timeout "${1:-60}" "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -w 2>/dev/null && return 0
  "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -k 2>/dev/null || true
  "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -w 2>/dev/null || true
}

oh_native_stop_wine() {
  [[ -x $OH_WINESERVER && -d $OH_NATIVE_PREFIX ]] || return 0
  oh_native_ws -k 2>/dev/null || true
}

oh_native_wine_ok() {
  [[ -x $OH_WINE && -x $OH_WINESERVER && $(cat -- "$OH_WINE_DIR/.omarchohard-release" 2>/dev/null) == "$OH_WINE_TAG" ]]
}

oh_native_has() {
  local exe=${OH_NATIVE_EXE[${1:-}]:-}
  [[ -n $exe && -f $OH_NATIVE_OFFICE/$exe ]]
}

# Wine and Word are both in place.
oh_native_ready() { oh_native_wine_ok && oh_native_has word; }

# A value from Office's Click-to-Run configuration in the prefix's registry
# file (HKLM, not the identity or token stores), without starting Wine.
oh_native_c2r() {
  local name=$1 reg=${2:-$OH_NATIVE_PREFIX}/system.reg
  [[ -f $reg ]] || return 1
  awk -v name="\"$name\"=\"" '
    /^\[/ { inside = index($0, "[Software\\\\Microsoft\\\\Office\\\\ClickToRun\\\\Configuration]") == 1; next }
    inside && index($0, name) == 1 { v = substr($0, length(name) + 1); sub(/".*/, "", v); print v; found = 1; exit }
    END { exit !found }
  ' "$reg"
}

oh_native_office_version() { oh_native_c2r VersionToReport "${1:-}" | grep -E '^[0-9]+(\.[0-9]+){3}$'; }
oh_native_office_product() { oh_native_c2r ProductReleaseIds "${1:-}" | grep -E '^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$'; }

# The plans a product serves, in words: "personal or family".
oh_native_plan_words() {
  local plan out=''
  for plan in $OH_NATIVE_PLAN_ORDER; do
    [[ ,$1, == *",${OH_NATIVE_PLANS[$plan]},"* ]] && out+=${out:+ or }$plan
  done
  printf '%s\n' "${out:-$1}"
}

oh_native_plan_check() {
  [[ -n ${OH_NATIVE_PLANS[${1:-}]:-} ]] || oh_die "--plan takes ${OH_NATIVE_PLAN_ORDER// /, }, not ${1:-nothing}"
}

# The stored seed, if there is one.
oh_native_seed_file() {
  local f found=''
  for f in "$OH_NATIVE_DIR"/seed-*.tar.zst; do
    [[ -f $f ]] && found=$f
  done
  [[ -n $found ]] && printf '%s\n' "$found"
}

# The product a seed's name carries (seed-O365ProPlusRetail-16.0.1.2.tar.zst).
oh_native_name_product() {
  local name=${1##*/}
  name=${name%%[?#]*}
  [[ $name =~ ^seed-([A-Za-z0-9]+)-[0-9.]+\.tar\.zst$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# The stored seed's SHA256: its .sha256 file, written when the seed was.
oh_native_seed_sha() {
  local f=$1 sum
  sum=$(head -c 64 -- "$f.sha256" 2>/dev/null || true)
  if [[ ! $sum =~ ^[0-9a-f]{64}$ ]]; then
    sum=$(sha256sum -- "$f" | awk '{ print $1 }')
    oh_dry || printf '%s\n' "$sum" >"$f.sha256"
  fi
  printf '%s\n' "$sum"
}

# A file path as Wine sees it: / is drive Z:.
oh_native_win_path() {
  local p=$1
  printf 'Z:%s\n' "${p//\//\\}"
}

oh_native_size() {
  local b=$1
  if ((b >= 1000000000)); then
    printf '%d.%d GB' $((b / 1000000000)) $((b % 1000000000 / 100000000))
  else
    printf '%d MB' $((b / 1000000))
  fi
}

# Bytes a folder takes on disk.
oh_native_du() {
  [[ -e $1 ]] || {
    echo 0
    return 0
  }
  du -s -B1 -- "$1" 2>/dev/null | awk '{ print $1 }'
}

# IPv4 address classes. Private: RFC 1918, the 100.64.0.0/10 shared range
# Tailscale uses, and link-local.
oh_ipv4() {
  local IFS=. o
  local -a q
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r -a q <<<"$1"
  for o in "${q[@]}"; do ((10#$o <= 255)) || return 1; done
  OH_Q=("${q[@]}")
}
oh_ipv4_tailnet() { oh_ipv4 "$1" && ((10#${OH_Q[0]} == 100 && 10#${OH_Q[1]} >= 64 && 10#${OH_Q[1]} <= 127)); }
oh_ipv4_lan() {
  oh_ipv4 "$1" || return 1
  local a=$((10#${OH_Q[0]})) b=$((10#${OH_Q[1]}))
  ((a == 10)) || ((a == 172 && b >= 16 && b <= 31)) || ((a == 192 && b == 168)) || ((a == 169 && b == 254))
}
# A host a plain http:// seed may come from.
oh_native_private_host() {
  local h=${1,,}
  oh_ipv4_lan "$h" || oh_ipv4_tailnet "$h" || [[ $h =~ ^([a-z0-9-]+\.)+ts\.net$ ]]
}

# The address a page or seed server listens on: this device's tailnet IPv4,
# or with LAN=1 its LAN address. Never 0.0.0.0.
oh_native_bind_ip() {
  local lan=$1 ip
  if ((lan)); then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1) || ip=''
    oh_ipv4_lan "$ip" || oh_die "no private LAN address found (got '${ip:-none}'); join the home or office network, or use the tailnet (drop --lan)"
  else
    oh_have tailscale || oh_die "Tailscale is not installed; to share a seed on a home network add --lan; to sign in, use this device's screen: omarchohard native signin"
    ip=$(tailscale ip -4 2>/dev/null | head -n1) || ip=''
    oh_ipv4_tailnet "$ip" || oh_die "Tailscale is not up (tailscale ip -4 gave '${ip:-nothing}'); start it (sudo tailscale up); to share a seed on a home network add --lan"
  fi
  printf '%s\n' "$ip"
}

# What keeps the native tier from running well here, one reason per line.
# Nothing printed means it can run.
oh_native_missing() {
  local total free_gb
  total=$(($(oh_mem_kib MemTotal) / 1024))
  free_gb=$(($(df --output=avail -k "$HOME" 2>/dev/null | tail -n1 || echo 0) / 1048576))
  [[ $(uname -m) == x86_64 ]] || echo "an x86_64 processor (wine-altars is built for x86_64)"
  oh_have Hyprland || [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || echo "Hyprland"
  # MiB: the kernel keeps some memory back, so an 8 GB machine shows about 7.6 GiB.
  ((total >= 7168)) || echo "8 GB of memory"
  ((free_gb >= 8)) || echo "8 GB free disk"
  return 0
}

oh_native_check() {
  local line bad=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    oh_err "needs $line"
    bad=1
  done < <(oh_native_missing)
  ((bad)) || oh_ok "this machine can run native Office (x86_64, Hyprland, 8 GB of memory, 8 GB free disk)"
  ((bad == 0))
}

# On btrfs, files written under DIR from now on are zstd-compressed: the
# 6.6 GB prefix takes 3.1 GB. Elsewhere, or without the btrfs tool, nothing.
oh_native_compress() {
  [[ $(stat -f -c %T -- "$1" 2>/dev/null) == btrfs ]] && oh_have btrfs || return 0
  btrfs property set "$1" compression zstd >/dev/null 2>&1 || true
}

# Download URL to FILE; with SHA, the file must have that SHA256 or it is
# deleted before anything reads it.
oh_native_fetch() {
  local url=$1 file=$2 sha=${3:-} sum
  if [[ -s $file ]] && [[ -z $sha || $(sha256sum -- "$file" | awk '{ print $1 }') == "$sha" ]]; then
    return 0
  fi
  mkdir -p "${file%/*}"
  rm -f -- "$file.part"
  "${OH_NATIVE_CURL[@]}" -o "$file.part" "$url" || {
    rm -f -- "$file.part"
    oh_die "could not download $url"
  }
  if [[ -n $sha ]]; then
    sum=$(sha256sum -- "$file.part" | awk '{ print $1 }')
    if [[ $sum != "$sha" ]]; then
      rm -f -- "$file.part"
      oh_die "$url has SHA256 $sum, not the pinned $sha; it was deleted and nothing was extracted"
    fi
  fi
  mv -f -- "$file.part" "$file"
}

# wine-altars into $OH_WINE_DIR, checked against its pinned SHA256 before
# anything is extracted. Kept when it is already there.
oh_native_wine_install() {
  local tarball=$OH_NATIVE_DIR/dl/wine-altars-linux-x86_64.tar.xz tmp=$OH_DATA_DIR/.wine.tmp
  if oh_native_wine_ok; then
    oh_ok "Wine: wine-altars $OH_WINE_TAG, already here"
    return 0
  fi
  if oh_dry; then
    oh_run "${OH_NATIVE_CURL[@]}" -o "$tarball" "$OH_WINE_URL"
    printf 'would check: SHA256 %s\n' "$OH_WINE_SHA256"
    oh_run tar -xJf "$tarball" -C "$OH_WINE_DIR" --strip-components=1
    return 0
  fi
  oh_say "Downloading wine-altars $OH_WINE_TAG (110 MB)..."
  oh_native_fetch "$OH_WINE_URL" "$tarball" "$OH_WINE_SHA256"
  rm -rf -- "$tmp"
  mkdir -p "$tmp"
  tar -xJf "$tarball" -C "$tmp" --strip-components=1 --no-same-owner ||
    oh_die "could not extract $tarball"
  [[ -x $tmp/bin/wine && -x $tmp/bin/wineserver ]] || oh_die "$tarball has no bin/wine and bin/wineserver"
  printf '%s\n' "$OH_WINE_TAG" >"$tmp/.omarchohard-release"
  rm -rf -- "$OH_WINE_DIR"
  mv -- "$tmp" "$OH_WINE_DIR"
  rm -f -- "$tarball"
  oh_ok "Wine: $("$OH_WINE" --version 2>/dev/null || echo "wine-altars $OH_WINE_TAG")"
}

# Sets OH_FROM_CMD to the command that writes the seed SRC to stdout. SHA is
# the --sha256 given, which plain http:// needs.
oh_native_from_cmd() {
  local src=$1 sha=$2 host
  case $src in
  ssh:*)
    host=${src#ssh:}
    [[ $host =~ ^[A-Za-z0-9_][A-Za-z0-9._@-]*$ ]] || oh_die "not a host name: $host (use --from ssh:HOST)"
    # A non-interactive ssh shell may not have ~/.local/bin on its PATH.
    # shellcheck disable=SC2016 # expanded by the remote shell
    OH_FROM_CMD=(ssh -o BatchMode=yes "$host" 'PATH="$HOME/.local/bin:$PATH" omarchohard native seed --stdout')
    ;;
  https://*)
    # No -L: a redirect is never followed, to another host or any host.
    OH_FROM_CMD=("${OH_OFFICE_CURL[@]}" "$src")
    ;;
  http://*)
    host=${src#http://}
    host=${host%%[/?#]*}
    [[ $host != *@* ]] || oh_die "a seed link may not carry a user name: $src"
    host=${host%:*}
    oh_native_private_host "$host" ||
      oh_die "plain http:// seeds come only from a private address (10.x, 172.16-31.x, 192.168.x, 169.254.x, a tailnet 100.64-127.x or a .ts.net name), not $host; use https://, ssh:HOST or a file"
    [[ -n $sha ]] ||
      oh_die "a plain http:// seed needs --sha256 (seed serve prints it), so a changed download is caught before it is used"
    OH_FROM_CMD=("${OH_NATIVE_CURL_LOCAL[@]}" "$src")
    ;;
  *://*) oh_die "--from takes a seed file, ssh:HOST, an https:// link or a private http:// link, not $src" ;;
  *)
    [[ -f $src ]] || oh_die "no seed file at $src"
    OH_FROM_CMD=(cat -- "$src")
    ;;
  esac
}

# Unpack the seed from SRC into a staging folder, keeping a copy of the
# stream as the stored seed while it unpacks (no second pass over 2.9 GB).
# Only once its SHA256 (when given) and its product (when a plan is given)
# match does it become the prefix; otherwise both are deleted.
oh_native_unpack() {
  local src=$1 sha=$2 want=$3 stage=$OH_NATIVE_DIR/.incoming part=$OH_NATIVE_DIR/.seed.part keep=1
  local v product old rc=0 sum name
  local -a tarx=(tar "${OH_NATIVE_XATTRS[@]}" --no-same-owner -C "$stage" -xf - prefix)
  oh_native_from_cmd "$src" "$sha"
  name=$(oh_native_name_product "$src" || true)
  [[ -z $want || -z $name || ,$name, == *",$want,"* ]] ||
    oh_die "the seed $src holds $name (Microsoft 365 $(oh_native_plan_words "$name")), but --plan $OH_NATIVE_PLAN needs $want; get a seed from a device with the same plan, or install without --from"
  old=$(oh_native_seed_file || true)
  [[ -f $src && -n $old && $src -ef $old ]] && keep=0
  if oh_dry; then
    if ((keep)); then
      printf 'would run: %s| tee %q | zstd -dcq | %s\n' "$(printf '%q ' "${OH_FROM_CMD[@]}")" "$part" "$(printf '%q ' "${tarx[@]}")"
    else
      printf 'would run: %s| zstd -dcq | %s\n' "$(printf '%q ' "${OH_FROM_CMD[@]}")" "$(printf '%q ' "${tarx[@]}")"
    fi
    [[ -z $sha ]] || printf 'would check: SHA256 %s\n' "$sha"
    printf 'would run: mv %q %q\n' "$stage/prefix" "$OH_NATIVE_PREFIX"
    return 0
  fi
  rm -rf -- "$stage" "$part"
  mkdir -p "$stage"
  oh_say "Copying Office from $src..."
  if ((keep)); then
    "${OH_FROM_CMD[@]}" | tee -- "$part" | zstd -dcq | "${tarx[@]}" || rc=$?
  else
    "${OH_FROM_CMD[@]}" | zstd -dcq | "${tarx[@]}" || rc=$?
  fi
  oh_native_unpack_fail() {
    rm -rf -- "$stage" "$part"
    oh_die "$1; nothing was kept"
  }
  ((rc == 0)) || oh_native_unpack_fail "the seed from $src did not arrive whole (exit $rc)"
  if [[ -n $sha || $keep == 1 ]]; then
    if ((keep)); then sum=$(sha256sum -- "$part" | awk '{ print $1 }'); else sum=$(sha256sum -- "$src" | awk '{ print $1 }'); fi
    [[ -z $sha || $sum == "$sha" ]] || oh_native_unpack_fail "the seed from $src has SHA256 $sum, not the $sha given"
  fi
  [[ -f $stage/prefix/system.reg && -f $stage/prefix/drive_c/Program\ Files/Microsoft\ Office/root/Office16/WINWORD.EXE ]] ||
    oh_native_unpack_fail "the seed from $src has no Office prefix in it (prefix/ with Word)"
  product=$(oh_native_office_product "$stage/prefix" || true)
  if [[ -n $want && ,$product, != *",$want,"* ]]; then
    oh_native_unpack_fail "the seed from $src holds ${product:-an unknown product} (Microsoft 365 $(oh_native_plan_words "${product:-unknown}")), but --plan $OH_NATIVE_PLAN needs $want"
  fi
  mv -- "$stage/prefix" "$OH_NATIVE_PREFIX"
  chmod 700 -- "$OH_NATIVE_PREFIX"
  rmdir -- "$stage" 2>/dev/null || true
  v=$(oh_native_office_version) || v=unknown
  if ((keep)); then
    [[ -z $old ]] || rm -f -- "$old" "$old.sha256"
    name=$OH_NATIVE_DIR/seed-${product%%,*}-$v.tar.zst
    mv -f -- "$part" "$name"
    printf '%s\n' "$sum" >"$name.sha256"
    chmod 600 -- "$name" "$name.sha256"
  fi
  oh_ok "Office $v (${product:-unknown product}) copied in; seed kept at $(oh_native_seed_file)"
}

# A hidden X screen for steps that need one. Xvfb on this machine when it is
# installed (Omarchy does not ship it: xorg-server-xvfb); sets OH_HIDDEN_PID
# and OH_HIDDEN_DISPLAY. Returns 1 without Xvfb.
oh_native_hidden_start() {
  local n i
  OH_HIDDEN_PID='' OH_HIDDEN_DISPLAY=''
  oh_have Xvfb || return 1
  for n in $(seq 90 119); do
    [[ -e /tmp/.X11-unix/X$n || -e /tmp/.X$n-lock ]] || break
  done
  Xvfb ":$n" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
  OH_HIDDEN_PID=$!
  for ((i = 0; i < 100; i++)); do
    [[ -S /tmp/.X11-unix/X$n ]] && break
    sleep 0.1
  done
  if [[ ! -S /tmp/.X11-unix/X$n ]]; then
    kill "$OH_HIDDEN_PID" 2>/dev/null || true
    OH_HIDDEN_PID=''
    return 1
  fi
  OH_HIDDEN_DISPLAY=:$n
}

oh_native_hidden_stop() {
  [[ -n ${OH_HIDDEN_PID:-} ]] || return 0
  kill "$OH_HIDDEN_PID" 2>/dev/null || true
  wait "$OH_HIDDEN_PID" 2>/dev/null || true
  OH_HIDDEN_PID=''
}

# 1. The prefix: 64-bit, Windows 11, Wine Gecko.
oh_native_step_prefix() {
  local arch f
  oh_say "Making the Wine prefix (about 50 seconds)..."
  if [[ ! -f $OH_NATIVE_PREFIX/system.reg ]]; then
    oh_run mkdir -p "$OH_NATIVE_PREFIX"
    oh_run chmod 700 "$OH_NATIVE_PREFIX"
    # Mono and Gecko prompts would wait for a click while the prefix is made.
    WINEARCH=win64 OH_NATIVE_OVERRIDES='mscoree=d;mshtml=d' oh_native_wine wineboot -u
    oh_native_settle 120
  fi
  oh_native_wine winecfg -v win11
  oh_native_settle 120
  if [[ ! -d $OH_NATIVE_PREFIX/drive_c/windows/system32/gecko/$OH_GECKO_VERSION ]]; then
    for arch in x86_64 x86; do
      f=$OH_NATIVE_DIR/dl/wine-gecko-$OH_GECKO_VERSION-$arch.msi
      oh_dry || oh_native_fetch "https://dl.winehq.org/wine/wine-gecko/$OH_GECKO_VERSION/${f##*/}" "$f" "${OH_GECKO_SHA256[$arch]}"
      oh_native_wine msiexec /i "$(oh_native_win_path "$f")" /qn
    done
  fi
  oh_native_ws -k 2>/dev/null || true
  oh_ok "Wine prefix: Windows 11, Gecko $OH_GECKO_VERSION"
}

oh_native_webview2_dir() {
  find "$OH_NATIVE_PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | head -n1
}

# 2. WebView2: Office's sign-in window is one.
oh_native_step_webview2() {
  local f=$OH_NATIVE_DIR/dl/MicrosoftEdgeWebview2Setup.exe
  if [[ -n $(oh_native_webview2_dir) ]]; then
    oh_ok "WebView2: already installed"
    return 0
  fi
  oh_say "Installing Microsoft Edge WebView2 (about 1.5 minutes)..."
  oh_dry || oh_native_fetch "$OH_WEBVIEW2_URL" "$f"
  oh_native_wine "$f" /silent /install || oh_warn "the WebView2 installer exited $?; checking the result"
  # Wine bug 53925: the installer leaves its update service on automatic
  # start, where it hangs the prefix. Wine bug 58921: the runtime's renderer
  # starts only when it is told it runs on Windows 7.
  oh_native_wine reg add 'HKLM\System\CurrentControlSet\Services\edgeupdate' /v Start /t REG_DWORD /d 3 /f >/dev/null
  oh_native_wine reg add 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' /v Version /t REG_SZ /d win7 /f >/dev/null
  # The update service is all that runs now; stopping the prefix ends it.
  oh_native_settle 15
  oh_dry || [[ -n $(oh_native_webview2_dir) ]] || oh_die "WebView2 did not install; run omarchohard native install again"
  oh_ok "WebView2: $(basename -- "$(oh_native_webview2_dir)" 2>/dev/null)"
}

# Office's install files, downloaded on the host while the prefix and
# WebView2 steps run: the desktop tier's prefetch (8 byte ranges at once),
# into $OH_NATIVE_SRC. A process of its own.
oh_native_src_start() {
  oh_dry && {
    oh_say "would download Office's install files into $OH_NATIVE_SRC (the desktop tier's office-prefetch)"
    return 0
  }
  mkdir -p "$OH_NATIVE_SRC"
  rm -f -- "$OH_NATIVE_SRC/ready" "$OH_NATIVE_SRC/failed"
  (
    OH_OFFICE_SRC=$OH_NATIVE_SRC
    oh_office_prefetch
  ) </dev/null >/dev/null 2>&1 &
  OH_NATIVE_SRC_PID=$!
}

# Wait for the download; prints the Office version it fetched.
oh_native_src_wait() {
  oh_dry && {
    echo 16.0.0.0
    return 0
  }
  while :; do
    [[ -f $OH_NATIVE_SRC/ready ]] && break
    [[ -f $OH_NATIVE_SRC/failed ]] && oh_die "Office's download failed: $(cat -- "$OH_NATIVE_SRC/failed") (log: $OH_NATIVE_SRC/prefetch.log)"
    kill -0 "${OH_NATIVE_SRC_PID:-0}" 2>/dev/null || oh_die "Office's download stopped (log: $OH_NATIVE_SRC/prefetch.log)"
    sleep 2
  done
  wait "${OH_NATIVE_SRC_PID:-0}" 2>/dev/null || true
  cat -- "$OH_NATIVE_SRC/ready"
}

# The Office Deployment Tool's configuration: PRODUCT from the local copy,
# never the CDN, with five apps; SHARED=1 turns on shared computer
# activation (ODT's SharedComputerLicensing property).
# https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/office-deployment-tool-configuration-options
oh_native_odt_config() {
  local v=$1 product=$2 shared=$3 a
  printf '<Configuration>\n'
  printf '  <Add OfficeClientEdition="64" Channel="Current" SourcePath="%s" Version="%s" AllowCdnFallback="FALSE">\n' "$(oh_native_win_path "$OH_NATIVE_SRC")" "$v"
  printf '    <Product ID="%s">\n' "$product"
  printf '      <Language ID="en-us" />\n'
  for a in Access Bing Groove Lync OneDrive OutlookForWindows Publisher Teams; do
    printf '      <ExcludeApp ID="%s" />\n' "$a"
  done
  printf '    </Product>\n  </Add>\n'
  ((shared)) && printf '  <Property Name="SharedComputerLicensing" Value="1" />\n'
  printf '  <Updates Enabled="FALSE" />\n'
  printf '  <Display Level="None" AcceptEULA="TRUE" />\n'
  printf '  <Logging Level="Standard" Path="C:\\c2rlog" />\n'
  printf '</Configuration>\n'
}

# 3. Office, from the copy downloaded meanwhile (2m36s to 2m49s measured).
oh_native_step_office() {
  local product=$1 shared=$2 v setup=$OH_NATIVE_DIR/dl/setup.exe conf=$OH_NATIVE_DIR/dl/configuration.xml rc=0
  oh_say "Waiting for Office's install files..."
  v=$(oh_native_src_wait)
  oh_say "Installing Microsoft 365 $v ($product) (about 3 minutes)..."
  if ! oh_dry; then
    mkdir -p "${setup%/*}"
    rm -f -- "$setup.part"
    "${OH_OFFICE_CURL[@]}" -o "$setup.part" "$OH_ODT_URL" || oh_die "could not download $OH_ODT_URL"
    mv -f -- "$setup.part" "$setup"
    oh_native_odt_config "$v" "$product" "$shared" >"$conf"
  fi
  oh_native_ws -k 2>/dev/null || true
  oh_native_wine "$setup" /configure "$(oh_native_win_path "$conf")" || rc=$?
  oh_native_settle 30
  if ! oh_dry && ! oh_native_has word; then
    oh_die "Office did not install (setup.exe exited $rc); its log is in $OH_NATIVE_PREFIX/drive_c/c2rlog/"
  fi
  oh_run rm -rf -- "$OH_NATIVE_SRC"
  oh_ok "Office $v installed"
}

# 4. Office's own sign-in window: two feature gates per app choose the
# WebView2 sign-in and turn off the Windows account broker, which this
# prefix does not have. Neither touches license state.
oh_native_step_gates() {
  local app gate key
  for app in word excel powerpoint outlook onenote; do
    key="HKCU\\Software\\Microsoft\\Office\\16.0\\Common\\ExperimentConfigs\\ExternalFeatureOverrides\\$app"
    for gate in Microsoft.Office.Identity.FG.IsWebView2ForOneAuthEnabled Microsoft.Office.Identity.TestGate.DisableBrokerForOneAuth; do
      oh_native_wine reg add "$key" /v "$gate" /t REG_SZ /d true /f /reg:64 >/dev/null 2>&1 ||
        oh_warn "could not set $gate for $app"
    done
  done
  oh_native_settle 15
  oh_ok "Office sign-in: Office's own window (WebView2)"
}

# 5. The first start in a new prefix can raise the fork's known crash dialog
# (0xe0000002) once; later starts are clean. Start Word once on a hidden
# screen, give it 30 seconds, and stop it.
oh_native_step_absorb() {
  if oh_dry; then
    oh_run Xvfb :90 -screen 0 1280x800x24 -nolisten tcp
    oh_run env DISPLAY=:90 "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINE" "$OH_NATIVE_OFFICE/WINWORD.EXE"
    return 0
  fi
  if ! oh_native_hidden_start; then
    oh_say "Xvfb is not installed (xorg-server-xvfb), so Word's first start was not done ahead of time."
    oh_say "The first time Word opens it may show \"WINWORD.EXE has encountered a serious problem\" once; close that box and Word keeps working."
    return 0
  fi
  oh_say "Starting Word once on a hidden screen (30 seconds)..."
  local -a env
  local word
  mapfile -t env < <(oh_native_env)
  oh_native_box app
  "${OH_BOX[@]}" env DISPLAY="$OH_HIDDEN_DISPLAY" "${env[@]}" "$OH_WINE" "$OH_NATIVE_OFFICE/WINWORD.EXE" >/dev/null 2>&1 &
  word=$!
  sleep "${OMARCHOHARD_NATIVE_ABSORB:-30}"
  oh_native_settle 1
  # Only Word: a bare wait would also wait for Xvfb, which never exits.
  wait "$word" 2>/dev/null || true
  oh_native_hidden_stop
  oh_ok "Word's first start is done"
}

# Selawik, Microsoft's open-source stand-in for Segoe UI (SIL OFL 1.1,
# share/omarchohard/fonts/selawik), in the prefix's Fonts folder, and Segoe UI
# mapped to it, so Office's interface text has its intended shapes. Every
# install does it, from Microsoft or from a seed.
OH_NATIVE_FONTS='Segoe UI=Selawik
Segoe UI Light=Selawik Light
Segoe UI Semilight=Selawik Semilight
Segoe UI Semibold=Selawik Semibold'
oh_native_fonts_ok() {
  local f
  for f in "$OH_SHARE"/fonts/selawik/*.ttf; do
    [[ -f $OH_NATIVE_PREFIX/drive_c/windows/Fonts/${f##*/} ]] || return 1
  done
}
oh_native_step_fonts() {
  local fonts=$OH_NATIVE_PREFIX/drive_c/windows/Fonts reg=$OH_NATIVE_DIR/.fonts.reg line
  oh_run mkdir -p "$fonts"
  oh_run cp -f -- "$OH_SHARE"/fonts/selawik/*.ttf "$fonts/"
  if ! oh_dry; then
    {
      printf 'Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]\r\n'
      while IFS= read -r line; do
        printf '"%s"="%s"\r\n' "${line%%=*}" "${line#*=}"
      done <<<"$OH_NATIVE_FONTS"
    } >"$reg"
  fi
  # One Wine start for all four, not one per key.
  oh_native_wine reg import "$(oh_native_win_path "$reg")" >/dev/null 2>&1 || oh_warn "could not map Segoe UI to Selawik; Office's text keeps Wine's default font"
  oh_native_settle 15
  oh_run rm -f -- "$reg"
  oh_ok "fonts: Segoe UI shows as Selawik"
}

# 6. The seed: the prefix now, before anyone has signed in. The only place
# the live prefix is ever packed.
oh_native_seed_write() {
  local v product part=$OH_NATIVE_DIR/.seed.part old name
  v=$(oh_native_office_version) || v=unknown
  product=$(oh_native_office_product) || product=${1:-unknown}
  name=$OH_NATIVE_DIR/seed-${product%%,*}-$v.tar.zst
  if oh_dry; then
    printf 'would run: tar %s -C %q -cf - prefix | zstd -T0 -3 -q > %q\n' "${OH_NATIVE_XATTRS[*]}" "$OH_NATIVE_DIR" "$name"
    return 0
  fi
  oh_say "Writing the seed for your other devices (about 10 seconds)..."
  old=$(oh_native_seed_file || true)
  tar "${OH_NATIVE_XATTRS[@]}" -C "$OH_NATIVE_DIR" -cf - prefix | zstd -T0 -3 -q -c >"$part" ||
    {
      rm -f -- "$part"
      oh_die "could not write the seed; Office itself is installed"
    }
  [[ -z $old ]] || rm -f -- "$old" "$old.sha256"
  mv -f -- "$part" "$name"
  sha256sum -- "$name" | awk '{ print $1 }' >"$name.sha256"
  chmod 600 -- "$name" "$name.sha256"
  oh_ok "seed: $name ($(oh_native_size "$(stat -c %s -- "$name")"))"
}

# One install at a time on a device: a second waits for the first, then
# finds Office there.
oh_native_lock() {
  local name=$1
  oh_dry && return 0
  mkdir -p "$OH_STATE_DIR"
  exec {OH_NATIVE_LOCK_FD}>"$OH_STATE_DIR/$name.lock"
  flock -w 3600 "$OH_NATIVE_LOCK_FD" || oh_die "another omarchohard $name is still running after an hour"
}

oh_native_install() {
  local from='' sha='' yes=0 shared=0 email='' start=$SECONDS question product='' tool
  OH_NATIVE_PLAN=''
  while (($#)); do
    case $1 in
    --from) from=${2:?--from needs a seed file, ssh:HOST or a link} && shift ;;
    --sha256) sha=${2:?--sha256 needs the seed\'s SHA256} && shift ;;
    --plan) OH_NATIVE_PLAN=${2:?--plan needs ${OH_NATIVE_PLAN_ORDER// /, }} && shift ;;
    --shared-computer) shared=1 ;;
    --email) email=${2:?--email needs an address} && shift ;;
    --yes | -y) yes=1 ;;
    *) oh_die "unknown native install option: $1 (usage: omarchohard native install [--from SRC [--sha256 H]] [--plan P] [--shared-computer] [--yes])" ;;
    esac
    shift
  done
  sha=${sha,,}
  [[ -z $sha || $sha =~ ^[0-9a-f]{64}$ ]] || oh_die "--sha256 takes 64 hex digits"
  [[ -z $OH_NATIVE_PLAN ]] || oh_native_plan_check "$OH_NATIVE_PLAN"
  if [[ -n $from ]]; then
    # The source is checked before anything is downloaded.
    oh_native_from_cmd "$from" "$sha"
    ((shared == 0)) || oh_warn "--shared-computer is ignored with --from: the seed was installed with or without it, on the first device"
    shared=0
    [[ -z $OH_NATIVE_PLAN ]] || product=${OH_NATIVE_PLANS[$OH_NATIVE_PLAN]}
  else
    [[ -n $sha ]] && oh_die "--sha256 checks a seed; it goes with --from"
    [[ -z $OH_NATIVE_PLAN ]] || product=${OH_NATIVE_PLANS[$OH_NATIVE_PLAN]}
    ((shared == 0)) || [[ " $OH_NATIVE_SHARED_PLANS " == *" ${OH_NATIVE_PLAN:-personal} "* ]] ||
      oh_die "--shared-computer is for --plan school or enterprise; Microsoft does not support shared computer activation for ${OH_NATIVE_PLAN:-personal} plans"
  fi
  [[ $(uname -m) == x86_64 ]] || oh_die "native Office needs an x86_64 machine; wine-altars is built for x86_64"
  # Office, its seed and the sign-in Office keeps are this user's alone.
  umask 077
  for tool in tar zstd curl sha256sum flock; do
    oh_have "$tool" || oh_die "native Office needs $tool"
  done
  oh_native_lock native-install
  if [[ -e $OH_NATIVE_PREFIX && ! -f $OH_NATIVE_COMPLETE ]]; then
    # Never finish it in place: someone may have signed in since, and the
    # seed must be packed before any sign-in. The download and Wine stay.
    if ((! yes)); then
      oh_ui_interactive || oh_die "an earlier install stopped before it finished; run this in a terminal or add --yes to remove it and install again"
      oh_ui_open
      oh_ui_confirm "An earlier install stopped before it finished. Remove it and install again? The Office download and Wine are kept." yes || oh_die "nothing was changed"
    fi
    oh_say "An earlier install stopped before it finished; removing it and installing again"
    oh_native_stop_wine
    oh_run rm -rf -- "$OH_NATIVE_PREFIX"
    yes=1
  fi
  if oh_native_has word; then
    local have
    have=$(oh_native_office_product || true)
    [[ -z $product || ,$have, == *",$product,"* ]] ||
      oh_die "Office here is $have (Microsoft 365 $(oh_native_plan_words "$have")), not the $product --plan $OH_NATIVE_PLAN needs; remove it first: omarchohard native uninstall"
    oh_native_wine_install
    oh_native_fonts_ok || oh_native_step_fonts
    oh_dry || chmod 700 -- "$OH_NATIVE_PREFIX"
    oh_ok "native Office is already installed (omarchohard native status)"
    oh_dry || oh_config_set open_with native
    oh_native_update_timer on
    return 0
  fi
  # A fresh install without --plan: personal, said out loud. (Checked only
  # now, so a rerun on an installed device never needs --plan.)
  if [[ -z $from && -z $OH_NATIVE_PLAN ]]; then
    OH_NATIVE_PLAN=personal
    product=${OH_NATIVE_PLANS[$OH_NATIVE_PLAN]}
    oh_say "No --plan given: installing Microsoft 365 Personal and Family ($OH_NATIVE_PLAN). For school or work, add --plan school, business or enterprise."
  fi
  if [[ -z $from ]]; then
    oh_office_prefetch_usable || oh_die "a fresh install needs curl, bsdtar and flock, and $OH_NATIVE_DIR under your home folder"
    question="Download Microsoft 365 ($product) from Microsoft (about 3.4 GB) and install Word, Excel, PowerPoint, Outlook and OneNote under Wine? This accepts Microsoft's license terms (https://www.microsoft.com/useterms)."
  else
    question="Copy Office from $from into $OH_NATIVE_PREFIX (about 7 GB, or 3 GB compressed on btrfs)?"
  fi
  if ((! yes)); then
    oh_ui_interactive || oh_die "native install asks first; run it in a terminal or add --yes"
    oh_ui_open
    oh_ui_confirm "$question" yes || oh_die "not installed"
  fi
  if ! oh_dry; then
    mkdir -p "$OH_NATIVE_DIR"
    oh_native_compress "$OH_NATIVE_DIR"
  fi
  if [[ -n $from ]]; then
    oh_native_wine_install
    oh_native_unpack "$from" "$sha" "$product"
    oh_native_fonts_ok || oh_native_step_fonts
  else
    oh_native_src_start
    oh_native_wine_install
    oh_native_step_prefix
    oh_native_step_webview2
    oh_native_step_office "$product" "$shared"
    oh_native_step_gates
    oh_native_step_fonts
    oh_native_step_absorb
    oh_native_seed_write "$product"
  fi
  [[ -z $email ]] || oh_say "Office has no setting that fills in the sign-in address; sign in as $email in Office's window."
  oh_native_update_timer on
  oh_dry && return 0
  : >"$OH_NATIVE_COMPLETE"
  oh_config_set open_with native
  oh_ok "native Office is ready in $((SECONDS - start)) s; Office files open in it (omarchohard native status)"
}

# The seed file, never the live prefix.
oh_native_seed() {
  local f
  case ${1:-} in
  --stdout | --path) ;;
  serve)
    shift
    oh_native_seed_serve "$@"
    return
    ;;
  *) oh_die "usage: omarchohard native seed --stdout | --path | serve [--minutes N] [--port P] [--lan] | serve --stop" ;;
  esac
  f=$(oh_native_seed_file) ||
    oh_die "no seed file in $OH_NATIVE_DIR. A seed is written only by a fresh install, before anyone signs in, or kept when one arrives with --from; a signed-in prefix is never packed."
  if [[ $1 == --path ]]; then
    printf '%s\n' "$f"
    return 0
  fi
  [[ ! -t 1 ]] || oh_die "the seed is $(oh_native_size "$(stat -c %s -- "$f")"); send it to a file or a pipe, not the terminal"
  exec cat -- "$f"
}

oh_native_serving() {
  local engine
  systemctl --user is-active --quiet "$OH_NATIVE_SERVE.service" 2>/dev/null && return 0
  engine=$(oh_native_engine 2>/dev/null) || return 1
  [[ $("$engine" inspect -f '{{.State.Running}}' "$OH_NATIVE_SERVE" 2>/dev/null) == true ]]
}

oh_native_serve_stop() {
  local engine
  oh_run systemctl --user stop "$OH_NATIVE_SERVE.service" >/dev/null 2>&1 || true
  if engine=$(oh_native_engine 2>/dev/null); then
    oh_run "$engine" rm -f "$OH_NATIVE_SERVE" >/dev/null 2>&1 || true
  fi
  return 0
}

# A python3 that runs (a version manager's shim may not, outside its shell).
oh_native_python() {
  local p
  for p in /usr/bin/python3 "$(command -v python3 2>/dev/null)"; do
    [[ -n $p && -x $p ]] && "$p" -c 'import http.server' >/dev/null 2>&1 && {
      printf '%s\n' "$p"
      return 0
    }
  done
  return 1
}

# `native seed serve`: the stored seed over HTTP, many devices at once, at a
# random path, on the tailnet address (or with --lan the LAN address) only,
# until N minutes are up. Prints the --from and --sha256 the other devices
# take.
oh_native_seed_serve() {
  local minutes=60 port=$OH_NATIVE_SERVE_PORT lan=0 f sha ip token envf py url i name
  while (($#)); do
    case $1 in
    --minutes) minutes=${2:?--minutes needs a number} && shift ;;
    --port) port=${2:?--port needs a number} && shift ;;
    --lan) lan=1 ;;
    --stop)
      oh_native_serve_stop
      oh_ok "seed server stopped"
      return 0
      ;;
    *) oh_die "usage: omarchohard native seed serve [--minutes N] [--port P] [--lan] | --stop" ;;
    esac
    shift
  done
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes >= 1 && minutes <= 1440)) || oh_die "--minutes takes 1 to 1440"
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || oh_die "--port takes 1024 to 65535"
  f=$(oh_native_seed_file) || oh_die "no seed file to serve in $OH_NATIVE_DIR (omarchohard native install writes one)"
  ip=$(oh_native_bind_ip "$lan")
  ! oh_native_serving || oh_die "a seed server is already running; stop it with: omarchohard native seed serve --stop"
  sha=$(oh_native_seed_sha "$f")
  name=${f##*/}
  token=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
  url="http://$ip:$port/$token/$name"
  py=$(oh_native_python || true)
  if oh_dry; then
    oh_run systemd-run --user --quiet --collect --unit="$OH_NATIVE_SERVE" "${py:-python3}" "$OH_SHARE/native-remote/seed-serve.py" "$ip" "$port" "$f" "$((minutes * 60))"
    printf -- '--from http://%s:%s/<token>/%s --sha256 %s\n' "$ip" "$port" "$name" "$sha"
    return 0
  fi
  # The token goes through the environment, never a command line.
  envf=$(oh_native_signin_dir).seed-env
  mkdir -p "${envf%/*}"
  (
    umask 077
    printf 'OH_SEED_TOKEN=%s\n' "$token" >"$envf"
  )
  if [[ -n $py ]] && oh_have systemd-run &&
    systemd-run --user --quiet --collect --unit="$OH_NATIVE_SERVE" -p "EnvironmentFile=$envf" "$py" "$OH_SHARE/native-remote/seed-serve.py" "$ip" "$port" "$f" "$((minutes * 60))" 2>/dev/null; then
    :
  elif [[ -n $py ]]; then
    OH_SEED_TOKEN=$token setsid -f "$py" "$OH_SHARE/native-remote/seed-serve.py" "$ip" "$port" "$f" "$((minutes * 60))" </dev/null >/dev/null 2>&1
  else
    oh_die "seed serve needs python3 (omarchy pkg add python)"
  fi
  for ((i = 0; i < 50; i++)); do
    # shellcheck disable=SC2016 # expanded by the inner bash
    timeout 1 bash -c ': >"/dev/tcp/$1/$2"' _ "$ip" "$port" 2>/dev/null && break
    sleep 0.1
  done
  rm -f -- "$envf"
  ((i < 50)) || {
    oh_native_serve_stop
    oh_die "the seed server did not start on $ip:$port (journalctl --user -u $OH_NATIVE_SERVE; try --port)"
  }
  oh_say "Serving $name ($(oh_native_size "$(stat -c %s -- "$f")")) on $ip:$port for $minutes minute$( ((minutes == 1)) || echo s) (stop: omarchohard native seed serve --stop)."
  oh_say "On each other device:  omarchohard setup --tier native --yes --from $url --sha256 $sha"
  printf -- '--from %s --sha256 %s\n' "$url" "$sha"
}

# Office processes of this prefix (another prefix's Word, in a container
# say, is not ours). One pid per line.
oh_native_app_pids() {
  local pid env
  for pid in $(pgrep -u "$(id -u)" -f '\.(EXE|exe)( |$)' 2>/dev/null || true); do
    env=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null) || continue
    grep -qxF -- "WINEPREFIX=$OH_NATIVE_PREFIX" <<<"$env" || continue
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qE '[\\/]Office16[\\/](WINWORD|EXCEL|POWERPNT|OUTLOOK|ONENOTE)\.EXE' && printf '%s\n' "$pid"
  done
  return 0
}

oh_native_run() {
  local app=${1:-} exe file abs
  exe=${OH_NATIVE_EXE[$app]:-}
  [[ -n $exe ]] || oh_die "usage: omarchohard native run word|excel|powerpoint|outlook|onenote [FILE...]"
  shift
  oh_native_ready || oh_die "native Office is not set up yet (omarchohard native install)"
  # A sign-in that died leaves its DevTools port open; close it first.
  [[ ! -e $OH_NATIVE_DIR/devtools-on ]] || oh_native_signin_running || oh_native_devtools off
  oh_native_has "$app" || oh_die "$(oh_app_name "$app") is not installed in $OH_NATIVE_PREFIX"
  [[ -n ${DISPLAY:-} ]] || oh_die "no X display (DISPLAY is not set); run this in your desktop session, where Xwayland shows Office's windows"
  local -a args=()
  for file in "$@"; do
    [[ $file != file://* ]] || file=$(oh_file_uri_path "$file")
    [[ -e $file ]] || oh_die "no such file: $file"
    abs=$(readlink -f -- "$file")
    oh_native_reachable "$abs" || abs=$(oh_native_copy_in "$abs")
    args+=("$(oh_native_win_path "$abs")")
  done
  oh_native_start "$exe" "${args[@]}"
}

# Whether Office can save FILE where it is: in one of its folders, or
# anywhere when the sandbox is off. Office's folders are fixed when its Wine
# server starts, so a file elsewhere (~/notes.docx, /tmp/x.docx) is never
# made reachable by binding its folder: that could be the whole home.
oh_native_reachable() {
  local d
  oh_native_bwrap_ok || return 0
  while IFS= read -r d; do
    [[ -n $d && -d $d ]] || continue
    d=$(readlink -f -- "$d")
    [[ $1 == "${d%/}"/* ]] && return 0
  done < <(oh_native_user_dirs)
  return 1
}

# A copy of FILE in Office's own /tmp; prints the path Office sees.
oh_native_copy_in() {
  local f=$1 d name=${1##*/}
  oh_warn "$name is outside the folders Office can reach (Documents, Downloads, Desktop, Pictures and OneDrive), so this opens a copy; save it into one of them to keep your changes"
  # Opened from a file manager, nobody reads stderr: say it on screen too.
  if [[ ! -t 2 ]] && ! oh_dry && oh_have notify-send; then
    notify-send -a omarchohard -u critical "Office opened a copy of $name" \
      "$name is outside Documents, Downloads, Desktop, Pictures and OneDrive. Save it into one of them to keep your changes." >/dev/null 2>&1 || true
  fi
  if oh_dry; then
    printf 'would run: cp -- %q %q\n' "$f" "$OH_NATIVE_TMP/opened/" >&2
    printf '/tmp/opened/%s\n' "$name"
    return 0
  fi
  mkdir -p -- "$OH_NATIVE_TMP/opened"
  d=$(mktemp -d "$OH_NATIVE_TMP/opened/XXXXXX")
  cp -- "$f" "$d/$name" || oh_die "could not copy $f for Office"
  printf '/tmp/opened/%s/%s\n' "${d##*/}" "$name"
}

# oh_native_start EXE [ARG...]: the app in the sandbox, with the same
# folders as its Wine server.
oh_native_start() {
  local exe=$1
  local -a env
  shift
  oh_native_drive_o
  # The Wine server stays up 10 minutes after the last app closes, so the
  # next start is the warm one (1 to 2.5 s, not 4 to 6 s). With one already
  # running, this one exits at once.
  if oh_native_outside_server; then
    flock -n "$OH_STATE_DIR/native-install.lock" true 2>/dev/null ||
      oh_die "native Office is being installed or updated; open it again when that finishes"
    oh_native_ws -k 2>/dev/null || true
  fi
  oh_native_ws_start -p600 >/dev/null 2>&1 || true
  mapfile -t env < <(oh_native_env)
  oh_native_box app
  oh_spawn "${OH_BOX[@]}" env "${env[@]}" "$OH_WINE" "$OH_NATIVE_OFFICE/$exe" "$@"
  oh_native_idle_start
}

# The OneDrive folder as drive O: in Windows, when there is one.
oh_native_drive_o() {
  local dir link=$OH_NATIVE_PREFIX/dosdevices/o:
  dir=$(oh_config_get onedrive_dir 2>/dev/null || true)
  if [[ -n $dir && -d $dir ]]; then
    [[ $(readlink -- "$link" 2>/dev/null) == "$dir" ]] || oh_run ln -sfn -- "$dir" "$link"
  elif [[ -L $link ]]; then
    oh_run rm -f -- "$link"
  fi
}

# A mailto: link in Outlook, when native Office is preferred, has Outlook,
# and mail links are on. Returns 1 otherwise, so the web app takes it.
oh_native_mailto() {
  [[ $(oh_config_get open_with) == native && $(oh_config_get mail) != 0 && -n ${DISPLAY:-} ]] || return 1
  oh_native_ready && oh_native_has outlook || return 1
  # Outlook's command-line switches: /c ipm.note makes a message, /m fills
  # in the address (and a ?subject=... after it).
  oh_native_start OUTLOOK.EXE /c ipm.note /m "${1#mailto:}"
}

# Office's Click-to-Run service keeps the prefix running after the last app
# closes, about 230 MB with explorer and services, so -p600 alone would keep
# it up for good. This watcher stops the prefix once no Office app has run
# for 10 minutes. One per user, as a user unit when there is systemd.
OH_NATIVE_IDLE=omarchohard-native-idle
oh_native_idle_start() {
  local bin
  oh_dry && return 0
  systemctl --user is-active --quiet "$OH_NATIVE_IDLE.service" 2>/dev/null && return 0
  bin=$(oh_bin_path)
  if oh_have systemd-run && systemd-run --user --quiet --collect --unit="$OH_NATIVE_IDLE" "${OH_UNIT_ENV[@]}" "$bin" native idle-watch 2>/dev/null; then
    return 0
  fi
  # Without systemd: one detached watcher, held to one by its lock.
  setsid -f "$bin" native idle-watch </dev/null >/dev/null 2>&1 || true
}

oh_native_idle_watch() {
  local idle=0 step=${OMARCHOHARD_NATIVE_IDLE_STEP:-30} limit=${OMARCHOHARD_NATIVE_IDLE:-600} lk
  mkdir -p "$OH_STATE_DIR"
  exec {lk}>"$OH_STATE_DIR/native-idle.lock"
  flock -n "$lk" || return 0
  while ((idle < limit)); do
    sleep "$step"
    if [[ -n $(oh_native_app_pids) ]] || oh_native_signin_running || oh_native_prewarm_on; then idle=0; else idle=$((idle + step)); fi
  done
  oh_native_stop_wine
}

# For open and the launchers: native Office when it is preferred and has
# the app. Returns 1 otherwise, so the caller opens another tier.
oh_native_launch() {
  [[ $(oh_config_get open_with) == native ]] && oh_native_ready && oh_native_has "${1:-}" || return 1
  oh_native_run "$@"
}

oh_native_engine() { oh_desktop_engine; }

# Where a sign-in keeps its pid, its link's session id until the bridge has
# read it, and its ready mark: the runtime folder (memory, this user only)
# when there is one.
oh_native_signin_dir() {
  local base=${XDG_RUNTIME_DIR:-}
  [[ -n $base && -d $base && -w $base ]] || base=$OH_STATE_DIR
  printf '%s\n' "$base/omarchohard-signin"
}

oh_native_signin_running() {
  local pid
  pid=$(cat -- "$(oh_native_signin_dir)/pid" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

oh_native_signin_stop() {
  local dir pid i
  dir=$(oh_native_signin_dir)
  oh_run systemctl --user stop "$OH_NATIVE_SIGNIN.service" >/dev/null 2>&1 || true
  if pid=$(cat -- "$dir/pid" 2>/dev/null) && [[ $pid =~ ^[0-9]+$ ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((i = 0; i < 100; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  oh_run rm -rf -- "$dir"
  [[ ! -e $OH_NATIVE_DIR/devtools-on ]] || oh_native_devtools off
}

# Office's sign-in window (WebView2) answers the DevTools protocol on PORT,
# on 127.0.0.1, while a sign-in runs; `off` closes it. A mark file says it is
# open, so a sign-in that died is closed by the next start of Office.
oh_native_devtools() {
  local reg k key
  oh_dry && {
    oh_say "would set Office's sign-in window DevTools to: $1"
    return 0
  }
  reg=$(mktemp "$OH_NATIVE_DIR/devtools-XXXXXX.reg")
  {
    printf 'Windows Registry Editor Version 5.00\r\n\r\n'
    for k in 'HKEY_CURRENT_USER\Software' 'HKEY_LOCAL_MACHINE\Software' 'HKEY_LOCAL_MACHINE\Software\Wow6432Node'; do
      key="$k\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments"
      if [[ $1 == off ]]; then
        printf '[-%s]\r\n\r\n' "$key"
      else
        printf '[%s]\r\n"*"="--remote-debugging-port=%s"\r\n\r\n' "$key" "$1"
      fi
    done
  } >"$reg"
  [[ $1 == off ]] || : >"$OH_NATIVE_DIR/devtools-on"
  oh_native_wine regedit /S "Z:${reg//\//\\}" >/dev/null 2>&1 || true
  rm -f -- "$reg"
  [[ $1 != off ]] || rm -f -- "$OH_NATIVE_DIR/devtools-on"
}

# What a sign-in needs on this machine; dies naming the fix.
oh_native_signin_needs() {
  local remote=$1
  oh_native_ready || oh_die "native Office is not set up yet (omarchohard native install)"
  oh_native_python >/dev/null || oh_die "the sign-in needs python3 (omarchy pkg add python)"
  oh_have Xvfb || oh_die "the sign-in runs Office on a hidden screen and needs Xvfb: omarchy pkg add xorg-server-xvfb"
  oh_browser_bin >/dev/null || oh_die "the sign-in needs a Chromium-based browser: omarchy pkg add chromium"
  ((remote)) || [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]] ||
    oh_die "there is no screen here for the sign-in window; sign in from another device: omarchohard native signin --remote"
  ! oh_native_signin_running || oh_die "a sign-in is already running; stop it with: omarchohard native signin --stop"
  [[ -z $(oh_native_app_pids) ]] || oh_die "close Word, Excel, PowerPoint, Outlook and OneNote first; the sign-in starts Office on its own"
}

# `native signin-run MINUTES [--remote IP:PORT] [--email E] [--device D]`,
# the sign-in's own process: Word on a hidden screen with its sign-in window
# open to DevTools, the bridge, then all of it stopped and closed again.
oh_native_signin_run() {
  local minutes=${1:?} remote='' email='' device='' dir bin py port rc=0
  shift
  while (($#)); do
    case $1 in
    --remote) remote=${2:?} && shift ;;
    --email) email=${2:?} && shift ;;
    --device) device=${2:?} && shift ;;
    *) oh_die "usage: omarchohard native signin-run MINUTES [--remote IP:PORT] [--email E] [--device D]" ;;
    esac
    shift
  done
  dir=$(oh_native_signin_dir)
  mkdir -p -- "$dir"
  printf '%s\n' "$$" >"$dir/pid"
  bin=$(oh_browser_bin)
  py=$(oh_native_python) || oh_die "the sign-in needs python3"
  oh_native_stop_wine
  oh_native_hidden_start || oh_die "the hidden screen did not start (Xvfb)"
  trap 'oh_native_signin_end' EXIT
  trap 'exit 143' TERM INT HUP
  port=$("$py" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  oh_native_devtools "$port"
  local -a env args
  mapfile -t env < <(oh_native_env)
  # In the apps' sandbox when it is on, so the Wine server stays one per prefix.
  oh_native_box app
  "${OH_BOX[@]}" env DISPLAY="$OH_HIDDEN_DISPLAY" "${env[@]}" "$OH_WINE" "$OH_NATIVE_OFFICE/WINWORD.EXE" >/dev/null 2>&1 &
  args=(--office-port "$port" --display "$OH_HIDDEN_DISPLAY" --browser "$bin" --minutes "$minutes" --ready-file "$dir/ready")
  [[ -z $email ]] || args+=(--email "$email")
  [[ -z $device ]] || args+=(--device "$device")
  [[ -z $remote ]] || args+=(--remote "$remote" --session-file "$dir/session")
  "$py" "$OH_SHARE/native-signin/bridge.py" "${args[@]}" || rc=$?
  case $rc in
  0) oh_ok "signed in to Office" ;;
  3) oh_say "the sign-in window was closed before the sign-in finished" ;;
  *) oh_warn "the sign-in did not finish (omarchohard native signin to try again)" ;;
  esac
  exit "$rc"
}

oh_native_signin_end() {
  oh_native_ws -k 2>/dev/null || true
  oh_native_box tmp
  oh_dry || timeout 20 "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -w 2>/dev/null || true
  oh_native_devtools off
  oh_native_ws -k 2>/dev/null || true
  oh_native_hidden_stop
  rm -rf -- "$(oh_native_signin_dir)"
}

# The name the link uses for this device: its tailnet DNS name (MagicDNS),
# which reaches the same address, or the address itself (with --lan, or
# when Tailscale gives no name). Sets OH_LINK_HOST and OH_LINK_DEVICE.
oh_native_link_host() {
  local lan=$1 ip=$2 dns='' name=''
  if ((lan == 0)) && oh_have jq; then
    dns=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null) || dns=''
    name=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // empty' 2>/dev/null) || name=''
    dns=${dns%.}
  fi
  [[ $dns =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || dns=''
  OH_LINK_HOST=${dns:-$ip}
  name=${name:-${dns%%.*}}
  name=${name:-$(uname -n)}
  OH_LINK_DEVICE=$(LC_ALL=C tr -cd 'A-Za-z0-9.-' <<<"$name")
}

# The sign-in: Microsoft's own page in a real browser window on this screen,
# so passkeys, security keys and password managers work. Office waits on a
# hidden screen and takes the result. With --remote, the window is a page on
# the tailnet address only, for a phone or another computer, behind a link
# with a one-time session id. Never on a plain LAN: the page is plain HTTP,
# and Tailscale's WireGuard tunnel is what encrypts it.
oh_native_signin() {
  local remote=0 minutes=30 port=$OH_NATIVE_PORT email='' wait=0 ip='' dir bin sid url i
  while (($#)); do
    case $1 in
    --remote) remote=1 ;;
    --lan) oh_die "remote sign-in works only over Tailscale, which encrypts it; on a plain network the Microsoft password would cross it unencrypted. Sign in on this device instead: omarchohard native signin" ;;
    --minutes) minutes=${2:?--minutes needs a number} && shift ;;
    --port) port=${2:?--port needs a number} && shift ;;
    --email) email=${2:?--email needs an address} && shift ;;
    --wait) wait=1 ;;
    --stop)
      oh_native_signin_stop
      oh_ok "sign-in stopped"
      return 0
      ;;
    *) oh_die "usage: omarchohard native signin [--remote [--minutes N] [--port P]] [--email E] [--wait] | --stop" ;;
    esac
    shift
  done
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes >= 1 && minutes <= 240)) || oh_die "--minutes takes 1 to 240"
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || oh_die "--port takes 1024 to 65535"
  ((remote)) && ip=$(oh_native_bind_ip 0)
  oh_native_signin_needs "$remote"
  dir=$(oh_native_signin_dir)
  bin=$(oh_bin_path)
  local -a run=("$bin" native signin-run "$minutes")
  [[ -z $email ]] || run+=(--email "$email")
  if ((remote)); then
    oh_native_link_host 0 "$ip"
    run+=(--remote "$ip:$port" --device "$OH_LINK_DEVICE")
  fi
  if oh_dry; then
    oh_run systemd-run --user --quiet --collect --unit="$OH_NATIVE_SIGNIN" "${run[@]}"
    ((remote)) && printf 'Sign in here: http://%s:%s/#s=<session>\n' "$OH_LINK_HOST" "$port"
    return 0
  fi
  rm -rf -- "$dir"
  (
    umask 077
    mkdir -p -- "$dir"
    # 192 bits, for one session of at most four hours on the tailnet.
    od -An -tx1 -N24 /dev/urandom | tr -d ' \n' >"$dir/session"
  )
  sid=$(cat -- "$dir/session")
  ((remote)) || rm -f -- "$dir/session"
  local -a unit_env=("${OH_UNIT_ENV[@]}") v
  for v in WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP LANG; do
    [[ -z ${!v:-} ]] || unit_env+=("--setenv=$v=${!v}")
  done
  if ! { oh_have systemd-run && systemd-run --user --quiet --collect --unit="$OH_NATIVE_SIGNIN" "${unit_env[@]}" "${run[@]}" 2>/dev/null; }; then
    setsid -f "${run[@]}" </dev/null >/dev/null 2>&1 || {
      oh_native_signin_stop
      oh_die "could not start the sign-in"
    }
  fi
  # The page answers about a second after start.
  for ((i = 0; i < 300; i++)); do
    [[ -e $dir/ready ]] && break
    oh_native_signin_running || ((i < 20)) || break
    sleep 0.1
  done
  if [[ ! -e $dir/ready ]]; then
    oh_native_signin_stop
    oh_die "the sign-in did not start (journalctl --user -u $OH_NATIVE_SIGNIN)"
  fi
  if ((! remote)); then
    oh_say "The sign-in window is open on this screen${email:+ for $email}."
    if ((wait)); then
      while oh_native_signin_running; do sleep 0.5; done
    fi
    return 0
  fi
  url="http://$OH_LINK_HOST:$port/#s=$sid"
  if oh_have notify-send; then
    notify-send -a omarchohard -i omarchohard "Sign in to Office" "Open on another device on your tailnet: $url" 2>/dev/null || true
  fi
  oh_say "Office is starting on a hidden screen; the sign-in page is shared only on $ip${email:+, for $email}."
  oh_say "It stops once you are signed in or after $minutes minute$( ((minutes == 1)) || echo s) (now: omarchohard native signin --stop)."
  printf 'Sign in here: %s\n' "$url"
}

oh_native_status() {
  local json=0 wine_ver='' office_ver='' product='' seed sha='' seed_bytes=0 remote=false serving=false app wine_bytes native_bytes
  local seed_ver='' seed_old=false latest checked result result_at timer=false
  local -a found=()
  case ${1:-} in --json) json=1 ;; '') ;; *) oh_die "usage: omarchohard native status [--json]" ;; esac
  oh_native_wine_ok && wine_ver=$("$OH_WINE" --version 2>/dev/null || echo "wine-altars $OH_WINE_TAG")
  office_ver=$(oh_native_office_version 2>/dev/null || true)
  product=$(oh_native_office_product 2>/dev/null || true)
  for app in $OH_NATIVE_APPS; do oh_native_has "$app" && found+=("$app"); done
  seed=$(oh_native_seed_file || true)
  if [[ -n $seed ]]; then
    seed_bytes=$(stat -c %s -- "$seed")
    sha=$(head -c 64 -- "$seed.sha256" 2>/dev/null || true)
  fi
  oh_native_signin_running && remote=true
  oh_native_serving && serving=true
  # The seed's version is in its name; an update leaves the seed behind.
  [[ ${seed##*/} =~ -([0-9]+(\.[0-9]+){3})\.tar\.zst$ ]] && seed_ver=${BASH_REMATCH[1]}
  ! oh_native_newer "$office_ver" "$seed_ver" || [[ -z $seed_ver ]] || seed_old=true
  latest=$(oh_native_update_get latest || true)
  checked=$(oh_native_update_get checked || true)
  result=$(oh_native_update_get result || true)
  result_at=$(oh_native_update_get result_at || true)
  oh_native_update_timer_on && timer=true
  wine_bytes=$(oh_native_du "$OH_WINE_DIR")
  native_bytes=$(oh_native_du "$OH_NATIVE_DIR")
  if ((json)); then
    local apps_json='' a
    for a in "${found[@]}"; do apps_json+=${apps_json:+,}$(oh_json_str "$a"); done
    printf '{"wine":{"present":%s,"version":%s,"path":%s},' "$([[ -n $wine_ver ]] && echo true || echo false)" "$(oh_json_str "$wine_ver")" "$(oh_json_str "$OH_WINE_DIR")"
    printf '"prefix":{"present":%s,"path":%s},' "$(oh_json_bool test -f "$OH_NATIVE_PREFIX/system.reg")" "$(oh_json_str "$OH_NATIVE_PREFIX")"
    printf '"office":{"product":%s,"plans":%s,"version":%s,"apps":[%s]},' "$(oh_json_str "$product")" \
      "$(oh_json_str "$([[ -z $product ]] || oh_native_plan_words "$product")")" "$(oh_json_str "$office_ver")" "$apps_json"
    printf '"seed":{"path":%s,"bytes":%s,"sha256":%s,"version":%s,"older_than_office":%s,"serving":%s},' "$(oh_json_str "$seed")" "$seed_bytes" "$(oh_json_str "$sha")" "$(oh_json_str "$seed_ver")" "$seed_old" "$serving"
    printf '"update":{"installed":%s,"latest":%s,"checked":%s,"available":%s,"result":%s,"result_at":%s,"timer":%s},' "$(oh_json_str "$office_ver")" "$(oh_json_str "$latest")" "$(oh_json_str "$checked")" \
      "$(oh_native_newer "$latest" "$office_ver" && echo true || echo false)" "$(oh_json_str "$result")" "$(oh_json_str "$result_at")" "$timer"
    printf '"disk":{"wine_bytes":%s,"native_bytes":%s},' "${wine_bytes:-0}" "${native_bytes:-0}"
    printf '"remote_signin":%s,"open_with":%s}\n' "$remote" "$(oh_json_str "$(oh_config_get open_with)")"
    return 0
  fi
  printf 'wine: %s\n' "${wine_ver:-not installed (omarchohard native install)}"
  if [[ -f $OH_NATIVE_PREFIX/system.reg ]]; then printf 'prefix: %s\n' "$OH_NATIVE_PREFIX"; else printf 'prefix: none\n'; fi
  printf 'office: %s\n' "${office_ver:-not installed}${product:+ $product, for $(oh_native_plan_words "$product") plans}${found[*]:+ (${found[*]})}"
  if [[ -n $seed ]]; then printf 'seed: %s (%s)%s%s\n' "$seed" "$(oh_native_size "$seed_bytes")" "$([[ $seed_old == true ]] && echo ", Office $seed_ver, older than the installed Office (devices installed from it update themselves)")" "$([[ $serving == true ]] && echo ', being served')"; else printf 'seed: none\n'; fi
  if [[ -n $office_ver ]]; then
    printf 'updates: latest known %s%s; last result: %s; weekly check %s\n' "${latest:-not checked yet}" "${checked:+ (checked $checked)}" "${result:+$result ($result_at)}${result:-none yet}" "$([[ $timer == true ]] && echo on || echo 'off (omarchohard native install turns it on)')"
    ! oh_native_newer "$latest" "$office_ver" || printf 'update available: Office %s (omarchohard native update)\n' "$latest"
  fi
  printf 'disk: wine %s, prefix and seed %s\n' "$(oh_native_size "${wine_bytes:-0}")" "$(oh_native_size "${native_bytes:-0}")"
  printf 'remote sign-in: %s\n' "$([[ $remote == true ]] && echo running || echo 'not running')"
  printf 'open_with: %s\n' "$(oh_config_get open_with)"
  # omarchohard never reads the sign-in state; this is what a refusal means.
  printf 'sign-in: shown in Word (File, Account). Errors AADSTS53000, 53001 or 53003 mean your organization requires a managed Windows device: use the web apps or ask IT.\n'
}

# Prewarm: a user unit that keeps the Wine server and Windows' own services
# running from login, so Office's first start of the day is a warm one.
OH_NATIVE_PREWARM=omarchohard-native-prewarm.service
oh_native_prewarm_on() { systemctl --user is-active --quiet "$OH_NATIVE_PREWARM" 2>/dev/null; }

oh_native_prewarm() {
  local bin
  case ${1:-status} in
  on)
    oh_native_ready || oh_die "native Office is not set up yet (omarchohard native install)"
    bin=$(oh_bin_path)
    oh_require_line "$bin" "the omarchohard path"
    mkdir -p "$OH_UNIT_DIR"
    cat >"$OH_UNIT_DIR/$OH_NATIVE_PREWARM" <<EOF
[Unit]
Description=omarchohard: keep native Office's Wine server warm
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Environment=$(oh_unit_arg "XDG_DATA_HOME=${OH_DATA_DIR%/*}") $(oh_unit_arg "XDG_STATE_HOME=${OH_STATE_DIR%/*}") $(oh_unit_arg "XDG_CONFIG_HOME=${OH_CONFIG_DIR%/*}")
ExecStart=$(oh_unit_arg "$bin") native prewarm-run
# Stopping it ends only the waiter: the Wine server and the apps using it
# keep running, and the idle watcher stops them once Office is closed.
KillMode=process
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
    oh_run systemctl --user daemon-reload
    oh_run systemctl --user enable --now "$OH_NATIVE_PREWARM"
    oh_ok "native prewarm on (the Wine server and its services stay resident)"
    ;;
  off)
    if [[ -f $OH_UNIT_DIR/$OH_NATIVE_PREWARM ]]; then
      oh_run systemctl --user disable --now "$OH_NATIVE_PREWARM" 2>/dev/null || true
      rm -f "$OH_UNIT_DIR/$OH_NATIVE_PREWARM"
      oh_run systemctl --user daemon-reload 2>/dev/null || true
    fi
    # What it kept running now stops once Office has been idle 10 minutes.
    ! oh_native_ready || oh_native_idle_start
    oh_ok "native prewarm off"
    ;;
  status) if oh_native_prewarm_on; then echo "native prewarm: on"; else echo "native prewarm: off"; fi ;;
  *) oh_die "usage: omarchohard native prewarm on|off|status" ;;
  esac
}

# The unit's process: a persistent Wine server, Windows' services started
# in the sandbox, then a wait on the server.
oh_native_prewarm_run() {
  local -a env
  oh_native_ready || oh_die "native Office is not set up"
  mapfile -t env < <(oh_native_env)
  oh_native_ws_start -p
  oh_native_box app
  "${OH_BOX[@]}" env "${env[@]}" "$OH_WINE" cmd.exe /c exit >/dev/null 2>&1 || true
  oh_native_box tmp
  exec "${OH_BOX[@]}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -w
}

# Updates. The ODT configuration turns Office's own updater off (it does
# not run under Wine), so omarchohard updates Office: `native update`
# compares the installed version with the Current channel's, downloads the
# newer one with the install's prefetch, and runs the Office Deployment Tool
# again with the new Version against the same prefix, which updates Office
# in place. The seed stays as it was: the live prefix is signed in after its
# first use and is never packed, so status says the seed is older than
# Office, and a device installed from that seed updates itself afterward.
OH_NATIVE_UPDATE=omarchohard-native-update
OH_NATIVE_UPDATE_STATE=$OH_STATE_DIR/native/update

# Whether version A is newer than version B.
oh_native_newer() {
  [[ -n $1 && $1 != "$2" && $(printf '%s\n%s\n' "$1" "${2:-0}" | sort -V | tail -n1) == "$1" ]]
}

# KEY from the update record: checked, latest, result, result_at.
oh_native_update_get() {
  [[ -f $OH_NATIVE_UPDATE_STATE ]] || return 1
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit } END { exit !found }' "$OH_NATIVE_UPDATE_STATE"
}

# Set KEY VALUE pairs in the update record, written whole.
oh_native_update_set() {
  local f=$OH_NATIVE_UPDATE_STATE k v
  local -A kv=()
  oh_dry && return 0
  mkdir -p -- "${f%/*}"
  if [[ -f $f ]]; then
    while IFS='=' read -r k v; do [[ -z $k ]] || kv[$k]=$v; done <"$f"
  fi
  while (($# >= 2)); do
    kv[$1]=${2//$'\n'/ }
    shift 2
  done
  for k in checked latest result result_at; do
    [[ -z ${kv[$k]:-} ]] || printf '%s=%s\n' "$k" "${kv[$k]}"
  done >"$f.tmp"
  mv -f -- "$f.tmp" "$f"
}

oh_native_update_result() { oh_native_update_set result "$1" result_at "$(date -u +%FT%TZ)"; }

# The record of an update that stopped partway (oh_die inside the install
# steps), from the EXIT trap.
oh_native_update_failed() {
  [[ -n ${OH_NATIVE_UPDATING:-} ]] || return 0
  oh_native_update_result "failed: $OH_NATIVE_UPDATING did not finish (log: $OH_NATIVE_PREFIX/drive_c/c2rlog/)"
}

# The update's EXIT trap: the failure, if any, and prewarm back on.
oh_native_update_end() {
  oh_native_update_failed
  [[ -z ${OH_NATIVE_PREWARM_AGAIN:-} ]] || systemctl --user start "$OH_NATIVE_PREWARM" 2>/dev/null || true
}

# `native update [--check]`; the timer runs `native update --auto`, which
# asks Microsoft at most once in 6 days unless an update is waiting, and
# leaves Office alone while an app or the remote sign-in is open.
oh_native_update() {
  local mode=update installed latest product shared=0 cab checked last tool
  case ${1:-} in
  '') ;;
  --check) mode=check ;;
  --auto) mode=auto ;;
  *) oh_die "usage: omarchohard native update [--check]" ;;
  esac
  oh_native_ready || oh_die "native Office is not set up yet (omarchohard native install)"
  installed=$(oh_native_office_version) || oh_die "cannot read the installed Office version from $OH_NATIVE_PREFIX/system.reg"
  if [[ $mode == auto ]] && checked=$(oh_native_update_get checked) && ! oh_native_newer "$(oh_native_update_get latest || true)" "$installed"; then
    last=$(date -d "$checked" +%s 2>/dev/null || echo 0)
    if (($(date +%s) - last < 6 * 86400)); then
      oh_say "native update: Office $installed was current at $checked; next check 6 days after that"
      return 0
    fi
  fi
  for tool in curl bsdtar; do
    oh_have "$tool" || oh_die "native update needs $tool"
  done
  if oh_dry; then
    oh_say "would read the Current channel's version from $OH_OFFICE_CDN/Office/Data/v64.cab, and if it is newer than $installed, download it and run setup.exe /configure in $OH_NATIVE_PREFIX"
    return 0
  fi
  mkdir -p -- "$OH_NATIVE_DIR"
  cab=$OH_NATIVE_DIR/.v64.cab
  if ! latest=$(oh_office_cdn_version "$cab"); then
    rm -f -- "$cab"
    oh_native_update_result "failed: could not read the current version from Microsoft"
    oh_die "could not read the current Office version from $OH_OFFICE_CDN/Office/Data/v64.cab"
  fi
  rm -f -- "$cab"
  oh_native_update_set checked "$(date -u +%FT%TZ)" latest "$latest"
  if ! oh_native_newer "$latest" "$installed"; then
    [[ $mode == check ]] || oh_native_update_result "up to date ($installed)"
    oh_ok "Office $installed is current (Current channel: $latest)"
    return 0
  fi
  if [[ $mode == check ]]; then
    oh_say "Office $latest is out; this device has $installed. Update it: omarchohard native update"
    return 0
  fi
  if [[ -n $(oh_native_app_pids) ]] || oh_native_signin_running; then
    [[ $mode == auto ]] || oh_die "close Word, Excel, PowerPoint, Outlook and OneNote first (and any remote sign-in); Office updates while none is open"
    oh_native_update_result "skipped: Office was open ($latest is waiting)"
    oh_say "native update: Office is open; $latest waits for the next try"
    return 0
  fi
  oh_office_prefetch_usable || oh_die "an update needs curl, bsdtar and flock, and $OH_NATIVE_DIR under your home folder"
  umask 077
  oh_native_lock native-install
  product=$(oh_native_office_product) || oh_die "cannot read the installed Office product from $OH_NATIVE_PREFIX/system.reg"
  [[ $(oh_native_c2r SharedComputerLicensing 2>/dev/null) != 1 ]] || shared=1
  trap oh_native_update_end EXIT
  # A Wine server left from Office's last use (it stays 10 minutes, or for
  # good with prewarm) would run setup.exe in its sandbox and /tmp, so it
  # stops first. Prewarm stops too, or it would start one again.
  if [[ -n $(oh_native_server_pids) ]]; then
    if oh_native_prewarm_on; then
      OH_NATIVE_PREWARM_AGAIN=1
      oh_run systemctl --user stop "$OH_NATIVE_PREWARM" 2>/dev/null || true
    fi
    if ! oh_native_server_stop; then
      [[ $mode == auto ]] || oh_die "Office's Wine server (pid $(oh_native_server_pids | paste -sd ' ')) did not stop; close Office and try again"
      oh_native_update_result "skipped: Office's Wine server was running ($latest is waiting)"
      oh_say "native update: Office's Wine server did not stop; $latest waits for the next try"
      return 0
    fi
  fi
  OH_NATIVE_UPDATING="Office $installed to $latest"
  oh_native_update_result "updating Office $installed to $latest"
  oh_native_src_start
  oh_native_step_office "$product" "$shared"
  installed=$(oh_native_office_version || true)
  OH_NATIVE_UPDATING=''
  if [[ $installed != "$latest" ]]; then
    oh_native_update_result "failed: Office still reports ${installed:-no version} after setup.exe (log: $OH_NATIVE_PREFIX/drive_c/c2rlog/)"
    oh_die "Office did not update to $latest; it reports ${installed:-no version} (log: $OH_NATIVE_PREFIX/drive_c/c2rlog/)"
  fi
  oh_native_update_result "updated to $latest"
  oh_ok "Office updated to $latest; the seed stays at its version (a device installed from it updates itself)"
}

# The weekly check, as a user timer: a randomized delay so many devices do
# not ask at once, Persistent so a week missed while off runs at the next
# start, a try an hour after each start (a device installed from an older
# seed updates the same day), and every 6 hours a quiet local retry that
# goes to Microsoft only while an update is waiting. Only on AC power.
oh_native_update_timer() {
  local bin
  case ${1:-} in
  on)
    oh_dry && {
      oh_say "would turn on $OH_NATIVE_UPDATE.timer (weekly Office update check)"
      return 0
    }
    oh_have systemctl || return 0
    bin=$(oh_bin_path)
    oh_require_line "$bin" "the omarchohard path"
    mkdir -p "$OH_UNIT_DIR"
    cat >"$OH_UNIT_DIR/$OH_NATIVE_UPDATE.service" <<EOF
[Unit]
Description=omarchohard: update native Office
ConditionACPower=true

[Service]
Type=oneshot
Environment=$(oh_unit_arg "XDG_DATA_HOME=${OH_DATA_DIR%/*}") $(oh_unit_arg "XDG_STATE_HOME=${OH_STATE_DIR%/*}") $(oh_unit_arg "XDG_CONFIG_HOME=${OH_CONFIG_DIR%/*}")
ExecStart=$(oh_unit_arg "$bin") native update --auto
Nice=10
IOSchedulingClass=idle
EOF
    cat >"$OH_UNIT_DIR/$OH_NATIVE_UPDATE.timer" <<EOF
[Unit]
Description=omarchohard: check for Office updates every week

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
OnActiveSec=1h
OnUnitInactiveSec=6h

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now "$OH_NATIVE_UPDATE.timer" >/dev/null 2>&1 ||
      oh_warn "could not turn on $OH_NATIVE_UPDATE.timer; update Office with: omarchohard native update"
    ;;
  off)
    [[ -f $OH_UNIT_DIR/$OH_NATIVE_UPDATE.timer || -f $OH_UNIT_DIR/$OH_NATIVE_UPDATE.service ]] || return 0
    oh_run systemctl --user disable --now "$OH_NATIVE_UPDATE.timer" >/dev/null 2>&1 || true
    oh_run rm -f -- "$OH_UNIT_DIR/$OH_NATIVE_UPDATE.timer" "$OH_UNIT_DIR/$OH_NATIVE_UPDATE.service"
    oh_run systemctl --user daemon-reload >/dev/null 2>&1 || true
    ;;
  esac
}

oh_native_update_timer_on() { [[ -f $OH_UNIT_DIR/$OH_NATIVE_UPDATE.timer ]] && systemctl --user is-enabled --quiet "$OH_NATIVE_UPDATE.timer" 2>/dev/null; }

oh_native_prefer() {
  case ${1:-} in
  on)
    oh_native_ready || oh_die "native Office is not set up yet (omarchohard native install)"
    oh_config_set open_with native
    oh_ok "local Office files now open in native Office"
    ;;
  off)
    oh_config_set open_with web
    oh_ok "local Office files now open in the web apps"
    ;;
  *) oh_die "usage: omarchohard native prefer on|off" ;;
  esac
}

oh_native_uninstall() {
  local yes=0 engine img
  [[ ${1:-} == --yes || ${1:-} == -y ]] && yes=1
  if [[ ! -e $OH_NATIVE_DIR && ! -e $OH_WINE_DIR ]]; then
    oh_ok "native Office is not installed"
    return 0
  fi
  if ((! yes)); then
    oh_ui_interactive || oh_die "native uninstall deletes Office, its sign-in and the seed; run it in a terminal or add --yes"
    oh_ui_open
    oh_ui_confirm "Delete native Office ($OH_NATIVE_PREFIX, with its sign-in), the seed and Wine ($OH_WINE_DIR)?" no || oh_die "nothing was removed"
  fi
  oh_native_signin_stop
  oh_native_serve_stop
  oh_native_prewarm off >/dev/null 2>&1 || true
  oh_native_update_timer off
  oh_native_stop_wine
  oh_run rm -rf -- "$OH_NATIVE_DIR" "$OH_WINE_DIR" "${OH_NATIVE_TMP%/*}"
  if engine=$(oh_native_engine 2>/dev/null); then
    for img in $("$engine" images --format '{{.Repository}}:{{.Tag}}' "$OH_NATIVE_IMAGE" 2>/dev/null); do
      oh_run "$engine" rmi "$img" >/dev/null 2>&1 || true
    done
  fi
  oh_dry && return 0
  [[ $(oh_config_get open_with) != native ]] || oh_config_set open_with web
  oh_ok "native Office, its seed and Wine are removed; Office files open in the web apps"
}

oh_native() {
  oh_config_load
  local action=${1:-status}
  (($#)) && shift
  case $action in
  check) oh_native_check ;;
  install) oh_native_install "$@" ;;
  run) oh_native_run "$@" ;;
  signin) oh_native_signin "$@" ;;
  signin-run) oh_native_signin_run "$@" ;;
  idle-watch) oh_native_idle_watch ;;
  seed) oh_native_seed "$@" ;;
  status) oh_native_status "$@" ;;
  prefer) oh_native_prefer "$@" ;;
  prewarm) oh_native_prewarm "$@" ;;
  prewarm-run) oh_native_prewarm_run ;;
  update) oh_native_update "$@" ;;
  uninstall) oh_native_uninstall "$@" ;;
  *) oh_die "usage: omarchohard native check|install|run|signin|seed|status|update|prefer|prewarm|uninstall" ;;
  esac
}
