#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version, without its heading:
#   scripts/changelog-section.sh 0.1.0 [CHANGELOG.md]
set -euo pipefail

version=${1:?usage: changelog-section.sh VERSION [FILE]}
file=${2:-$(dirname "${BASH_SOURCE[0]}")/../CHANGELOG.md}
out=$(awk -v v="$version" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]+\]: / { exit }
  on { print }
' "$file" | sed -e '/./,$!d')
[[ -n $out ]] || {
  echo "changelog-section: no section for $version in $file" >&2
  exit 1
}
printf '%s\n' "$out"
