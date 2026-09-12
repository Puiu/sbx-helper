#!/usr/bin/env bash
# setup_dev_signing.sh — create one stable local signing identity so TCC
# grants survive rebuilds during development.
#
# Background (PLAN.md Phase 0 finding): ad-hoc signatures (`codesign
# --sign -`) change on every rebuild, so macOS TCC keys the iTerm Automation
# grant to something new each time — every repackaged build re-prompts (or
# silently stalls the AppleEvent) even though the bundle id is unchanged.
# Signing dev builds with a stable self-signed identity instead means you
# approve the Automation prompt once and it sticks across rebuilds.
#
# Usage (one time):
#   ./Scripts/setup_dev_signing.sh
#   export APP_IDENTITY=sbx-helper-dev   # then use the dev loop normally
#   ./Scripts/compile_and_run.sh
#
# The final distribution build (Scripts/install.sh) stays ad-hoc — this
# identity is for day-to-day iteration only. Do not enable the hardened
# runtime with ad-hoc signing; with this identity package_app.sh signs with
# --timestamp --options runtime, which is the supported combination.
set -euo pipefail

IDENTITY="${APP_IDENTITY:-sbx-helper-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Identity '$IDENTITY' already exists — nothing to do."
  echo "Use it with: export APP_IDENTITY=$IDENTITY"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate '$IDENTITY'"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 825 -nodes -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null
openssl pkcs12 -export \
  -out "$WORK/identity.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass: 2>/dev/null

echo "==> Importing into the login keychain (Keychain Access may prompt once)"
security import "$WORK/identity.p12" -k "$KEYCHAIN" \
  -T /usr/bin/codesign -T /usr/bin/security 2>&1 | grep -v "already exists" || true

echo "Done. Verify with:"
echo "  security find-identity -v -p codesigning | grep $IDENTITY"
echo "Then sign dev builds with it:"
echo "  export APP_IDENTITY=$IDENTITY"
echo "  ./Scripts/compile_and_run.sh"
echo "If TCC state ever goes stale: tccutil reset AppleEvents com.alexalbu.sbx-helper"
