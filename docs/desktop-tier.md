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

## Requirements

| Need | Minimum | Checked by `desktop check` |
| --- | --- | --- |
| Hardware virtualization | `/dev/kvm` readable and writable (virtualization on in firmware, you in the `kvm` group) | Yes |
| Container engine | Docker (`omarchy install docker`) or Podman | Yes |
| FreeRDP 3 | `xfreerdp3`, `xfreerdp` or `sdl-freerdp3` (`omarchy pkg add freerdp`) | Yes |
| Memory | 16 GiB total; 6 GiB free when you start (the VM takes 4 GiB) | Yes |
| Disk | About 80 GB free in your home folder | Yes |

`omarchohard desktop install` runs the same checks and stops if one fails;
`--force` continues anyway.

## Install

```sh
omarchohard desktop check
omarchohard desktop install                    # Windows 11 evaluation + Microsoft 365
omarchohard desktop install --windows 11 --office 2024
```

| Option | Values | Default |
| --- | --- | --- |
| `--windows` | `11e`: Windows 11 Enterprise, free 90-day evaluation. `11`: Windows 11, activate with your own license. (`10e` and `10` also work.) | `11e` |
| `--office` | `m365` (Microsoft 365 Apps for enterprise, for school and work accounts), `m365-home` (Microsoft 365 Personal or Family), `2024` (Office Professional Plus 2024, ODT id `ProPlus2024Retail`), `home2024` (Office Home 2024, ODT id `HomeStudent2024Retail`, not yet confirmed against Microsoft's product list), `2021` (Office Professional Plus 2021) | `m365` |
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
Office opens files under `~` and `/run/media`.

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
4. A scheduled task in Windows checks the inbox once a minute. It deletes the
   request before acting on it, applies the key with `OSPP.VBS` (Office) or
   `slmgr` (Windows), and writes a result file with the key replaced by
   `*****`.
5. omarchohard waits up to 3 minutes, prints the result, and deletes both the
   request and the result.

## Remove

```sh
omarchohard desktop remove              # stop the VM; keep its disk
omarchohard desktop remove --delete-vm  # delete the VM disk (asks you to type DELETE)
```

WinApps launchers come out with
`~/.local/share/omarchohard/winapps/setup.sh --user --uninstall`.

## Licensing

You need a valid license for what you run: the Windows evaluation is for
evaluation use, and Office needs a subscription or a bought key. omarchohard
does not supply, bypass or share licenses.
