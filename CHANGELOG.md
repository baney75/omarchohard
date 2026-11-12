# Changelog

All notable changes to omarchohard are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Nightly and dev
builds are not listed; they carry the version of the next release plus a
`-nightly` or `-dev` suffix.

## [Unreleased]

### Added

- Setup asks which files open in Office: Microsoft Office files only (the
  default), or those plus other formats, all of them or the ones you pick
  (`.odt`, `.ods`, `.odp`, `.rtf`, `.csv`). Only formats of the apps you
  installed are offered.
- `omarchohard files` shows the choice; `omarchohard files microsoft|all|LIST`
  changes it, such as `omarchohard files odt,csv`. Formats you turn off go
  back to the app that had them before.
- `setup --files microsoft|all|LIST` answers the question without asking.
  `setup --yes` without it keeps the current choice.
- `.csv` files can open in Excel (`omarchohard files csv`).

### Changed

- OpenDocument (`.odt`, `.ods`, `.odp`) and Rich Text (`.rtf`) files no
  longer open in Office unless you choose them (`omarchohard files all`).
  The next install hands them back to the app that had them before.
- omarchohard has its own logo, the `omarchohard` icon. The Setup launcher,
  "Open in Windows" and notifications use it instead of the Microsoft 365
  icon.

### Fixed

- After a package update (AUR), the first open, launch or doctor sets the
  launchers and file types again, so new types such as .ppsm are claimed
  without running `omarchohard install`.
- Desktop Office pauses its idle VM reliably. The pause ran inside the
  FreeRDP holder, so a holder that was killed first (a logout, a closed
  terminal) left Windows running, using about 4 GB of memory and 13% of a
  core. A user timer of its own now pauses the VM once nothing is connected.
- Word templates (`.dot`), macro-enabled Excel templates (`.xltm`),
  macro-enabled PowerPoint slide shows (`.ppsm`) and macro-enabled
  PowerPoint templates (`.potm`) now open in Office from Files.

## [0.3.0] - 2026-11-12

### Added

- Desktop Office prints to your Linux printers. omarchohard's RDP
  connections pass FreeRDP's `/printer`, so each CUPS printer shows in
  Windows as `NAME (redirected N)`; a new `winapps.conf` has it in
  `RDP_FLAGS` too, for WinApps' own launches. On the test VM, pages from PowerShell's
  `Out-Printer` and from Word reached a CUPS queue; with no CUPS server the
  connection still opens and Windows lists no redirected printers.
- The README's Sign-in section says what each tier needs: one browser
  sign-in covers every web app and one Office sign-in covers every desktop
  app. It also says what Windows' "Stay signed in to all your apps" prompt
  does. Tests now fail if a web app gets its own browser profile or if
  `desktop slim` touches Office's sign-in.

### Fixed

- An Office app or file opened right after the hidden connection had
  dropped without a sign-out could open nothing while the command reported
  success. Windows reconnected the old session, which does not run the
  start command again. The request now waits in the agent's queue too, so
  the reconnected agent runs it, and when nothing takes it within 5 seconds
  WinApps opens it.

## [0.2.0] - 2026-11-12

### Added

- `omarchohard desktop slim` shrinks the Windows VM's disk: apps for home
  use, Wi-Fi drivers, Windows Update's download cache, reserved storage and
  superseded update files go, Office's program files are compressed, and the
  freed blocks are trimmed so the image on Linux shrinks. The first boot
  runs it once Office is in. The test VM went from 21 GB to 15 GB with no
  slower Word start.
- Desktop Office opens through a warm agent: one hidden RDP connection
  stays open and a PowerShell agent in the Windows session starts each app
  from a request file, with no new connection per launch. A Word file opens
  in 1.2 s instead of 2.1 s, and in 0.24 to 0.33 s once the agent keeps
  Word, Excel and PowerPoint warm (after Office is signed in). Paths with
  commas open now. `desktop_agent=off` and `desktop_warm=` in the config
  turn each off.
- `omarchohard desktop open APP [FILE...]` opens desktop Office whatever
  `open_with` says. WinApps' own launcher entries now point at it.
- Desktop Office draws at the monitor's scale (`/scale-desktop:160` on a 1.6
  screen) instead of a fixed 100, which drew it at about 60 percent size on
  HiDPI screens.

- Setup asks which Office you want: desktop Office (the real Windows apps in
  a Windows VM) or the web apps, and recommends desktop Office only when
  `desktop check` passes. `setup --tier desktop|web` for scripts; `--yes`
  without `--tier` stays `web`. Desktop runs `desktop install --wait` and
  still sets up the web apps, for Teams. `probe` reports `recommend.tier`,
  `desktop_installed` and `config.open_with`.
- `omarchohard desktop status [--json]` reports the install phase, from
  downloading Windows to ready, and `desktop install --wait` and
  `desktop wait` follow it for up to 90 minutes, then add the Office apps to
  the launcher and turn `prefer on`. Ctrl-C stops the watching, not the VM.
  The Office install in Windows writes `office-status.json` to the inbox.
- `omarchohard open --app word` (and the other Office apps) raises an open
  desktop Office window or starts it, when the desktop tier is preferred.
- `omarchohard desktop run FILE` opens a file in Windows, such as an Office
  add-in, with FreeRDP reading the password from standard input. An Open in
  Windows entry handles `.xll`, `.xlam`, `.ppam`, `.dotm` and `.vsto` files.
- `omarchohard desktop update [--channel current|monthly|semi-annual]
  [--to VERSION]` updates Office now and starts a Windows Update scan, and
  `omarchohard update` points to it.
- `omarchohard doctor` checks the VM, the install phase, RDP, the Office
  version and channel, the WinApps launchers and `open_with`.
- Hyprland window rules for desktop Office in `~/.config/hypr/omarchohard.lua`,
  loaded by one guarded line in `hyprland.lua` that uninstall removes:
  documents are opaque and the RemoteApp marker window is hidden. Doctor
  warns when Hyprland uses `hyprland.conf`.

### Changed

- New desktop VMs keep their disk in `~/.local/share/omarchohard/vm/storage`
  with copy-on-write off on btrfs, instead of a Docker volume. Existing VMs
  keep their volume. `desktop remove --delete-vm` deletes the folder.
- The dockur/windows image is pinned to `6.06` instead of `latest`.
- Office in the VM installs with updates on, on the chosen channel, and the
  install fails loudly when Office's installer does.
- The first boot of the VM signs out of the Windows console after Office
  installs and turns automatic sign-in off, so RemoteApp no longer shows
  "Another user is signed in". When WinApps cannot connect, `desktop wait`
  and `desktop apps` say to sign out once.
- WinApps' TimeSync task and the inbox task run through
  `conhost.exe --headless`, with no window at sign-in.
- Launch-or-focus finds desktop Office windows by title, as FreeRDP gives
  all windows of the session the class of its newest connection.
- WinApps, its setup and FreeRDP run with `KRB5_CONFIG=/dev/null`, skipping a
  failing Kerberos attempt on each connection.
- The README leads with desktop Office and keeps the web apps as the light
  option.

### Fixed

- `desktop update` and `desktop activate` reach Windows. Windows kept a cached
  listing of the shared inbox folder and never saw a request written from
  Linux; the first boot now turns the SMB client cache off.
- `desktop status` counts RDP as up only when Windows answers an RDP
  connection request, not when Docker's port proxy accepts a connection.
- Launch-or-focus and the Hyprland rules match windows titled with the full
  app name, such as `Budget.xlsx - Microsoft Excel`, as RemoteApp shows them.
- `desktop activate --status` reports Microsoft 365 by its version and
  channel instead of "not installed".
- Setup's "Open Word now?" opens desktop Word when desktop Office is chosen.
- The first boot removes the plain-text password automatic sign-in left in
  the registry, and turns hibernation off, which saves several GB of disk.

## [0.1.1] - 2026-11-11

### Fixed

- `setup --prewarm off`, the default in the one-line install, no longer stops
  with "Failed to connect to user scope bus" where no systemd user manager
  runs, such as a container or a fresh SSH session.

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
  Office Home 2024 (`Home2024Retail`) and Home & Business 2024
  (`HomeBusiness2024Retail`) are supported editions.
- `omarchohard setup`: a five-step guided setup (browser, account, apps,
  sign-in, OneDrive) that the one-line installer starts from a terminal, and
  a Microsoft 365 Setup launcher that opens it in a floating terminal.
  `--yes` and answer flags run it with no questions.
- `omarchohard probe [--json]` and `optimize [--apply]`: what this device has,
  what omarchohard recommends for it, and applying it (cache size, prewarm).
- `omarchohard share [--link] [--edit] [--anyone|--org]`: share by name in the
  app, or copy a OneDrive link; Files right-click scripts for the same.
- `omarchohard add` and `remove`, and `install --apps`, to choose which apps
  are installed, Teams included.
- `omarchohard onedrive sync` and a live upload queue in `onedrive status`,
  through the rclone mount's private control socket.
- `omarchohard addins`: where Office Add-ins live in the web apps.
- Faster launches: app lookups stay in bash, the browser is cached until your
  default changes, and apps start with setsid rather than uwsm-app.
  `open --app word` takes 18 ms before the browser starts.

[Unreleased]: https://github.com/baney75/omarchohard/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/baney75/omarchohard/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/baney75/omarchohard/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/baney75/omarchohard/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/baney75/omarchohard/releases/tag/v0.1.0
