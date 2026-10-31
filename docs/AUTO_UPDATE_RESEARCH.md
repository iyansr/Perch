# Auto-update research: Tinycast as a reference

Status: research notes. The native path in section 10 is implemented in `Perch/Updates/` (`UpdateFeed`, `UpdateInstaller`, `UpdateController`); user-facing behavior is documented in [release.md](release.md).

Date of research: 2026-10-31.

Tinycast source revision examined: [`37e6043f3f550febb64bdb3cff3ac29a30caad5a`](https://github.com/abue-ammar/tinycast/commit/37e6043f3f550febb64bdb3cff3ac29a30caad5a) (`main` HEAD on 2026-10-31, committed 2026-10-26 "Update issue templates and documentation for Xcode 27 compatibility"). All `blob` links below are pinned to this SHA.
Tinycast Homebrew tap revision examined: [`abue-ammar/homebrew-tinycast@612ee78c324ed88770ad6344f6d11d76b61682de`](https://github.com/abue-ammar/homebrew-tinycast/commit/612ee78c324ed88770ad6344f6d11d76b61682de) ("tinycast@beta 0.12.3-beta.127").

Convention: **Observed** = read in source or measured on a downloaded artifact. **Doc claim** = statement in prose that was not confirmed by code. **Recommendation / Unknown** = labeled as such.

Recommendation: use a native Tinycast-style updater while Perch retains its current self-signed distribution. Prefer Sparkle if its signing compatibility is proven or Perch moves to Developer ID. Sections 10–12 map both paths and the required checks.

## 1. Headline findings

1. **Observed: current Tinycast does not use Sparkle.** Its feature doc explicitly says "There is no Sparkle and no appcast" ([source](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/features/updates.md#L3-L5)). An earlier [Sparkle implementation](https://github.com/abue-ammar/tinycast/commit/96121c5a9b032993a48815368a7ce176fd05a7bc) is historical evidence, not the current design. The native updater lives under `Tinycast/Features/Updates/`.
2. **Observed: opt-out, default on.** `automaticallyCheckForUpdates` is true when the key is absent ([`AppSettings.swift` L700-702](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Settings/AppSettings.swift#L700-L702)). The toggle was added in [#1305](https://github.com/abue-ammar/tinycast/commit/2c9b4459e0) (2026-10-04); before that, checking was unconditional. Manual "Check for Updates" works regardless of the toggle ([`updates.md` L106-109](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/features/updates.md#L106-L109)).
3. **Observed: the feed is the GitHub Releases REST API.** `GET https://api.github.com/repos/abue-ammar/tinycast/releases?per_page=20`, unauthenticated, ephemeral session ([`UpdateCheckStore.swift` L7-8, L173-183](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateCheckStore.swift#L7-L8)).
4. **Observed: no cryptographic signature on the downloaded archive other than the macOS code signature of the app inside it.** No EdDSA, no checksum comparison, no signed feed. The only integrity check is `SecStaticCodeCheckValidity` plus an identity match (see section 4).
5. **Observed: documentation and code disagree on several points.** Details in section 8. Most important: the public docs say the signature must match "the same way as the copy you're running", but the code *also* accepts any bundle signed under Apple Developer ID team `J656U8XZ93`; docs say "never runs `xattr`", but the installer *removes* the quarantine attribute itself (via `removexattr(2)`, not the `xattr` tool); docs say both casks declare `auto_updates true`, but no such line exists in the tap at the examined revision.
6. **Observed: releases are still self-signed, not Developer ID, not notarized.** I downloaded `Tinycast-Universal-0.12.1.zip` from the latest stable release and inspected it (section 6). So Tinycast's actual trust path today is the "same leaf certificate" branch; the Developer ID branch is a staged forward-compatibility hook.

## 2. Primary sources read

- Public docs page: <https://tinycast.dev/docs/reference/updates/> (read 2026-10-31).
- Repo: <https://github.com/abue-ammar/tinycast> at SHA above. Files read in full:
  - [`docs/features/updates.md`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/features/updates.md), [`docs/release.md`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/release.md), [`docs/signing.md`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/signing.md)
  - `Tinycast/Features/Updates/Model/`: [`AppVersion`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/AppVersion.swift), [`ReleaseArchitecture`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/ReleaseArchitecture.swift), [`ReleaseChannel`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/ReleaseChannel.swift), [`ReleaseFeed`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/ReleaseFeed.swift), [`UpdateReadiness`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/UpdateReadiness.swift)
  - `Tinycast/Features/Updates/Service/`: [`BundleSignature`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/BundleSignature.swift), [`Quarantine`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/Quarantine.swift), [`ToolRunner`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/ToolRunner.swift), [`UpdateCheckStore`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateCheckStore.swift), [`UpdateDownloader`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateDownloader.swift), [`UpdateFailure`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateFailure.swift), [`UpdateInstaller`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateInstaller.swift)
  - UI: [`UpdateCoordinator`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/UI/UpdateCoordinator.swift). Not read: `UpdateWindowView`, `ReleaseNotesView`, `ReleaseNotes` (presentation only).
  - [`AppCore.swift` `relaunch()`/`prepareForTermination()`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/App/AppCore.swift#L568-L596) and [`RelaunchRunner.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Platform/RelaunchRunner.swift)
  - [`.github/workflows/release.yml`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/.github/workflows/release.yml), [`Scripts/verify-signature.sh`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Scripts/verify-signature.sh), [`project.yml`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/project.yml), [`Tinycast/Info.plist`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Info.plist)
- Commit messages: [`2774c63`](https://github.com/abue-ammar/tinycast/commit/2774c63f4d6f91e5e5db0343760f9833333d9261) (first updater, 2026-08-20), [`7caa286`](https://github.com/abue-ammar/tinycast/commit/7caa286ed0aa47adfa7425dd197db20dd00605a9) (hardened runtime + Developer ID requirement, 2026-09-12).
- Tap casks: <https://github.com/abue-ammar/homebrew-tinycast/tree/612ee78c324ed88770ad6344f6d11d76b61682de/Casks> (`tinycast.rb`, `tinycast-universal.rb`, `tinycast@beta.rb`, `tinycast-sequoia.rb`).
- Releases API and shipped artifact: <https://github.com/abue-ammar/tinycast/releases/tag/v0.12.1> (`Tinycast-Universal-0.12.1.zip` downloaded and inspected locally).

Not examined: updater test contents, CI logs, and private signing configuration. Public test files exist, but this investigation did not evaluate their coverage.

### Verification scope: what was checked and what was not

Research checks actually run (2026-10-31):

- Read the source files, docs, workflow, casks and commit messages listed above at the pinned SHAs.
- Parent-run live probe: `gh api repos/abue-ammar/tinycast/releases/latest` returned stable `v0.12.1` with assets `Tinycast-0.12.1.{dmg,zip}` and `Tinycast-Universal-0.12.1.{dmg,zip}`; `gh api repos/iyansr/Perch` confirmed the Perch repository is public. My own releases-API listing showed the same stable release plus several `-beta.N` prereleases with DMG+zip pairs.
- Downloaded `Tinycast-Universal-0.12.1.zip`, expanded with `ditto -x -k`, and ran `codesign -dv`, `codesign -d -r-`, `spctl -a -vv`, `xattr -l` and `lipo -archs` on it (section 6).

**No end-to-end updater run was performed.** I did not build or run Tinycast, did not perform an in-app update, did not run `brew upgrade` against any cask, and did not observe quarantine state after a real in-app update. Every statement about runtime behavior of the updater comes from reading the code and docs.


## 3. Behavior trace

### 3.1 Opt-in / default

- Observed: default on (section 1 item 2). Setting is `Settings -> General -> Automatically check for updates`, travels through settings backup ([`updates.md` L53-57](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/features/updates.md#L53-L57)).
- Observed: `UpdateCoordinator.applyAutomaticChecking()` calls `store.start()` or `store.stop()` ([`UpdateCoordinator.swift` L44-50](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/UI/UpdateCoordinator.swift#L44-L50)); `presentIfAvailable` returns false when the toggle is off, so a cached release cannot raise a prompt either.
- Observed: **check is automatic, install is not.** The user must click through the update window to download and install. There is no silent install.
- Observed: development builds (any bundle id other than `com.tinycast.app` / `com.tinycast.app.beta`) never update and hide the command ([`ReleaseChannel.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/ReleaseChannel.swift)).

### 3.2 Schedule

All in [`UpdateCheckStore.swift` L9-17, L125-140](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateCheckStore.swift#L9-L17):

- First check 30 s after launch (`startupDelay`).
- Interval 24 h, measured from persisted `lastCheckedAt`, so relaunching does not re-hit GitHub.
- 2 h retry after a failed fetch (non-200 or error returns `nil`).
- If the prompt is withheld because the user is busy, retry every 120 s, at most 15 times (30 min), then fall back to the daily rhythm. Each version is announced at most once per launch (`announcedVersion`).
- State in `~/Library/Caches/<bundle-id>/update-check.json`: last check time, newest release, skipped version, just-installed version.
- Skip ("Later") records the version; only a strictly newer one prompts again. Manual check ignores the skip.

### 3.3 Feed and version selection

- Observed: [`ReleaseFeed.newest`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/ReleaseFeed.swift#L21-L29) decodes the 20 most recent releases, drops drafts, drops anything whose `prerelease` flag does not match the channel, requires the tag to parse as `vMAJOR.MINOR.PATCH` or `-beta.N`, requires `tag.isPrerelease == prerelease` flag, and requires a usable `.zip` asset. It takes the max version.
- Observed: asset choice by architecture. Names containing `-Universal-` are universal; Intel only takes universal; Apple silicon prefers a non-universal zip and falls back to universal.
- Observed: the offered release must be strictly newer than `CFBundleShortVersionString`. **`CFBundleVersion` (build number) is not consulted.**
- Observed: release notes are the release `body` cut at `<!-- tinycast:install -->`.
- Channels: stable updates only to non-prerelease, beta only to prerelease; separate bundle ids.

### 3.4 Download and install pipeline

[`UpdateInstaller.install`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateInstaller.swift#L36-L66) (observed):

1. Stream `browser_download_url` to `~/Library/Caches/<bundle-id>/Updates/<tag>.zip` with an ephemeral, cacheless `URLSession` download task; 60 s request timeout; status must be exactly 200 ([`UpdateDownloader.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/UpdateDownloader.swift)). Cancel cancels the transfer. **No checksum or size check against the asset metadata** (`assetSize` is only used for progress display).
2. `/usr/bin/ditto -x -k <zip> <staging>/expanded` via `Process` (`ToolRunner`, 120 s timeout). First `*.app` in the expanded folder is taken.
3. Quarantine guard: if `com.apple.quarantine` is set on the staged app, **clear it** recursively (`removexattr`), then refuse if it still survives ([`Quarantine.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/Quarantine.swift)).
4. Verify (`UpdateInstaller.verify`, L83-98): `CFBundleIdentifier` equals running bundle id; `CFBundleShortVersionString` equals the release version; `BundleSignature.isTrusted`.
5. `FileManager.replaceItemAt(bundleURL, withItemAt: staged, options: .usingNewMetadataOnly)` onto the running bundle path. Failure is surfaced ("usually means /Applications is not writable by your account"); no privileged helper, no admin prompt.
6. Offer Relaunch. `AppCore.relaunch()` calls `NSApp.terminate`; in `prepareForTermination` a detached `/bin/sh -c` loop waits for the old PID to disappear, then `/usr/bin/open <bundle path>` ([`RelaunchRunner.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Platform/RelaunchRunner.swift)).

Readiness gating ([`UpdateReadiness.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Model/UpdateReadiness.swift)): the prompt, and the install click, are blocked while a snippet is expanding, an extension command is running, the uninstaller is trashing, a hotkey is being recorded, a dialog is open, or the palette is visible.

## 4. Signing keys and trust model

Observed in [`BundleSignature.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/BundleSignature.swift):

A staged bundle is trusted when **both**:

1. `SecStaticCodeCheckValidity` passes with `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode` (seal intact, nested helpers included, every slice), **and**
2. *either*
   - it satisfies the hard-coded Developer ID requirement
     `anchor apple generic and certificate leaf[subject.OU] = "J656U8XZ93" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists` (team pin; `notarized` deliberately omitted so offline Macs do not fail), **or**
   - the leaf certificate (`SecCertificateCopyData` of `certificates.first`) is byte-identical to the running app's leaf.

Consequences (observed unless marked):

- The public docs page's "signed the same way as the copy you're running" describes only branch 2b. The shipped code additionally trusts any code signed by Apple team `J656U8XZ93`. That is a larger trust set than the docs imply, though it is the project's own Developer ID. A reader of the docs alone would not know a signature-key migration path exists.
- Releases currently sign with the self-signed identity (section 6), so branch 2b is what runs in production today. Branch 2a exists so that already-installed copies can accept the first Developer ID-signed release ([`7caa286` message](https://github.com/abue-ammar/tinycast/commit/7caa286ed0aa47adfa7425dd197db20dd00605a9); [`signing.md` "The Developer ID migration"](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/signing.md#the-developer-id-migration)). The doc says the code trusting the new identity must reach users before the first build carrying it; the stated reason is that a leaf-only comparison would otherwise reject every future update.
- Self-signed identity provenance: created by a one-liner `openssl` recipe with the password `tinycast` for the intermediate `.p12`, then exported and stored as repo secrets `SIGNING_P12_BASE64` / `SIGNING_P12_PASSWORD` ([`signing.md` L15-77](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/signing.md#L15-L77)). The contributor docs tell every contributor to create a locally-named `Tinycast Self-Signed` identity with their own key. This is a **distinct key per contributor** with the same name; the updater compares the certificate bytes, not the name, so local builds cannot install as a release update. Observed from this doc, not tested.
- There is **no signing key dedicated to updates**: the same code-signing identity signs the app and thereby authorizes updates. A leak of the CI `.p12` (it lives in a GitHub secret) would let an attacker ship updates that existing installs accept, with no second factor (such as Sparkle's EdDSA key) and no revocation path other than a Developer ID switch that old installs trust anyway.
- A GitHub-account compromise (or a malicious release edit) yields only a zip that fails the identity check unless the attacker also has the `.p12` / Developer ID key. This is the strength of the model: the transport (GitHub, TLS) is not trusted for authenticity. The version rule also blocks downgrades below the running app: the staged bundle's `CFBundleShortVersionString` sits inside the signed seal and must equal the feed version, and the feed version must be strictly greater than the running version. What a feed attacker can still do, because there is no signed manifest, is offer an older-but-still-newer validly signed build (a partial rollback) or withhold new releases (a freeze). [INFERENCE: derived from the code paths above, not exercised.]
- TOCTOU: the bundle is verified in `~/Library/Caches/<bundle-id>/Updates/expanded` and then moved with `replaceItemAt`. A same-user process could in principle swap the staged bundle between verify and replace. [INFERENCE] Low severity (same-user attacker already owns the app's own data), but a notable gap relative to Sparkle's installer, which runs verification and replacement in a separate helper process.

## 5. Archive packaging

Observed in [`release.yml`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/.github/workflows/release.yml):

- Runner `xcode-27`; builds via `xcodebuild` with `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Tinycast Self-Signed" OTHER_CODE_SIGN_FLAGS="--timestamp=none" ARCHS=arm64` (stable thin / beta) and `ARCHS="arm64 x86_64"` (universal job). Slices asserted with `lipo -archs` on app and helpers.
- The signing identity is imported into a temporary keychain from base64 secrets, with `set-key-partition-list`; the universal job comment says "The SAME identity, or fail: the updater compares the staged bundle's leaf certificate."
- `Scripts/verify-signature.sh` asserts hardened runtime on app, helper, nested helper app; bundle-id / signing-identifier agreement on the dictation helper; `codesign --verify --deep --strict`; no `get-task-allow`; entitlement for each usage string. The workflow step name says "notarizable", but nothing is notarized.
- Packaging (L131-145): DMG via `diskutil image create from <stage> --format UDZO` (with `/Applications` symlink) for humans and Homebrew; **ZIP via `ditto -c -k --keepParent --sequesterRsrc "$APP" dist/<zip>`** for the updater. The docs call this "the only zip that leaves the code signature verifiable".
- Asset naming: `Tinycast-<ver>.dmg|zip` (thin) and `Tinycast-Universal-<ver>.dmg|zip`; universal pair uploaded second so older clients that take "first zip" still get the thin one.
- Releases created with `gh release create` including `--prerelease` for beta. Release notes built by `Scripts/release-notes.sh`; changelog above the `<!-- tinycast:install -->` marker is what the in-app window shows.
- Observed: there is **no Sparkle `sign_update`, no `appcast.xml`, no EdDSA step** and no notarization (`notarytool`/`stapler`) in the workflow (I grepped for `sparkle`, `appcast`, `notar` as step actions: only the "notarizable" comment/step name appear).

## 6. Gatekeeper and quarantine handling (self-signed, not notarized)

Observed measurements on `Tinycast-Universal-0.12.1.zip` (v0.12.1, latest stable at time of reading; extracted with `ditto -x -k`):

```text
Identifier=com.tinycast.app
CodeDirectory v=20500 ... flags=0x10000(runtime)
Authority=Tinycast Self-Signed
TeamIdentifier=not set
designated => identifier "com.tinycast.app" and certificate leaf = H"69ff954306991df2c5d7fb8a93104e0848affe83"
spctl -a -vv:  rejected   origin=Tinycast Self-Signed
CFBundleShortVersionString=0.12.1  CFBundleVersion=124
lipo -archs: x86_64 arm64
```

- Hardened runtime on, self-signed, no team ID, **Gatekeeper assessment rejects it** (`spctl` "rejected" on a freshly extracted copy; this is expected for a self-signed app).
- **Direct DMG users:** README says "It's self-signed, so run `xattr -dr com.apple.quarantine /Applications/Tinycast.app` once" ([README](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/README.md)).
- **Homebrew users:** casks clear quarantine in `postflight_steps` with `/usr/bin/xattr -dr com.apple.quarantine`. Observed in all four casks at tap revision `612ee78`.
- **In-app updates:** the downloaded zip comes from `URLSession` in an app that is neither sandboxed nor opted into `LSFileQuarantineEnabled`, so macOS does not quarantine it. Tinycast's own docs assert this ([`updates.md` L21-24](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/features/updates.md#L21-L24)); I verified that `Info.plist` has no `LSFileQuarantineEnabled` key. I did not run a live in-app update, so "the extracted bundle has no quarantine flag after a real update" is the project's claim and a reasoned consequence of those two facts, not something I observed end-to-end. The installer clears the attribute defensively if it is there.
- **[INFERENCE]** Avoiding or removing quarantine explains the intended no-extra-`xattr` update flow. This is not proof that Gatekeeper or XProtect can never assess or block an updated app. First-install behavior remains unchanged.
- Privacy grants (TCC / Accessibility): Tinycast's stated reason for byte-identical leaf matching is that a stable certificate-pinned designated requirement is what lets macOS keep the Accessibility grant across updates ([`2774c63` message](https://github.com/abue-ammar/tinycast/commit/2774c63f4d6f91e5e5db0343760f9833333d9261); [`signing.md` L1-5](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/signing.md#L1-L5)). The designated requirement of the shipped build pins the leaf certificate hash (above), consistent with that explanation. Switching identity would make the DR change and, per the project's own docs, drop the grants once.

## 7. Homebrew

- **Doc claim** ([public docs](https://tinycast.dev/docs/reference/updates/), [`updates.md` L9-13, L157-159](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/docs/features/updates.md#L9-L13)): both casks declare `auto_updates true`, so `brew upgrade` skips Tinycast and never rolls back a self-updated copy.
- **Observed contradiction:** `auto_updates true` does **not** appear in `Casks/tinycast.rb`, `tinycast-universal.rb`, `tinycast@beta.rb` or `tinycast-sequoia.rb` at tap revision `612ee78` (grep over the raw files returned no match for `auto_updates`). Given the docs insist removing it "would reintroduce exactly those three problems", either the line is absent in the tap's `main` branch and the behavior described on the website is not currently true for brew users, or it is expressed another way I did not recognize. I did not find one. **Unknown:** actual `brew upgrade` behavior on a self-updated install; I did not run Homebrew.
- Observed: cask `version`/`sha256` are rewritten by `sed` in the release workflow and pushed to the tap using a `HOMEBREW_TAP_TOKEN` PAT. Pre-releases go to a separate `tinycast@beta` cask.
- Observed: casks use `postflight_steps` for quarantine removal. This research did not validate that DSL against an installed Homebrew version; do not treat its presence as runtime proof.
- Cask URL is the DMG; the updater uses the zip. Two code paths, one release.

## 8. Doc versus code differences (explicit)

| Topic | Public docs / feature docs say | Source shows |
| --- | --- | --- |
| Signature | "signed the same way as the copy you're running" ([tinycast.dev updates](https://tinycast.dev/docs/reference/updates/)) | Trusted if seal validates **and** (Developer ID team `J656U8XZ93` requirement **or** identical leaf cert). The first branch is not mentioned on the website. `updates.md` L25-31 does describe it. |
| xattr | "Tinycast never runs `xattr`" | Never spawns `/usr/bin/xattr`, but `Quarantine.clear` calls `removexattr(2)` on the staged bundle if the attribute is set, then refuses if it persists ([`Quarantine.swift`](https://github.com/abue-ammar/tinycast/blob/37e6043f3f550febb64bdb3cff3ac29a30caad5a/Tinycast/Features/Updates/Service/Quarantine.swift)). `updates.md` L21-24 states this accurately ("checks anyway through getxattr/removexattr"); the website page is a simplification. |
| Homebrew | `auto_updates true` on both casks | Not present in tap at `612ee78` (section 7). |
| Notarization | workflow step "Assert the signature is notarizable" | No notarization performed; shipped app is `spctl` rejected, self-signed. The Developer ID path is not yet used for any release I inspected (v0.12.1). |
| Install checks | "Bundle id and version" | `CFBundleShortVersionString` string equality with the feed tag only; build number (`CFBundleVersion`) is ignored. |
| Admin | "never asks for an administrator password" | True in code: no `AuthorizationExecuteWithPrivileges`, no helper; replace failure is reported. Observed. |

## 9. Limitations and safety concerns (Tinycast design, relevant to anyone copying it)

Observed:

1. **Single signing identity is the only trust root.** No separate update-signing key, no signed manifest, no notarization. The identity is a self-signed key whose `.p12` is stored in GitHub secrets and was created with a throwaway password in the docs.
2. **No archive digest check.** `assetSize` is for progress only; the release body contains a DMG SHA-256 for humans, not machine-verified, and it is for the DMG not the zip. Integrity relies entirely on the code signature.
3. **Unauthenticated GitHub API.** Subject to GitHub's unauthenticated rate limit (60 requests/hour/IP per [GitHub REST docs](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)); once per day per install is fine, but shared-IP offices could see failures, which the code treats like any other failure (2 h retry). [INFERENCE] not observed.
4. **Verification in a user-writable cache directory, then swap** (TOCTOU, section 4). No out-of-process installer.
5. **Install needs a writable target.** Fails on a non-writable `/Applications` (e.g., app installed by another admin account); there is no fallback.
6. **Running app replaces its own bundle** with `replaceItemAt` while live; relaunch is a shell `sh -c` polling loop spawned from the dying process. If the shell loop dies, the app does not come back (user must reopen). Observed code; failure behavior not tested.
7. **Version comparison by marketing version only** (`MAJOR.MINOR.PATCH[-beta.N]`; anything else parses to nil and is ignored), so a release with a malformed tag or an unusual suffix is silently invisible.
8. **Release authoring errors disable updates silently:** DMG-only releases, drafts, tag/prerelease-flag mismatch and missing universal zip on Intel are all skipped with no error.
9. **Release-note rendering is custom.** Notes are untrusted-ish text from the release body (author-controlled); the app builds its own Markdown-ish view and links handles/PR numbers to `ReleaseFeed.repository`. [INFERENCE] low risk, I did not read `ReleaseNotesView`.
10. **Gatekeeper and TCC coupling.** If the signing certificate ever changes, Accessibility (and potentially other TCC) grants are lost once, per the project's own docs. Any plan using a different identity must be staged exactly the way Tinycast staged the Developer ID requirement (ship acceptance first, switch later).

Unknown (not established by primary sources I read):

- Whether any Tinycast release has ever been signed with Developer ID (the only release inspected, v0.12.1, is self-signed; the current beta zip was not downloaded).
- Whether real-world in-app updates leave the extracted bundle un-quarantined on current macOS (project claim; no first-hand run).
- Whether `auto_updates true` is present in some branch of the tap other than the examined commit.

## 10. Perch integration and proposed implementation

### Decision and trade-off

**Recommend a native updater for Perch's current signing model**, borrowing Tinycast's flow rather than copying its installer unchanged. Perch owns replacement, recovery and relaunch safety. Sparkle remains the lower-maintenance standard option if its compatibility is proven without weakening Release hardening, or if Perch adopts Developer ID.

Observed local integration points:

| Existing file | Current behavior | Proposed change |
| --- | --- | --- |
| [`Perch/App/PerchApp.swift`](../Perch/App/PerchApp.swift) | Accessory app, no main menu; startup excludes bridge/listeners under XCTest | Retain one updater coordinator; start only in production Release, outside XCTest. Disable it for `id.iyansr.perch.dev`. |
| [`Perch/Settings/SettingsPages.swift`](../Perch/Settings/SettingsPages.swift) | General page already holds startup and feedback controls | Add automatic-check toggle, installed version, and **Check for Updates…**. Manual checks remain available when automatic checks are off. |
| [`Scripts/build-release.sh`](../Scripts/build-release.sh) | Builds and verifies universal signed app; packages DMG | Also create `Perch-<version>.zip` using `ditto -c -k --keepParent --sequesterRsrc`. Extract a copy and verify its signature before publishing. |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml) | Publishes DMG; stable website alias; prereleases excluded from Homebrew | Upload versioned ZIP beside DMG. Publish complete assets before clients can select the release. Keep stable/prerelease filtering explicit. |
| [`Scripts/verify-signature.sh`](../Scripts/verify-signature.sh) | Pins certificate, checks universal app/CLI/adapter, hardened runtime and seal | Reuse these release invariants; explicitly verify embedded CLI and adapter after ZIP extraction and in updater validation. |
| [`Homebrew/perch.rb`](../Homebrew/perch.rb) | Versioned DMG, quarantine hook, quit before replacement; no `auto_updates` | Add `auto_updates true` when self-update ships. Continue publishing cask versions and hashes. |

Signing constraints are documented in [`signing.md`](signing.md): Release is self-signed, has no Team ID, uses hardened runtime, and pins the designated requirement to the same certificate. [`release.md`](release.md) describes the existing release contract. A live GitHub API query confirmed the repository is public, so an unauthenticated feed is reachable without distributing a token.

### Proposed native flow

1. **Discover.** Check stable releases automatically once daily, with a short startup delay and a user-visible off switch. Require user confirmation to download/install; do not silently restart Perch. Use the stable endpoint for stable builds so many newer beta releases cannot hide a stable release outside a 20-entry listing. Never bundle a GitHub token.
2. **Select.** Require the exact expected ZIP name and a newer semantic version. Perch already ships one universal app, so no separate thin/universal asset selection is needed. Do not introduce a beta channel or beta bundle ID as part of stable auto-update support.
3. **Stage.** Download over HTTPS with cancellation and progress, into a unique private staging directory. Reject incomplete transfers and unexpected archive layout. Treat metadata and release notes as untrusted input. Do not extract or execute arbitrary release-supplied commands.
4. **Authenticate.** Validate the entire app seal across architectures and nested code. Require `id.iyansr.perch`, expected signed marketing version, and a newer signed build number. Pin the existing designated requirement/certificate, not the certificate's display name. Explicitly check the CLI and MediaRemote adapter rather than assuming every resource path qualifies as nested code. A checksum from the same unsigned feed is not a substitute for identity verification.
5. **Prepare installation.** Reject read-only mounts, translocated copies, and unwritable destinations with actionable errors; do not request administrator credentials. Defer prompts and installation during active input or work. Do not mark every visible live activity as busy: persistent weather/media could otherwise block updates forever.
6. **Replace and relaunch.** Design a bounded installer/relauncher that waits for normal termination, verifies the staged candidate again, retains the old bundle until replacement succeeds, and restores it on replacement failure. Do not blindly copy Tinycast's live in-process swap. Preserve `applicationWillTerminate`, which stops the agent socket and activity sources and restores Apple's HUD. Prove that socket cleanup finishes before relaunch.
7. **Quarantine policy.** Authenticate first. If the implementation removes quarantine, do so only from the verified staged app; fail visibly if the installed candidate cannot launch. Do not claim self-signing satisfies Gatekeeper. First DMG installation retains the documented manual trust step until Developer ID/notarization changes.
8. **Ship the bootstrap release.** Existing Perch versions have no updater. Users must install the first updater-enabled release manually or through Homebrew. Subsequent releases can update in-app. Update README, release/install notes and signing documentation when the feature actually ships.

Implemented as described: stable `releases/latest` feed, staged and verified ZIP, out-of-process helper that waits for normal termination, requires an explicit commit, swaps at the same path, relaunches and restores the previous bundle on failure.

## 11. Sparkle alternative: official requirements

Sparkle's [official setup](https://sparkle-project.org/documentation/) supports SPM, programmatic initialization, Ed25519 archive signatures, and DMG or ZIP updates. Developer ID and notarization are recommended, not presented as prerequisites for configuring archive authentication. This does **not** establish end-to-end compatibility with Perch's signing.

- Add `https://github.com/sparkle-project/Sparkle` and retain an `SPUStandardUpdaterController`; expose `checkForUpdates` through Settings because Perch has no main menu. See [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/).
- Generate an update key once with `generate_keys`; embed `SUPublicEDKey` and a stable HTTPS `SUFeedURL`. Back up the private key separately from the app-signing identity and store the CI copy as a secret. Run `generate_appcast` against the final packaged archive.
- Proposed hosting: publish `appcast.xml` as an asset on every stable GitHub Release; use `https://github.com/iyansr/Perch/releases/latest/download/appcast.xml`. Point enclosures to immutable versioned release assets. Upload archive and feed before publishing the release. GitHub documents the [latest-release asset URL](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases); Sparkle redirect handling was not exercised here.
- Sparkle compares incrementing `CFBundleVersion`, not just the displayed version. Perch currently uses full-history commit count. That does not guarantee monotonicity across divergent branches or repeated releases from one commit; enforce a strictly higher build number at publication.
- [Customization](https://sparkle-project.org/documentation/customization/) distinguishes checks from installs: `SUEnableAutomaticChecks=YES` enables checks only; `SUAutomaticallyUpdate` defaults to `NO`. Leave silent installation off for the proposed UX. Without an explicit checks setting, Sparkle asks permission on second launch.
- Prefer `SUVerifyUpdateBeforeExtraction=YES`. Optional signed feeds require Sparkle 2.9+ and `SURequireSignedFeed`; key-loss and rotation consequences must be understood first. Do not assume Developer-ID-based rotation recovery exists for Perch's self-signed certificate.
- Sparkle's helper executables require correct inside-out signing, not merely signing the outer framework. See [code-signing instructions](https://sparkle-project.org/documentation/sandboxing/).

**Compatibility gate:** Apple says hardened runtime [library validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) accepts Apple-signed libraries or libraries with the host's Team ID. Sparkle warns that ad-hoc hosts can fail to load its framework. Perch's host is self-signed, not ad-hoc, but has no Team ID. **[INFERENCE]** Framework loading may fail; this investigation did not run that combination. A real Release launch and update must settle it. Do not silently add `disable-library-validation` or remove hardened runtime to make Sparkle work.

Homebrew officially supports [`auto_updates true`](https://docs.brew.sh/Cask-Cookbook) for apps that install their own updates. Ordinary upgrades exclude those casks; [`--greedy` / `--greedy-auto-updates`](https://docs.brew.sh/Manpage) can still include them. Never promise that Homebrew can no longer replace a self-updated app.

## 12. Verification required before shipping

Research checks: source inspection, live release API queries, and inspection of Tinycast's downloaded universal artifact (section 6). Perch's implementation was smoke-tested locally with signed 0.1.0 and 0.1.1 builds: successful in-place update and relaunch, rollback after a failed relaunch, cancelled handoff, and rejection of tampered, ad-hoc re-signed, older and mismatched-version bundles. Intel hardware, Homebrew upgrade behavior and a published GitHub release were not exercised.

Acceptance for either implementation:

- Update an installed older Release to a newer Release on macOS 26; inspect resulting bundle version, signature and relaunch. Cover Apple silicon and Intel.
- Confirm Accessibility and other previously granted permissions survive with the unchanged certificate. Confirm clipboard data, preferences and agent integration survive.
- Reject wrong certificate, wrong bundle ID, tampered nested CLI/adapter, wrong version/build, malformed archive and downgrade; keep the original runnable.
- Cancel downloads and simulate interrupted transfer, low disk space, unwritable Applications directory and replacement failure. Confirm recovery and a clear error.
- Confirm normal termination restores HUD state, closes the socket, and prevents duplicate Perch processes after relaunch.
- Check first-install quarantine separately from updater-installed quarantine. Do not infer Gatekeeper behavior from signature verification alone.
- Exercise manual checks, automatic-check opt-out, skip behavior, stable/prerelease isolation and missing ZIP assets.
- Install through Homebrew, self-update, then exercise ordinary and greedy upgrade behavior. Confirm documentation matches observed ownership.
- For Sparkle specifically, prove self-signed hardened-runtime launch, embedded helper signatures, archive authentication and installation before adopting the dependency.
