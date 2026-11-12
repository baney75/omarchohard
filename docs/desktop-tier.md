# Desktop tier (experimental)

**Status: experimental and untested.** Every command below exists and is
linted and tested against stub Docker and FreeRDP, but the tier has not been
run end to end. End-to-end run in progress. On the test laptop,
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

The image is pinned to `ghcr.io/dockur/windows:6.06`.

VMs installed before 0.2.0 also keep their old first-boot scripts in
`C:\OEM`. Those do not write `office-status.json` and do not know the
update requests, so `desktop status` falls back to the log and the launchers,
and `desktop update` answers "unknown action". `desktop remove --delete-vm`
and a new install bring the new scripts.

## Using desktop Office

- `omarchohard open --app word` (and `excel`, `powerpoint`, `outlook`,
  `onenote`) raises the open window of that app, found by its window class
  (`Microsoft Word` and so on) through `hyprctl`, or starts it through
  WinApps. With a file it always opens the file. Teams stays a web app.
- `omarchohard desktop run FILE` opens any file in Windows with the program
  Windows picks: an add-in (`.xll`, `.xlam`, `.ppam`, `.dotm`, `.vsto`), an
  installer or a document. It runs `explorer.exe` as a RemoteApp on the file's
  `\\tsclient\home` path. Files must be under your home folder or
  `/run/media`, and names with control characters are refused. The
  connection details come from `~/.config/winapps/winapps.conf`, read as text
  and never run, and FreeRDP reads the password from standard input
  (`/from-stdin:force`), so it is never on the command line.
- The desktop tier adds an **Open in Windows** entry to Open With for those
  add-in types. It is hidden from the launcher, and uninstall removes it.
- WinApps' own launchers pass the RDP password to FreeRDP on its command
  line (`/p:`), where other processes of your user can read it. That is
  WinApps' code, pinned at `0b950dc`, not omarchohard's. WinApps' setup also
  updates its own copy from git, so it may run a newer WinApps than the pin.

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
