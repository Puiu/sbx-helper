#!/usr/bin/env bash
#
# Stores sandbox secrets from .env into sbx's secret store and opens the
# matching network policy. Idempotent — safe to re-run after editing .env.
#
# Usage (from sbx-vm-configurator/):
#   cp .env.example .env   # once; fill in real values (never commit .env)
#   ./setup-secrets.sh
#
# After adding secrets, recreate existing sandboxes (`sbx rm` + `sbx run`)
# so the new env vars are present inside.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if ! command -v sbx >/dev/null 2>&1; then
  echo "Error: 'sbx' not found on PATH." >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: '${ENV_FILE}' not found. Copy the template first:" >&2
  echo "  cp \"${SCRIPT_DIR}/.env.example\" \"${ENV_FILE}\"" >&2
  exit 1
fi

# Load .env (KEY=VALUE lines only; skips blanks/comments). Values are never echoed.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

set_secret() {
  local host="$1" env_name="$2" value="$3"
  if [[ -z "${value}" ]]; then
    echo "Skipping ${env_name} (empty/unset in ${ENV_FILE})."
    return 0
  fi
  echo "Setting secret ${env_name} for host ${host}..."
  sbx secret set-custom --host "${host}" --env "${env_name}" --value "${value}"
}

allow_network() {
  local rule="$1" env_name="$2" value="$3"
  if [[ -z "${value}" ]]; then
    return 0
  fi
  echo "Allowing network ${rule} (for ${env_name})..."
  sbx policy allow network "${rule}"
}

set_secret "mcp.context7.com" "CONTEXT7_API_KEY" "${CONTEXT7_API_KEY:-}"
allow_network "mcp.context7.com:443" "CONTEXT7_API_KEY" "${CONTEXT7_API_KEY:-}"

set_secret "dev.azure.com" "AZURE_DEVOPS_PAT" "${AZURE_DEVOPS_PAT:-}"
# NOTE: no `sbx policy allow` for dev.azure.com here — the PAT is sent to
# assorted AzDO hosts (dev.azure.com, *.visualstudio.com, nuget feeds)
# depending on your org setup; open exactly what you need, e.g.:
#   sbx policy allow network dev.azure.com:443

set_secret "opencode.ai" "OPENCODE_API_KEY" "${OPENCODE_API_KEY:-}"
allow_network "opencode.ai:443" "OPENCODE_API_KEY" "${OPENCODE_API_KEY:-}"

set_secret "github.com" "GITHUB_PAT" "${GITHUB_PAT:-}"
allow_network "github.com:443" "GITHUB_PAT" "${GITHUB_PAT:-}"

set_secret "api.anthropic.com" "CLAUDE_API_KEY" "${CLAUDE_API_KEY:-}"
allow_network "api.anthropic.com:443" "CLAUDE_API_KEY" "${CLAUDE_API_KEY:-}"

echo "Done. Recreate existing sandboxes (sbx rm + sbx run) to pick up new secrets."
