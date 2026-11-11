#!/usr/bin/env bash
# Lay out a local release tree with all three channels, in the same address
# scheme as GitHub releases, for tests:
#   scripts/release-base.sh DIR
#   DIR/latest/download/*      stable
#   DIR/download/nightly/*     nightly
#   DIR/download/dev/*         dev
#   DIR/install.sh
# Point OMARCHOHARD_RELEASE_BASE at file://DIR or an HTTP server on DIR.
set -euo pipefail

dir=${1:?usage: release-base.sh DIR}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$dir"
"$root/scripts/build-release.sh" stable "$dir/latest/download" >/dev/null
"$root/scripts/build-release.sh" nightly "$dir/download/nightly" >/dev/null
"$root/scripts/build-release.sh" dev "$dir/download/dev" >/dev/null
cp "$root/install.sh" "$dir/install.sh"
for f in "$dir/latest/download" "$dir/download/nightly" "$dir/download/dev"; do
  printf '%s %s\n' "${f#"$dir"/}" "$(cat "$f/omarchohard.version")"
done
