#!/usr/bin/env bash
# install.sh — rebuild the native sbx-helper and install it into /Applications.
#
# Port of src/electron/bundle-and-install.sh, adapted for the SwiftPM app:
# no npm step (zero package dependencies), the build goes through
# package_app.sh, and the installed name is sbx-helper.app (replacing the
# Electron build) even though the bundle target itself is SbxHelperApp.
#
# Run it after any code change:
#   ./Scripts/install.sh
#
# macOS only, matching the rest of this project.
#
# Environment overrides (used by dry-run verification, not normal installs):
#   INSTALL_PATH   install destination (default /Applications/sbx-helper.app)
#   SKIP_LAUNCH=1   install but don't `open` the result
#   SIGNING_MODE / APP_IDENTITY are passed through to package_app.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_NAME="SbxHelperApp"
INSTALL_PATH="${INSTALL_PATH:-/Applications/sbx-helper.app}"

echo "==> Building ${BUILD_NAME}.app"
APP_NAME="$BUILD_NAME" ./Scripts/package_app.sh release

BUILD_PATH="${BUILD_NAME}.app"
if [ ! -d "$BUILD_PATH" ]; then
  echo "Expected build output at $BUILD_PATH but it's not there." >&2
  exit 1
fi

echo "==> Installing to ${INSTALL_PATH}"

# Quit a currently-running installed copy first, so a later double-click
# isn't looking at the process we're about to replace on disk. Guarded: this
# is a no-op (not a failure) when nothing's running.
pkill -f "${INSTALL_PATH}/Contents/MacOS/${BUILD_NAME}" >/dev/null 2>&1 || true

rm -rf "$INSTALL_PATH"
cp -R "$BUILD_PATH" "$INSTALL_PATH"

# Local builds don't usually pick up the quarantine flag the way a download
# would, but strip it defensively anyway — cheap, and keeps this consistent
# with the Gatekeeper note in README.md.
xattr -cr "$INSTALL_PATH" 2>/dev/null || true

if [ "${SKIP_LAUNCH:-0}" != "1" ]; then
  echo "==> Launching ${INSTALL_PATH}"
  open "$INSTALL_PATH"
fi

echo "Done — installed at ${INSTALL_PATH}"
