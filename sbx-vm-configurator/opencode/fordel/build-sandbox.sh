#!/usr/bin/env bash
#
# Builds the combined .NET 10 + Swift 6 OpenCode sandbox image, exports it,
# loads it into sbx's local template store, and starts a sandbox from it.
#
# Usage:
#   ./build-sandbox.sh [workspace-path]
#
# Config (override via env var):
#   IMAGE_NAME  (default: opencode-sbx-fordel)
#   IMAGE_TAG   (default: v1)  -- bump this each time you rebuild
#
# Zen API key: NOT baked into the image. Supply it at runtime via
#   sbx secret set-custom --host opencode.ai --env OPENCODE_API_KEY --value "$OPENCODE_API_KEY"
# plus `sbx policy allow network opencode.ai:443` (see README.md).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"  # statusline-command.sh lives at the sbx-vm-configurator root

IMAGE_NAME="${IMAGE_NAME:-opencode-sbx-fordel}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"
TAR_FILE="${SCRIPT_DIR}/${IMAGE_NAME}-${IMAGE_TAG}.tar"
WORKSPACE="${1:-$PWD}"

for cmd in docker sbx; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found on PATH." >&2
    exit 1
  fi
done

echo "==> Step 2: Building image ${FULL_TAG}"
docker build -f "${SCRIPT_DIR}/Dockerfile" -t "${FULL_TAG}" "${CONTEXT_DIR}"

echo "==> Step 3: Exporting image to ${TAR_FILE}"
docker image save "${FULL_TAG}" -o "${TAR_FILE}"

echo "==> Step 4: Loading template into sbx"
sbx template load "${TAR_FILE}"

# remove TAR_FILE after loading it into sbx
echo "==> Step 4b: Removing exported image file ${TAR_FILE}"
rm -f "${TAR_FILE}"
echo "==> Finished removing exported image file ${TAR_FILE}"

# echo "==> Step 5: Starting sandbox from ${FULL_TAG} in ${WORKSPACE}"
# echo "    (Step 6: once inside, run 'dotnet --version' and 'swift --version' to confirm both toolchains)"
# sbx run --template "${FULL_TAG}" opencode "${WORKSPACE}"
