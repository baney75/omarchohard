# Desktop tier (experimental)

**Status: experimental and untested.** Every command below exists and is
linted and tested against stub Docker and FreeRDP, but the tier has not been
run end to end. End-to-end run in progress: on one machine, Word and Excel
opened as RemoteApp windows (see [Measured](#measured)). On the test laptop,
it was not run because the machine had about 7 GiB free of 31 GiB with 25 GiB
of swap in use; the preflight refuses below 6 GiB free. Expect rough edges,
and keep anything you care about in OneDrive.

Microsoft ships no native Linux desktop Office. The desktop tier runs real
Microsoft Office in a Windows virtual machine and shows each Office app as its
own Linux window:

- [dockur/windows](https://github.com/dockur/windows) installs and runs
  Windows in a Docker or Podman container with KVM.
- [WinApps](https://github.com/winapps-org/winapps) (pinned to commit
  `0b950dc`) shows each Windows app as a Linux window through FreeRDP
  RemoteApp and adds them to the launcher.
- omarchohard writes the VM definition, the first-boot scripts that install
  Office from Microsoft's CDN, and the activation inbox.

Word, Excel, PowerPoint, Outlook and OneNote work this way. Teams stays in the
web app.

> **The Windows VM can read your whole home folder.** dockur/windows shares
> `~` with the VM, and a scheduled task runs there as SYSTEM every minute.
> Anything in Windows (Office, an add-in, a macro in a document you open,
> malware) can read every file under `~`, including
> `~/.config/rclone/rclone.conf` (your OneDrive sign-in), browser profiles
> with their cookies, `~/.ssh` and `~/.config/winapps/winapps.conf`.
> Only use the desktop tier on a machine where that is acceptable.
>
> To limit it, stop the VM (`omarchohard desktop down`), edit
> `~/.local/share/omarchohard/vm/compose.yaml` and change `- ${HOME}:/shared`
> to a folder that holds only what Windows should see, for example
> `- ${HOME}/WindowsShare:/shared`, then start it again
> (`omarchohard desktop up`). Desktop Office can then open only files in that
> folder, and `omarchohard desktop activate` stops working, because its inbox
> is under `~/.local/share`; enter a product key inside Windows instead.
> `omarchohard desktop install` rewrites `compose.yaml`, so make the change
> again after running it.

## Requirements

| Need | Minimum | Checked by `desktop check` |
| --- | --- | --- |
| Hardware virtualization | `/dev/kvm` readable and writable (virtualization on in firmware, you in the `kvm` group) | Yes |
| Container engine | Docker (`omarchy install docker`) or Podman | Yes |
| FreeRDP 3 | `xfreerdp3`, `xfreerdp` or `sdl-freerdp3` (`omarchy pkg add freerdp`) | Yes |
| Memory | 16 GiB total; 6 GiB free when you start (the VM takes 4 GiB) | Yes |
| Disk | About 80 GB free in your home folder | Yes |

`omarchohard desktop install` runs the same checks and stops if one fails;
`--force` continues anyway. A 16 GB machine passes the memory check: the
kernel keeps some memory back, so the check accepts 15 GiB or more.

## Install

The simple way is setup, which asks which Office you want and recommends
desktop Office only when `desktop check` passes:

```sh
omarchohard setup                    # step 1 asks: desktop Office or the web apps
omarchohard setup --yes --tier desktop
```

`--tier desktop` runs `desktop install --wait` after the other steps and still
sets up the web apps, for Teams. `--yes` without `--tier` means `web`. If the
desktop install does not finish, setup says so and exits 1; the web apps work
meanwhile.

By hand:

```sh
omarchohard desktop check
omarchohard desktop install --wait             # Windows 11 evaluation + Microsoft 365
omarchohard desktop install --windows 11 --office 2024
```

| Option | Values | Default |
| --- | --- | --- |
| `--windows` | `11e`: Windows 11 Enterprise, free 90-day evaluation. `11`: Windows 11, activate with your own license. (`10e` and `10` also work.) | `11e` |
| `--office` | `m365` (Microsoft 365 Apps for enterprise, for school and work accounts), `m365-home` (Microsoft 365 Personal or Family), `2024` (Office Professional Plus 2024, ODT id `ProPlus2024Retail`), `home2024` (Office Home 2024, ODT id `Home2024Retail`), `homebusiness2024` (Office Home & Business 2024, ODT id `HomeBusiness2024Retail`), `2021` (Office Professional Plus 2021) | `m365` |
| `--ram` | VM memory, such as `4G` or `6G` | `4G` |

The whole install takes about 45 minutes: Windows installs itself in 20 to
40, then Office installs. Watch the Windows screen at <http://127.0.0.1:8006>
if you like.

### Office download during Windows Setup

On the test VM (2026-11-12, Windows image already downloaded), Windows Setup
took about 3.5 minutes and Office about 12 of the 15.5-minute install, nearly
all of it downloading from Microsoft's CDN, while the network sat idle during
Setup. So when `desktop install` starts a new VM, it also starts a download of
Office's install files on this machine, in a user service
(`omarchohard-office-prefetch`) that keeps going after the command ends:

- The files go to `~/.local/share/omarchohard/vm/office-src`, which Windows
  reads as `\\host.lan\Data\.local\share\omarchohard\vm\office-src`
  (`C:\OEM\office-source.txt` names it). They are the Office Deployment
  Tool's local source for the current version of the Current channel, in
  English: about 3.2 GB, the biggest file in 8 byte ranges at once, since the
  CDN gives one connection a few MB/s. Each file must come to the size the
  CDN gives for it.
- The folder holds `progress` (rewritten as bytes arrive), then `ready` with
  the version, or `failed` with the reason. `prefetch.log` has each step.
- A complete copy of the current version is used again by a later run; an
  older version is deleted. Once Windows reports Office installed, the next
  `desktop status`, `wait` or `doctor` deletes the folder, so the 3.2 GB do
  not stay on disk.
- In Windows, `office.ps1` waits for `ready` while the copy's files keep
  growing (it reads their sizes from a folder listing, since Windows caches a
  file it read over the share and never sees the host rewrite it),
  then installs from the copy (`SourcePath`, with `AllowCdnFallback` for any
  file the copy lacks). It goes to the CDN instead when the host writes
  `failed` or the files have not grown for 2 minutes, and when setup.exe
  fails with the copy it runs once more from the CDN, so a bad copy never
  fails the install. `C:\OEM\office.log` says which source it used.
- Without `curl`, `bsdtar` (libarchive) or `flock`, there is no download and
  Office comes from the CDN as before. A VM whose disk already exists gets
  none either, as Windows runs the first-boot scripts only once.

dockur also downloads the Windows image over 16 connections
(`CONNECTIONS: "16"` in `compose.yaml`; its default is 4).

### Progress

`omarchohard desktop status` (or `--json`) names the phase:

| Phase | Meaning |
| --- | --- |
| `not-installed` | No VM yet |
| `downloading-windows` | dockur is downloading or checking the Windows image |
| `installing-windows` | Windows Setup is running in the VM |
| `installing-office` | Windows is up and the Office installer runs |
| `starting` | Office is installed, RDP does not answer yet |
| `ready` | Office is installed and RDP answers |
| `failed` | Windows or Office stopped with an error (in `detail`) |
| `stopped`, `paused` | The VM is not running, or is paused |

The phase comes from the container state, the dockur log, a check of the RDP
port and `office-status.json`, which the Office install script in Windows
writes to the inbox with the phase, product, version, channel and any error.
An open RDP port alone never counts as ready: the container engine can accept
connections before Windows does.

`install --wait` prints each change of phase. It stops after 90 minutes, and
Ctrl-C stops only the watching; the VM keeps going. Pick it up again with
`omarchohard desktop wait`. When Office is ready it runs WinApps' setup for
the officially supported apps, which adds Word, Excel, PowerPoint, Outlook and
OneNote to the launcher, and turns `prefer on`. Without `--wait`, run
`omarchohard desktop wait` later, or by hand:

```sh
omarchohard desktop apps         # WinApps scans the VM; choose the Office apps
omarchohard desktop prefer on    # local Office files open in desktop Office
omarchohard desktop up | down    # start or stop the VM
```

### Storage

The VM disk lives in `~/.local/share/omarchohard/vm/storage`, a plain folder,
so `desktop remove --delete-vm` can find it and backups can skip it. On btrfs
the install turns off copy-on-write for that folder (`chattr +C`) before the
first start, because a copy-on-write disk image fragments and Windows Setup
can fail on it. If `chattr` fails, the install warns and goes on. VMs
installed before 0.2.0 keep their Docker volume (`data`); the install
detects the old `compose.yaml` and leaves it in place.

Without copy-on-write, btrfs does not compress the image either. Once
Windows is set up, `omarchohard desktop compress` stops the VM, rewrites the
image as a copy-on-write file btrfs keeps zstd-compressed, and starts the VM
again. On the test VM (2026-11-12) the image's 13 GB of data took 7.5 GB on
disk afterward, and the copy took 45 seconds. A new VM does it by itself,
once: Windows writes `slim-done` to the inbox when the first boot's cleanup
(DISM, about 8 minutes) has ended, and the next idle pause compresses the
disk instead of pausing the VM. An app opened during the copy starts the VM
again, and the disk stays as it was: run `omarchohard desktop compress`
later. The copy
needs free space for one more copy of the image, and running it again does
nothing.

The image is pinned to `ghcr.io/dockur/windows:6.06`.

VMs installed before 0.2.0 also keep their old first-boot scripts in
`C:\OEM`. Those do not write `office-status.json` and do not know the
update requests, so `desktop status` falls back to the log and the launchers,
and `desktop update` answers "unknown action". `desktop remove --delete-vm`
and a new install bring the new scripts.

## Using desktop Office

- `omarchohard open --app word` (and `excel`, `powerpoint`, `outlook`,
  `onenote`) raises the open window of that app through `hyprctl`, or starts
  it through the agent (below). With a file it always opens the file.
  `omarchohard desktop open APP [FILE...]` does the same whatever
  `open_with` says; WinApps' own launcher entries are pointed at it. Teams stays a web
  app. Windows are found by title (`Report.docx - Word`, or `Microsoft Word`
  with no document; Outlook and OneNote titles end in `Outlook` and
  `OneNote`), not by class: each new RemoteApp connection gives every window
  of the Windows session its own class, so after Excel opens, Word's window
  has the class `Microsoft Excel` too.
- **Hyprland rules.** With Omarchy's Lua config, adding the apps writes
  `~/.config/hypr/omarchohard.lua` and appends one line to
  `~/.config/hypr/hyprland.lua`:
  `pcall(dofile, os.getenv("HOME") .. "/.config/hypr/omarchohard.lua") -- omarchohard`.
  The rules keep Office windows opaque (`tag = "-default-opacity"`,
  `opacity = "1 1"`) and send the `RemoteApp Marker Window` to the hidden
  workspace `special:omarchohard` without focus. No other line changes, and
  uninstall and `desktop remove` take out exactly that line and the file. With
  the older `hyprland.conf`, nothing is written and doctor warns.
- **Sign-in.** Desktop Office signs in once in Office's own window: an
  unlicensed Microsoft 365 opens "Sign in to get started with Word", and
  "Sign in or create account" opens Microsoft's sign-in page as a RemoteApp
  window of its own. Every Office app runs as the one Windows user, so they
  share the account through Windows' Web Account Manager (the `TokenBroker`
  service and the `Microsoft.AAD.BrokerPlugin` package), and one sign-in
  activates them all. On the test VM (2026-11-12) both services ran, the
  broker packages were installed, and the sign-in page opened with
  dockur's default of UAC off. `desktop slim` removes none of them. The web
  apps sign in through your default browser.
- omarchohard starts WinApps, its setup and FreeRDP with `KRB5_CONFIG=/dev/null`
  in their environment only. FreeRDP otherwise tries Kerberos first with
  Arch's example `/etc/krb5.conf`, which fails, costs about 0.1 s and prints
  errors, before it falls back to NTLM.
- `omarchohard desktop run FILE` opens any file in Windows with the program
  Windows picks: an add-in (`.xll`, `.xlam`, `.ppam`, `.dotm`, `.vsto`), an
  installer or a document, through the agent, or without it as an
  `explorer.exe` RemoteApp on the file's `\\tsclient\home` path. Files must be under your home folder or
  `/run/media`, and names with control characters are refused. The
  connection details come from `~/.config/winapps/winapps.conf`, read as text
  and never run, and FreeRDP reads the password from standard input
  (`/from-stdin:force`), so it is never on the command line.
- **The agent.** A new RDP connection per launch costs about a second
  before Windows starts the app. So omarchohard keeps one hidden FreeRDP
  RemoteApp connection, the holder, running `agent.ps1` in the Windows
  session. A launch writes one request line to
  `~/.local/state/omarchohard/agent` (a 0700 folder); the agent reads it
  over the RDP drive within 0.1 s, starts the app, and the window comes
  through the same connection. The first launch starts the holder with a
  `first.cmd` that starts the app and then the agent, so it costs no more
  than a WinApps launch. The agent is read from
  `~/.local/share/omarchohard/vm/agent.ps1` on each start, so an update
  needs nothing installed in Windows. It accepts only Office apps, files
  under `\\tsclient\home` or `\\tsclient\media`, and `ms-word:`,
  `ms-excel:`, `ms-powerpoint:` and `onenote:` links. It exits after 15
  minutes with no request and no Office window, and the holder then pauses
  the VM after WinApps' `AUTOPAUSE_TIME`. `desktop_agent=off` in
  `~/.config/omarchohard/config` goes back to WinApps for every launch.
- **Warm apps.** Once Office is signed in, the agent starts Word, Excel and
  PowerPoint hidden, so opening a file is a new window in an app that is
  already running. They hold about 650 MB of the VM's memory. Set the list
  with `desktop_warm=word,excel` in the config, or turn it off with
  `desktop_warm=`.
- **HiDPI.** Omarchy draws XWayland windows at the monitor's own pixels
  (`xwayland:force_zero_scaling`), so Windows scales itself: the holder
  passes the focused monitor's scale (`/scale-desktop:160` at 1.6) and keeps
  `RDP_SCALE` in `winapps.conf` the same for WinApps launches.
- **Printing.** A new `winapps.conf` has FreeRDP's `/printer` in
  `RDP_FLAGS`, so WinApps' own launches pass it. The holder adds it when an
  older `winapps.conf` lacks it, and the `desktop run` fallback always
  passes it. FreeRDP 3 asks CUPS for its printers and Windows
  shows each one as `NAME (redirected N)` with the `MS Publisher
  Imagesetter` driver, which sends PostScript to the CUPS queue. Measured on
  the test VM (2026-11-12, FreeRDP 3.33.1, CUPS 2.4): `Get-Printer` listed
  the redirected printer about 3 s after the session started, and pages from
  `Out-Printer` and from Word's `PrintOut` arrived in CUPS as
  `application/postscript`; the spooled pages held the printed text. With
  no CUPS server reachable, the connection opened as usual and Windows
  listed only its own printers. libcups finds the server the usual way
  (`CUPS_SERVER`, `client.conf`, `/run/cups/cups.sock`, then
  `localhost:631`).
- **Clipboard.** The holder passes `+clipboard`. Measured in a nested
  Hyprland session (2026-11-12): `Set-Clipboard` in Windows showed in both
  `wl-paste` and `xclip` within 2 s, and text set with `xclip` reached
  `Get-Clipboard` in Windows. Text set with `wl-copy` did not: the
  XWayland clipboard owner offered no formats, so FreeRDP had none to send.
  That may be the nested session; it is untested on a real Omarchy desktop.
- **Macros.** omarchohard changes no macro setting. A `.docm` with an
  `AutoOpen` macro, opened with `omarchohard open` from `~/Documents`, showed
  Word's yellow "Macros have been disabled" bar with **Enable Content**
  (Word's default, "Disable VBA macros with notification"), and the macro
  did not run. Microsoft 365 was not signed in, and its "Sign in to get
  started with Word" window opened on top. To run a document's macros,
  choose Enable Content, or set a trusted location or the macro setting in
  Word's Trust Center in Windows. With Word's macro setting at "Enable all
  macros" (`VBAWarnings=1`, set for the test and removed after), the same
  document's `AutoOpen` macro ran 2 s after `omarchohard open`.
- The desktop tier adds an **Open in Windows** entry to Open With for those
  add-in types. It is hidden from the launcher, and uninstall removes it.
- WinApps' own launchers pass the RDP password to FreeRDP on its command
  line (`/p:`), where other processes of your user can read it. That is
  WinApps' code, pinned at `0b950dc`, not omarchohard's. WinApps' setup also
  updates its own copy from git, so it may run a newer WinApps than the pin.

### First boot

After Windows Setup, dockur runs `C:\OEM\install.bat` in the session it signs
in automatically. The script runs WinApps' setup, then recreates WinApps'
`TimeSync` sign-in task and creates the `omarchohard-inbox` task through
`conhost.exe --headless`, because Windows 11's default terminal ignores
`-WindowStyle Hidden` and would show an "Administrator: powershell.exe"
window. It installs Office, which writes `installed` to
`office-status.json`, then turns automatic sign-in off (`AutoAdminLogon` =
`0`), writes `ready` and signs out of the console. When the VM stops before
that, the inbox task finishes those steps on the next boot. While the console session is open, a RemoteApp shows "Another
user is signed in" instead of the app, and WinApps' setup stops with
"REMOTE DESKTOP PROTOCOL FAILURE" (exit 14). For a VM installed before this,
sign out of Windows once at <http://127.0.0.1:8006> (Start, your name, Sign
out); `desktop wait` and `desktop apps` say so when WinApps exits 14.

### Measured

Measured on one machine (Parish1, 2026-11-12: dockur 6.06, Windows 11
Enterprise evaluation, Microsoft 365 Apps 16.0.20527, FreeRDP 3, Hyprland
0.57), from the command to the window on screen:

| Opening | WinApps, a connection each | Agent | Agent, app warm |
| --- | --- | --- | --- |
| Excel with a file, nothing running | 2.1 s | 2.0 to 2.2 s | |
| Word with a file | 2.1 s | 1.2 to 1.3 s | 0.24 to 0.33 s |
| PowerPoint with a file | 2.3 s | 1.0 to 1.5 s | 0.59 to 0.63 s |
| Excel with a file | | | 0.78 s |
| A new window of a running app | | 0.46 to 0.58 s | |
| A window already open | | 0.03 s (focus) | |

The VM used 3.4 GiB of memory. These are numbers from one machine, not a
promise.

### Disk size

The disk image is sparse: it is 80 GB at most, and holds only what Windows
has written. On the test VM it grew to 21 GB in its first day, most of it
update downloads that Windows keeps. `omarchohard desktop slim` takes it
down and the first boot runs it once Office is in:

- apps Windows ships for home use go: games, Xbox, news, weather, maps,
  Bing search, Copilot, Cortana, Dev Home, Power Automate, Phone Link, Quick
  Assist, Get Help, Tips, Feedback Hub, alarms, camera, sound recorder,
  Media Player, Movies & TV, the Microsoft 365 hub app, widgets, cross-device, personal Teams, the new Outlook,
  Photos and the Snipping Tool. Office, the new Teams, the Store, Notepad,
  Paint, the calculator, the terminal and Windows Security stay, and so do
  Sticky Notes, To Do, Clipchamp and People, which can keep notes and
  projects only on the VM;
- Wi-Fi and face sign-in drivers go; speech, text to speech, handwriting
  and OCR stay for Dictate, Read Aloud and ink;
- Windows Update's download cache is cleared and kept under 1 GB;
- reserved storage is turned off and superseded update files are removed
  (`DISM /StartComponentCleanup /ResetBase`, so installed updates can no
  longer be uninstalled);
- Office's program files are compressed (4.92 GB into 2.53 GB);
- the freed blocks are trimmed, so the image on Linux shrinks too.

Measured on the test VM (2026-11-12): 21 GB before, 15 GB after, in about
8 minutes. A cold Word open after a VM boot took 4.95 to 5.25 s after
compression against 5.03 to 5.33 s before, so compression did not slow it.
Run it again after big Windows or Office updates; Office's updater writes
new files uncompressed. Temp files newer than a day stay, so a document open
in Office keeps its working files.

## Updates

Office updates itself in the background; the install configures Office's
updates on with the channel it installed. To update now:

```sh
omarchohard desktop update                         # Office now, plus a Windows Update scan
omarchohard desktop update --channel monthly       # current, monthly or semi-annual
omarchohard desktop update --to 16.0.19127.20000   # a specific version
```

The request goes through the inbox. Windows checks the channel and version
against its own allowlist again, runs `OfficeC2RClient.exe /update user` (and
`/changesetting Channel=...` for a channel), and starts
`UsoClient StartInteractiveScan` for Windows Update. The result shows the
version and channel and never contains a key. `omarchohard update` prints a
one-line reminder of this command, and `omarchohard doctor` shows the Office
version and channel.

The VM listens on 127.0.0.1 only (8006 for the web viewer, 3389 for RDP).
Its Windows account is local, with a random 20-character password stored in
`~/.config/winapps/winapps.conf` and `~/.local/share/omarchohard/vm/compose.yaml`,
both mode 0600. Your home folder is shared with the VM, which is how desktop
Office opens files under `~` and `/run/media` (see the warning above).

The Office installer (`setup.exe`, downloaded from Microsoft's CDN in the VM)
runs only when its Authenticode signature is valid and signed by Microsoft
Corporation; otherwise the install stops and `C:\OEM\office.log` says why.

Office links from SharePoint and Teams ("Open in app", `ms-word:` and the
like) still open in the web app with `prefer on`: WinApps starts desktop
Office without the document.

## Activation and product keys

- **Microsoft 365** (`m365`, `m365-home`) activates by signing in: open Word
  from the launcher and sign in with the account that has the subscription.
  No key is needed.
- **Office 2021 or 2024** bought with a key:
  `omarchohard desktop activate` (hidden prompt) or
  `omarchohard desktop activate --key-file ~/office-key.txt`.
- **Windows**: `omarchohard desktop activate --windows` (hidden prompt) or
  `--windows-key-file FILE`. The `11e` evaluation needs no key for 90 days.
- `omarchohard desktop activate --status` shows Windows and Office activation
  state.

### How keys are handled

1. The key is read from a hidden prompt or a file you name. It is never taken
   from the command line (where it would land in shell history and process
   lists), never written to the config, and never logged.
2. It must look like a product key: 25 letters and digits in five groups of
   five.
3. omarchohard writes a one-shot request file, mode 0600, in
   `~/.local/share/omarchohard/vm-inbox` (mode 0700), which the VM sees
   through the shared home folder.
   The request is written by the shell itself, so no process (on the host or
   in Windows) ever has the key in its command line.
4. A scheduled task in Windows checks the inbox once a minute. It deletes the
   request before acting on it, installs the key through the Windows
   licensing service (`SoftwareLicensingService.InstallProductKey`, a method
   call, not `slmgr` or `OSPP.VBS` arguments), activates the product that
   key belongs to, and writes a result file with the license status and no
   key.
5. omarchohard waits up to 3 minutes, prints the result, and deletes both the
   request and the result. If you press Ctrl-C or the wait times out, the
   request file is deleted too.

## Remove

```sh
omarchohard desktop remove              # stop the VM; keep its disk
omarchohard desktop remove --delete-vm  # delete the VM disk (asks you to type DELETE)
```

`--delete-vm` deletes the storage folder as well. If Windows wrote files
there as root, it says to run `sudo rm -rf` on it. Both modes remove the
Open in Windows entry.

WinApps launchers come out with
`~/.local/share/omarchohard/winapps/setup.sh --user --uninstall`.

## Doctor

`omarchohard doctor` checks the VM state (a paused VM counts as fine), the
install phase, RDP, the Office version and channel, the WinApps launchers and
the `open_with` setting. RDP that does not answer is a warning while Windows
installs and a failure after that.

## Uninstall

`omarchohard uninstall --purge` leaves the VM in place and says so; remove
it with `omarchohard desktop remove --delete-vm`.

## Licensing

You need a valid license for what you run: the Windows evaluation is for
evaluation use, and Office needs a subscription or a bought key. omarchohard
does not supply, bypass or share licenses.
