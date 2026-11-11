# Architecture

omarchohard is about 1,850 lines of bash with no build step.

## Layout

| Path | Role |
| --- | --- |
| `bin/omarchohard` | Entry point: finds its root, sources the modules, dispatches commands |
| `lib/omarchohard/common.sh` | Paths, logging, dry run, the key=value config parser (parsed, never sourced), URL encoding |
| `lib/omarchohard/apps.sh` | The app table: id, name, URL, MIME types and URL schemes per app |
| `lib/omarchohard/browser.sh` | Browser detection, `--app` windows, launch-or-focus through `hyprctl`, prewarm |
| `lib/omarchohard/integrate.sh` | Desktop entries, icons, `xdg-mime` defaults with a backup, uninstall and restore |
| `lib/omarchohard/open.sh` | Routing of files, `mailto:`, `msteams:` and Office URI links |
| `lib/omarchohard/onedrive.sh` | rclone or abraunegg setup, the user service, OneDrive web addresses |
| `lib/omarchohard/release.sh` | Channels, `update`, checksum check, atomic release switch |
| `lib/omarchohard/doctor.sh` | Every check, text or JSON |
| `lib/omarchohard/desktop.sh` | The experimental Windows VM tier and key inbox |
| `share/omarchohard/icons/` | App icons |
| `share/omarchohard/vm/` | VM definition template and first-boot scripts |

The root is the folder above `bin/`, so the same code runs from a checkout,
from `~/.local/share/omarchohard/current`, or from `/usr` in the pacman
layout (`/usr/bin`, `/usr/lib/omarchohard`, `/usr/share/omarchohard`). The
version comes from `share/omarchohard/VERSION` in releases and packages and
from `VERSION` in a checkout.

## What it writes

| Path | What |
| --- | --- |
| `~/.local/share/applications/omarchohard-*.desktop` | One launcher per app; `Exec` runs `omarchohard open --app ID %U` |
| `~/.local/share/icons/hicolor/scalable/apps/omarchohard-*.svg` | Icons |
| `~/.config/mimeapps.list` | Default handlers, through `xdg-mime default` |
| `~/.config/omarchohard/config` | Settings, `key=value` |
| `~/.local/state/omarchohard/` | `manifest` (every file install wrote) and `mime-backup.tsv` (your handlers before install) |
| `~/.config/systemd/user/omarchohard-*.service` | OneDrive and prewarm services, when turned on |
| `~/.local/share/omarchohard/` | Releases, the isolated browser profile, the desktop tier |

Uninstall removes everything in the manifest, strips `omarchohard-*.desktop`
from `mimeapps.list` and puts back the handlers in the backup.

## Opening something

```
xdg-open file.docx
  -> mimeapps.list -> omarchohard-word.desktop
  -> omarchohard open --app word file.docx
     inside OneDrive?  -> <web root>/<encoded path>?web=1
     elsewhere?        -> copy to OneDrive/Omarchohard, wait for upload, open the copy
     desktop tier on?  -> winapps word-o365 file.docx
  -> Hyprland window with that class open?  focus it
     otherwise  browser --app=URL, detached with setsid (uwsm-app only with OMARCHOHARD_UWSM=1, as it adds 40 to 80 ms)
```

## Tests

- `tests/*.bats`: every test runs in its own HOME and XDG folders with stub
  `chromium`, `systemctl` and `hyprctl`; `OMARCHOHARD_DRY_RUN=1` prints
  commands instead of running them.
- `tests/container/`: a clean Arch Linux container for lint, bats, the
  installer over HTTP, a headless sway launch smoke with real Chromium, and
  the pacman package. `OMARCHOHARD_BROWSER_FLAGS` adds browser flags such as
  `--no-sandbox`; it exists for these tests only.
