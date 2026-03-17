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
    ('avatars',      'avatars',      true,  2097152),
    ('documents',    'documents',    false, 10485760),
    ('certificates', 'certificates', false, 10485760),
    ('logos',        'logos',        true,  2097152)
ON CONFLICT (id) DO NOTHING;
"

for PROJECT_REF in "$@"; do
    CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Creating storage buckets for: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    if psql "${CONNECTION_STRING}" --command "${SQL}"; then
        echo -e "  ${GREEN}✓${NC} avatars (public, 2MB)"
        echo -e "  ${GREEN}✓${NC} documents (private, 10MB)"
        echo -e "  ${GREEN}✓${NC} certificates (private, 10MB)"
        echo -e "  ${GREEN}✓${NC} logos (public, 2MB)"
        echo -e "${GREEN}✓ Completed ${PROJECT_REF}${NC}"
    else
        echo -e "  ${RED}✗${NC} Failed for ${PROJECT_REF}"
    fi
done

echo ""
echo -e "${GREEN}✓ All projects processed${NC}"
