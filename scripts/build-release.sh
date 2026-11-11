#!/usr/bin/env bash
# Build a release: scripts/build-release.sh <stable|nightly|dev> [outdir]
#
# Writes outdir/omarchohard.tar.gz, omarchohard.tar.gz.sha256 and
# omarchohard.version. Versions:
#   stable   X.Y.Z from VERSION (must match the tag when GITHUB_REF is a tag)
#   nightly  X.Y.Z-nightly.YYYYMMDD+<sha7>
#   dev      X.Y.Z-dev.<commit count>+<sha7>
# Prints the version on stdout.
set -euo pipefail

die() {
  printf 'build-release: %s\n' "$*" >&2
  exit 1
}

channel=${1:-}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${2:-$root/dist}

base=$(tr -d '[:space:]' <"$root/VERSION")
[[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be X.Y.Z, got '$base'"

git_rev() { git -C "$root" rev-parse --short=7 HEAD; }

case $channel in
stable)
  version=$base
  if [[ ${GITHUB_REF:-} == refs/tags/* ]]; then
    tag=${GITHUB_REF#refs/tags/}
    [[ $tag == "v$version" ]] || die "tag $tag does not match VERSION $version"
  fi
  ;;
nightly)
  day=$(date -u ${SOURCE_DATE_EPOCH:+-d "@$SOURCE_DATE_EPOCH"} +%Y%m%d)
  version=$base-nightly.$day+$(git_rev)
  ;;
dev)
  version=$base-dev.$(git -C "$root" rev-list --count HEAD)+$(git_rev)
  ;;
*) die "usage: build-release.sh <stable|nightly|dev> [outdir]" ;;
esac
[[ $version =~ ^[0-9A-Za-z.+_-]+$ ]] || die "bad version string: $version"

for f in bin/omarchohard lib/omarchohard share/omarchohard LICENSE README.md CHANGELOG.md; do
  [[ -e $root/$f ]] || die "missing $f"
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
top=$stage/omarchohard-$version
mkdir -p "$top/lib" "$top/share"
cp -a "$root/bin" "$top/bin"
cp -a "$root/lib/omarchohard" "$top/lib/omarchohard"
cp -a "$root/share/omarchohard" "$top/share/omarchohard"
cp "$root/LICENSE" "$root/README.md" "$root/CHANGELOG.md" "$top/"
printf '%s\n' "$version" >"$top/share/omarchohard/VERSION"

# Reproducible archive: fixed order, owner and time (the commit time).
mtime=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct 2>/dev/null || date +%s)}
mkdir -p "$outdir"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$mtime" \
  -C "$stage" -cf - "omarchohard-$version" | gzip -n -9 >"$outdir/omarchohard.tar.gz"
(cd "$outdir" && sha256sum omarchohard.tar.gz >omarchohard.tar.gz.sha256)
printf '%s\n' "$version" >"$outdir/omarchohard.version"
printf '%s\n' "$version"
