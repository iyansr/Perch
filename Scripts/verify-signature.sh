#!/bin/bash
# Asserts a Release Perch.app is signed the way every release must be. Usage: verify-signature.sh <Perch.app>
# See docs/release.md.
set -uo pipefail

APP="${1:?usage: verify-signature.sh <path-to-Perch.app>}"
STATUS=0

# SHA-1 of the "Perch Self-Signed" certificate. The designated requirement pins it, so a build signed
# with any other certificate makes macOS drop every privacy grant on update. See docs/signing.md.
EXPECTED_LEAF="1F2AA6E84584DD5185AD1C42626BD2A148C810E8"
EXPECTED_ID="id.iyansr.perch"

# Each usage string needs its hardened-runtime entitlement, or the request is denied without a prompt.
USAGE_ENTITLEMENTS=(
  NSAppleEventsUsageDescription=com.apple.security.automation.apple-events
  NSMicrophoneUsageDescription=com.apple.security.device.audio-input
  NSCameraUsageDescription=com.apple.security.device.camera
  NSCalendarsFullAccessUsageDescription=com.apple.security.personal-information.calendars
  NSContactsUsageDescription=com.apple.security.personal-information.addressbook
  NSLocationUsageDescription=com.apple.security.personal-information.location
  NSLocationWhenInUseUsageDescription=com.apple.security.personal-information.location
)

fail() {
  echo "✗ $1" >&2
  STATUS=1
}

[ -d "$APP" ] || { echo "✗ $APP not found" >&2; exit 1; }

# Shipped Mach-O code: the app, the bundled CLI and the MediaRemote adapter the perl helper loads.
BINARIES=(
  "$APP/Contents/MacOS/Perch"
  "$APP/Contents/Helpers/perch"
  "$APP/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
)
for BIN in "${BINARIES[@]}"; do
  NAME="${BIN##*/}"
  if [ ! -f "$BIN" ]; then
    fail "$NAME: missing from the bundle"
    continue
  fi
  INFO="$(codesign -dv --verbose=2 "$BIN" 2>&1)"
  [[ "$INFO" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "$NAME: hardened runtime not enabled"
  grep -Fxq "Authority=Perch Self-Signed" <<<"$INFO" || fail "$NAME: not signed by Perch Self-Signed"
  # macOS 26 still boots on Intel, so every shipped binary carries both slices.
  ARCHS="$(lipo -archs "$BIN" 2>/dev/null)"
  for A in arm64 x86_64; do
    [[ " $ARCHS " == *" $A "* ]] || fail "$NAME: no $A slice (has '$ARCHS')"
  done
done

codesign --verify --deep --strict "$APP" || fail "Perch.app: the seal does not verify"

REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
grep -Fq "identifier \"$EXPECTED_ID\"" <<<"$REQUIREMENT" || fail "Perch.app: designated requirement does not name $EXPECTED_ID"
grep -iFq "certificate leaf = H\"$EXPECTED_LEAF\"" <<<"$REQUIREMENT" ||
  fail "Perch.app: designated requirement does not pin the Perch Self-Signed certificate ($EXPECTED_LEAF)"

ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

# Xcode injects get-task-allow unless CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO; it lets any debugger attach.
for BIN in "$APP" "$APP/Contents/Helpers/perch"; do
  codesign -d --entitlements - --xml "$BIN" >"$ENTITLEMENTS" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ENTITLEMENTS" &>/dev/null &&
    fail "${BIN##*/}: get-task-allow is present"
done

codesign -d --entitlements - --xml "$APP" >"$ENTITLEMENTS" 2>/dev/null
for PAIR in "${USAGE_ENTITLEMENTS[@]}"; do
  USAGE="${PAIR%%=*}" ENTITLEMENT="${PAIR#*=}"
  /usr/libexec/PlistBuddy -c "Print :$USAGE" "$APP/Contents/Info.plist" &>/dev/null || continue
  [ "$(/usr/libexec/PlistBuddy -c "Print :$ENTITLEMENT" "$ENTITLEMENTS" 2>/dev/null)" = true ] ||
    fail "Perch.app: $USAGE is declared but $ENTITLEMENT is not"
done

if [ "$STATUS" -eq 0 ]; then
  echo "✓ Perch.app is universal, signed by Perch Self-Signed, and its prompts are entitled"
fi
exit "$STATUS"
