#!/bin/bash
# Pull all LEARN user profiles via the profile-lookup Edge Function.
# Paginates through all pages and writes the combined result to a JSON snapshot file.
# Also fetches and prints the org SSO config (GET /v1/org).
#
# Usage:
#   ./pull-learn-profiles.sh --dev
#   ./pull-learn-profiles.sh --staging
#   ./pull-learn-profiles.sh --lentor
#   ./pull-learn-profiles.sh <20-char-project_ref>
#
# Project ref and API keys are resolved via projects.conf + learn/secrets/client-api-keys.json.
# For --dev, keys are read from learn/secrets/dev-secrets.env.
#
# Examples:
#   ./pull-learn-profiles.sh --dev
#   ./pull-learn-profiles.sh --ygos
#
# Output:
#   deploy/scripts/backups/profiles-snapshot-<timestamp>.json

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

API_KEY="${LEARN_API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: LEARN_API_KEY not set — check learn/secrets/dev-secrets.env"
  exit 1
fi

BASE_URL="https://${PROJECT_REF}.supabase.co/functions/v1/profile-lookup"
PAGE_SIZE=200
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="${SCRIPT_DIR}/backups"
OUTPUT_FILE="${OUTPUT_DIR}/profiles-snapshot-${TIMESTAMP}.json"

mkdir -p "$OUTPUT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Org SSO config
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Fetching org SSO config from ${BASE_URL}/v1/org${NC}"

org_response=$(curl -sf \
  "${BASE_URL}/v1/org" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json") || {
  echo -e "${RED}Failed to fetch org SSO config${NC}"
  exit 1
}

if ! echo "$org_response" | jq -e '.data' > /dev/null 2>&1; then
  echo -e "${RED}Unexpected org response:${NC}"
  echo "$org_response" | jq . 2>/dev/null || echo "$org_response"
  exit 1
fi

echo -e "${GREEN}Org SSO config:${NC}"
echo "$org_response" | jq '.data'
echo ""

# ---------------------------------------------------------------------------
# Paginate profiles
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Pulling profiles from ${BASE_URL}/v1/profiles${NC}"

all_profiles="[]"
page=1
total_count=0
total_pages=0

while true; do
  response=$(curl -sf \
    "${BASE_URL}/v1/profiles?page=${page}&page_size=${PAGE_SIZE}" \
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

  all_profiles=$(echo "$all_profiles $page_data" | jq -s '.[0] + .[1]')

  echo "  Page ${page}/${total_pages} — ${page_count} records (${total_count} total)"

  if [[ "$has_next" != "true" ]]; then
    break
  fi

  page=$((page + 1))
done

# ---------------------------------------------------------------------------
# Write initial snapshot (enriched_sample added later after enriched fetch)
# ---------------------------------------------------------------------------

fetched=$(echo "$all_profiles" | jq 'length')
org_data=$(echo "$org_response" | jq '.data')

echo -e "${GREEN}Done. ${fetched}/${total_count} profiles fetched.${NC}"

# ---------------------------------------------------------------------------
# Quick validation summary
# ---------------------------------------------------------------------------

echo ""
echo "Validation summary:"
echo "$all_profiles" | jq '
  {
    total: length,
    statuses: (group_by(.status) | map({ (.[0].status // "null"): length }) | add),
    missing_email:   (map(select(.email == null)) | length),
    missing_name:    (map(select(.full_name == null and .first_name == null)) | length),
    inactive:        (map(select(.status == "Inactive")) | length)
  }
'

# ---------------------------------------------------------------------------
# Enriched single-user endpoint — fetch first 5 profiles fully enriched
# ---------------------------------------------------------------------------

ENRICHED_SAMPLE_SIZE=5
enriched_sample="[]"
enriched_ok=0
enriched_fail=0

sample_uuids=$(echo "$all_profiles" | jq -r ".[0:${ENRICHED_SAMPLE_SIZE}][].id")

if [[ -n "$sample_uuids" ]]; then
  echo ""
  echo -e "${YELLOW}Fetching enriched data for first ${ENRICHED_SAMPLE_SIZE} profiles...${NC}"

  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue

    single_response=$(curl -sf \
      "${BASE_URL}/v1/profiles/${uuid}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json") || {
      echo -e "${RED}  ✗ ${uuid} — request failed${NC}"
      enriched_fail=$((enriched_fail + 1))
      continue
    }

    # Validate expected enriched keys (null is valid — check key existence)
    missing_keys=""
    for key in track_status departments roles documents manager_email; do
      if ! echo "$single_response" | jq -e ".data | has(\"${key}\")" > /dev/null 2>&1; then
        missing_keys="${missing_keys} ${key}"
      fi
    done

    if [[ -n "$missing_keys" ]]; then
      echo -e "${RED}  ✗ ${uuid} — missing keys:${missing_keys}${NC}"
      enriched_fail=$((enriched_fail + 1))
    else
      echo -e "${GREEN}  ✓ ${uuid}${NC}"
      enriched_ok=$((enriched_ok + 1))
      enriched_sample=$(echo "$enriched_sample $(echo "$single_response" | jq '.data')" | jq -s '.[0] + [.[1]]')
    fi
  done <<< "$sample_uuids"

  echo ""
  if [[ $enriched_fail -eq 0 ]]; then
    echo -e "${GREEN}✓ All ${enriched_ok} enriched profiles OK${NC}"
  else
    echo -e "${RED}${enriched_fail} enriched profile(s) failed, ${enriched_ok} succeeded${NC}"
  fi
else
  echo -e "${YELLOW}No profiles returned — skipping enriched sample${NC}"
fi

# ---------------------------------------------------------------------------
# Write snapshot with enriched_sample
# ---------------------------------------------------------------------------

jq -n \
  --arg pulled_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg project_ref "$PROJECT_REF" \
  --arg client_short "${CLIENT_SHORT:-}" \
  --argjson total_count "$total_count" \
  --argjson fetched "$fetched" \
  --argjson org "$org_data" \
  --argjson profiles "$all_profiles" \
  --argjson enriched_sample "$enriched_sample" \
  '{
    pulled_at: $pulled_at,
    client_short: (if $client_short == "" then null else $client_short end),
    project_ref: $project_ref,
    org: $org,
    total_count: $total_count,
    fetched: $fetched,
    profiles: $profiles,
    enriched_sample: $enriched_sample
  }' > "$OUTPUT_FILE"

echo -e "${GREEN}Snapshot updated with enriched_sample (${enriched_ok} profiles):${NC}"
echo "  $OUTPUT_FILE"
