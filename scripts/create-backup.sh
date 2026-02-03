#!/bin/bash

# Create Database Backup Script
# Generates backup files for client onboarding

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_REF=${1:-""}
OUTPUT_DIR=${2:-"backups"}

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: Project reference is required${NC}"
    echo "Usage: ./create-backup.sh <project-ref> [output-dir]"
    echo "Example: ./create-backup.sh cleqfnrbiqpxpzxkatda"
    echo ""
    echo "Environment Variables:"
    echo "  PGPASSWORD - Database password (optional, will prompt if not set)"
    exit 1
fi

echo -e "${GREEN}Creating backup for project: ${PROJECT_REF}${NC}"

# Create output directory
mkdir -p ${OUTPUT_DIR}

# Get database password from environment variable or prompt
if [ -z "$PGPASSWORD" ]; then
    echo "Enter database password for ${PROJECT_REF}:"
    read -s DB_PASSWORD
    export PGPASSWORD="$DB_PASSWORD"
else
    echo "Using database password from PGPASSWORD environment variable"
fi

# Create connection string using direct database connection (not pooler)
# PGPASSWORD environment variable will be used for authentication
CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

echo -e "${GREEN}Creating schema backup (custom format, public schema)...${NC}"
pg_dump --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
    --schema-only \
    --schema=public \
    --format=custom \
    --no-owner \
    --file ${OUTPUT_DIR}/schema.dump \
    --verbose

# Create storage schema backup if it exists
echo -e "${GREEN}Creating storage schema backup (if available)...${NC}"
pg_dump --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
    --schema-only \
    --schema=storage \
    --format=custom \
    --no-owner \
    --file ${OUTPUT_DIR}/storage.dump \
    --verbose 2>&1 || echo -e "${YELLOW}Note: Storage schema not found or empty (this is OK)${NC}"

echo -e "${GREEN}Creating demo data backup (custom format)...${NC}"
pg_dump --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
    --data-only \
    --schema=public \
    --format=custom \
    --no-owner \
    --file ${OUTPUT_DIR}/demo.dump \
    --verbose

# Create auth.users dump for demo data (needed for foreign key constraints)
echo -e "${GREEN}Creating auth.users backup for demo data (custom format)...${NC}"
pg_dump --host=db.${PROJECT_REF}.supabase.co --port=6543 --user=postgres \
    --data-only \
    --table=auth.users \
    --format=custom \
    --no-owner \
    --file ${OUTPUT_DIR}/auth.dump \
    --verbose 2>&1 || echo -e "${YELLOW}Note: Could not dump auth.users (may not be accessible)${NC}"

echo -e "${GREEN}✓ Backup files created in ${OUTPUT_DIR}/${NC}"
echo "Files:"
echo "  - ${OUTPUT_DIR}/schema.dump (custom format)"
if [ -f "${OUTPUT_DIR}/storage.dump" ]; then
    echo "  - ${OUTPUT_DIR}/storage.dump (custom format)"
fi
echo "  - ${OUTPUT_DIR}/demo.dump (custom format, demo data)"
if [ -f "${OUTPUT_DIR}/auth.dump" ]; then
    echo "  - ${OUTPUT_DIR}/auth.dump (custom format, auth.users for demo data)"
fi

# Automatically extract seed data from demo.dump
if [ -f "${OUTPUT_DIR}/demo.dump" ]; then
    echo ""
    echo -e "${GREEN}Extracting seed data from demo.dump...${NC}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/extract-seed-data.sh" ]; then
        # Call extract-seed-data.sh with the same PROJECT_REF and OUTPUT_DIR
        "${SCRIPT_DIR}/extract-seed-data.sh" "${OUTPUT_DIR}/demo.dump" "${OUTPUT_DIR}" "${PROJECT_REF}" || {
            echo -e "${YELLOW}Warning: Seed data extraction failed or skipped${NC}"
            echo -e "${YELLOW}         You can run it manually: ./scripts/extract-seed-data.sh ${OUTPUT_DIR}/demo.dump ${OUTPUT_DIR} ${PROJECT_REF}${NC}"
        }
    else
        echo -e "${YELLOW}Warning: extract-seed-data.sh not found, skipping seed data extraction${NC}"
    fi
fi

echo ""
echo -e "${GREEN}✓ Backup process complete!${NC}"