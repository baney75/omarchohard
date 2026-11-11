# Test image: a clean Arch Linux with the tools the test suite needs.
# Used by `make lint`, `make test`, `make container` and tests/container/run.sh.
FROM archlinux:latest
RUN pacman -Syu --noconfirm --needed \
      bash bats coreutils curl diffutils file findutils git grep jq python sed sudo tar which \
      desktop-file-utils xdg-utils shellcheck shfmt actionlint base-devel \
    && pacman -Scc --noconfirm
RUN pacman -S --noconfirm --needed sway chromium ttf-dejavu \
    && pacman -Scc --noconfirm
# Arch gives sway cap_sys_nice, which a container refuses to exec; drop it.
# The repo is mounted read-only and owned by another uid, so let git read it.
RUN setcap -r /usr/bin/sway \
    && git config --system --add safe.directory '*' \
    && useradd -m -u 1000 tester \
    && echo 'tester ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/tester
USER tester
WORKDIR /home/tester
