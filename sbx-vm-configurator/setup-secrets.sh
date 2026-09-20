#!/usr/bin/env bash
#
# Stores sandbox secrets from .env into sbx's secret store and opens the
# matching network policy. Idempotent — safe to re-run after editing .env,
# including to rotate a key that's already stored (requires jq).
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

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found on PATH." >&2
  echo "  jq is required to read 'sbx secret ls --json' and detect secrets that" >&2
  echo "  already exist. Install it and re-run this script." >&2
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

# Placeholder of the existing global custom secret for env var $1, else empty.
existing_placeholder() {
  local env_name="$1"
  sbx secret ls --json 2>/dev/null \
    | jq -r --arg env "${env_name}" '
        (.custom_secrets // [])
        | map(select(.scope == "global" and .env == $env))
        | .[0].placeholder // empty'
}

# set-custom has no --force (verified against sbx v0.42.1): an existing custom
# secret must be removed before it can be re-created. When one already exists,
# reuse its placeholder so sandboxes that already hold the old env var value
# keep working — only the real secret behind it rotates.
set_secret() {
  local env_name="$1" value="$2"
  shift 2
  local hosts=("$@") host_args=() h placeholder
  if [[ -z "${value}" ]]; then
    echo "Skipping ${env_name} (empty/unset in ${ENV_FILE})."
    return 0
  fi
  for h in "${hosts[@]}"; do host_args+=(--host "${h}"); done

  placeholder="$(existing_placeholder "${env_name}")"
  if [[ -n "${placeholder}" ]]; then
    echo "Updating secret ${env_name} (hosts: ${hosts[*]})..."
    sbx secret rm --placeholder "${placeholder}" -f
    if ! sbx secret set-custom "${host_args[@]}" --env "${env_name}" \
           --placeholder "${placeholder}" --value "${value}"; then
      echo "ERROR: failed to re-create ${env_name}; its previous entry was already removed." >&2
      echo "       Fix the error above and re-run this script." >&2
      return 1
    fi
  else
    echo "Setting secret ${env_name} (hosts: ${hosts[*]})..."
    sbx secret set-custom "${host_args[@]}" --env "${env_name}" --value "${value}"
  fi
}

allow_network() {
  local rule="$1" env_name="$2" value="$3"
  if [[ -z "${value}" ]]; then
    return 0
  fi
  echo "Allowing network ${rule} (for ${env_name})..."
  sbx policy allow network "${rule}"
}

# Service secrets are the built-in sbx path: the proxy authenticates requests
# (including git over HTTPS) on the sandbox's behalf. Distinct from set_secret
# above, which only injects a placeholder env var and rewrites request headers —
# git sends no auth header, so a custom secret alone cannot authenticate a clone.
set_service_secret() {
  local service="$1" value="$2"
  if [[ -z "${value}" ]]; then
    echo "Skipping ${service} service secret (empty/unset in ${ENV_FILE})."
    return 0
  fi
  echo "Setting ${service} service secret..."
  sbx secret set "${service}" --token "${value}" --force
}

set_secret "CONTEXT7_API_KEY" "${CONTEXT7_API_KEY:-}" "mcp.context7.com"
allow_network "mcp.context7.com:443" "CONTEXT7_API_KEY" "${CONTEXT7_API_KEY:-}"

set_secret "AZURE_DEVOPS_PAT" "${AZURE_DEVOPS_PAT:-}" "dev.azure.com" "pkgs.dev.azure.com"
# NOTE: no `sbx policy allow` for dev.azure.com/pkgs.dev.azure.com here — the
# PAT is sent to assorted AzDO hosts (dev.azure.com, *.visualstudio.com, nuget
# feeds) depending on your org setup; open exactly what you need, e.g.:
#   sbx policy allow network dev.azure.com:443
#   sbx policy allow network pkgs.dev.azure.com:443

set_secret "OPENCODE_API_KEY" "${OPENCODE_API_KEY:-}" "opencode.ai"
allow_network "opencode.ai:443" "OPENCODE_API_KEY" "${OPENCODE_API_KEY:-}"

set_service_secret "github" "${GITHUB_PAT:-}"
set_secret "GITHUB_PAT" "${GITHUB_PAT:-}" "github.com"
allow_network "github.com:443" "GITHUB_PAT" "${GITHUB_PAT:-}"

set_secret "CLAUDE_CODE_OAUTH_TOKEN" "${CLAUDE_CODE_OAUTH_TOKEN:-}" "api.anthropic.com"
allow_network "api.anthropic.com:443" "CLAUDE_CODE_OAUTH_TOKEN" "${CLAUDE_CODE_OAUTH_TOKEN:-}"

echo "Done. Recreate existing sandboxes (sbx rm + sbx run) to pick up new secrets."
