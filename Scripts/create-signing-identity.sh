#!/bin/bash
# Creates the "Perch Self-Signed" code-signing identity in the login keychain. Run once per Mac.
# Release builds sign with it so macOS keeps privacy grants across updates. See docs/signing.md.
set -euo pipefail

NAME="Perch Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Capture first: `grep -q` exits early, and under pipefail the SIGPIPE to `security` fails the test.
identities="$(security find-identity -p codesigning "$KEYCHAIN")"
if grep -q "\"$NAME\"" <<<"$identities"; then
  echo "\"$NAME\" already exists; nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# /usr/bin/openssl is LibreSSL. Its PKCS#12 output uses the legacy ciphers `security import` reads;
# Homebrew's OpenSSL 3 would need -legacy.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# security import rejects an empty PKCS#12 password; this one only lives until the import.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout pass:perch

# Only codesign may use the private key without a prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P perch -T /usr/bin/codesign

security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
