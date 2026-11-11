# omarchohard

Microsoft 365 on [Omarchy](https://omarchy.org) (Arch Linux + Hyprland), set
up with one command: Word, Excel, PowerPoint, Outlook, OneNote, Teams and
OneDrive open as their own app windows, show up in the launcher with their
icons, and open your `.docx`, `.xlsx` and `.pptx` files, `mailto:` links and
Teams meeting links.

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash
omarchohard install
```

## What it is

- A bash CLI that turns the Microsoft 365 web apps into desktop apps. Each app
  is a Chromium `--app` window in your default Chromium-family browser
  profile, so one sign-in covers every app.
- Desktop entries, icons, file handlers and URL handlers (`mailto`, `msteams`,
  `ms-word`, `ms-excel`, `ms-powerpoint`, `onenote`), registered the
  freedesktop way and fully reversible.
- Launch-or-focus through `hyprctl`: opening Word when Word is open raises
  that window.
- OneDrive on disk, so files open from the Files app, through an rclone mount
  (default) or the abraunegg `onedrive` client.
- An experimental desktop tier that runs real Microsoft Office in a Windows VM.

## What it is not

- **Not native Office.** Microsoft ships no native Linux desktop version of
  Word, Excel, PowerPoint, Outlook or OneNote. omarchohard runs the web apps
  Microsoft hosts at `*.cloud.microsoft`; they need a network connection and
  a Microsoft account (personal, school or work). Features that exist only in
  desktop Office (some macros, add-ins, advanced mail merge) are not there.
- **Not a browser and not a sync engine.** It drives the browser you have and
  the OneDrive client you pick.
- **Not affiliated with Microsoft.** See the trademark notice at the end.

## Quick start

```sh
# 1. Install the CLI into ~/.local (stable channel)
curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash

# 2. Add the apps, icons and file handlers
omarchohard install

# 3. Sign in once (your school or work SSO page appears if you have one)
omarchohard login

# 4. Put OneDrive on disk so local files open in place
omarchohard onedrive setup

# Check everything at any time; exits 1 if a required check fails
omarchohard doctor
```

You need a Chromium-family browser (Chromium, Chrome, Edge, Brave, Helium or
Vivaldi). If you have none: `omarchy pkg add chromium`. Firefox cannot open
app windows; see [Firefox as default browser](docs/troubleshooting.md#firefox-as-default-browser).

Options for `omarchohard install`:

| Option | Effect |
| --- | --- |
| `--isolated` | Use a dedicated browser profile instead of your everyday one (separate sign-in) |
| `--no-mail` | Leave your current `mailto:` handler alone |
| `--prewarm` | Turn on the prewarm service (isolated profile only) |

## Supported apps

| App | Web address | Files and links it opens | Desktop tier |
| --- | --- | --- | --- |
| Word | `word.cloud.microsoft` | `.docx` `.doc` `.docm` `.dotx` `.dotm` `.rtf` `.odt`, `ms-word:` links | Yes |
| Excel | `excel.cloud.microsoft` | `.xlsx` `.xls` `.xlsm` `.xlsb` `.xltx` `.ods`, `ms-excel:` links | Yes |
| PowerPoint | `powerpoint.cloud.microsoft` | `.pptx` `.ppt` `.pptm` `.ppsx` `.potx` `.odp`, `ms-powerpoint:` links | Yes |
| Outlook | `outlook.cloud.microsoft/mail/` | `mailto:` links (skipped with `--no-mail`) | Yes |
| OneNote | `onenote.cloud.microsoft` | `onenote:` links | Yes |
| Teams | `teams.cloud.microsoft` | `msteams:` links (meetings, chats) | No, web only |
| OneDrive | `onedrive.cloud.microsoft` | None; files come to disk through `omarchohard onedrive setup` | No, web only |
| Microsoft 365 | `m365.cloud.microsoft` | None; the home page and Copilot | No, web only |

Launch any of them from the launcher, or with `omarchohard launch word`
(`excel`, `powerpoint`, `outlook`, `onenote`, `teams`, `onedrive`, `m365`).

## How files open

The web apps edit files that live in OneDrive, so where a file sits decides
what happens:

- **Inside your OneDrive folder** (`~/OneDrive` by default): the file opens in
  place at its OneDrive address. Edits save to that file, and the sync client
  brings them back to disk.
- **Anywhere else** (Downloads, a USB stick): omarchohard copies the file into
  `OneDrive/Omarchohard/`, waits up to 60 seconds for the upload, and opens
  the copy. Your original is never changed. A different file with the same
  name gets a numbered copy, such as `Report (1).docx`.
- **Before OneDrive is set up**: the app opens and a notification says to run
  `omarchohard onedrive setup`.
- **Desktop tier with `omarchohard desktop prefer on`**: local files open
  directly in desktop Office in the VM (files under your home folder or
  `/run/media`), with no copy.

In-place opening needs your OneDrive web address, the part up to and
including `/Documents`, for example
`https://school-my.sharepoint.com/personal/you_school_edu/Documents`.
`omarchohard onedrive setup` asks for it; set it later with
`omarchohard onedrive web-root URL`.

## How sync works

`omarchohard onedrive setup` sets up one of two clients as a systemd user
service, `omarchohard-onedrive.service`:

- **rclone (default)**: a FUSE mount at `~/OneDrive` with a full local cache
  (`--vfs-cache-mode full`, up to 20 GB, kept for a year). Every file is
  listed at once; a file downloads the first time you open it and opens from
  cache after that. Saves upload 2 seconds after the file closes, and changes
  made on the web show up within 30 seconds.
- **abraunegg `onedrive`** (`--client abraunegg`): a complete two-way copy on
  disk, for full offline use, kept current by `onedrive --monitor`.

The web apps save straight to OneDrive, so either client brings their edits
back down to the same folder. `omarchohard onedrive status` shows the client,
folder, service state and web address.

## Sign-in

- Every app uses single sign-on (SSO) in your default browser profile. Sign in
  once with `omarchohard login` (or in any app window) and every app is signed
  in. School and work accounts go through their own sign-in page.
- `omarchohard login --email you@school.edu` fills in the address for you.
- `--isolated` keeps Microsoft 365 in its own profile, apart from your
  everyday browsing; you sign in once more there.
- omarchohard never reads tokens, cookies, passwords or auth files. rclone and
  the `onedrive` client run their own Microsoft sign-in and keep their own
  tokens. If your school blocks that sign-in, see
  [OneDrive sign-in](docs/troubleshooting.md#onedrive-sign-in).

## Release channels

| Channel | What it is | Version example | Install with |
| --- | --- | --- | --- |
| stable | The newest tagged release | `0.1.0` | `curl -fsSL .../install.sh \| bash` |
| nightly | A build of `main` at 06:00 UTC that passed the full test suite; skipped when `main` has not changed | `0.1.0-nightly.20261111+636ab6e` | `... \| bash -s -- --channel nightly` |
| dev | Every push to `main` that passed CI | `0.1.0-dev.42+636ab6e` | `... \| bash -s -- --channel dev` |

Switch at any time with `omarchohard channel nightly` (or `dev`, `stable`);
`omarchohard update` updates within the channel. Every download is checked
against its sha256 before anything changes, and a failed update leaves the
old version and channel in place. Details: [docs/channels.md](docs/channels.md).

Arch packages: `packaging/arch` has PKGBUILDs for `omarchohard` (stable) and
`omarchohard-git` (newest commit). They are not on the AUR yet; build them
with `makepkg -si`. A package-managed install updates through pacman, not
`omarchohard update`.

## Performance

Time from the launch command to Hyprland mapping the app window, measured on
an Intel i9-14900HX laptop (Omarchy, Hyprland 0.56.2, Chromium 152, 32 threads). This is window
time, not page load; page load depends on your network and on Microsoft.

| Case | Median | Runs |
| --- | --- | --- |
| First launch ever, new profile | 757 ms | 678, 835 ms |
| Cold, browser not running | 404 ms | 404, 401, 430 ms |
| Warm, another omarchohard app already open | 231 ms | 200, 261 ms |
| Prewarm on (resident windowless browser, about 215 MB RSS) | 230 ms | 230, 238, 221 ms |

With two runs, the median is the midpoint of the two.

Prewarm (`omarchohard prewarm on`) keeps one windowless browser running in
the isolated profile. With your default profile it is not needed: when your
browser is open, launches are already warm.

## Desktop tier (experimental, untested)

For the features only desktop Office has, omarchohard can run real Microsoft
Office in a Windows VM ([dockur/windows](https://github.com/dockur/windows))
and show each app as its own Linux window through
[WinApps](https://github.com/winapps-org/winapps) (FreeRDP RemoteApp). Word,
Excel, PowerPoint, Outlook and OneNote are available this way; Teams is web
only.

```sh
omarchohard desktop check        # KVM, Docker or Podman, FreeRDP 3, memory, disk
omarchohard desktop install      # Windows 11 evaluation + Microsoft 365, 20 to 40 minutes
omarchohard desktop apps         # add the Office apps to the launcher
omarchohard desktop prefer on    # open local files in desktop Office
```

It needs KVM, Docker or Podman, FreeRDP 3, at least 16 GiB of RAM (6 GiB free
when you start it) and about 80 GB of disk.

**Product keys.** Microsoft 365 activates when you sign in inside Word. A
bought Office 2021 or 2024 key goes in with `omarchohard desktop activate`,
and a Windows key with `omarchohard desktop activate --windows`. Keys are read
from a hidden prompt or a key file, never from the command line, and reach the
VM through a one-shot request file that is deleted after use; results come
back with the key masked. The default Windows is the free 90-day evaluation;
`--windows 11` uses your own license.

This tier has not been run end to end yet. Full details, requirements and key
handling: [docs/desktop-tier.md](docs/desktop-tier.md).

## Uninstall

```sh
omarchohard uninstall           # remove launchers, icons and handlers; restore your previous defaults
omarchohard uninstall --purge   # also remove config, state, the OneDrive service and the isolated profile
rm -rf ~/.local/share/omarchohard ~/.local/bin/omarchohard   # remove the CLI itself
```

Files in your OneDrive folder stay where they are. A pacman install comes out
with `sudo pacman -R omarchohard` after `omarchohard uninstall`.

## Troubleshooting

`omarchohard doctor` names the failing piece and the command that fixes it.
For sign-in blocks, camera and microphone in Teams, Hyprland window rules,
Firefox and wrong accounts, see [docs/troubleshooting.md](docs/troubleshooting.md).

## Status

**Verified** (checks that could fail and passed, in a clean Arch Linux
container; see `make lint test container`):

- 44 bats tests: install twice is idempotent; doctor passes after install and
  fails on a removed launcher, a removed icon, a reassigned handler and a
  non-executable Exec path; `xdg-open` sends the `.docx`, `.xlsx` and `.pptx`
  fixtures to Word, Excel and PowerPoint; `mailto`, `msteams` and `ms-word`
  mapping; OneDrive address encoding (space, `#`, `é`); outside files copied
  with the original untouched; uninstall restores `mimeapps.list`; the config
  is never executed; channel switching and checksum refusal.
- The one-line installer over HTTP for stable, nightly and dev, then install,
  doctor, file handler defaults, switching between all three channels, and
  uninstall.
- A launch smoke under headless sway with real Chromium 156: all 7 apps map a
  window with the expected app id (about 350 ms for the first, 150 ms for
  each after it, in the container).
- The `omarchohard-git` and `omarchohard` PKGBUILDs build with makepkg,
  install with `pacman -U`, and pass `omarchohard install` and `doctor` in
  the `/usr` layout.

**Untested live:** a real Microsoft sign-in, the OneDrive mount with a real
account, an in-place edit round trip, Teams calls, launch-or-focus under
Hyprland, the prewarm service under systemd, and the whole desktop tier. The
launch times above were measured by hand on that laptop.

## License and trademarks

MIT; see [LICENSE](LICENSE).

omarchohard is an independent project. It is not affiliated with, endorsed by
or sponsored by Microsoft Corporation. Microsoft, Microsoft 365, Word, Excel,
PowerPoint, Outlook, OneNote, Teams, OneDrive and Windows are trademarks of
the Microsoft group of companies. The app icons are plain letter tiles drawn
for this project, used only to tell the apps apart.
