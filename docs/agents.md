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
| `desktop_installed`, `native_installed` | Whether a desktop Office VM, or native Office, has been installed |
| `config` | The current answers: `apps`, `browser`, `profile`, `onedrive_client`, `onedrive_cache_size`, `mail`, `open_with` (`web`, `desktop` or `native`), and whether an email and OneDrive web address are set (never their values) |
| `device` | Threads, memory, free disk, battery, Hyprland and Omarchy versions, KVM, a container engine, FreeRDP, rclone, FUSE, gum |
| `browsers` | Installed Chromium-family browsers, the default first |
| `recommend` | `tier` (`native` on an x86_64 Hyprland machine with 8 GB of memory and 8 GB free disk, else `desktop` when `desktop check` passes, else `web`), `profile`, `prewarm`, `onedrive_client`, `onedrive_cache_size`, `native_office` and `desktop_office`, each with a `value` and a `why` |
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
| `--tier native\|desktop\|web` | Native Office under Wine, desktop Office in a Windows VM, or the web apps. `native` and `desktop` install Office at the end and still set up the web apps, for Teams; setup exits 1 if Office does not finish. Without `--tier`, `--yes` means `web` |
| `--plan P` | Native: `personal`, `family`, `school`, `business` or `enterprise`, which picks the Office product ([README](../README.md#who-it-is-for)). With `--yes` and no `--plan`, a fresh install is `personal`; with `--from`, the seed's Office is used |
| `--from SRC` | Native: copy a seed instead of installing from Microsoft. A seed file, `ssh:HOST`, an `https://` link, or a private-address `http://` link with `--sha256` |
| `--sha256 H` | Native: the seed's SHA256, checked before the seed is used or kept |
| `--shared-computer` | Native, fresh installs, `school` and `enterprise` only: shared computer activation |
| `--remote-signin` | Native: end with a one-time sign-in link instead of the sign-in window on this screen. The link is served only on the device's Tailscale address: on a plain network the password would cross it unencrypted, so there the person signs in on the device |
| `--json` | Print everything for people on stderr and one JSON line on stdout at the end (see [Set up many devices](#set-up-many-devices)) |
| `--browser B` | The browser command, such as `chromium` or `microsoft-edge-stable` |
| `--shared` or `--isolated` | Share the everyday browser profile (default) or give Microsoft 365 its own |
| `--apps LIST` | `all`, or a comma list of `word excel powerpoint outlook onenote teams onedrive` |
| `--files F` | Which files open in Office: `microsoft` (default), `all`, or Microsoft formats plus a comma list of `odt ods odp rtf csv`. Without it, `--yes` keeps the current choice |
| `--email E` | Fills in the sign-in page and OneDrive address. In native Office the sign-in takes it as the account and skips its own email step |
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

## Set up many devices

Native Office (the [README](../README.md#native-office) has what it is) is
made for this. The first device installs Office from Microsoft and keeps a
**seed**, its prefix from before anyone signed in. Every other device copies
a seed, from the first device or from any device that already has one,
since each finished device keeps the seed it got. The person signs in last,
on the device's screen or through a link.

The two commands:

```sh
# the first device (about 6 minutes)
omarchohard setup --tier native --yes --plan school
# every other device (21 s from a seed file, 32 s from a link, measured on one machine)
omarchohard setup --tier native --yes --from ssh:first-device
```

`ssh:HOST` runs `omarchohard native seed --stdout` on HOST over ssh. The seed
streams straight into the new prefix and is kept as it arrives, with no
second pass over its 2.9 GB.

**Seeds hold Microsoft's Office binaries. Move them only between the
person's own devices, or one organization's, and never publish one.** The
license comes from each person's own sign-in, and a seed is from before any
sign-in. `native seed` sends only that file: it never packs the live
prefix, so a signed-in Office never leaves its device.

### One device

```sh
omarchohard setup --tier native --yes --plan personal
```

With a display, the sign-in window opens at the end. The last line says
what the person does next.

### A family's devices, on the home network

```sh
# the first device
omarchohard setup --tier native --yes --plan family
omarchohard native seed serve --lan
# prints: --from http://192.168.1.20:6090/<token>/seed-O365HomePremRetail-<version>.tar.zst --sha256 <hex>

# each other device, with the two values it printed
omarchohard setup --tier native --yes --plan family \
  --from http://192.168.1.20:6090/<token>/seed-O365HomePremRetail-<version>.tar.zst --sha256 <hex>
```

`seed serve` listens only on that one address (`--lan`: the home network
address; without it, the Tailscale address), at a random path, for 60
minutes (`--minutes N`); `seed serve --stop` ends it. It never listens on
every address. No network? `omarchohard native seed --path` names the file;
copy it to a USB stick and pass its path to `--from`.

### Many devices, many agents, one organization

On a tailnet, one agent per device, each running one command:

```sh
# the first device
omarchohard setup --tier native --yes --plan school --json
omarchohard native seed serve --minutes 120

# every other device's agent
omarchohard setup --tier native --yes --plan school \
  --from http://100.101.2.3:6090/<token>/seed-O365ProPlusRetail-16.0.20527.20196.tar.zst --sha256 <hex> \
  --remote-signin --email student@school.edu --json
```

The last line on stdout is one JSON object:

```json
{"state":"needs_signin","signin_url":"http://lab-07.example.ts.net:6080/#s=<one-time>","seconds":34,"host":"lab-07","tier":"native","email":"student@school.edu","detail":""}
```

| `state` | Meaning |
| --- | --- |
| `needs_signin` | Office is installed. The person signs in, at `signin_url` when `--remote-signin` was given, else on the device's screen |
| `ready` | Set up already; the command changed nothing. Whether the person has signed in shows in Word (File, Account) |
| `failed` | It stopped; `detail` and stderr say why. The web apps were set up meanwhile when the run got that far |

- **Rerun it freely.** On a device that is set up, the same command reports
  `ready` at once. Two agents that start it together on one device take
  turns on a lock: one installs, the other then reports `ready`.
- **The sign-in link** opens a page served only on the device's Tailscale
  address, under its tailnet name. It works from the person's phone or
  laptop on the same tailnet. The page asks for the email, then shows
  Microsoft's own sign-in page, running in a headless browser on the
  device and laid out for the person's screen. A password and Microsoft
  Authenticator work there; a passkey or security key does not, as it is
  bound to the device in the person's hand. There is no home network
  option: Tailscale is what encrypts the password the person types. The
  link carries a one-time session id (192 bits) after `#`, which browsers
  never send to a server, and the page removes it from the address bar.
  Hand `signin_url` to that person only, by the channel you already use
  with them; it stops once the person is signed in or after 30 minutes,
  and `omarchohard native signin --remote` starts a new one.
- **Updates.** Each device updates its own Office: a weekly user timer
  runs `omarchohard native update --auto`, and `omarchohard native update
  --check` (0.3 s) reports `update.latest` and `update.available` in
  `native status --json`. Seeds keep the version they were written with;
  a device installed from an older seed updates itself within the hour.
- **Fan out as a tree.** `seed serve` handles many downloads at once, and
  every finished device can run its own `seed serve`, so 1 device seeds 2,
  those seed 4, and so on.
- **Plans must match.** A seed carries its Office product in its name
  (`seed-O365ProPlusRetail-...`) and in its registry; `--plan business`
  refuses a ProPlus seed rather than install the wrong Office.
- **Organizations that require managed devices.** If Office shows
  AADSTS53000, 53001 or 53003 at sign-in, the organization requires a
  managed Windows device, and Wine is not one. Use the web apps or ask IT.
  `native status` says the same.

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

`optimize` also prints `suggest tier=native` (or `tier=desktop`) when the
device can run that tier and it is not installed; it never installs it.

## 4. Check it

```sh
omarchohard doctor --json   # {"fails": 0, ...}; exit 1 when a required check fails
omarchohard desktop status --json
omarchohard native status --json
```

`native status --json` gives `wine` (`present`, `version`), `prefix`
(`present`, `path`), `office` (`product`, the `plans` it serves, `version`,
`apps`), `seed` (`path`, `bytes`, `sha256`, `serving`), `disk`,
`remote_signin` and `open_with`.

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
