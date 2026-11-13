# Troubleshooting

Start with `omarchohard doctor`. It checks the browser, every launcher, icon
and handler, the OneDrive service and the prewarm service, names what failed
and prints the command that fixes it. `omarchohard doctor --json` gives the
same results for a bug report.

## OneDrive sign-in

`omarchohard onedrive setup` signs in through rclone (or the abraunegg
`onedrive` client), not through the browser profile the apps use. Some
schools and companies block that step.

**"Need admin approval", AADSTS90094 or AADSTS65001**: your tenant requires an
administrator to consent before a third-party app can reach OneDrive. You
have three options:

1. Ask your IT department to approve the app the error page names. Send them
   the exact error code from the page.
2. **rclone with your own app registration.** rclone accepts a custom
   `client_id` and `client_secret` from an Azure app registration. Create the
   remote yourself with `rclone config` (choose `onedrive`, then enter the
   client ID and secret when asked), name it `omarchohard-onedrive`, and run
   `omarchohard onedrive setup` again; it reuses an existing remote with that
   name. The rclone documentation says a custom client ID "may or may not
   work for OneDrive Business", so this depends on your tenant's policy. See
   <https://rclone.org/onedrive/#getting-your-own-client-id-and-key>.
3. **abraunegg `onedrive`**: to get a link your administrator can use to
   approve access, set `application_id` and `azure_tenant_id` in
   `~/.config/onedrive/config`, then run
   `onedrive --display-admin-consent-url`. Both values are required for that
   link. Then run `omarchohard onedrive setup --client abraunegg`.

You can use the web apps without any of this. Only opening local files in
place needs OneDrive on disk.

**The browser never opened for rclone**: run `rclone config reconnect
omarchohard-onedrive:` in a terminal and open the link it prints.

**Files open but say "file not found" on the web**: the OneDrive web address
is wrong. Open OneDrive (`omarchohard launch onedrive`), copy the address up
to and including `/Documents`, and run `omarchohard onedrive web-root URL`.

## Teams camera and microphone

Teams runs in the browser, so the browser owns the camera and microphone.

- The first call asks for permission. If you clicked Block, open
  `chrome://settings/content/camera` and `chrome://settings/content/microphone`
  in the same browser and allow `teams.cloud.microsoft` and
  `teams.microsoft.com`.
- Only one program can use a camera at a time. Close other video apps, or
  check with `fuser /dev/video0`.
- Screen sharing on Hyprland goes through `xdg-desktop-portal-hyprland`.
  Omarchy ships it; `systemctl --user status xdg-desktop-portal-hyprland`
  should show it running.
- With `--isolated`, permissions are kept in the isolated profile, apart from
  your everyday browser.

## Hyprland window classes

Chromium names each app window `chrome-<host>__<path>-<Profile>`: dots stay,
each slash in the path becomes `_`, and the profile is `Default` for
your everyday profile or `Omarchohard` with `--isolated`.

| App | Class (default profile) |
| --- | --- |
| Word | `chrome-word.cloud.microsoft__-Default` |
| Excel | `chrome-excel.cloud.microsoft__-Default` |
| PowerPoint | `chrome-powerpoint.cloud.microsoft__-Default` |
| Outlook | `chrome-outlook.cloud.microsoft__mail_-Default` |
| OneNote | `chrome-onenote.cloud.microsoft__-Default` |
| Teams | `chrome-teams.cloud.microsoft__-Default` |
| OneDrive | `chrome-onedrive.cloud.microsoft__-Default` |
| Microsoft 365 | `chrome-m365.cloud.microsoft__-Default` |

With `--isolated` the suffix is `-Omarchohard`, for example
`chrome-word.cloud.microsoft__-Omarchohard`.

Example: always open Teams on workspace 4 and Outlook on workspace 3. Add to
`~/.config/hypr/hyprland.lua`:

```lua
o.window("^chrome-teams\\.cloud\\.microsoft__-Default$", { workspace = "4" })
o.window("^chrome-outlook\\.cloud\\.microsoft__mail_-Default$", { workspace = "3" })
```

`hyprctl clients` lists the class of every open window. A document opened
from a file or link keeps the class of the address it opened, such as
`chrome-contoso-my.sharepoint.com__...`, not the app's class.

## Firefox as default browser

Firefox has no app-window mode, so omarchohard never uses it. When Firefox is
your default browser, omarchohard uses the first Chromium-family browser it
finds (Edge, Chrome, Chromium, Brave, Helium, Vivaldi). That browser has its
own profile, so you sign in to Microsoft once there.

To choose the browser, set it in `~/.config/omarchohard/config`:

```ini
browser=chromium
```

It takes effect at the next launch. If no Chromium-family browser is
installed: `omarchy pkg add chromium`.

## Wrong account signed in

The apps use whatever Microsoft account your browser profile is signed in
with.

- To switch: open any app, choose your account picture, sign out, and sign in
  with the right account. Every app follows.
- To keep a school or work account apart from a personal one, use a separate
  profile: `omarchohard install --isolated`, then `omarchohard login --email
  you@school.edu`.
- `omarchohard login --email ADDR` pre-fills the address on the sign-in page.

## Desktop Office: "Another user is signed in"

A desktop Office app shows a Windows box saying another user is signed in,
or `omarchohard desktop apps` stops with "REMOTE DESKTOP PROTOCOL FAILURE".
Windows is still signed in on its own screen, and a RemoteApp cannot start
while that session is open. dockur signs the user in automatically after
setup; VMs installed since 0.2.0 sign out at the end of the first boot and
turn automatic sign-in off.

For a VM installed earlier, sign out of Windows once at
<http://127.0.0.1:8006> (Start, your name, Sign out), then run
`omarchohard desktop apps`.

## Native Office: AADSTS53000, 53001 or 53003

Office's sign-in window stops with one of these codes. Your organization
requires a managed Windows device for its accounts (Conditional Access), and
native Office runs under Wine, which is not one. Nothing on the device can
change that: use the web apps (`omarchohard setup --tier web`), or ask your
IT department whether there is another way. omarchohard does not read
Office's sign-in state; `omarchohard native status` lists these codes.

## Native Office: "WINWORD.EXE has encountered a serious problem"

wine-altars can show this once, on Word's first start in a new prefix; the
starts after it are clean. Setup starts Word once on a hidden screen to
absorb it when Xvfb is installed (`xorg-server-xvfb`). Without Xvfb, close
the box; Word keeps working.

## Something else

Open an issue with the output of `omarchohard version` and
`omarchohard doctor --json`: <https://github.com/baney75/omarchohard/issues>.
