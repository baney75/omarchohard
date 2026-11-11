# Contributing

Thanks for helping. omarchohard is plain bash; there is no build step.

## Run the checks

```sh
make lint        # shellcheck, shfmt -i 2, actionlint
make test        # the bats suite
make container   # installer over HTTP per channel, headless sway launch smoke, Arch package
```

`make lint` and `make test` use the tools on your PATH and fall back to a
clean Arch Linux container when shellcheck, shfmt or bats is missing. `make
container` always uses Docker (no sudo needed if you are in the `docker`
group). The first run builds the test image, which takes a few minutes.

Every pull request runs the same checks in CI. A bug fix comes with a test
that fails without the fix.

## Style

- bash, `set -euo pipefail` in entry points, two-space indent, case arms
  flush with `case` (`shfmt -i 2`).
- Functions are prefixed `oh_`. Config is parsed, never sourced.
- Anything that launches, installs or changes system state goes through
  `oh_run` or `oh_spawn`, so `OMARCHOHARD_DRY_RUN=1` can print it instead.
- Messages say what happened and the command that fixes it.
- Plain American English in code, docs and commits. No em or en dashes, no
  hype words; give numbers.

## Commits

- Small, logical commits. The subject is imperative and under 72 characters
  ("Fix OneDrive address encoding for #"); the body says why.
- Do not commit generated files except the test fixtures and `.SRCINFO`
  (`make srcinfo` regenerates them; the package test fails when they are
  stale).

## Channels

- Every push to `main` that passes CI publishes the dev build.
- The nightly build runs at 06:00 UTC when `main` has changed.
- A stable release is a `vX.Y.Z` tag that matches `VERSION`, with a
  `CHANGELOG.md` section of the same version. See
  [docs/channels.md](docs/channels.md).
