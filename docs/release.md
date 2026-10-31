# Releasing

Every release is built by the `Release` workflow (`.github/workflows/release.yml`). It builds a
universal `Perch.app`, signs it with the `Perch Self-Signed` identity, checks the signature, packages
`Perch-<version>.dmg`, and publishes it as GitHub Release `v<version>`. Three things start it: a merged
Changesets version pull request, a pushed `v<version>` tag, or a manual run.

## One-time setup

| Secret | Used by | Holds |
| --- | --- | --- |
| `SIGNING_P12_BASE64` | Release | The `Perch Self-Signed` identity (certificate and private key), base64 |
| `SIGNING_P12_PASSWORD` | Release | The password the `.p12` was exported with |
| `HOMEBREW_TAP_TOKEN` | Release | A token that can push to `iyansr/homebrew-perch` |

The Changesets workflow needs no secret: it uses the built-in `GITHUB_TOKEN`.

### 1. Signing identity

The workflow must sign with the same certificate as every earlier release. Any other certificate makes
macOS drop every user's privacy grants on update (see [signing.md](signing.md)), so
`Scripts/verify-signature.sh` fails the run unless the signature pins the `Perch Self-Signed`
certificate (SHA-1 `1F2AA6E84584DD5185AD1C42626BD2A148C810E8`).

1. Open Keychain Access, choose the **login** keychain and the **My Certificates** tab, select the
   `Perch Self-Signed` certificate row (not the private key nested under it), and use File › Export
   Items…. Save it as `perch-signing.p12` in the **Personal Information Exchange (.p12)** format, with
   a strong password. Exporting the certificate row includes its private key; exporting the key row
   gives a `.p12` with no certificate, which cannot sign. Do not use `security export`: it exports
   every identity in the keychain, including your Apple Development key.
2. Check the file holds the right identity:

   ```sh
   /usr/bin/openssl pkcs12 -in perch-signing.p12 -nokeys | /usr/bin/openssl x509 -noout -subject -fingerprint -sha1
   ```

   It asks for the export password, then must print the subject `/CN=Perch Self-Signed` and the SHA-1
   above. Use `/usr/bin/openssl` (LibreSSL): it reads both the legacy and the AES `.p12` formats, and
   Homebrew's OpenSSL 3 rejects the legacy one without `-legacy`.
3. Store it, then keep the `.p12` and its password in your password manager. They are also the backup
   that [signing.md](signing.md) asks for.

   ```sh
   base64 -i perch-signing.p12 | gh secret set SIGNING_P12_BASE64 --repo iyansr/Perch
   gh secret set SIGNING_P12_PASSWORD --repo iyansr/Perch   # paste the password at the prompt
   rm perch-signing.p12
   ```

### 2. Homebrew tap

Homebrew installs come from a separate tap repository, `iyansr/homebrew-perch`. The cask's source of
truth is `Homebrew/perch.rb` in this repository; `Scripts/render-cask.sh <version> <dmg>` prints it with
the release's version and SHA-256 filled in, and the workflow pushes that to the tap's `Casks/perch.rb`.

1. Create the tap. It must be public, and its README gives it a `main` branch to push to:

   ```sh
   gh repo create iyansr/homebrew-perch --public --add-readme --description "Homebrew tap for Perch"
   ```

2. Create a token at GitHub › Settings › Developer settings › Fine-grained tokens › Generate new token:
   - **Resource owner:** iyansr
   - **Expiration:** your choice. When it expires, the workflow fails to push; generate a new one and
     set the secret again.
   - **Repository access:** Only select repositories › `iyansr/homebrew-perch`
   - **Permissions:** Repository › Contents › Read and write (Metadata: Read-only is added for you)
3. Store it:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN --repo iyansr/Perch   # paste the token at the prompt
   ```

Without this secret the workflow still publishes the GitHub Release and warns that it skipped the cask.

The cask clears the quarantine flag in `postflight_steps`, so Homebrew users never run `xattr`. It quits
Perch before an upgrade or uninstall replaces the bundle, and `brew uninstall --zap` also removes
Perch's Application Support folder and preferences. Users install with:

```sh
brew trust --tap iyansr/perch
brew install --cask iyansr/perch/perch
```

### 3. Repository settings

In `iyansr/Perch` › Settings › Actions › General › Workflow permissions, enable **Allow GitHub Actions
to create and approve pull requests**. The Changesets workflow opens the version pull request with
`GITHUB_TOKEN`.

Check all three secrets are there with `gh secret list --repo iyansr/Perch`.

### While the repository is private

- The cask and the website download from `github.com/iyansr/Perch/releases`, which anonymous users can
  only reach once the repository is public. Until then `brew install` and the Download button fail
  for everyone else; you can still download a release with `gh release download`.
- macOS runner minutes count against your plan's included minutes at 10× the Linux rate on a private
  repository; public repositories run free.

The release workflows run on `push`, `workflow_call` and `workflow_dispatch` only, never on pull
requests, so making the repository public never exposes the secrets to a fork's code.

The Release workflow runs on the `xcode-27` runner image and uses its newest released Xcode 27.

## Cut a release

### With Changesets (recommended)

Versions live in the root `package.json`, which exists only for Changesets; Perch has no npm package.

1. With each user-facing change, add a changeset and commit it with the change:

   ```sh
   pnpm install          # once
   pnpm changeset        # pick patch, minor or major, then describe the change
   ```

2. On every push to `main` with pending changesets, the `Changesets` workflow
   (`.github/workflows/changesets.yml`) opens or updates a **chore: version Perch** pull request. It
   bumps `package.json`, writes `CHANGELOG.md` and deletes the consumed changesets. Each changelog
   entry links its pull request, commit and author (`@changesets/changelog-github`), so
   `changeset version` needs a `GITHUB_TOKEN`; the workflow provides one, and you never run it locally.
3. Merge that pull request when you want to ship. The push changes `package.json`'s version, so the
   workflow calls the Release workflow with it, and the release notes are that version's
   `CHANGELOG.md` section.

A tag pushed with `GITHUB_TOKEN` starts no workflow, so the Changesets workflow calls the Release
workflow directly instead of tagging. Re-running a failed run retries the release, because it only
skips a version that already has a GitHub Release.

For a pre-release, enter Changesets pre mode (`pnpm changeset pre enter beta`), merge version pull
requests as usual (they produce `0.2.0-beta.0`, `0.2.0-beta.1`, …), then `pnpm changeset pre exit`.

### With a tag

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The release notes are the tag's `CHANGELOG.md` section if there is one, and GitHub's generated notes
otherwise.

### By hand

```sh
gh workflow run release.yml -f version=0.2.0
```

### What the Release workflow does

1. Takes the version from the input or the tag. It rejects one that is not semver, or whose
   `v<version>` release already exists. A version with a suffix, such as `0.2.0-beta.1`, is a
   pre-release.
2. Imports the `.p12` into a temporary keychain, deleted when the job ends.
3. Runs `Scripts/build-release.sh <version> <commit count>`. `MARKETING_VERSION` is the version and
   `CURRENT_PROJECT_VERSION` is the number of commits on the released commit, so later releases always
   get a higher build number, whichever way they were started.
4. Uploads the DMG as a workflow artifact, then creates the GitHub Release (and its tag, unless a
   tag push started the run) on the commit being built. The notes are the changelog, install steps and
   the DMG's SHA-256. A stable release also gets an unversioned `Perch.dmg`, which the website's
   Download button links to through `releases/latest/download/Perch.dmg`.
5. For a stable release, bumps the cask in the tap. Pre-releases never reach Homebrew, because
   `brew upgrade` would install them for everyone.

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
