#!/bin/bash
# Builds MediaRemoteAdapter.framework from Vendor/ and installs it, with the perl script,
# into the app bundle's Resources/MediaRemoteAdapter.
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
V="$ROOT/Vendor/mediaremote-adapter"
: "${TARGET_BUILD_DIR:?must run from Xcode}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?must run from Xcode}"
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MediaRemoteAdapter"
FW="$OUT/MediaRemoteAdapter.framework"
BIN="$FW/Versions/A/MediaRemoteAdapter"

SOURCES=(
  src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m
  src/adapter/now_playing.m src/adapter/repeat.m src/adapter/seek.m src/adapter/send.m
  src/adapter/shuffle.m src/adapter/speed.m src/adapter/stream.m src/adapter/test.m
  src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m
)

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="-"
SIGN_ARGS=(--force --timestamp=none)
[ "$IDENTITY" = "-" ] || SIGN_ARGS+=(--options runtime)

ARCH_LIST="${ARCHS:-arm64 x86_64}"

mkdir -p "$OUT"
cp -f "$V/bin/mediaremote-adapter.pl" "$OUT/mediaremote-adapter.pl"

needs_build=0
if [ ! -f "$BIN" ] || [ ! -f "$FW/Versions/A/Resources/Info.plist" ]; then
  needs_build=1
else
  while IFS= read -r f; do
    if [ "$f" -nt "$BIN" ]; then needs_build=1; break; fi
  done < <(find "$V/src" "$V/include" -type f; echo "$0")
fi

if [ "$needs_build" = 1 ]; then
  rm -rf "$FW"
  mkdir -p "$FW/Versions/A/Resources"
  ARCH_FLAGS=()
  for a in $ARCH_LIST; do ARCH_FLAGS+=(-arch "$a"); done
  SRC_ABS=()
  for s in "${SOURCES[@]}"; do SRC_ABS+=("$V/$s"); done
  /usr/bin/clang "${ARCH_FLAGS[@]}" -dynamiclib -fobjc-arc -fvisibility=default \
    -mmacosx-version-min=14.0 -I "$V/include" -I "$V/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$BIN" "${SRC_ABS[@]}"

  cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  ln -sfn A "$FW/Versions/Current"
  ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
  ln -sfn Versions/Current/Resources "$FW/Resources"
fi

# Always (re)sign: the signing identity may change between builds.
/usr/bin/codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$FW"
