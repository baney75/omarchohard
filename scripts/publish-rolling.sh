#!/usr/bin/env bash
# Publish a rolling prerelease (nightly or dev) from CI:
#   scripts/publish-rolling.sh TAG DIR TITLE NOTES
# Moves TAG to HEAD, then creates the prerelease or replaces its three assets.
# Needs gh with GH_TOKEN and a checkout that can push tags.
set -euo pipefail

tag=${1:?usage: publish-rolling.sh TAG DIR TITLE NOTES}
dir=${2:?missing DIR}
title=${3:?missing TITLE}
notes=${4:?missing NOTES}
[[ $tag == nightly || $tag == dev ]] || {
  echo "publish-rolling: only the nightly and dev tags roll" >&2
  exit 1
}
# The tarball first and the version last, so a client never sees a new
# version before its archive is in place.
assets=("$dir/omarchohard.tar.gz" "$dir/omarchohard.tar.gz.sha256" "$dir/omarchohard.version")
for f in "${assets[@]}"; do
  [[ -s $f ]] || {
    echo "publish-rolling: missing $f" >&2
    exit 1
  }
done

git tag -f "$tag" HEAD
git push -f origin "refs/tags/$tag"

if gh release view "$tag" >/dev/null 2>&1; then
  gh release edit "$tag" --title "$title" --notes "$notes" --prerelease --latest=false
  gh release upload "$tag" "${assets[@]}" --clobber
else
  gh release create "$tag" "${assets[@]}" --title "$title" --notes "$notes" --prerelease --latest=false --verify-tag
fi
echo "published $(cat "$dir/omarchohard.version") to $tag"
