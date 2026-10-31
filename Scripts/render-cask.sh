#!/bin/bash
# Prints Homebrew/perch.rb with the release's version and DMG checksum filled in.
# Usage: render-cask.sh <version> <path-to-Perch-<version>.dmg>. See docs/release.md.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: render-cask.sh <version> <dmg>}"
DMG="${2:?usage: render-cask.sh <version> <dmg>}"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

sed -E \
  -e "s|^  version \".*\"$|  version \"${VERSION}\"|" \
  -e "s|^  sha256 \".*\"$|  sha256 \"${SHA256}\"|" \
  Homebrew/perch.rb
