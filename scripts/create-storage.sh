#!/bin/bash

# Create Supabase Storage buckets on existing projects via psql
# Requires PGPASSWORD env var (the database password for each project)
# Usage: PGPASSWORD=<password> ./create-storage.sh <project-ref> [project-ref2] ...
# Example: PGPASSWORD=mypassword ./create-storage.sh cleqfnrbiqpxpzxkatda ptectyngjnovskdtkxcq
# Find password: Supabase Dashboard → Project Settings → Database → Database password

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project reference is required${NC}"
    echo "Usage: PGPASSWORD=<password> ./create-storage.sh <project-ref> [project-ref2] ..."
    exit 1
fi

if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set.${NC}"
    echo "Find it: Supabase Dashboard → Project Settings → Database → Database password"
    echo "Then run: PGPASSWORD=yourpassword ./create-storage.sh <project-ref>"
    exit 1
fi

SQL="
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES
    ('avatars',      'avatars',      true,  52428800),
    ('documents',    'documents',    false, 52428800),
    ('certificates', 'certificates', false, 10485760),
    ('logos',        'logos',        true,  2097152)
ON CONFLICT (id) DO UPDATE SET file_size_limit = EXCLUDED.file_size_limit;
"

for PROJECT_REF in "$@"; do
    # Detect connection method: direct IPv6 or session-mode pooler fallback
    DB_HOSTNAME="db.${PROJECT_REF}.supabase.co"
    POOLER_HOST="${POOLER_HOST:-aws-1-${REGION:-ap-southeast-1}.pooler.supabase.com}"
    RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v "^\." | head -1)
    if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
        export PGHOSTADDR="${RESOLVED_ADDR}"
        CONNECTION_STRING="host=${DB_HOSTNAME} port=6543 user=postgres dbname=postgres sslmode=require"
    else
        unset PGHOSTADDR
        CONNECTION_STRING="host=${POOLER_HOST} port=5432 user=postgres.${PROJECT_REF} dbname=postgres sslmode=require"
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Creating storage buckets for: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    if psql "${CONNECTION_STRING}" --command "${SQL}"; then
        echo -e "  ${GREEN}✓${NC} avatars (public, 50MB — covers lesson-media/ folder incl. videos)"
        echo -e "  ${GREEN}✓${NC} documents (private, 50MB)"
        echo -e "  ${GREEN}✓${NC} certificates (private, 10MB)"
        echo -e "  ${GREEN}✓${NC} logos (public, 2MB)"
        echo -e "${GREEN}✓ Completed ${PROJECT_REF}${NC}"
    else
        echo -e "  ${RED}✗${NC} Failed for ${PROJECT_REF}"
    fi
done

echo ""
echo -e "${GREEN}✓ All projects processed${NC}"
