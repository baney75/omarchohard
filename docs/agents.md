# For agents and scripts

omarchohard can be set up end to end by a script or a coding agent. Two steps
always need a person: the Microsoft sign-in and the OneDrive sign-in, as both
happen on Microsoft's own page in a browser. Nothing in omarchohard reads
tokens, cookies, passwords or auth files.

## 1. Look at the device

```sh
omarchohard probe --json
```

The report has:

| Key | What it holds |
| --- | --- |
| `version`, `channel`, `installed` | This copy and whether `install` has run |
| `desktop_installed` | Whether a desktop Office VM has been installed |
| `config` | The current answers: `apps`, `browser`, `profile`, `onedrive_client`, `onedrive_cache_size`, `mail`, `open_with` (`web` or `desktop`), and whether an email and OneDrive web address are set (never their values) |
| `device` | Threads, memory, free disk, battery, Hyprland and Omarchy versions, KVM, a container engine, FreeRDP, rclone, FUSE, gum |
| `browsers` | Installed Chromium-family browsers, the default first |
| `recommend` | `tier` (`desktop` only when `desktop check` passes), `profile`, `prewarm`, `onedrive_client`, `onedrive_cache_size` and `desktop_office`, each with a `value` and a `why` |
| `needs_person` | The steps a person has to do |

Plain `omarchohard probe` prints the same as text.

## 2. Set it up

```sh
omarchohard setup --yes --optimize \
  --browser chromium --shared --apps all \
  --email you@school.edu --onedrive none
```

| Flag | Effect |
| --- | --- |
| `--yes`, `-y` | Take the default for every question; never read the terminal |
| `--tier desktop\|web` | Desktop Office in a Windows VM, or the web apps. `desktop` installs the VM and waits for Office (about 45 minutes) and still sets up the web apps, for Teams; setup exits 1 if Office does not finish. Without `--tier`, `--yes` means `web` |
| `--browser B` | The browser command, such as `chromium` or `microsoft-edge-stable` |
| `--shared` or `--isolated` | Share the everyday browser profile (default) or give Microsoft 365 its own |
| `--apps LIST` | `all`, or a comma list of `word excel powerpoint outlook onenote teams onedrive` |
| `--files F` | Which files open in Office: `microsoft` (default), `all`, or Microsoft formats plus a comma list of `odt ods odp rtf csv`. Without it, `--yes` keeps the current choice |
| `--email E` | Fills in the sign-in page and OneDrive address |
| `--no-mail` | Leave the `mailto:` handler alone |
| `--onedrive C` | `rclone`, `abraunegg` or `none`. With `--yes`, OneDrive is skipped unless named, as its sign-in needs a person |
| `--prewarm on\|off` | Keep a windowless browser resident (isolated profile only) |
| `--optimize` | Apply `optimize` at the end |

The one-line installer passes `--yes` and anything after `--` to setup:

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash -s -- --yes
curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash -s -- -- --yes --apps teams
```

`--no-setup` installs only the CLI.

## 3. Tune it

```sh
omarchohard optimize            # print the plan, change nothing
omarchohard optimize --apply    # apply it
```

`optimize` sets the OneDrive cache size to a tenth of free disk (2 to 50 GB)
and turns prewarm on or off for an isolated profile, from memory, free memory
and power. It restarts the OneDrive mount only when something changed. It
never changes the profile, since that moves where the person is signed in; it
prints a suggestion instead.

`optimize` also prints `suggest tier=desktop` when the device can run desktop
Office and it is not installed; it never installs it.

## 4. Check it

```sh
omarchohard doctor --json   # {"fails": 0, ...}; exit 1 when a required check fails
omarchohard desktop status --json
```

`desktop status --json` gives `phase` (`not-installed`, `downloading-windows`,
`installing-windows`, `installing-office`, `starting`, `ready`, `failed`,
`stopped` or `paused`), `detail`, `vm`, `rdp` (true or false), `office`
(`product`, `version`, `channel`, `error`) and `open_with`. To wait for a
desktop install from a script, run `omarchohard desktop wait`: it exits 0
when Office is ready and 1 on a failure or after 90 minutes. Other desktop
commands for scripts: `desktop update [--channel current|monthly|semi-annual]
[--to VERSION]` and `desktop run FILE`. See
[desktop-tier.md](desktop-tier.md).

## 5. Hand off

Tell the person to run, or to open from the launcher:

- `omarchohard login` (sign in once)
- `omarchohard onedrive setup` (OneDrive sign-in in the browser)

Then `omarchohard doctor` should report no warnings for OneDrive.
