#!/bin/sh
# bundle-and-install.sh — rebuild sbx-helper and install it into /Applications.
#
# Run it after any code change:
#   ./bundle-and-install.sh
#
# macOS only, matching the rest of this project.

set -eu

# Always operate relative to this script's own location, not the caller's cwd.
cd "$(dirname "$0")"

APP_NAME="sbx-helper"
INSTALL_PATH="/Applications/${APP_NAME}.app"

echo "==> Installing dependencies (also reapplies the patch-package fix)"
npm install

echo "==> Building ${APP_NAME}.app"
npm run package

# electron-forge names the output directory after the actual build
# architecture, not necessarily this Mac's — but we're building for the Mac
# we're running on, so map `uname -m` to the same naming Electron uses
# (arm64 stays arm64; Intel's x86_64 becomes x64) instead of hardcoding
# "darwin-arm64", so this keeps working unmodified on either Mac type.
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *) echo "Unrecognized architecture: $ARCH_RAW" >&2; exit 1 ;;
esac

BUILD_PATH="out/${APP_NAME}-darwin-${ARCH}/${APP_NAME}.app"
if [ ! -d "$BUILD_PATH" ]; then
  echo "Expected build output at $BUILD_PATH but it's not there." >&2
  exit 1
fi

echo "==> Installing to ${INSTALL_PATH}"

# Quit a currently-running installed copy first, so a later double-click
# isn't looking at the process we're about to replace on disk. Guarded: this
# is a no-op (not a failure) when nothing's running.
pkill -f "${INSTALL_PATH}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 || true

rm -rf "$INSTALL_PATH"
cp -R "$BUILD_PATH" "$INSTALL_PATH"

# Local builds don't usually pick up the quarantine flag the way a download
# would, but strip it defensively anyway — cheap, and keeps this consistent
# with the Gatekeeper note in README.md.
xattr -cr "$INSTALL_PATH" 2>/dev/null || true

echo "==> Launching ${APP_NAME}"
open "$INSTALL_PATH"

echo "Done — installed at ${INSTALL_PATH}"
