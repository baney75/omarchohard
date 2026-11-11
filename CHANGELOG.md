# Changelog

All notable changes to omarchohard are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Nightly and dev
builds are not listed; they carry the version of the next release plus a
`-nightly` or `-dev` suffix.

## [Unreleased]

## [0.1.0] - 2026-11-11

### Added

- `omarchohard install`: Word, Excel, PowerPoint, Outlook, OneNote, Teams,
  OneDrive and a Microsoft 365 home launcher as Chromium app windows, with
  desktop entries, icons, file handlers (.docx, .xlsx, .pptx and 16 related
  types) and URL handlers (mailto, msteams, ms-word, ms-excel, ms-powerpoint,
  onenote). `--isolated` uses a dedicated browser profile; `--no-mail` leaves
  mailto alone.
- Launch-or-focus through `hyprctl`: a second launch raises the open window.
- `omarchohard open`: files inside the OneDrive folder open in place; files
  elsewhere are copied into OneDrive/Omarchohard and the original is left
  untouched.
- `omarchohard onedrive setup`: OneDrive on disk through an rclone FUSE mount
  with a full VFS cache (default) or the abraunegg `onedrive` client.
- `omarchohard prewarm on`: an optional user service that keeps a windowless
  browser resident (about 215 MB) so apps open in about 0.2 s.
- `omarchohard doctor`: checks every launcher, icon, handler and service and
  exits 1 when a required check fails.
- `omarchohard uninstall`: removes every launcher and icon and restores the
  previous handlers; `--purge` also removes config and state.
- Release channels (stable, nightly, dev), `omarchohard channel` and
  `omarchohard update` with sha256 verification and atomic switching.
- One-line installer (`install.sh`) and Arch packages (`omarchohard`,
  `omarchohard-git`).
- Experimental desktop tier: real Microsoft Office in a Windows VM through
  WinApps and dockur/windows, with product-key activation through a VM inbox.

[Unreleased]: https://github.com/baney75/omarchohard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/baney75/omarchohard/releases/tag/v0.1.0
