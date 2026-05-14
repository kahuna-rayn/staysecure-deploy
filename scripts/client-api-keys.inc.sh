#!/usr/bin/env bash
# Resolve PROJECT_REF + LEARN/GOVERN API keys for pull scripts.
#
# Usage (source this file, then call the function):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/client-api-keys.inc.sh"
#   resolve_api_keys_for_target "$1" || exit $?
#
# Accepts (with or without leading --):
#   --dev / dev             → DEV_REF from projects.conf + dev-secrets.env
#   --staging / staging     → STAGING_REF from projects.conf + client-api-keys.json
#   --lentor / lentor       → LENTOR_REF from projects.conf + client-api-keys.json
#   <20-char ref>           → Raw ref; keys looked up in client-api-keys.json by project_ref
#
# Exports: PROJECT_REF, CLIENT_SHORT, LEARN_API_KEY, GOVERN_API_KEY, IMPORT_INTERNAL_TOKEN

resolve_api_keys_for_target() {
  local arg="${1:-}"
  local _here _root _secrets _conf _dev _keys short

  if [[ -z "$arg" ]]; then
    echo "Error: pass a target flag (--dev, --staging, --lentor, ...) or a raw project ref." >&2
    return 1
  fi

  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _root="$(cd "${_here}/../.." && pwd)"
  _secrets="${_root}/learn/secrets"
  _conf="${_secrets}/projects.conf"
  _dev="${_secrets}/dev-secrets.env"
  _keys="${_secrets}/client-api-keys.json"

  # Strip leading -- to get the short name
  short="${arg#--}"

  # ── Dev: use DEV_REF + dev-secrets.env ──────────────────────────────────────
  if [[ "$short" == "dev" ]]; then
    if [[ ! -f "$_conf" ]]; then
      echo "Error: projects.conf not found at ${_conf}" >&2; return 1
    fi
    # shellcheck source=/dev/null
    source "$_conf"
    export PROJECT_REF="$DEV_REF"
    export CLIENT_SHORT="dev"
    if [[ ! -f "$_dev" ]]; then
      echo "Error: dev-secrets.env not found at ${_dev}" >&2; return 1
    fi
    set -a; source "$_dev"; set +a
    return 0
  fi

  # ── Named target: resolve via projects.conf ──────────────────────────────────
  if [[ ! "$short" =~ ^[a-z0-9]{20}$ ]]; then
    # It's a short name — look up <UPPER>_REF in projects.conf
    if [[ ! -f "$_conf" ]]; then
      echo "Error: projects.conf not found at ${_conf}" >&2; return 1
    fi
    # shellcheck source=/dev/null
    source "$_conf"
    local upper_key
    upper_key="$(echo "${short}" | tr '[:lower:]-' '[:upper:]_')_REF"
    local resolved_ref="${!upper_key:-}"
    if [[ -z "$resolved_ref" ]]; then
      echo "Error: '${short}' not found in projects.conf (looked for ${upper_key})." >&2
      echo "  Available: dev, staging, master, $(grep '_REF=' "$_conf" | sed 's/_REF=.*//' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')" >&2
      return 1
    fi
    export PROJECT_REF="$resolved_ref"
    export CLIENT_SHORT="$short"
  else
    # Raw 20-char ref
    export PROJECT_REF="$short"
    export CLIENT_SHORT=""
  fi

  # ── Load API keys from client-api-keys.json ──────────────────────────────────
  if [[ ! -f "$_keys" ]]; then
    echo "Error: client-api-keys.json not found at ${_keys}" >&2; return 1
  fi

  # Try by short name first; fall back to matching project_ref field
  local entry=""
  if [[ -n "$CLIENT_SHORT" ]]; then
    entry=$(jq -r --arg k "$CLIENT_SHORT" '.[$k] // empty' "$_keys" 2>/dev/null)
  fi
  if [[ -z "$entry" ]]; then
    entry=$(jq -r --arg ref "$PROJECT_REF" 'to_entries[] | select(.value.project_ref == $ref) | .value' "$_keys" 2>/dev/null)
    # Also set CLIENT_SHORT from the matched key if it wasn't already set
    if [[ -z "$CLIENT_SHORT" && -n "$entry" ]]; then
      CLIENT_SHORT=$(jq -r --arg ref "$PROJECT_REF" 'to_entries[] | select(.value.project_ref == $ref) | .key' "$_keys" 2>/dev/null)
      export CLIENT_SHORT
    fi
  fi

  if [[ -z "$entry" ]]; then
    echo "Warning: No entry in client-api-keys.json for '${CLIENT_SHORT:-$PROJECT_REF}'." >&2
    echo "  API keys will be empty — set LEARN_API_KEY / GOVERN_API_KEY in your environment." >&2
    return 0
  fi

  export LEARN_API_KEY=$(echo "$entry" | jq -r '.LEARN_API_KEY // empty')
  export GOVERN_API_KEY=$(echo "$entry" | jq -r '.GOVERN_API_KEY // empty')
  export IMPORT_INTERNAL_TOKEN=$(echo "$entry" | jq -r '.IMPORT_INTERNAL_TOKEN // empty')
}
