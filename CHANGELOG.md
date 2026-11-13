# Changelog

All notable changes to omarchohard are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Nightly and dev
builds are not listed; they carry the version of the next release plus a
`-nightly` or `-dev` suffix.

## [Unreleased]

### Added

- Native Office (experimental): `omarchohard setup --tier native` installs
  Microsoft 365's Word, Excel, PowerPoint, Outlook and OneNote on Linux
  itself under wine-altars v11.19-altars.1, a Wine fork, with no VM. The
  first device installs from Microsoft and keeps a seed, its Office from
  before sign-in; every other device copies a seed with `--from` (a file,
  `ssh:HOST`, an `https://` link, or a private `http://` link with
  `--sha256`): 21 s from a file and 32 s from a link on one machine.
  Word opened in 5.7 s cold and 1.0 s warm.
- `--plan personal|family|school|business|enterprise` picks the Office
  product, and a seed for another product is refused. `--shared-computer`
  turns on shared computer activation for school and enterprise plans.
- `omarchohard native signin --remote` shows only Office's sign-in window,
  as a page on the device's Tailscale name only (never a plain LAN) that
  fits a phone, in light or dark mode, behind a one-time password carried
  after `#` in the link, and prints the link last as `Sign in here: ...`.
- Native Office maps Segoe UI to Selawik, Microsoft's open-source stand-in
  (SIL OFL 1.1, shipped with omarchohard), so Office's text looks as meant.
- `omarchohard native seed serve` hands the seed to many devices at once,
  on one private address and a random path, for a set time.
- `setup --json` ends with one JSON line, `{"state":"ready"|"needs_signin"|"failed",
  "signin_url":...,"seconds":...}`. A native setup that is done reports
  `ready` on a rerun, and two at once on one device take turns.
- `probe` recommends `native` ahead of `desktop` on x86_64 Hyprland machines
  with 8 GB of memory and 8 GB free disk, and `open_with=native` opens local
  Office files in native Office.
- Setup asks which files open in Office: Microsoft Office files only (the
  default), or those plus other formats, all of them or the ones you pick
  (`.odt`, `.ods`, `.odp`, `.rtf`, `.csv`). Only formats of the apps you
  installed are offered.
- `omarchohard files` shows the choice; `omarchohard files microsoft|all|LIST`
  changes it, such as `omarchohard files odt,csv`. Formats you turn off go
  back to the app that had them before.
- `setup --files microsoft|all|LIST` answers the question without asking.
  `setup --yes` without it keeps the current choice.
- `omarchohard desktop compress` keeps the VM's disk image zstd-compressed on
  btrfs. It cut the image from 13 GB to 7.5 GB on disk on tiny11, and to
  12 GB on the stock Windows evaluation, whose files are already compressed
  inside Windows. The stop also lets dockur delete its 8.2 GB Windows image.
  A new VM runs it once by itself, at the first idle pause after Windows
  finishes its first-boot cleanup: the VM stops for about 45 seconds and
  starts again.
- `.csv` files can open in Excel (`omarchohard files csv`).
- `desktop install` downloads Office's install files on the host while
  Windows Setup runs, and Windows installs Office from that copy. On the test
  VM (tiny11, 2026-11-13) the install took 9.5 minutes instead of 15.5:
  Office took 5 minutes after Setup instead of 12. The copy is checked file
  by file against the CDN's sizes; when it fails or stops growing for 2
  minutes, Office installs from the CDN as before. On the stock path
  (2026-11-13, nothing cached) the whole install took 20 minutes, 8.6 of them
  downloading Windows; the docs said about 45. See docs/desktop-tier.md.

### Changed

- The desktop VM downloads the Windows image over 16 connections
  (dockur's `CONNECTIONS`), up from dockur's default of 4.
- OpenDocument (`.odt`, `.ods`, `.odp`) and Rich Text (`.rtf`) files no
  longer open in Office unless you choose them (`omarchohard files all`).
  The next install hands them back to the app that had them before.
- omarchohard has its own logo, the `omarchohard` icon. The Setup launcher,
  "Open in Windows" and notifications use it instead of the Microsoft 365
  icon.

### Fixed

- `desktop wait` and `desktop apps` on a reinstalled VM: WinApps refused to
  set up over its own earlier install, so no apps were added. When it does,
  that install is removed and setup runs again.
- The idle-pause timer gets this shell's folders even where they are left to
  their defaults; the user manager's own `XDG_*` folders were used instead.
- After a package update (AUR), the first open, launch or doctor sets the
  launchers again and claims the file types omarchohard never had, such as
  .ppsm, without running `omarchohard install`. A type you gave to another
  app stays with it.
- A double-click no longer opens nothing after Windows kept an old session
  without its agent. The agent stays while any window is open and signs its
  session out when it goes idle, so the next open starts a fresh one.
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
