#!/bin/bash

# Data Import Script
# Imports demo or seed data into an existing Supabase project
# Usage: ./import-data.sh <project-ref> <data-type> [region]
# Example: ./import-data.sh xjxrrropjhbnoexvzpkz demo

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check arguments
if [ $# -lt 2 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: ./import-data.sh <project-ref> <data-type> [region]"
    echo "  project-ref: Supabase project reference ID"
    echo "  data-type: 'demo' for full demo data, 'seed' for reference data only"
    echo "  region: Optional, defaults to ap-southeast-1"
    exit 1
fi

PROJECT_REF=${1}
DATA_TYPE=${2}
REGION=${3:-ap-southeast-1}

# Validate data type
if [ "$DATA_TYPE" != "seed" ] && [ "$DATA_TYPE" != "demo" ]; then
    echo -e "${RED}Error: Data type must be 'seed' or 'demo'${NC}"
    exit 1
fi

# Load environment variables
# Try .env.local first (current or parent directory), then .env
if [ -f ".env.local" ]; then
    source .env.local
elif [ -f "../.env.local" ]; then
    source ../.env.local
elif [ -f ".env" ]; then
    source .env
elif [ -f "../.env" ]; then
    source ../.env
fi

# Check for required environment variables
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is required${NC}"
    exit 1
fi

CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

echo -e "${GREEN}Importing ${DATA_TYPE} data into project: ${PROJECT_REF}${NC}"
echo ""

# Change to script directory to ensure relative paths work
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Restore data based on type (using custom format if available, otherwise SQL)
if [ "$DATA_TYPE" = "demo" ] && [ -f "backups/demo.dump" ]; then
    echo -e "${GREEN}Restoring demo data (excluding auth.users and user_roles)...${NC}"
    
    # Restore profiles first (with FK checks disabled - profiles.id references auth.users.id but we won't restore auth.users)
    # We'll temporarily drop the FK constraint, restore profiles, then NOT recreate it (since auth.users doesn't exist)
    echo -e "${GREEN}Restoring profiles (temporarily disabling FK constraint to auth.users)...${NC}"
    
    # Find and drop ALL FK constraints on profiles (there may be multiple, including one to auth.users)
    # profiles.id is typically the primary key that references auth.users.id
    echo -e "${YELLOW}Finding FK constraints on profiles table...${NC}"
    FK_CONSTRAINTS=$(psql "${CONNECTION_STRING}" -t -c "SELECT conname FROM pg_constraint WHERE conrelid = 'public.profiles'::regclass AND contype = 'f';" 2>&1 | grep -v "ERROR" | tr -d ' ' | grep -v '^$')
    if [ -n "$FK_CONSTRAINTS" ]; then
        while IFS= read -r FK_CONSTRAINT; do
            if [ -n "$FK_CONSTRAINT" ]; then
                echo -e "${YELLOW}Temporarily dropping FK constraint: ${FK_CONSTRAINT}${NC}"
                psql "${CONNECTION_STRING}" \
                    --command "ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS ${FK_CONSTRAINT};" > /dev/null 2>&1
            fi
        done <<< "$FK_CONSTRAINTS"
    fi
    
    # Create a TOC list with ONLY profiles
    PROFILES_TOC_FILE=$(mktemp)
    pg_restore --list backups/demo.dump 2>/dev/null | \
        grep "TABLE DATA public profiles" > "${PROFILES_TOC_FILE}"
    
    # Restore profiles using the TOC list
    pg_restore --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
        --dbname=postgres \
        --no-owner \
        --data-only \
        --use-list="${PROFILES_TOC_FILE}" \
        --no-acl \
        backups/demo.dump 2>&1 | tee /tmp/restore-profiles.log || {
            echo -e "${YELLOW}Warning: Some errors occurred during profiles restore${NC}"
        }
    rm -f "${PROFILES_TOC_FILE}"
    
    # Note: We do NOT recreate the FK constraint because auth.users doesn't exist
    # The profiles will work fine without it - they just won't have referential integrity
    
    # Check if profiles were actually restored
    PROFILE_COUNT=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM public.profiles;" 2>&1 | grep -v "ERROR" | tr -d ' \n')
    echo -e "${GREEN}Profiles restored: ${PROFILE_COUNT}${NC}"
    
    # Restore all other demo data (excluding profiles, user_roles, and auth.users)
    # Note: created_by/updated_by columns allow NULL, so we'll set them to NULL after restore
    echo -e "${GREEN}Restoring remaining demo data...${NC}"
    # Create a TOC list excluding profiles, user_roles, and auth.users
    TOC_FILE=$(mktemp)
    pg_restore --list backups/demo.dump 2>/dev/null | \
        grep -v "TABLE DATA public profiles" | \
        grep -v "TABLE DATA public user_roles" | \
        grep -v "TABLE DATA auth.users" > "${TOC_FILE}"
    # Restore using the filtered TOC list
    pg_restore --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
        --dbname=postgres \
        --no-owner \
        --data-only \
        --use-list="${TOC_FILE}" \
        --no-acl \
        backups/demo.dump 2>&1 | tee /tmp/restore-data.log || {
            echo -e "${YELLOW}Warning: Some data restore errors occurred (may be expected for missing foreign keys)${NC}"
        }
    rm -f "${TOC_FILE}"
    
    # Set all created_by and updated_by columns to NULL (since they reference auth.users which we don't restore)
    # Only update columns that actually exist in each table
    echo -e "${GREEN}Setting created_by/updated_by columns to NULL...${NC}"
    psql "${CONNECTION_STRING}" \
        --variable ON_ERROR_STOP=0 <<EOF 2>&1 | tee /tmp/nullify-user-refs.log
-- account_inventory: created_by, modified_by
UPDATE public.account_inventory SET created_by = NULL WHERE created_by IS NOT NULL;
UPDATE public.account_inventory SET modified_by = NULL WHERE modified_by IS NOT NULL;

-- email_layouts: created_by only
UPDATE public.email_layouts SET created_by = NULL WHERE created_by IS NOT NULL;

-- email_preferences: created_by, updated_by
UPDATE public.email_preferences SET created_by = NULL WHERE created_by IS NOT NULL;
UPDATE public.email_preferences SET updated_by = NULL WHERE updated_by IS NOT NULL;

-- email_templates: created_by only
UPDATE public.email_templates SET created_by = NULL WHERE created_by IS NOT NULL;

-- key_dates: created_by, modified_by (not updated_by)
UPDATE public.key_dates SET created_by = NULL WHERE created_by IS NOT NULL;
UPDATE public.key_dates SET modified_by = NULL WHERE modified_by IS NOT NULL;

-- learning_tracks: created_by only
UPDATE public.learning_tracks SET created_by = NULL WHERE created_by IS NOT NULL;

-- lessons: created_by, updated_by
UPDATE public.lessons SET created_by = NULL WHERE created_by IS NOT NULL;
UPDATE public.lessons SET updated_by = NULL WHERE updated_by IS NOT NULL;

-- notification_rules: created_by only
UPDATE public.notification_rules SET created_by = NULL WHERE created_by IS NOT NULL;

-- org_profile: created_by only
UPDATE public.org_profile SET created_by = NULL WHERE created_by IS NOT NULL;

-- org_sig_roles: created_by only
UPDATE public.org_sig_roles SET created_by = NULL WHERE created_by IS NOT NULL;

-- template_variables: created_by only
UPDATE public.template_variables SET created_by = NULL WHERE created_by IS NOT NULL;

-- translation_change_log: updated_by only (not created_by)
UPDATE public.translation_change_log SET updated_by = NULL WHERE updated_by IS NOT NULL;
EOF
    
    # Re-enable foreign key checks
    psql "${CONNECTION_STRING}" \
        --command 'SET session_replication_role = DEFAULT' > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Demo data restored successfully${NC}"
    
elif [ "$DATA_TYPE" = "seed" ] && [ -f "backups/seed.dump" ]; then
    echo -e "${GREEN}Restoring seed data (reference data only) from custom format...${NC}"
    pg_restore --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
        --dbname=postgres \
        --verbose \
        --no-owner \
        --data-only \
        backups/seed.dump 2>&1 | tee /tmp/restore-seed.log || {
            echo -e "${YELLOW}Warning: Some errors occurred during seed data restore${NC}"
        }
    echo -e "${GREEN}✓ Seed data restored successfully${NC}"
    
elif [ "$DATA_TYPE" = "demo" ] && [ -f "backups/demo.sql" ]; then
    echo -e "${GREEN}Restoring demo data from SQL format...${NC}"
    psql "${CONNECTION_STRING}" \
        --single-transaction \
        --variable ON_ERROR_STOP=0 \
        --command 'SET session_replication_role = replica' \
        --file backups/demo.sql 2>&1 | tee /tmp/restore-demo-sql.log || {
            echo -e "${YELLOW}Warning: Some errors occurred during demo data restore${NC}"
        }
    echo -e "${GREEN}✓ Demo data restored successfully${NC}"
    
elif [ "$DATA_TYPE" = "seed" ] && [ -f "backups/seed.sql" ]; then
    echo -e "${GREEN}Restoring seed data from SQL format...${NC}"
    psql "${CONNECTION_STRING}" \
        --single-transaction \
        --variable ON_ERROR_STOP=0 \
        --file backups/seed.sql 2>&1 | tee /tmp/restore-seed-sql.log || {
            echo -e "${YELLOW}Warning: Some errors occurred during seed data restore${NC}"
        }
    echo -e "${GREEN}✓ Seed data restored successfully${NC}"
    
else
    echo -e "${RED}Error: No backup file found for ${DATA_TYPE} data${NC}"
    echo "Expected one of:"
    echo "  - backups/${DATA_TYPE}.dump (custom format)"
    echo "  - backups/${DATA_TYPE}.sql (SQL format)"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Data import complete!${NC}"

