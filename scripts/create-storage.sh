#!/bin/bash

# Create Supabase Storage buckets on existing projects
# Uses the access token from `supabase login` (~/.supabase/access-token)
# Usage: ./create-storage.sh <project-ref> [project-ref2] ...
# Example: ./create-storage.sh cleqfnrbiqpxpzxkatda ptectyngjnovskdtkxcq

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project reference is required${NC}"
    echo "Usage: ./create-storage.sh <project-ref> [project-ref2] ..."
    exit 1
fi

# Requires SUPABASE_ACCESS_TOKEN env var.
# Get one from: https://supabase.com/dashboard/account/tokens
# Then: export SUPABASE_ACCESS_TOKEN=your-token
if [ -z "${SUPABASE_ACCESS_TOKEN}" ]; then
    echo -e "${RED}Error: SUPABASE_ACCESS_TOKEN is not set.${NC}"
    echo -e "Get a token from: https://supabase.com/dashboard/account/tokens"
    echo -e "Then run: export SUPABASE_ACCESS_TOKEN=your-token"
    exit 1
fi
ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN}"

SQL="
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES
  ('documents',    'documents',    false, 10485760),
  ('certificates', 'certificates', false, 10485760),
  ('logos',        'logos',        true,  2097152)
ON CONFLICT (id) DO NOTHING;
"

for PROJECT_REF in "$@"; do
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Creating storage buckets for: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    HTTP_STATUS=$(curl -s -o /tmp/supabase_storage_out.json -w "%{http_code}" \
        -X POST "https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"query\": $(echo "$SQL" | jq -Rs .)}")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
        echo -e "  ${GREEN}✓${NC} documents (private, 10MB)"
        echo -e "  ${GREEN}✓${NC} certificates (private, 10MB)"
        echo -e "  ${GREEN}✓${NC} logos (public, 2MB)"
        echo -e "${GREEN}✓ Completed ${PROJECT_REF}${NC}"
    else
        echo -e "  ${RED}✗${NC} Failed (HTTP ${HTTP_STATUS})"
        cat /tmp/supabase_storage_out.json
    fi
done

echo ""
echo -e "${GREEN}✓ All projects processed${NC}"
