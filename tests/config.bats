#!/usr/bin/env bats
# The config file is parsed as key=value and never executed.

load test_helper

setup() { oh_sandbox; }

@test "config values that look like code are never executed" {
  cat >"$XDG_CONFIG_HOME/omarchohard/config" <<CONF
browser=chromium
email=\$(touch $HOME/pwned1)
channel=stable; touch $HOME/pwned2
onedrive_dir=\`touch $HOME/pwned3\`
\$(touch $HOME/pwned4)=x
profile=\${IFS}\$(touch $HOME/pwned5)
CONF
  run "$OH" doctor
  run "$OH" channel
  run "$OH" onedrive status
  OMARCHOHARD_DRY_RUN=1 run "$OH" login
  OMARCHOHARD_DRY_RUN=1 run "$OH" launch word
  for n in 1 2 3 4 5; do
    [ ! -e "$HOME/pwned$n" ]
  done
}

@test "a channel value with shell syntax is reported as unknown, not run" {
  # shellcheck disable=SC2016 # the config must hold the literal text
  printf 'browser=chromium\nchannel=$(touch %s/pwned)\n' "$HOME" >"$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" update
  [ "$status" -eq 1 ]
  [[ $output == *"unknown channel"* ]]
  [ ! -e "$HOME/pwned" ]
}

@test "quotes, spaces, comments and ~ are handled" {
  cat >"$XDG_CONFIG_HOME/omarchohard/config" <<'CONF'
# a comment
  browser = chromium
channel="nightly"

onedrive_dir=~/Cloud Drive
Bad-Key=ignored
CONF
  run "$OH" channel
  [ "$status" -eq 0 ]
  [[ $output == *"channel: nightly"* ]]
  run "$OH" onedrive status
  [[ $output == *"folder:   $HOME/Cloud Drive"* ]]
}

@test "config set rewrites one key and keeps the rest" {
  printf '# mine\nbrowser=chromium\nemail=a@b.c\n' >"$XDG_CONFIG_HOME/omarchohard/config"
  run "$OH" onedrive web-root https://contoso-my.sharepoint.com/personal/a_b_c/Documents
  [ "$status" -eq 0 ]
  run "$OH" onedrive web-root https://contoso-my.sharepoint.com/personal/a_b_c/Documents/
  grep -qx '# mine' "$XDG_CONFIG_HOME/omarchohard/config"
  grep -qx 'email=a@b.c' "$XDG_CONFIG_HOME/omarchohard/config"
  [ "$(grep -c '^onedrive_web_root=' "$XDG_CONFIG_HOME/omarchohard/config")" = 1 ]
}
