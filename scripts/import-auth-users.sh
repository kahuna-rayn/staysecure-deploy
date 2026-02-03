#!/bin/bash

# Import Auth Users Script
# Imports auth users into a target Supabase project

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TARGET_PROJECT_REF=${1:-""}
INPUT_DIR=${2:-"backups"}

if [ -z "$TARGET_PROJECT_REF" ]; then
    echo -e "${RED}Error: Target project reference is required${NC}"
    echo "Usage: ./import-auth-users.sh <target-project-ref> [input-dir]"
    echo "Example: ./import-auth-users.sh edqvoopjtigbyerwyesb"
    exit 1
fi

if [ ! -f "${INPUT_DIR}/auth-users-clean.sql" ]; then
    echo -e "${RED}Error: Auth backup file not found: ${INPUT_DIR}/auth-users-clean.sql${NC}"
    echo "Please run export-auth-users.sh first to create the backup file"
    exit 1
fi

echo -e "${GREEN}Importing auth users into project: ${TARGET_PROJECT_REF}${NC}"

# Get database password from environment variable
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    echo "Please set PGPASSWORD in your environment or .zshrc"
    exit 1
fi

echo "Using PGPASSWORD for database operations"
echo "Region: ${REGION}"

# Create connection string
CONNECTION_STRING="host=db.${TARGET_PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

# Wait for project to be ready (if it was just created)
echo -e "${GREEN}Checking if project is ready...${NC}"
echo "This may take a moment..."

MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    # Test connection using psql
    if PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" -c "SELECT 1;" > /dev/null 2>&1; then
        echo -e "${GREEN}Database is ready!${NC}"
        break
    fi
    
    if [ $ATTEMPT -eq $((MAX_ATTEMPTS - 1)) ]; then
        echo -e "${RED}Database did not become ready within expected time${NC}"
        echo -e "${YELLOW}Attempting connection anyway...${NC}"
        break
    fi
    
    echo "Waiting for database... (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS)"
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

echo -e "${YELLOW}Warning: This will overwrite any existing auth users in the target database${NC}"
echo -e "${YELLOW}Press Ctrl+C to cancel, or wait 5 seconds to continue...${NC}"
sleep 5

# Import auth users and identities
# Note: We're using auth-users-clean.sql which contains only users and identities tables
echo -e "${GREEN}Importing auth users and identities...${NC}"
psql "${CONNECTION_STRING}" \
    --single-transaction \
    --variable ON_ERROR_STOP=1 \
    --command 'SET session_replication_role = replica' \
    --file ${INPUT_DIR}/auth-users-clean.sql || {
        echo -e "${RED}Failed to import auth data${NC}"
        exit 1
    }

echo -e "${GREEN}✓ Auth users imported successfully${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Verify users can login in the target project"
echo "  2. Check that profiles exist for the imported users"
echo "  3. Delete the auth backup files for security"

