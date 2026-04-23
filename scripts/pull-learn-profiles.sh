#!/bin/bash
# Pull all LEARN user profiles via the profile-lookup Edge Function.
# Paginates through all pages and writes the combined result to a JSON snapshot file.
# Also fetches and prints the org SSO config (GET /v1/org).
#
# Usage:
#   ./pull-learn-profiles.sh [project-ref]
#
# Examples:
#   ./pull-learn-profiles.sh
#   ./pull-learn-profiles.sh cleqfnrbiqpxpzxkatda
#
# Output:
#   deploy/scripts/backups/profiles-snapshot-<timestamp>.json

set -euo pipefail

# ---------------------------------------------------------------------------
# Args & config
# ---------------------------------------------------------------------------

SECRETS_FILE="$(dirname "$0")/../../learn/secrets/dev-secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$SECRETS_FILE"; set +a
fi

PROJECT_REF="${1:-cleqfnrbiqpxpzxkatda}"
API_KEY="${LEARN_API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: LEARN_API_KEY not set in dev-secrets.env and not found in environment."
  exit 1
fi

BASE_URL="https://${PROJECT_REF}.supabase.co/functions/v1/profile-lookup"
PAGE_SIZE=200
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="$(dirname "$0")/backups"
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
# Write snapshot
# ---------------------------------------------------------------------------

fetched=$(echo "$all_profiles" | jq 'length')
org_data=$(echo "$org_response" | jq '.data')

jq -n \
  --arg pulled_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg project_ref "$PROJECT_REF" \
  --argjson total_count "$total_count" \
  --argjson fetched "$fetched" \
  --argjson org "$org_data" \
  --argjson profiles "$all_profiles" \
  '{
    pulled_at: $pulled_at,
    project_ref: $project_ref,
    org: $org,
    total_count: $total_count,
    fetched: $fetched,
    profiles: $profiles
  }' > "$OUTPUT_FILE"

echo -e "${GREEN}Done. ${fetched}/${total_count} profiles written to:${NC}"
echo "  $OUTPUT_FILE"

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
