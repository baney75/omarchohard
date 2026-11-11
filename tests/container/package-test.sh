#!/usr/bin/env bash
# Arch package test (run by tests/container/run.sh package).
#   1. makepkg the omarchohard-git package from this checkout (the PKGBUILD's
#      GitHub source is swapped for the local repo in a scratch copy),
#      pacman -U it, then check version, install and doctor in the pacman
#      layout (/usr/bin, /usr/lib/omarchohard, /usr/share/omarchohard).
#   2. The same for the stable PKGBUILD, fed a local tag-style tarball.
#   3. Check the committed .SRCINFO files are current.
#
# With --srcinfo DIR it only writes DIR/<pkg>/.SRCINFO for both packages.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
cp -a /src "$work/src"
pkgs=(omarchohard omarchohard-git)

srcinfo() { (cd "$work/src/packaging/arch/$1" && makepkg --printsrcinfo); }

if [[ ${1:-} == --srcinfo ]]; then
  out=${2:?--srcinfo needs a directory}
  for p in "${pkgs[@]}"; do
    srcinfo "$p" >"$out/$p/.SRCINFO"
    echo "wrote $p/.SRCINFO"
  done
  exit 0
fi

# Check a package installed in the pacman layout, in a fresh HOME.
check_installed() {
  local name=$1 want=$2 got
  pacman -Ql "$name" | grep -q ' /usr/bin/omarchohard$' || fail "$name has no /usr/bin/omarchohard"
  pacman -Ql "$name" | grep -q ' /usr/lib/omarchohard/common.sh$' || fail "$name has no /usr/lib/omarchohard"
  [[ $(cat /usr/share/omarchohard/VERSION) == "$want" ]] || fail "/usr/share/omarchohard/VERSION is not $want"
  got=$(omarchohard version)
  [[ $got == "omarchohard $want" ]] || fail "version: expected $want, got '$got'"
  echo "   $got"
  (
    export HOME=$work/home-$name
    mkdir -p "$HOME/.config/omarchohard" "$work/stubs"
    printf '#!/bin/sh\nexit 0\n' >"$work/stubs/chromium"
    chmod +x "$work/stubs/chromium"
    export PATH=$work/stubs:$PATH OMARCHOHARD_NO_UWSM=1 NO_COLOR=1
    printf 'browser=chromium\n' >"$HOME/.config/omarchohard/config"
    omarchohard install >/dev/null 2>&1 || fail "omarchohard install"
    omarchohard doctor || fail "doctor in the pacman layout"
    grep -q '^Exec=/usr/bin/omarchohard open --app word' "$HOME/.local/share/applications/omarchohard-word.desktop" ||
      fail "Exec does not use /usr/bin/omarchohard"
    omarchohard update 2>&1 | grep -q 'installed by a package manager' || fail "update did not defer to pacman"
    omarchohard uninstall >/dev/null 2>&1
  )
}

echo "-- omarchohard-git"
build=$work/build-git
mkdir -p "$build"
cp "$work/src/packaging/arch/omarchohard-git/PKGBUILD" "$build/"
sed -i "s|git+https://github.com/baney75/omarchohard.git|git+file://$work/src|" "$build/PKGBUILD"
grep -q "git+file://$work/src" "$build/PKGBUILD" || fail "source override did not apply"
(cd "$build" && makepkg -f --noconfirm --syncdeps >"$work/makepkg-git.log" 2>&1) || {
  tail -n 30 "$work/makepkg-git.log"
  fail "makepkg omarchohard-git"
}
pkgfile=$(ls "$build"/omarchohard-git-*.pkg.tar.zst)
gitver=$(sed -n 's/^pkgver=//p' "$build/PKGBUILD")
echo "   built ${pkgfile##*/}"
sudo pacman -U --noconfirm "$pkgfile" >/dev/null
check_installed omarchohard-git "$gitver"
sudo pacman -R --noconfirm omarchohard-git >/dev/null

echo "-- omarchohard (stable PKGBUILD, local tag tarball)"
build=$work/build-stable
mkdir -p "$build"
cp "$work/src/packaging/arch/omarchohard/PKGBUILD" "$build/"
ver=$(sed -n 's/^pkgver=//p' "$build/PKGBUILD")
[[ $ver == "$(cat "$work/src/VERSION")" ]] || fail "PKGBUILD pkgver $ver does not match VERSION"
# The same layout GitHub serves for refs/tags/vX.Y.Z.tar.gz.
git -C "$work/src" archive --format=tar.gz --prefix="omarchohard-$ver/" -o "$build/omarchohard-$ver.tar.gz" HEAD
(cd "$build" && makepkg -f --noconfirm --syncdeps >"$work/makepkg-stable.log" 2>&1) || {
  tail -n 30 "$work/makepkg-stable.log"
  fail "makepkg omarchohard"
}
pkgfile=$(ls "$build"/omarchohard-"$ver"-*.pkg.tar.zst)
echo "   built ${pkgfile##*/}"
sudo pacman -U --noconfirm "$pkgfile" >/dev/null
check_installed omarchohard "$ver"
sudo pacman -R --noconfirm omarchohard >/dev/null

echo "-- .SRCINFO"
for p in "${pkgs[@]}"; do
  diff -u "$work/src/packaging/arch/$p/.SRCINFO" <(srcinfo "$p") || fail "$p/.SRCINFO is stale; run: make srcinfo"
  echo "   $p/.SRCINFO is current"
done
echo "package-test: both packages built, installed and passed doctor"
