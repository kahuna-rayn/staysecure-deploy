#!/usr/bin/env bash
# Fetch all agents for an Atera customer via API v3 (same contract as device-ingest/atera.ts).
# Use this to inspect raw Atera data before relying on device-ingest / hardware_inventory.
#
# Auth: Atera API key in header X-API-KEY (not Supabase).
#
# Usage:
#   ATERA_CUSTOMER_ID is required (--customer-id or env).
#   API key defaults below; override with ATERA_API_KEY or --api-key.
#
#   ./pull-atera-agents.sh --customer-id 12345
#   ATERA_CUSTOMER_ID=12345 ./pull-atera-agents.sh
#   ./pull-atera-agents.sh --customer-id 12345 --summary
#
# Options:
#   --summary   Print duplicate VendorSerialNumber counts to stderr (common cause of ingest upsert issues).
#
# Output:
#   deploy/scripts/backups/atera-agents-<customer_id>-<timestamp>.json
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/backups"
ATERA_BASE="https://app.atera.com/api/v3"
PAGE_SIZE=100

# Default key for local/dev pulls; override via ATERA_API_KEY or --api-key (rotate if this is ever leaked).
DEFAULT_ATERA_API_KEY='2ff9efc88f3d490d98a0e219991d72bd'

API_KEY="${ATERA_API_KEY:-}"
CUSTOMER_ID="${ATERA_CUSTOMER_ID:-}"
SUMMARY=0

usage() {
  sed -n '1,20p' "$0" | tail -n +2 | sed -n '/^# /s/^# //p'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --customer-id) CUSTOMER_ID="${2:-}"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "${API_KEY}" ]]; then
  API_KEY="${DEFAULT_ATERA_API_KEY}"
fi
if [[ -z "${CUSTOMER_ID}" ]]; then
  echo "Error: set ATERA_CUSTOMER_ID or pass --customer-id (integer)" >&2
  exit 1
fi
if ! [[ "${CUSTOMER_ID}" =~ ^[0-9]+$ ]]; then
  echo "Error: customer id must be an integer, got: ${CUSTOMER_ID}" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT="${OUTPUT_DIR}/atera-agents-${CUSTOMER_ID}-${TIMESTAMP}.json"

page=1
combined='[]'
while true; do
  url="${ATERA_BASE}/agents/customer/${CUSTOMER_ID}?page=${page}&itemsInPage=${PAGE_SIZE}"
  if ! resp=$(curl -sS -f \
    -H "X-API-KEY: ${API_KEY}" \
    -H "Accept: application/json" \
    "$url"); then
    echo "Error: Atera request failed (page ${page}): ${url}" >&2
    echo "Hint: check API key permissions and customer id." >&2
    exit 1
  fi

  chunk=$(echo "$resp" | jq -c '.items // .Items // []')
  combined=$(jq -n --argjson acc "$combined" --argjson ch "$chunk" '$acc + $ch')
  total_pages=$(echo "$resp" | jq '.totalPages // .TotalPages // 1')
  n=$(echo "$chunk" | jq 'length')

  if [[ "${page}" -ge "${total_pages}" ]] || [[ "${n}" -lt "${PAGE_SIZE}" ]]; then
    break
  fi
  page=$((page + 1))
done

# Single JSON document: metadata + agents (stable shape for tooling)
jq -n \
  --argjson agents "$combined" \
  --arg customer_id "${CUSTOMER_ID}" \
  --arg fetched_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{ customer_id: ($customer_id | tonumber), fetched_at: $fetched_at, agent_count: ($agents | length), agents: $agents }' \
  > "$OUT"

echo "Wrote ${OUT} ($(jq '.agent_count' "$OUT") agents)"

if [[ "${SUMMARY}" -eq 1 ]]; then
  echo "--- Serial / AgentID summary (stderr) ---" >&2
  jq -r '
    .agents
    | map({
        id: (.AgentID // .agentID),
        serial: ((.VendorSerialNumber // .vendorSerialNumber // "") | ascii_downcase | gsub("^\\s+|\\s+$";""))
      })
    | group_by(.serial)
    | map(select(length > 1))
    | sort_by(-length)
    | .[]
    | "dup \((.[0].serial | if . == "" then "(empty)" else . end)): \(length) agents ids=\(map(.id) | join(","))"
  ' "$OUT" >&2 || true
  dup_groups=$(jq '.agents | group_by(((.VendorSerialNumber // .vendorSerialNumber // "") | ascii_downcase | gsub("^\\s+|\\s+$";""))) | map(select(length > 1)) | length' "$OUT")
  echo "Duplicate serial groups (non-unique within response): ${dup_groups}" >&2
fi
