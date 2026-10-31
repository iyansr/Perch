# Perch

**A native macOS launcher that lives in your notch. One hotkey, search, clipboard, live activities and your coding agents, all in one spot.**

<p align="center">
  <img alt="macOS 26 or later"
       src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat&logo=apple&logoColor=white">
  <img alt="Swift 6.2"
       src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat&logo=swift&logoColor=white">
  <a href="LICENSE">
    <img alt="License: AGPL-3.0"
         src="https://img.shields.io/badge/License-AGPL--3.0-3DA639?style=flat"></a>
</p>

SwiftUI and AppKit. On a notched MacBook the black shape grows out of the hardware notch. On an external display or in clamshell mode, a floating pill sits at the top centre and expands the same way.

<p align="center">
  <img src="docs/screenshot-notch.png" alt="Perch command panel under the notch" width="720">
</p>

<p align="center">
  <img src="docs/screenshot-island.png" alt="Perch command panel as a floating island on an external display" width="720">
</p>

## Features

- **Command panel**: fuzzy-search and launch apps, jump to System Settings panes, and get inline math and unit answers.
- **Global hotkey**: `⌥ Space` opens the panel from anywhere. Rebind it in Settings.
- **Clipboard history**: searchable, pasted back into the app you were using.
- **Drop to convert**: drag an image toward the notch and convert or resize it in one step.
- **Live activities**: one shared slot in the pill for timers, media, weather, calls (Meet and Zoom), notifications, AirDrop and dictation.
- **Coding agents**: Claude Code and Codex report progress and permission requests to the notch through the `perch` CLI.
- **Two screen modes**: notch on the built-in display, floating island on external displays. Switches live when you open or close the lid.

## Install

Perch needs macOS 26 or later and runs on Apple silicon and Intel. Install it with Homebrew:

```sh
brew trust --tap iyansr/perch
brew install --cask iyansr/perch/perch
```

Homebrew clears the quarantine flag on every install and upgrade. The cask is marked `auto_updates`, so a plain `brew upgrade` (no cask named) normally skips Perch because the app updates itself; naming it (`brew upgrade perch`), `--greedy` or `--greedy-auto-updates` still upgrades it.

Or download `Perch-<version>.dmg` from [Releases](https://github.com/iyansr/Perch/releases) and drag Perch to Applications.

### Updates

Perch checks GitHub for a new stable release once a day. This is on by default; turn it off in Settings, or run **Check for Updates** there at any time. Perch never installs on its own: it shows the release and, only when you approve, downloads the update, installs it over the same app path and relaunches. It never restarts without your approval. Pre-releases are not offered, and development builds never check.

Every release is signed with the same certificate, so macOS keeps the privacy permissions you granted. The first release that includes the updater must be installed manually (Homebrew or DMG); updates apply from then on. The quarantine step below is unchanged for first installs. Perch does not promise to bypass Gatekeeper.

### “Perch” Not Opened

Perch is signed with its own certificate, not an Apple Developer ID, so Apple has not notarized it. macOS quarantines anything a browser downloads, and Gatekeeper refuses to open a quarantined app that isn't notarized: it shows **“Perch” Not Opened — Apple could not verify “Perch” is free of malware**. Click **Done**, then clear the flag and open Perch again:

```sh
xattr -dr com.apple.quarantine /Applications/Perch.app
open /Applications/Perch.app
```

Homebrew installs never show this, because the cask clears the flag for you. Do it again after manually installing a DMG. Other self-signed apps, such as [Tinycast](https://github.com/abue-ammar/tinycast), work the same way.

## Building from source

Requirements: macOS 26 or later (macOS 27 recommended), Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/iyansr/Perch.git
cd Perch
open Perch.xcodeproj
```

Run the `Perch` scheme. The Xcode build phase runs `Scripts/build-mediaremote-adapter.sh` for you.

Debug builds sign with your own Apple Development team. Release builds sign with a self-signed `Perch Self-Signed` identity; create it once with `./Scripts/create-signing-identity.sh`. See [docs/signing.md](docs/signing.md).

Add a changeset with each user-facing change (`pnpm changeset`). Merging the version pull request that Changesets opens, or pushing a `v<version>` tag, releases Perch through the `Release` workflow; `./Scripts/build-release.sh <version>` builds the same DMG and updater ZIP locally. See [docs/release.md](docs/release.md).

The marketing site lives in `web/` (Astro, pnpm):

```sh
cd web
pnpm install
pnpm dev
```

See [docs/PRD.md](docs/PRD.md) for the product spec and [docs/ACTIVITIES_PLAN.md](docs/ACTIVITIES_PLAN.md) for the activities design.

## Agent hooks

The `perch` command-line tool bridges coding agents and Perch.app.

```sh
perch event --source claude|codex [--await]   # hook command; reads the hook JSON on stdin
perch watch -- <command> [arguments…]         # run a command, report start and exit
```

`event` always fails open: if Perch is not running, the agent never notices.

## Community

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull request guidance, and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report bugs or suggest features through [issues](https://github.com/iyansr/Perch/issues/new/choose).

Support Perch through [GitHub Sponsors](https://github.com/sponsors/iyansr).

## Third-party software

`Vendor/mediaremote-adapter` is [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), licensed under BSD-3-Clause. Its own license stays in `Vendor/mediaremote-adapter/LICENSE`.

## License

[AGPL-3.0](LICENSE)
