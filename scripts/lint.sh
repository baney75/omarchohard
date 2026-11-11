#!/usr/bin/env bash
# Lint every shell file in the repo with shellcheck, shfmt and actionlint.
# Needs shellcheck and shfmt on PATH; actionlint runs when installed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t sh_files < <(
  {
    printf '%s\n' bin/omarchohard install.sh
    ls lib/omarchohard/*.sh scripts/*.sh tests/container/*.sh tests/*.bash
  } | sort -u
)
mapfile -t bats_files < <(ls tests/*.bats)
mapfile -t pkgbuilds < <(ls packaging/arch/*/PKGBUILD 2>/dev/null || true)

echo "shellcheck: ${#sh_files[@]} scripts, ${#bats_files[@]} bats files, ${#pkgbuilds[@]} PKGBUILDs"
# The CLI sources its modules in a loop, so shellcheck checks them one by one
# and cannot see globals shared between modules (SC2034 there only).
mapfile -t core < <(printf '%s\n' bin/omarchohard lib/omarchohard/*.sh)
mapfile -t rest < <(printf '%s\n' "${sh_files[@]}" | grep -v -x -F -f <(printf '%s\n' "${core[@]}"))
shellcheck -x -e SC2034 "${core[@]}"
shellcheck -x "${rest[@]}" "${bats_files[@]}"
if ((${#pkgbuilds[@]})); then
  # makepkg sets pkgdir and srcdir, reads the metadata variables and runs
  # every function with set -e (so a failed cd stops the build).
  shellcheck -s bash -e SC2034,SC2154,SC2164 "${pkgbuilds[@]}"
fi

echo "shfmt -i 2 (case arms flush with case, as in the core)"
shfmt -d -i 2 "${sh_files[@]}"
shfmt -d -i 2 -ln bats "${bats_files[@]}"
((${#pkgbuilds[@]} == 0)) || shfmt -d -i 2 -ln bash "${pkgbuilds[@]}"

if command -v actionlint >/dev/null 2>&1; then
  echo "actionlint"
  actionlint
else
  echo "actionlint not installed; skipped"
fi
echo "lint: ok"
