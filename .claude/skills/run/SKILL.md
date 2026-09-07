---
name: run
description: Launch the Flaj macOS app. Always repackages Flaj.app from current source first — `swift build` alone does not update it.
---

# Running Flaj

`Flaj.app` at the repo root is a hand-assembled bundle (see `package_app.sh`), not
something `swift build` produces or updates directly. `swift build` only
refreshes `.build/**/Flaj`; the `.app` bundle Finder/Dock/the app icon launch
is a separate copy that goes stale until `package_app.sh` re-runs.

So launching Flaj always means, in order:

1. `./package_app.sh` — release-builds and re-assembles `Flaj.app` (rebuilds,
   copies the binary + icons into `Flaj.app/Contents`, re-signs, re-registers
   with Launch Services). Run this from the repo root every time, even if it
   seems like only a small change was made — there's no cheaper way to know
   the bundle is current.
2. `open Flaj.app` — launches the freshly packaged app.

Never `open Flaj.app` (or launch it via Finder/Dock) without running
`package_app.sh` first in the same session — that's the exact bug this skill
exists to avoid: the icon launching a stale build.
