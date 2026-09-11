#!/usr/bin/env bash
#
# Builds the custom Claude Code sandbox image, exports it, loads it into
# sbx's local template store, and starts a sandbox from it.
#
# Usage:
#   ./build-and-run-sandbox.sh [workspace-path]
#
# Config (override via env var):
#   IMAGE_NAME  (default: claude-sbx-dotnet10)
#   IMAGE_TAG   (default: v3)  -- bump this each time you rebuild
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_DIR="$(dirname "${SCRIPT_DIR}")"  # statusline-command.sh lives one level up

IMAGE_NAME="${IMAGE_NAME:-claude-sbx-dotnet10}"
IMAGE_TAG="${IMAGE_TAG:-v3}"
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

# echo "==> Step 5: Starting sandbox from ${FULL_TAG} in ${WORKSPACE}"
# echo "    (Step 6: once inside, run 'dotnet --version' to confirm the SDK)"
# sbx run --template "${FULL_TAG}" claude "${WORKSPACE}"
