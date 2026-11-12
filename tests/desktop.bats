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

# A filesystem type for stat -f, so the btrfs path runs anywhere.
fs_is() {
  real_stat=$(command -v stat)
  stub stat "case \"\$1\" in -f) echo $1 ;; *) exec $real_stat \"\$@\" ;; esac"
}

install_stubs() {
  stub docker 'exit 0'
  stub git 'exit 0'
  # shellcheck disable=SC2016
  stub chattr 'printf "%s\n" "$*" >>"$HOME/chattr.log"'
}

@test "desktop install keeps the VM disk in a folder, pins dockur, and turns off copy-on-write on btrfs" {
  install_stubs
  fs_is btrfs
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  vm=$XDG_DATA_HOME/omarchohard/vm
  grep -qxF '      - ./storage:/storage' "$vm/compose.yaml"
  grep -qxF '    image: ghcr.io/dockur/windows:6.06' "$vm/compose.yaml"
  run grep -E 'data:|:latest' "$vm/compose.yaml"
  [ "$status" -ne 0 ]
  [ -d "$vm/storage" ]
  [ "$(cat "$HOME/chattr.log")" = "+C $vm/storage" ]
}

@test "desktop install warns when chattr fails, and skips it off btrfs" {
  install_stubs
  stub chattr 'exit 1'
  fs_is btrfs
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  [[ $output == *"could not turn off copy-on-write"* ]]
  install_stubs
  fs_is ext2/ext3
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/chattr.log" ]
}

@test "desktop install keeps the named volume of a VM made before 0.2.0" {
  install_stubs
  fs_is btrfs
  vm=$XDG_DATA_HOME/omarchohard/vm
  printf 'volumes:\n  data:\nservices:\n  windows:\n    volumes:\n      - data:/storage\n' >"$vm/compose.yaml"
  run "$OH" desktop install --force
  [ "$status" -eq 0 ]
  grep -qxF '      - data:/storage' "$vm/compose.yaml"
  grep -qxF '    image: ghcr.io/dockur/windows:6.06' "$vm/compose.yaml"
  [ "$(sed -n '/^volumes:$/{n;p}' "$vm/compose.yaml")" = '  data:' ]
  run grep -F './storage' "$vm/compose.yaml"
  [ "$status" -ne 0 ]
  [ ! -e "$vm/storage" ]
  [ ! -e "$HOME/chattr.log" ]
}
