#!/bin/bash

# Export Auth Users Script
# Exports auth users from a source Supabase project for migration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SOURCE_PROJECT_REF=${1:-""}
OUTPUT_DIR=${2:-"backups"}

if [ -z "$SOURCE_PROJECT_REF" ]; then
    echo -e "${RED}Error: Source project reference is required${NC}"
    echo "Usage: ./export-auth-users.sh <source-project-ref> [output-dir]"
    echo "Example: ./export-auth-users.sh cleqfnrbiqpxpzxkatda"
    exit 1
fi

echo -e "${GREEN}Exporting auth users from project: ${SOURCE_PROJECT_REF}${NC}"

# Create output directory
mkdir -p ${OUTPUT_DIR}

# Get database password from environment variable
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    echo "Please set PGPASSWORD in your environment or .zshrc"
    exit 1
fi

echo "Using PGPASSWORD for database operations"

# Create connection string
CONNECTION_STRING="host=db.${SOURCE_PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

echo -e "${GREEN}Creating auth schema backup...${NC}"
pg_dump "${CONNECTION_STRING}" \
    --schema=auth \
    --schema-only \
    --no-owner \
    --file ${OUTPUT_DIR}/auth-schema.sql || {
        echo -e "${RED}Failed to export auth schema${NC}"
        exit 1
    }

echo -e "${GREEN}Creating auth data backup...${NC}"
pg_dump "${CONNECTION_STRING}" \
    --schema=auth \
    --data-only \
    --no-owner \
    --file ${OUTPUT_DIR}/auth-data.sql || {
        echo -e "${RED}Failed to export auth data${NC}"
        exit 1
    }

echo -e "${GREEN}✓ Auth backup files created in ${OUTPUT_DIR}/${NC}"
echo "Files:"
echo "  - ${OUTPUT_DIR}/auth-schema.sql"
echo "  - ${OUTPUT_DIR}/auth-data.sql"
echo ""
echo -e "${YELLOW}Note: These files contain sensitive authentication data. Keep them secure!${NC}"

