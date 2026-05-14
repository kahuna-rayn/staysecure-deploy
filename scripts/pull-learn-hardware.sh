#!/bin/bash
# Pull all hardware inventory devices via the device-ingest Edge Function.
# Paginates through all pages and writes the combined result to a JSON snapshot file.
# Fetches a detail sample via GET /v1/devices/:id (same pattern as profile-lookup).
#
# Uses GOVERN_API_KEY — see govern/docs/DEVICE_INGEST_API_REFERENCE.md.
#
# Usage:
#   ./pull-learn-hardware.sh --dev
#   ./pull-learn-hardware.sh --staging
#   ./pull-learn-hardware.sh --lentor
#   ./pull-learn-hardware.sh <20-char-project_ref>
#
# Project ref and API keys are resolved via projects.conf + learn/secrets/client-api-keys.json.
# For --dev, keys are read from learn/secrets/dev-secrets.env.
#
# Examples:
#   ./pull-learn-hardware.sh --dev
#   ./pull-learn-hardware.sh --ygos
#
# Output:
#   deploy/scripts/backups/hardware-snapshot-<timestamp>.json

set -euo pipefail

# ---------------------------------------------------------------------------
# Args & config
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=client-api-keys.inc.sh
source "${SCRIPT_DIR}/client-api-keys.inc.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <--dev | --staging | --lentor | --ygos | ... | project_ref>"
  echo "  --dev / --staging / --<short>   → resolved via projects.conf + client-api-keys.json"
  echo "  <20-char ref>                   → raw ref; keys looked up in client-api-keys.json"
  exit 1
fi

resolve_api_keys_for_target "$1" || exit $?

API_KEY="${GOVERN_API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: GOVERN_API_KEY not set — check learn/secrets/dev-secrets.env"
  exit 1
fi

BASE_URL="https://${PROJECT_REF}.supabase.co/functions/v1/device-ingest"
PAGE_SIZE=200
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="${SCRIPT_DIR}/backups"
OUTPUT_FILE="${OUTPUT_DIR}/hardware-snapshot-${TIMESTAMP}.json"

mkdir -p "$OUTPUT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Paginate devices (same flow as profiles /v1/profiles)
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Pulling devices from ${BASE_URL}/v1/devices${NC}"

all_devices="[]"
page=1
total_count=0
total_pages=0

while true; do
  response=$(curl -sf \
    "${BASE_URL}/v1/devices?page=${page}&page_size=${PAGE_SIZE}" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json") || {
    echo -e "${RED}Request failed on page ${page}${NC}"
    exit 1
  }

  # Validate it's JSON with a data array
  if ! echo "$response" | jq -e '.data | arrays' > /dev/null 2>&1; then
    echo -e "${RED}Unexpected response:${NC}"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    exit 1
  fi

  page_data=$(echo "$response" | jq '.data')
  page_count=$(echo "$page_data" | jq 'length')
  total_count=$(echo "$response" | jq '.pagination.total_count')
  total_pages=$(echo "$response" | jq '.pagination.total_pages')
  has_next=$(echo "$response" | jq '.pagination.has_next_page')

  all_devices=$(echo "$all_devices $page_data" | jq -s '.[0] + .[1]')

  echo "  Page ${page}/${total_pages} — ${page_count} records (${total_count} total)"

  if [[ "$has_next" != "true" ]]; then
    break
  fi

  page=$((page + 1))
done

fetched=$(echo "$all_devices" | jq 'length')

echo -e "${GREEN}Done. ${fetched}/${total_count} devices fetched.${NC}"

# ---------------------------------------------------------------------------
# Quick validation summary
# ---------------------------------------------------------------------------

echo ""
echo "Validation summary:"
echo "$all_devices" | jq '
  {
    total: length,
    by_source: (group_by(.source // "null") | map({ (.[0].source // "null"): length }) | add),
    missing_serial:    (map(select(.serial_number == null or .serial_number == "")) | length),
    missing_device_name: (map(select(.device_name == null or .device_name == "")) | length),
    by_os: (group_by(.os_type // "null") | map({ (.[0].os_type // "null"): length }) | add)
  }
'

# ---------------------------------------------------------------------------
# Single-device endpoint — fetch first N devices (same pattern as enriched profiles)
# ---------------------------------------------------------------------------

ENRICHED_SAMPLE_SIZE=5
enriched_sample="[]"
enriched_ok=0
enriched_fail=0

sample_ids=$(echo "$all_devices" | jq -r ".[0:${ENRICHED_SAMPLE_SIZE}][].id")

if [[ -n "$sample_ids" ]]; then
  echo ""
  echo -e "${YELLOW}Fetching device detail for first ${ENRICHED_SAMPLE_SIZE} devices...${NC}"

  while IFS= read -r did; do
    [[ -z "$did" ]] && continue

    single_response=$(curl -sf \
      "${BASE_URL}/v1/devices/${did}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json") || {
      echo -e "${RED}  ✗ ${did} — request failed${NC}"
      enriched_fail=$((enriched_fail + 1))
      continue
    }

    if ! echo "$single_response" | jq -e '.data | type == "object"' > /dev/null 2>&1; then
      echo -e "${RED}  ✗ ${did} — unexpected .data${NC}"
      enriched_fail=$((enriched_fail + 1))
      continue
    fi

    sid=$(echo "$single_response" | jq -r '.data.id // empty')
    if [[ "$sid" != "$did" ]]; then
      echo -e "${RED}  ✗ ${did} — id mismatch${NC}"
      enriched_fail=$((enriched_fail + 1))
      continue
    fi

    echo -e "${GREEN}  ✓ ${did}${NC}"
    enriched_ok=$((enriched_ok + 1))
    enriched_sample=$(echo "$enriched_sample $(echo "$single_response" | jq '.data')" | jq -s '.[0] + [.[1]]')
  done <<< "$sample_ids"

  echo ""
  if [[ $enriched_fail -eq 0 ]]; then
    echo -e "${GREEN}✓ All ${enriched_ok} device detail fetches OK${NC}"
  else
    echo -e "${RED}${enriched_fail} device detail fetch(es) failed, ${enriched_ok} succeeded${NC}"
  fi
else
  echo -e "${YELLOW}No devices returned — skipping detail sample${NC}"
fi

# ---------------------------------------------------------------------------
# Write snapshot (parallel shape to profiles snapshot: list + enriched_sample)
# ---------------------------------------------------------------------------

jq -n \
  --arg pulled_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg project_ref "$PROJECT_REF" \
  --arg client_short "${CLIENT_SHORT:-}" \
  --argjson total_count "$total_count" \
  --argjson fetched "$fetched" \
  --argjson devices "$all_devices" \
  --argjson enriched_sample "$enriched_sample" \
  '{
    pulled_at: $pulled_at,
    client_short: (if $client_short == "" then null else $client_short end),
    project_ref: $project_ref,
    total_count: $total_count,
    fetched: $fetched,
    devices: $devices,
    enriched_sample: $enriched_sample
  }' > "$OUTPUT_FILE"

echo -e "${GREEN}Snapshot updated with enriched_sample (${enriched_ok} devices):${NC}"
echo "  $OUTPUT_FILE"
