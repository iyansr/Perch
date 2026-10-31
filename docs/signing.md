# Signing

Perch has no paid Apple Developer account, so it can't use a Developer ID certificate or notarization.
Release builds are signed with a **stable self-signed identity** called `Perch Self-Signed` instead.

## Why

macOS stores privacy grants (Accessibility, Microphone, Calendars, Contacts, Location, Apple events)
against the app's *designated requirement*, which is derived from its signature. Ad-hoc signing gives
every build a new requirement (`cdhash H"…"`), so macOS forgets every grant on each update. Signing
every release with the same certificate keeps the requirement the same:

```
identifier "id.iyansr.perch" and certificate leaf = H"<sha1 of Perch Self-Signed>"
```

Check any build with `codesign -d -r- Perch.app`.

## What signs with what

| Configuration | Identity | Hardened runtime |
| --- | --- | --- |
| Debug | Automatic, team `YY38U4HDQ3` (Apple Development) | Yes |
| Release | Manual, `Perch Self-Signed`, no team | Yes |

Debug keeps Apple Development signing: its requirement pins the certificate's common name, so
Accessibility already survives rebuilds, and its Team ID lets library validation load Xcode's
`Perch.debug.dylib`. A self-signed certificate has no Team ID, so a Debug build signed with it would be
refused at launch under the hardened runtime.

Release sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` on the app and the `perch` CLI. Otherwise
Xcode adds `com.apple.security.get-task-allow`, which lets any debugger attach to a shipped build.

Debug builds are `Perch Dev.app` with bundle ID `id.iyansr.perch.dev`; Release is `Perch.app` with
`id.iyansr.perch`. macOS keeps grants and preferences per bundle ID, so the two coexist on one Mac
without overwriting each other's grants. Each one asks for its permissions separately.

## Create the identity (once per Mac)

```sh
./Scripts/create-signing-identity.sh
```

It generates a 10-year self-signed code-signing certificate with `/usr/bin/openssl` and imports it
into the login keychain, letting only `/usr/bin/codesign` use the key. It does nothing if the identity
already exists. `security find-identity -p codesigning` lists it as `CSSMERR_TP_NOT_TRUSTED`; that is
expected and does not stop `codesign`.

**Back the identity up.** The requirement pins this exact certificate. If it is lost and recreated,
every installed copy's grants are lost on the next update, and users must grant them again. Export it
to a password-protected file kept somewhere safe:

```sh
security export -t identities -f pkcs12 -k ~/Library/Keychains/login.keychain-db \
  -P "<password>" -o ~/perch-signing.p12
```

`security export` exports every identity in the keychain. To keep only Perch's, open Keychain Access,
select the `Perch Self-Signed` certificate, and use File › Export Items… instead.

The same `.p12`, base64-encoded, is what a CI release job would import. Perch has no CI yet.

## Gatekeeper

Self-signing does not satisfy Gatekeeper. A downloaded build is quarantined and macOS refuses to open
it as coming from an unidentified developer. Users clear the flag once after copying Perch to
`/Applications`:

```sh
xattr -dr com.apple.quarantine /Applications/Perch.app
```

A Homebrew cask can do this in `postflight`. Moving to a paid account later means signing with
Developer ID and notarizing; that changes the requirement, so every user grants permissions once more.
