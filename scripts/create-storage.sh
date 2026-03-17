#!/bin/bash

# Create Supabase Storage buckets on existing projects
# Uses the same SUPABASE_ACCESS_TOKEN as onboard-client.sh
# Usage: SUPABASE_ACCESS_TOKEN=xxx ./create-storage.sh <project-ref> [project-ref2] ...
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

if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
    echo -e "${RED}Error: SUPABASE_ACCESS_TOKEN is not set.${NC}"
    echo -e "Get a token from: https://supabase.com/dashboard/account/tokens"
    echo -e "Then run: export SUPABASE_ACCESS_TOKEN=your-token"
    exit 1
fi

create_bucket() {
    local PROJECT_REF=$1
    local BUCKET_NAME=$2
    local IS_PUBLIC=$3
    local FILE_SIZE_LIMIT=$4

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "https://api.supabase.com/v1/projects/${PROJECT_REF}/storage/buckets" \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${BUCKET_NAME}\",\"public\":${IS_PUBLIC},\"file_size_limit\":${FILE_SIZE_LIMIT}}")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
        echo -e "  ${GREEN}✓${NC} ${BUCKET_NAME} created"
    elif [ "$HTTP_STATUS" = "409" ]; then
        echo -e "  ${YELLOW}~${NC} ${BUCKET_NAME} already exists (skipped)"
    else
        echo -e "  ${RED}✗${NC} ${BUCKET_NAME} failed (HTTP ${HTTP_STATUS})"
    fi
}

for PROJECT_REF in "$@"; do
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Creating storage buckets for: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    create_bucket "$PROJECT_REF" "documents"    "false" "10485760"
    create_bucket "$PROJECT_REF" "certificates" "false" "10485760"
    create_bucket "$PROJECT_REF" "logos"        "true"  "2097152"

    echo -e "${GREEN}✓ Completed ${PROJECT_REF}${NC}"
done

echo ""
echo -e "${GREEN}✓ All projects processed${NC}"
