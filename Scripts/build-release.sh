#!/bin/bash
# Builds, verifies and packages a signed universal Perch.app into dist/Perch-<version>.dmg (first install)
# and dist/Perch-<version>.zip (the in-app updater's payload).
# Usage: build-release.sh <version> [build-number]. The release workflow runs this too; see docs/release.md.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: build-release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-1}"
IDENTITY="Perch Self-Signed"
DERIVED="${DERIVED_DATA_PATH:-build/ReleaseDerivedData}"
APP="$DERIVED/Build/Products/Release/Perch.app"
DMG="dist/Perch-${VERSION}.dmg"
ZIP="dist/Perch-${VERSION}.zip"

# Capture first: `grep -q` exits early, and under pipefail the SIGPIPE to `security` fails the test.
identities="$(security find-identity -p codesigning)"
if ! grep -q "\"$IDENTITY\"" <<<"$identities"; then
  echo "✗ '$IDENTITY' code-signing identity not found. See docs/signing.md." >&2
  exit 1
fi

echo "▸ Building Perch $VERSION ($BUILD_NUMBER)"
# A stale bundle could hide a build that silently skipped a phase.
rm -rf "$APP"
# ARCHS pinned: macOS 26 still boots on Intel, and one DMG serves both.
# --timestamp=none: Apple's timestamp server only stamps Apple-issued certificates.
xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$PLIST_VERSION" != "$VERSION" ]; then
  echo "✗ Built version is $PLIST_VERSION, expected $VERSION" >&2
  exit 1
fi

Scripts/verify-signature.sh "$APP"

echo "▸ Packaging $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto, not cp: it keeps the framework's symlinks and extended attributes, so the seal still verifies.
ditto "$APP" "$STAGE/Perch.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "$DMG"
# hdiutil create is deprecated on macOS 27. diskutil writes progress to stderr; show it only on failure.
if ! OUTPUT="$(diskutil image create from "$STAGE" --format UDZO --volumeName Perch "$DMG" 2>&1)"; then
  echo "$OUTPUT" >&2
  exit 1
fi

echo "▸ Packaging $ZIP"
rm -f "$ZIP"
# ditto, not zip: --keepParent stores Perch.app/ at the archive root and keeps symlinks, xattrs and the seal.
# --sequesterRsrc puts AppleDouble data in a top-level __MACOSX folder, so non-ditto extractors cannot write ._ files inside the bundle.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Round trip: the updater extracts this archive, so the extracted copy must pass the same checks.
echo "▸ Verifying extracted $ZIP"
EXTRACTED="$STAGE/extracted"
mkdir -p "$EXTRACTED"
ditto -x -k "$ZIP" "$EXTRACTED"
if [ "$(ls -A "$EXTRACTED")" != "Perch.app" ]; then
  echo "✗ $ZIP must contain exactly Perch.app at its root" >&2
  exit 1
fi
Scripts/verify-signature.sh "$EXTRACTED/Perch.app"

echo "✓ $DMG"
echo "✓ $ZIP"
shasum -a 256 "$DMG" "$ZIP"
