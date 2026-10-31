# Releasing

Releases are built by the `Release` GitHub Actions workflow (`.github/workflows/release.yml`). It
builds a universal `Perch.app`, signs it with the `Perch Self-Signed` identity, checks the signature,
packages `Perch-<version>.dmg`, and publishes it as GitHub Release `v<version>`.

## One-time setup

The workflow signs with the same certificate as local Release builds. Signing with any other
certificate makes macOS drop every user's privacy grants on update (see [signing.md](signing.md)), so
`Scripts/verify-signature.sh` fails the run unless the designated requirement pins the
`Perch Self-Signed` certificate (SHA-1 `1F2AA6E84584DD5185AD1C42626BD2A148C810E8`).

1. In Keychain Access, open the login keychain, select the `Perch Self-Signed` certificate, and use
   File › Export Items… to save it as `perch-signing.p12` with a strong password. Exporting the
   certificate includes its private key. Keep this file somewhere safe; it is also your backup.
2. Add two repository secrets (Settings › Secrets and variables › Actions):

   ```sh
   base64 -i perch-signing.p12 | gh secret set SIGNING_P12_BASE64
   gh secret set SIGNING_P12_PASSWORD   # prompts for the export password
   ```

The workflow runs on the `xcode-27` runner image and uses its newest released Xcode 27.

## Cut a release

```sh
gh workflow run release.yml -f version=0.1.0
gh workflow run release.yml -f version=0.2.0-beta.1 -f prerelease=true
```

Or use Actions › Release › Run workflow. The workflow:

1. Rejects a version that is not semver, or whose `v<version>` release already exists.
2. Imports the `.p12` into a temporary keychain, deleted when the job ends.
3. Runs `Scripts/build-release.sh <version> <run number>`. `MARKETING_VERSION` is the version and
   `CURRENT_PROJECT_VERSION` is the run number, so build numbers always increase.
4. Uploads the DMG as a workflow artifact, then creates the tag and GitHub Release on the dispatched
   commit. The notes are GitHub's generated changelog, install steps and the DMG's SHA-256.

## Build a release locally

With the identity in your login keychain:

```sh
./Scripts/build-release.sh 0.1.0
```

It writes `dist/Perch-0.1.0.dmg`. `Scripts/verify-signature.sh <Perch.app>` checks that the app, the
`perch` CLI and the MediaRemote adapter are universal, use the hardened runtime and are signed by
`Perch Self-Signed`; that the seal verifies; that the designated requirement pins the certificate;
that there is no `get-task-allow`; and that every usage string has its entitlement.

## Installing a release

The DMG is self-signed, not notarized, and Perch has no updater. After dragging each release to
Applications, users clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Perch.app
```
