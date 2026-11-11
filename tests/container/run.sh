#!/usr/bin/env bash
# Run omarchohard's checks in a clean Arch Linux container (Docker, no sudo).
#
#   tests/container/run.sh [TARGET...]
#
# Targets:
#   lint     shellcheck, shfmt, actionlint
#   test     the bats suite
#   install  install.sh over HTTP for each channel, install, doctor, channel
#            switching, uninstall (tests/container/install-test.sh)
#   launch   headless sway plus real Chromium: every app maps a window
#   package  makepkg the -git package, pacman -U, version, install, doctor
#   srcinfo  regenerate packaging/arch/*/.SRCINFO in the repo
#   all      lint test install launch package (the default)
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
image=${OMARCHOHARD_TEST_IMAGE:-omarchohard-test:latest}

command -v docker >/dev/null || {
  echo "run.sh: docker is required" >&2
  exit 1
}

(($#)) || set -- all
targets=()
for t in "$@"; do
  case $t in
  all) targets+=(lint test install launch package) ;;
  lint | test | install | launch | package | srcinfo) targets+=("$t") ;;
  *)
    echo "run.sh: unknown target '$t'" >&2
    exit 2
    ;;
  esac
done

echo "== building $image"
docker build -q -t "$image" -f "$root/tests/container/Dockerfile" "$root/tests/container" >/dev/null

drun() {
  local -a tty=()
  [[ -t 1 ]] && tty=(-t)
  docker run --rm --init "${tty[@]}" --shm-size=1g -e CI="${CI:-}" -v "$root:/src:ro" "$@"
}

for t in "${targets[@]}"; do
  echo "== $t"
  case $t in
  lint) drun -w /src "$image" scripts/lint.sh ;;
  test) drun -w /src "$image" bats --print-output-on-failure tests ;;
  install) drun "$image" bash /src/tests/container/install-test.sh ;;
  launch) drun "$image" bash /src/tests/container/launch-test.sh ;;
  package) drun "$image" bash /src/tests/container/package-test.sh ;;
  srcinfo) drun -v "$root/packaging/arch:/out" "$image" bash /src/tests/container/package-test.sh --srcinfo /out ;;
  esac
  echo "== $t: ok"
done
