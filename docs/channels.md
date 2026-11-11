# Release channels

omarchohard publishes three channels. Each channel is the same three files at
a fixed address:

| File | Contents |
| --- | --- |
| `omarchohard.tar.gz` | One top folder, `omarchohard-<version>/`, with `bin`, `lib`, `share`, `LICENSE`, `README.md`, `CHANGELOG.md` and `share/omarchohard/VERSION` |
| `omarchohard.tar.gz.sha256` | The archive's sha256, in `sha256sum` format |
| `omarchohard.version` | The version string |

| Channel | Built from | Version | Address |
| --- | --- | --- | --- |
| stable | A `vX.Y.Z` tag | `X.Y.Z` | `releases/latest/download/FILE` |
| nightly | `main` at 06:00 UTC, after the full test suite passes; skipped when `main` has not changed since the last nightly | `X.Y.Z-nightly.YYYYMMDD+<sha7>` | `releases/download/nightly/FILE` |
| dev | `main` after every push whose CI passes | `X.Y.Z-dev.<commit count>+<sha7>` | `releases/download/dev/FILE` |

`X.Y.Z` comes from the `VERSION` file. Nightly and dev carry the version of
the next release, so `0.1.0-dev.42+636ab6e` is the 42nd commit of work toward
or after 0.1.0. Addresses are under
`https://github.com/baney75/omarchohard/`. nightly and dev are GitHub
prereleases on rolling tags of the same name, so the stable address never
points at them.

## Install and switch

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash                       # stable
curl -fsSL https://raw.githubusercontent.com/baney75/omarchohard/main/install.sh | bash -s -- --channel nightly
omarchohard channel            # show the channel and version
omarchohard channel dev        # switch to dev and update now
omarchohard update --check     # is there a newer build on this channel?
omarchohard update             # install it
```

Switching from nightly or dev back to stable installs the stable build even
when its version number is lower.

## What an update does

1. Downloads `omarchohard.version`. If it matches the running version, stop.
2. Downloads the archive and its checksum and checks the sha256. On a
   mismatch it stops with "checksum mismatch; nothing was changed".
3. Unpacks into `~/.local/share/omarchohard/releases/<version>` (through a
   `.partial` folder), then swaps the `current` symlink to it in one
   `rename`, so a running app never sees a half-written release.
4. Saves the channel in `~/.config/omarchohard/config`. A failed update
   keeps the old channel.
5. Keeps the current release and the two before it, and deletes older ones.
6. Runs `omarchohard install` from the new release, so launchers and
   handlers match it.

`~/.local/bin/omarchohard` points at `current/bin/omarchohard`, so launchers
keep working across updates.

The checksum guards against a corrupt or partial download. It comes from the
same release as the archive, so it does not protect against a compromised
GitHub account.

## Package-managed installs

When omarchohard runs from outside `~/.local/share/omarchohard/releases`
(for example `/usr/bin/omarchohard` from pacman), `update` and `channel`
print a note to update through the package manager and exit 0. The
`omarchohard` package follows stable; `omarchohard-git` builds the newest
commit on `main`. Both PKGBUILDs are in `packaging/arch`.

## How CI publishes

| Workflow | Trigger | Publishes |
| --- | --- | --- |
| `ci.yml` | Push to `main`, pull requests | Nothing; runs lint, bats, the container install test, the sway launch smoke and the package build |
| `release.yml` | A `v*` tag | stable: runs every test, checks the tag matches `VERSION`, creates the release with notes from `CHANGELOG.md` |
| `nightly.yml` | 06:00 UTC daily, or by hand | nightly: skips if `main` is already the nightly, runs every test, replaces the assets and moves the `nightly` tag |
| `dev.yml` | `ci.yml` succeeding on a push to `main` | dev: replaces the assets and moves the `dev` tag; skips if `main` has moved on |

To cut a stable release: update `VERSION` and `CHANGELOG.md`, merge, then
`git tag vX.Y.Z && git push origin vX.Y.Z`. Then bump
`packaging/arch/omarchohard/PKGBUILD` (its header lists the steps).

## Testing against a local release tree

`OMARCHOHARD_RELEASE_BASE` replaces `https://github.com/baney75/omarchohard/releases`
in both `install.sh` and the CLI. `scripts/release-base.sh DIR` builds all
three channels into `DIR` in the same layout:

```sh
scripts/release-base.sh /tmp/rb
OMARCHOHARD_RELEASE_BASE=file:///tmp/rb bash install.sh --channel dev
```

`tests/release.bats` and `tests/container/install-test.sh` do exactly this,
the second over HTTP.
