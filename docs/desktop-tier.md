# Desktop tier (experimental)

**Status: experimental and untested.** Every command below exists and is
linted, but the tier has not been run end to end. On the test laptop,
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

```sh
omarchohard desktop check
omarchohard desktop install                    # Windows 11 evaluation + Microsoft 365
omarchohard desktop install --windows 11 --office 2024
```

| Option | Values | Default |
| --- | --- | --- |
| `--windows` | `11e`: Windows 11 Enterprise, free 90-day evaluation. `11`: Windows 11, activate with your own license. (`10e` and `10` also work.) | `11e` |
| `--office` | `m365` (Microsoft 365 Apps for enterprise, for school and work accounts), `m365-home` (Microsoft 365 Personal or Family), `2024` (Office Professional Plus 2024, ODT id `ProPlus2024Retail`), `home2024` (Office Home 2024, ODT id `Home2024Retail`), `homebusiness2024` (Office Home & Business 2024, ODT id `HomeBusiness2024Retail`), `2021` (Office Professional Plus 2021) | `m365` |
| `--ram` | VM memory, such as `4G` or `6G` | `4G` |

Windows installs itself in 20 to 40 minutes; watch it at
<http://127.0.0.1:8006>. Office installs right after Windows. Then:

```sh
omarchohard desktop apps         # WinApps scans the VM; choose the Office apps
omarchohard desktop prefer on    # local Office files open in desktop Office
omarchohard desktop up | down    # start or stop the VM
```

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

WinApps launchers come out with
`~/.local/share/omarchohard/winapps/setup.sh --user --uninstall`.

`omarchohard uninstall --purge` leaves the VM in place and says so; remove
it with `omarchohard desktop remove --delete-vm`.

## Licensing

You need a valid license for what you run: the Windows evaluation is for
evaluation use, and Office needs a subscription or a bought key. omarchohard
does not supply, bypass or share licenses.
