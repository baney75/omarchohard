#!/usr/bin/env bats
# Desktop tier: product keys and the RDP password never reach a command line.
# No VM runs; a background job stands in for the Windows inbox task.

load test_helper

KEY=ABCDE-FGHIJ-KLMNO-PQRST-UVWXY

setup() {
  oh_sandbox
  INBOX=$XDG_DATA_HOME/omarchohard/vm-inbox
  mkdir -p "$XDG_DATA_HOME/omarchohard/vm"
  printf '%s\n' "${KEY,,}" >"$BATS_TEST_TMPDIR/key"
}

# Answer the first request like the VM would, keeping a copy of it.
fake_vm() {
  (
    for _ in $(seq 100); do
      for r in "$INBOX"/*.request; do
        [ -f "$r" ] || continue
        cp "$r" "$BATS_TEST_TMPDIR/seen.json"
        rm -f "$r"
        printf 'Office: licensed\n' >"${r%.request}.result"
        exit 0
      done
      sleep 0.1
    done
  ) 3>&- &
}

@test "desktop activate writes the request without running jq or any process with the key" {
  # shellcheck disable=SC2016
  stub jq 'printf "%s\n" "$*" >>"$HOME/jq.log"; exit 1'
  fake_vm
  run "$OH" desktop activate --key-file "$BATS_TEST_TMPDIR/key"
  wait
  [ "$status" -eq 0 ]
  [[ $output == *"Office: licensed"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = "{\"action\":\"office-key\",\"key\":\"$KEY\"}" ]
  [ ! -e "$HOME/jq.log" ]
  [ -z "$(ls -A "$INBOX")" ]
}

@test "a stopped desktop activate deletes its request" {
  "$OH" desktop activate --key-file "$BATS_TEST_TMPDIR/key" >/dev/null 2>&1 3>&- &
  pid=$!
  for _ in $(seq 50); do
    compgen -G "$INBOX/*.request" >/dev/null && break
    sleep 0.1
  done
  compgen -G "$INBOX/*.request" >/dev/null
  kill -TERM "$pid"
  wait "$pid" || true
  [ -z "$(ls -A "$INBOX")" ]
}

@test "desktop install builds compose.yaml in bash, with the VM password intact and off sed's arguments" {
  real_sed=$(command -v sed)
  stub sed "printf '%s\n' \"\$*\" >>\"\$HOME/sed.log\"; exec $real_sed \"\$@\""
  stub docker 'exit 0'
  stub git 'exit 0'
  # A test value with the characters that broke the old sed substitution.
  # shellcheck disable=SC2016 # a literal $ in the value
  secret='p&ss|w0rd"q$x'
  mkdir -p "$XDG_CONFIG_HOME/winapps"
  printf '%s="%s"\n' RDP_USER ada RDP_PASS "$secret" >"$XDG_CONFIG_HOME/winapps/winapps.conf"
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  compose=$XDG_DATA_HOME/omarchohard/vm/compose.yaml
  # shellcheck disable=SC2016 # compose escapes $ as $$
  grep -qF '"p&ss|w0rd\"q$$x"' "$compose"
  grep -qxF '      USERNAME: "ada"' "$compose"
  grep -qxF '      VERSION: "11e"' "$compose"
  [ "$(stat -c %a "$compose")" = 600 ]
  run grep -qF 'w0rd' "$HOME/sed.log"
  [ "$status" -ne 0 ]
}
