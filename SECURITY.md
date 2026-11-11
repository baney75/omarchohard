# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open the
repository's **Security** tab and choose **Report a vulnerability**. Do not
open a public issue. You can expect a first reply within a week.

Supported versions: the newest stable release and the current nightly and
dev builds.

## What omarchohard touches

- Desktop entries, icons and `~/.config/mimeapps.list` (through `xdg-mime`),
  its own config in `~/.config/omarchohard`, state in
  `~/.local/state/omarchohard`, releases and the optional isolated browser
  profile in `~/.local/share/omarchohard`, and systemd user units it creates.
- It starts your browser, rclone or `onedrive`, and, for the desktop tier,
  Docker or Podman and FreeRDP.
- It needs no root. The installer refuses to run as root.

## What it never does

- Read browser cookies, tokens, passwords or any auth file. Microsoft sign-in
  happens in the browser, and rclone and `onedrive` keep their own tokens.
- Execute its config file: values are parsed as `key=value` text, and a test
  checks that values such as `$(...)` never run.
- Change a file outside OneDrive when opening it: it copies the file into
  `OneDrive/Omarchohard` and opens the copy.

## Updates

`install.sh` and `omarchohard update` download over HTTPS from GitHub
releases and check the archive's sha256 before changing anything. The
checksum comes from the same release, so it catches corrupt or partial
downloads, not a compromised release.

## Product keys (desktop tier)

- Keys come from a hidden prompt or a file you name; never from the command
  line, the config or a log.
- A key reaches the VM in a one-shot request file, mode 0600, in a 0700 inbox
  folder in your home. Windows deletes the request before using it and writes
  the result with the key masked as `*****`. omarchohard deletes the request
  and the result afterward.
- The VM listens on 127.0.0.1 only. Its local Windows password is random and
  stored in files with mode 0600.
