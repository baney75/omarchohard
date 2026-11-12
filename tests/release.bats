#!/usr/bin/env bats
# Release builds, install.sh and channel switching against a local release
# tree (file://), in the same address scheme as GitHub releases.

load test_helper

setup_file() {
  export RB=$BATS_FILE_TMPDIR/release-base
  "$BATS_TEST_DIRNAME/../scripts/release-base.sh" "$RB" >/dev/null
}

setup() {
  oh_sandbox
  export OMARCHOHARD_RELEASE_BASE=file://$RB
  STABLE=$(cat "$RB/latest/download/omarchohard.version")
  NIGHTLY=$(cat "$RB/download/nightly/omarchohard.version")
  DEV=$(cat "$RB/download/dev/omarchohard.version")
  DATA=$XDG_DATA_HOME/omarchohard
}

installed() { "$HOME/.local/bin/omarchohard" "$@"; }

@test "release versions have the documented formats" {
  [ "$STABLE" = "$(cat "$OH_REPO_ROOT/VERSION")" ]
  [[ $NIGHTLY =~ ^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\+[0-9a-f]{7}$ ]]
  [[ $DEV =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]{7}$ ]]
}

@test "the archive has one top directory with the release files and VERSION" {
  run tar -tzf "$RB/download/dev/omarchohard.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(cut -d/ -f1 <<<"$output" | sort -u)" = "omarchohard-$DEV" ]
  for f in bin/omarchohard lib/omarchohard/common.sh share/omarchohard/icons/word.svg LICENSE README.md CHANGELOG.md share/omarchohard/VERSION; do
    grep -qx "omarchohard-$DEV/$f" <<<"$output"
  done
  [ "$(tar -xzOf "$RB/download/dev/omarchohard.tar.gz" "omarchohard-$DEV/share/omarchohard/VERSION")" = "$DEV" ]
  (cd "$RB/download/dev" && sha256sum -c --quiet omarchohard.tar.gz.sha256)
}

@test "a stable build refuses a tag that does not match VERSION" {
  GITHUB_REF=refs/tags/v99.0.0 run "$OH_REPO_ROOT/scripts/build-release.sh" stable "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ $output == *"does not match VERSION"* ]]
  GITHUB_REF=refs/tags/v$STABLE run "$OH_REPO_ROOT/scripts/build-release.sh" stable "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$STABLE" ]
}

@test "install.sh installs stable, links the CLI and writes the channel" {
  run bash "$OH_REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"Next: omarchohard setup"* ]]
  [ "$(readlink "$HOME/.local/bin/omarchohard")" = "$DATA/current/bin/omarchohard" ]
  [ "$(readlink "$DATA/current")" = "$DATA/releases/$STABLE" ]
  [ "$(installed version)" = "omarchohard $STABLE" ]
  grep -qx channel=stable "$XDG_CONFIG_HOME/omarchohard/config"
  grep -qx browser=chromium "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "install.sh twice is idempotent" {
  bash "$OH_REPO_ROOT/install.sh" >/dev/null 2>&1
  run bash "$OH_REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$(ls "$DATA/releases")" = "$STABLE" ]
  [ "$(grep -c '^channel=' "$XDG_CONFIG_HOME/omarchohard/config")" = 1 ]
  [ "$(installed version)" = "omarchohard $STABLE" ]
}

@test "install.sh --channel nightly and dev install those builds" {
  run bash "$OH_REPO_ROOT/install.sh" --channel nightly
  [ "$status" -eq 0 ]
  [ "$(installed version)" = "omarchohard $NIGHTLY" ]
  grep -qx channel=nightly "$XDG_CONFIG_HOME/omarchohard/config"
  run bash "$OH_REPO_ROOT/install.sh" --channel dev
  [ "$status" -eq 0 ]
  [ "$(installed version)" = "omarchohard $DEV" ]
  grep -qx channel=dev "$XDG_CONFIG_HOME/omarchohard/config"
}

@test "install.sh --install also runs omarchohard install" {
  run bash "$OH_REPO_ROOT/install.sh" --install
  [ "$status" -eq 0 ]
  [ -f "$APPS/omarchohard-word.desktop" ]
  grep -q "^Exec=$HOME/.local/bin/omarchohard open --app word" "$APPS/omarchohard-word.desktop"
  run installed doctor
  [ "$status" -eq 0 ]
}

@test "install.sh refuses a checksum mismatch and installs nothing" {
  cp -r "$RB" "$BATS_TEST_TMPDIR/bad"
  printf '%064d  omarchohard.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/bad/latest/download/omarchohard.tar.gz.sha256"
  OMARCHOHARD_RELEASE_BASE=file://$BATS_TEST_TMPDIR/bad run bash "$OH_REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"checksum mismatch"* ]]
  [ ! -e "$DATA/releases" ]
  [ ! -e "$HOME/.local/bin/omarchohard" ]
}

@test "install.sh rejects an unknown channel" {
  run bash "$OH_REPO_ROOT/install.sh" --channel beta
  [ "$status" -eq 1 ]
  [[ $output == *"unknown channel"* ]]
}

@test "channel switching moves between stable, nightly and dev" {
  bash "$OH_REPO_ROOT/install.sh" --install >/dev/null 2>&1
  run installed channel nightly
  [ "$status" -eq 0 ]
  [ "$(installed version)" = "omarchohard $NIGHTLY" ]
  run installed channel dev
  [ "$status" -eq 0 ]
  [ "$(installed version)" = "omarchohard $DEV" ]
  run installed channel stable
  [ "$status" -eq 0 ]
  [ "$(installed version)" = "omarchohard $STABLE" ]
  run installed channel
  [[ $output == *"channel: stable"* ]]
  run installed update
  [ "$status" -eq 0 ]
  [[ $output == *"up to date"* ]]
  # Launchers still work after the swaps.
  run installed doctor
  [ "$status" -eq 0 ]
}

@test "update --check reports a newer build without installing it" {
  bash "$OH_REPO_ROOT/install.sh" >/dev/null 2>&1
  sed -i 's/^channel=.*/channel=dev/' "$XDG_CONFIG_HOME/omarchohard/config"
  run installed update --check
  [ "$status" -eq 0 ]
  [[ $output == *"update available: $STABLE -> $DEV (dev)"* ]]
  [ "$(installed version)" = "omarchohard $STABLE" ]
}

@test "a checksum mismatch on update refuses and changes nothing" {
  bash "$OH_REPO_ROOT/install.sh" >/dev/null 2>&1
  cp -r "$RB" "$BATS_TEST_TMPDIR/bad"
  printf '%064d  omarchohard.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/bad/download/nightly/omarchohard.tar.gz.sha256"
  config_before=$(cat "$XDG_CONFIG_HOME/omarchohard/config")
  current_before=$(readlink "$DATA/current")
  OMARCHOHARD_RELEASE_BASE=file://$BATS_TEST_TMPDIR/bad run installed channel nightly
  [ "$status" -eq 1 ]
  [[ $output == *"checksum mismatch; nothing was changed"* ]]
  [ "$(readlink "$DATA/current")" = "$current_before" ]
  [ "$(ls "$DATA/releases")" = "$STABLE" ]
  [ "$(cat "$XDG_CONFIG_HOME/omarchohard/config")" = "$config_before" ]
  [ "$(installed version)" = "omarchohard $STABLE" ]
}

@test "a package-managed install prints the AUR message; a channel switch changes nothing and fails" {
  run "$OH" update
  [ "$status" -eq 0 ]
  [[ $output == *"installed by a package manager"* ]]
  [[ $output == *"AUR package 'omarchohard'"* ]]
  run "$OH" channel dev
  [ "$status" -eq 1 ]
  [[ $output == *"omarchohard-git"* ]]
  run grep -q '^channel=' "$XDG_CONFIG_HOME/omarchohard/config"
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/releases" ]
}

@test "install.sh stops before downloading when ~/.local/bin/omarchohard is a regular file" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' >"$HOME/.local/bin/omarchohard"
  run bash "$OH_REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"is not a symlink"* ]]
  [[ $output != *"Fetching"* ]]
  [ ! -e "$DATA" ]
}

@test "a channel version of .. is refused by install.sh and by update" {
  mkdir -p "$DATA/keep"
  cp -r "$RB" "$BATS_TEST_TMPDIR/bad"
  printf '..\n' >"$BATS_TEST_TMPDIR/bad/latest/download/omarchohard.version"
  OMARCHOHARD_RELEASE_BASE=file://$BATS_TEST_TMPDIR/bad run bash "$OH_REPO_ROOT/install.sh" --no-setup
  [ "$status" -eq 1 ]
  [[ $output == *"bad version"* ]]
  [ -d "$DATA/keep" ]
  bash "$OH_REPO_ROOT/install.sh" --no-setup >/dev/null 2>&1
  printf '1.0..2\n' >"$BATS_TEST_TMPDIR/bad/download/nightly/omarchohard.version"
  OMARCHOHARD_RELEASE_BASE=file://$BATS_TEST_TMPDIR/bad run installed channel nightly
  [ "$status" -eq 1 ]
  [[ $output == *"bad version"* ]]
  [ -d "$DATA/keep" ]
}
