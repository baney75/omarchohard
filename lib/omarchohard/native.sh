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

oh_native_wine() {
  local -a env
  mapfile -t env < <(oh_native_env "${OH_NATIVE_OVERRIDES:-}")
  oh_run env "${env[@]}" "$OH_WINE" "$@"
}

oh_native_ws() { oh_run env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" "$@"; }

# Wait up to SECONDS for every process of the prefix to end, then stop the
# rest. Office leaves its Click-to-Run service running, so the wait alone may
# never end. wineserver saves the registry as it exits.
oh_native_settle() {
  oh_dry && return 0
  timeout "${1:-60}" env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -w 2>/dev/null && return 0
  env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -k 2>/dev/null || true
  env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -w 2>/dev/null || true
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
    oh_have tailscale || oh_die "Tailscale is not installed; on a home network use --lan, or sign in on this screen: omarchohard native signin"
    ip=$(tailscale ip -4 2>/dev/null | head -n1) || ip=''
    oh_ipv4_tailnet "$ip" || oh_die "Tailscale is not up (tailscale ip -4 gave '${ip:-nothing}'); start it (sudo tailscale up), or on a home network use --lan"
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
  rmdir -- "$stage" 2>/dev/null || true
  v=$(oh_native_office_version) || v=unknown
  if ((keep)); then
    [[ -z $old ]] || rm -f -- "$old" "$old.sha256"
    name=$OH_NATIVE_DIR/seed-${product%%,*}-$v.tar.zst
    mv -f -- "$part" "$name"
    printf '%s\n' "$sum" >"$name.sha256"
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
  mapfile -t env < <(oh_native_env)
  env DISPLAY="$OH_HIDDEN_DISPLAY" "${env[@]}" "$OH_WINE" "$OH_NATIVE_OFFICE/WINWORD.EXE" >/dev/null 2>&1 &
  sleep "${OMARCHOHARD_NATIVE_ABSORB:-30}"
  oh_native_ws -k 2>/dev/null || true
  oh_native_ws -w 2>/dev/null || true
  wait 2>/dev/null || true
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
  for tool in tar zstd curl sha256sum flock; do
    oh_have "$tool" || oh_die "native Office needs $tool"
  done
  oh_native_lock native-install
  if oh_native_has word; then
    local have
    have=$(oh_native_office_product || true)
    [[ -z $product || ,$have, == *",$product,"* ]] ||
      oh_die "Office here is $have (Microsoft 365 $(oh_native_plan_words "$have")), not the $product --plan $OH_NATIVE_PLAN needs; remove it first: omarchohard native uninstall"
    oh_native_wine_install
    oh_native_fonts_ok || oh_native_step_fonts
    oh_ok "native Office is already installed (omarchohard native status)"
    oh_dry || oh_config_set open_with native
    return 0
  fi
  # A fresh install without --plan: personal, said out loud. (Checked only
  # now, so a rerun on an installed device never needs --plan.)
  if [[ -z $from && -z $OH_NATIVE_PLAN ]]; then
    OH_NATIVE_PLAN=personal
    product=${OH_NATIVE_PLANS[$OH_NATIVE_PLAN]}
    oh_say "No --plan given: installing Microsoft 365 Personal and Family ($OH_NATIVE_PLAN). For school or work, add --plan school, business or enterprise."
  fi
  [[ -z $from || ! -e $OH_NATIVE_PREFIX ]] ||
    oh_die "$OH_NATIVE_PREFIX is there but has no Word in it (an install that stopped). Remove it first: omarchohard native uninstall"
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
  oh_dry && return 0
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
  local minutes=60 port=$OH_NATIVE_SERVE_PORT lan=0 f sha ip token envf py engine tag url i name
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
    # No Python on this machine: the sign-in image has it.
    engine=$(oh_native_engine) || oh_die "seed serve needs python3, or Docker or Podman"
    tag=$(oh_native_image "$engine")
    OH_SEED_TOKEN=$token "$engine" run -d --rm --name "$OH_NATIVE_SERVE" -u "$(id -u):$(id -g)" -e OH_SEED_TOKEN \
      -p "$ip:$port:8080" -v "$f:/seed/$name:ro" --entrypoint python3 "$tag" \
      /usr/local/share/omarchohard/seed-serve.py 0.0.0.0 8080 "/seed/$name" "$((minutes * 60))" >/dev/null ||
      oh_die "could not start the seed server (is port $port on $ip free? try --port)"
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
  oh_native_has "$app" || oh_die "$(oh_app_name "$app") is not installed in $OH_NATIVE_PREFIX"
  [[ -n ${DISPLAY:-} ]] || oh_die "no X display (DISPLAY is not set); run this in your desktop session, where Xwayland shows Office's windows"
  local -a args=() env
  for file in "$@"; do
    [[ $file != file://* ]] || file=$(oh_file_uri_path "$file")
    [[ -e $file ]] || oh_die "no such file: $file"
    abs=$(readlink -f -- "$file")
    args+=("$(oh_native_win_path "$abs")")
  done
  # The Wine server stays up 10 minutes after the last app closes, so the
  # next start is the warm one (1 to 2.5 s, not 4 to 6 s). With one already
  # running, this one exits at once.
  oh_run env "WINEPREFIX=$OH_NATIVE_PREFIX" "$OH_WINESERVER" -p600 >/dev/null 2>&1 || true
  mapfile -t env < <(oh_native_env)
  oh_spawn env "${env[@]}" "$OH_WINE" "$OH_NATIVE_OFFICE/$exe" "${args[@]}"
  oh_native_idle_start
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
    if [[ -n $(oh_native_app_pids) ]] || oh_native_signin_running; then idle=0; else idle=$((idle + step)); fi
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

oh_native_signin_running() {
  local engine
  engine=$(oh_native_engine 2>/dev/null) || return 1
  [[ $("$engine" inspect -f '{{.State.Running}}' "$OH_NATIVE_SIGNIN" 2>/dev/null) == true ]]
}

# Where the remote session keeps its X socket and the one-time password
# file: the runtime folder (memory, this user only) when there is one.
oh_native_signin_dir() {
  local base=${XDG_RUNTIME_DIR:-}
  [[ -n $base && -d $base && -w $base ]] || base=$OH_STATE_DIR
  printf '%s\n' "$base/omarchohard-signin"
}

# The image, tagged by its own files, so a change rebuilds it.
oh_native_image() {
  local engine=$1 dir=$OH_SHARE/native-remote tag
  tag=$OH_NATIVE_IMAGE:$(cat -- "$dir/Dockerfile" "$dir/entry.sh" "$dir/index.html" "$dir/seed-serve.py" | sha256sum | cut -c1-12)
  if ! "$engine" image inspect "$tag" >/dev/null 2>&1; then
    oh_say "Building the sign-in page's image (about a minute, once)..."
    oh_run "$engine" build -q -t "$tag" "$dir" >/dev/null || oh_die "could not build $tag from $dir"
  fi
  printf '%s\n' "$tag"
}

oh_native_signin_stop() {
  local engine dir
  dir=$(oh_native_signin_dir)
  if engine=$(oh_native_engine 2>/dev/null); then
    oh_run "$engine" rm -f "$OH_NATIVE_SIGNIN" >/dev/null 2>&1 || true
  fi
  oh_run rm -rf -- "$dir"
}

# `native signin-watch MINUTES DISPLAY`, the remote session's own process:
# Word on the hidden screen until it closes or the time is up, then
# everything stops.
oh_native_signin_watch() {
  local minutes=${1:?} display=${2:?} rc=0
  local -a env
  [[ $minutes =~ ^[0-9]+$ ]] || oh_die "minutes must be a number"
  trap 'oh_native_ws -k 2>/dev/null; oh_native_signin_stop; exit 143' TERM INT
  mapfile -t env < <(oh_native_env)
  timeout -k 10 "$((minutes * 60))" env DISPLAY="$display" "${env[@]}" "$OH_WINE" "$OH_NATIVE_OFFICE/WINWORD.EXE" >/dev/null 2>&1 || rc=$?
  oh_native_ws -k 2>/dev/null || true
  oh_native_signin_stop
  if ((rc == 124 || rc == 137)); then oh_say "remote sign-in: stopped after $minutes minute$( ((minutes == 1)) || echo s)"; else oh_say "remote sign-in: Word closed"; fi
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

# The sign-in. On this screen, Word opens. With --remote, Word opens on a
# hidden screen shared as a web page on the tailnet address (or with --lan
# the LAN address) only, behind a one-time password, and the link is
# printed last, on a line of its own.
oh_native_signin() {
  local remote=0 lan=0 minutes=30 port=$OH_NATIVE_PORT email='' ip engine tag dir pw url i bin
  while (($#)); do
    case $1 in
    --remote) remote=1 ;;
    --lan) lan=1 ;;
    --minutes) minutes=${2:?--minutes needs a number} && shift ;;
    --port) port=${2:?--port needs a number} && shift ;;
    --email) email=${2:?--email needs an address} && shift ;;
    --stop)
      oh_run systemctl --user stop "$OH_NATIVE_SIGNIN.service" >/dev/null 2>&1 || true
      oh_native_signin_stop
      oh_ok "remote sign-in stopped"
      return 0
      ;;
    *) oh_die "usage: omarchohard native signin [--remote [--lan] [--minutes N] [--port P]] [--email E] | --stop" ;;
    esac
    shift
  done
  [[ $minutes =~ ^[0-9]+$ ]] && ((minutes >= 1 && minutes <= 240)) || oh_die "--minutes takes 1 to 240"
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || oh_die "--port takes 1024 to 65535"
  oh_native_ready || oh_die "native Office is not set up yet (omarchohard native install)"
  if ((! remote)); then
    oh_native_run word
    oh_say "Sign in to Office in the Word window: Sign in, then ${email:-your account}."
    return 0
  fi

  ip=$(oh_native_bind_ip "$lan")
  engine=$(oh_native_engine) || oh_die "remote sign-in needs Docker or Podman for its hidden screen"
  ! oh_native_signin_running || oh_die "a remote sign-in is already running; stop it with: omarchohard native signin --stop"
  [[ -z $(oh_native_app_pids) ]] || oh_die "close Word, Excel, PowerPoint, Outlook and OneNote first; the sign-in starts Word on its own screen"
  # A warm Wine server still has the person's screen; start from a clean one.
  oh_native_stop_wine
  tag=$(oh_native_image "$engine")
  dir=$(oh_native_signin_dir)
  bin=$(oh_bin_path)
  if oh_dry; then
    oh_run "$engine" run -d --rm --name "$OH_NATIVE_SIGNIN" -p "$ip:$port:6080" -v "$dir/xsock:/tmp/.X11-unix" -v "$dir/pw:/run/omarchohard" "$tag"
    oh_run systemd-run --user --quiet --collect --unit="$OH_NATIVE_SIGNIN" "$bin" native signin-watch "$minutes" "unix:$dir/xsock/X0"
    oh_native_link_host "$lan" "$ip"
    printf 'Sign in here: http://%s:%s/#pw=<one-time password>&device=%s\n' "$OH_LINK_HOST" "$port" "$OH_LINK_DEVICE"
    return 0
  fi
  rm -rf -- "$dir"
  (
    umask 077
    mkdir -p "$dir/xsock" "$dir/pw"
    # VNC passwords are 8 characters: 62^8, about 2 x 10^14, for one session
    # of at most four hours, reachable only from the tailnet or the LAN.
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))
    printf '%s\n' "${pw:0:8}" >"$dir/pw/pw"
  )
  pw=$(head -n1 "$dir/pw/pw")
  local -a run=("$engine" run -d --rm --name "$OH_NATIVE_SIGNIN" -u "$(id -u):$(id -g)")
  [[ $engine != podman ]] || run+=(--userns=keep-id)
  run+=(-p "$ip:$port:6080" -v "$dir/xsock:/tmp/.X11-unix" -v "$dir/pw:/run/omarchohard" "$tag")
  "${run[@]}" >/dev/null || {
    rm -rf -- "$dir"
    oh_die "could not start the sign-in screen (is port $port on $ip free? try --port)"
  }
  for ((i = 0; i < 100; i++)); do
    [[ -S $dir/xsock/X0 ]] && break
    sleep 0.1
  done
  if [[ ! -S $dir/xsock/X0 ]]; then
    oh_native_signin_stop
    oh_die "the sign-in screen did not start ($engine logs $OH_NATIVE_SIGNIN)"
  fi
  # x11vnc deletes the password file once it has read it.
  for ((i = 0; i < 50; i++)); do
    [[ -e $dir/pw/pw ]] || break
    sleep 0.1
  done
  rm -f -- "$dir/pw/pw"
  if ! { oh_have systemd-run && systemd-run --user --quiet --collect --unit="$OH_NATIVE_SIGNIN" "${OH_UNIT_ENV[@]}" "$bin" native signin-watch "$minutes" "unix:$dir/xsock/X0" 2>/dev/null; }; then
    setsid -f "$bin" native signin-watch "$minutes" "unix:$dir/xsock/X0" </dev/null >/dev/null 2>&1 ||
      {
        oh_native_signin_stop
        oh_die "could not start Word for the sign-in"
      }
  fi
  # The password travels in the link's fragment (after #), which browsers
  # never send to the server; the page takes it out of the address bar.
  oh_native_link_host "$lan" "$ip"
  url="http://$OH_LINK_HOST:$port/#pw=$pw&device=$OH_LINK_DEVICE"
  # The link is printed only once the page answers (about 2 s after start).
  for ((i = 0; i < 150; i++)); do
    curl -fs -o /dev/null --max-time 1 "http://$ip:$port/" && break
    sleep 0.1
  done
  ((i < 150)) || oh_warn "the sign-in page does not answer yet on $ip:$port ($engine logs $OH_NATIVE_SIGNIN)"
  if oh_have notify-send; then
    notify-send -a omarchohard -i omarchohard "Sign in to Office" "Open on another device on your network: $url" 2>/dev/null || true
  fi
  oh_say "Word is starting on a hidden screen, shared only on $ip${email:+; sign in as $email}."
  oh_say "It stops when Word closes or after $minutes minute$( ((minutes == 1)) || echo s) (now: omarchohard native signin --stop)."
  printf 'Sign in here: %s\n' "$url"
}

oh_native_status() {
  local json=0 wine_ver='' office_ver='' product='' seed sha='' seed_bytes=0 remote=false serving=false app wine_bytes native_bytes
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
  wine_bytes=$(oh_native_du "$OH_WINE_DIR")
  native_bytes=$(oh_native_du "$OH_NATIVE_DIR")
  if ((json)); then
    local apps_json='' a
    for a in "${found[@]}"; do apps_json+=${apps_json:+,}$(oh_json_str "$a"); done
    printf '{"wine":{"present":%s,"version":%s,"path":%s},' "$([[ -n $wine_ver ]] && echo true || echo false)" "$(oh_json_str "$wine_ver")" "$(oh_json_str "$OH_WINE_DIR")"
    printf '"prefix":{"present":%s,"path":%s},' "$(oh_json_bool test -f "$OH_NATIVE_PREFIX/system.reg")" "$(oh_json_str "$OH_NATIVE_PREFIX")"
    printf '"office":{"product":%s,"plans":%s,"version":%s,"apps":[%s]},' "$(oh_json_str "$product")" \
      "$(oh_json_str "$([[ -z $product ]] || oh_native_plan_words "$product")")" "$(oh_json_str "$office_ver")" "$apps_json"
    printf '"seed":{"path":%s,"bytes":%s,"sha256":%s,"serving":%s},' "$(oh_json_str "$seed")" "$seed_bytes" "$(oh_json_str "$sha")" "$serving"
    printf '"disk":{"wine_bytes":%s,"native_bytes":%s},' "${wine_bytes:-0}" "${native_bytes:-0}"
    printf '"remote_signin":%s,"open_with":%s}\n' "$remote" "$(oh_json_str "$(oh_config_get open_with)")"
    return 0
  fi
  printf 'wine: %s\n' "${wine_ver:-not installed (omarchohard native install)}"
  if [[ -f $OH_NATIVE_PREFIX/system.reg ]]; then printf 'prefix: %s\n' "$OH_NATIVE_PREFIX"; else printf 'prefix: none\n'; fi
  printf 'office: %s\n' "${office_ver:-not installed}${product:+ $product, for $(oh_native_plan_words "$product") plans}${found[*]:+ (${found[*]})}"
  if [[ -n $seed ]]; then printf 'seed: %s (%s)%s\n' "$seed" "$(oh_native_size "$seed_bytes")" "$([[ $serving == true ]] && echo ', being served')"; else printf 'seed: none\n'; fi
  printf 'disk: wine %s, prefix and seed %s\n' "$(oh_native_size "${wine_bytes:-0}")" "$(oh_native_size "${native_bytes:-0}")"
  printf 'remote sign-in: %s\n' "$([[ $remote == true ]] && echo running || echo 'not running')"
  printf 'open_with: %s\n' "$(oh_config_get open_with)"
  # omarchohard never reads the sign-in state; this is what a refusal means.
  printf 'sign-in: shown in Word (File, Account). Errors AADSTS53000, 53001 or 53003 mean your organization requires a managed Windows device: use the web apps or ask IT.\n'
}

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
  oh_run systemctl --user stop "$OH_NATIVE_SIGNIN.service" >/dev/null 2>&1 || true
  oh_native_signin_stop
  oh_native_serve_stop
  oh_native_stop_wine
  oh_run rm -rf -- "$OH_NATIVE_DIR" "$OH_WINE_DIR"
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
  signin-watch) oh_native_signin_watch "$@" ;;
  idle-watch) oh_native_idle_watch ;;
  seed) oh_native_seed "$@" ;;
  status) oh_native_status "$@" ;;
  prefer) oh_native_prefer "$@" ;;
  uninstall) oh_native_uninstall "$@" ;;
  *) oh_die "usage: omarchohard native check|install|run|signin|seed|status|prefer|uninstall" ;;
  esac
}
