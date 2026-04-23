#!/bin/bash

# Migration Validation Script
# Compares the source database with the destination database to ensure completeness

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
OLD_PROJECT_REF=${1:-""}
NEW_PROJECT_REF=${2:-""}
REGION=${3:-ap-southeast-1}

# Validate inputs
if [ -z "$OLD_PROJECT_REF" ] || [ -z "$NEW_PROJECT_REF" ]; then
    echo -e "${RED}Error: Both project references are required${NC}"
    echo "Usage: ./validate-migration.sh <old-project-ref> <new-project-ref> [region]"
    exit 1
fi

echo -e "${GREEN}Validating migration from ${OLD_PROJECT_REF} to ${NEW_PROJECT_REF}${NC}"

# Get database passwords
if [ -z "$OLD_DB_PASSWORD" ]; then
    echo "Please enter the database password for ${OLD_PROJECT_REF}:"
    read -s OLD_DB_PASSWORD
fi

if [ -z "$NEW_DB_PASSWORD" ]; then
    echo "Please enter the database password for ${NEW_PROJECT_REF}:"
    read -s NEW_DB_PASSWORD
fi

# Note: Passwords are different from service role keys and can be safely reset
# This won't affect the running application which uses service role keys
OLD_CONNECTION_STRING="postgresql://postgres.${OLD_PROJECT_REF}:${OLD_DB_PASSWORD}@aws-0-${REGION}.pooler.supabase.com:5432/postgres"
NEW_CONNECTION_STRING="postgresql://postgres.${NEW_PROJECT_REF}:${NEW_DB_PASSWORD}@aws-0-${REGION}.pooler.supabase.com:5432/postgres"

# Function to run SQL query
run_query() {
    local query=$1
    local connection=$2
    psql -t -A -c "$query" "$connection" 2>/dev/null || echo "0"
}

# Compare table counts
echo -e "${GREEN}Comparing table counts...${NC}"
OLD_TABLES=$(run_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" "$OLD_CONNECTION_STRING")
NEW_TABLES=$(run_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" "$NEW_CONNECTION_STRING")

if [ "$OLD_TABLES" = "$NEW_TABLES" ]; then
    echo -e "${GREEN}✓ Tables match: ${OLD_TABLES}${NC}"
else
    echo -e "${RED}✗ Table count mismatch: Old=${OLD_TABLES}, New=${NEW_TABLES}${NC}"
fi

# Compare function counts
echo -e "${GREEN}Comparing function counts...${NC}"
OLD_FUNCTIONS=$(run_query "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = 'public' AND routine_type = 'FUNCTION';" "$OLD_CONNECTION_STRING")
NEW_FUNCTIONS=$(run_query "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = 'public' AND routine_type = 'FUNCTION';" "$NEW_CONNECTION_STRING")

if [ "$OLD_FUNCTIONS" = "$NEW_FUNCTIONS" ]; then
    echo -e "${GREEN}✓ Functions match: ${OLD_FUNCTIONS}${NC}"
else
    echo -e "${RED}✗ Function count mismatch: Old=${OLD_FUNCTIONS}, New=${NEW_FUNCTIONS}${NC}"
fi

# Compare trigger counts and list missing triggers
echo -e "${GREEN}Comparing trigger counts...${NC}"
OLD_TRIGGERS=$(run_query "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema IN ('public', 'auth');" "$OLD_CONNECTION_STRING")
NEW_TRIGGERS=$(run_query "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema IN ('public', 'auth');" "$NEW_CONNECTION_STRING")

if [ "$OLD_TRIGGERS" = "$NEW_TRIGGERS" ]; then
    echo -e "${GREEN}✓ Triggers match: ${OLD_TRIGGERS}${NC}"
else
    echo -e "${RED}✗ Trigger count mismatch: Old=${OLD_TRIGGERS}, New=${NEW_TRIGGERS}${NC}"
    echo -e "${YELLOW}Missing triggers:${NC}"
    # Get list of triggers from old DB
    psql -t -A -c "SELECT trigger_name FROM information_schema.triggers WHERE trigger_schema IN ('public', 'auth') ORDER BY trigger_name;" "$OLD_CONNECTION_STRING" > /tmp/old_triggers.txt
    psql -t -A -c "SELECT trigger_name FROM information_schema.triggers WHERE trigger_schema IN ('public', 'auth') ORDER BY trigger_name;" "$NEW_CONNECTION_STRING" > /tmp/new_triggers.txt
    comm -23 /tmp/old_triggers.txt /tmp/new_triggers.txt | while read trigger; do
        echo "  - $trigger"
    done
fi

# Compare RLS policy counts
echo -e "${GREEN}Comparing RLS policy counts...${NC}"
OLD_POLICIES=$(run_query "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';" "$OLD_CONNECTION_STRING")
NEW_POLICIES=$(run_query "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';" "$NEW_CONNECTION_STRING")

if [ "$OLD_POLICIES" = "$NEW_POLICIES" ]; then
    echo -e "${GREEN}✓ RLS policies match: ${OLD_POLICIES}${NC}"
else
    echo -e "${RED}✗ RLS policy count mismatch: Old=${OLD_POLICIES}, New=${NEW_POLICIES}${NC}"
fi

# Compare index counts
echo -e "${GREEN}Comparing index counts...${NC}"
OLD_INDEXES=$(run_query "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';" "$OLD_CONNECTION_STRING")
NEW_INDEXES=$(run_query "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';" "$NEW_CONNECTION_STRING")

if [ "$OLD_INDEXES" = "$NEW_INDEXES" ]; then
    echo -e "${GREEN}✓ Indexes match: ${OLD_INDEXES}${NC}"
else
    echo -e "${RED}✗ Index count mismatch: Old=${OLD_INDEXES}, New=${NEW_INDEXES}${NC}"
fi

# Compare constraint counts
echo -e "${GREEN}Comparing constraint counts...${NC}"
OLD_CONSTRAINTS=$(run_query "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema = 'public';" "$OLD_CONNECTION_STRING")
NEW_CONSTRAINTS=$(run_query "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema = 'public';" "$NEW_CONNECTION_STRING")

if [ "$OLD_CONSTRAINTS" = "$NEW_CONSTRAINTS" ]; then
    echo -e "${GREEN}✓ Constraints match: ${OLD_CONSTRAINTS}${NC}"
else
    echo -e "${RED}✗ Constraint count mismatch: Old=${OLD_CONSTRAINTS}, New=${NEW_CONSTRAINTS}${NC}"
fi

echo ""
echo -e "${GREEN}Validation complete!${NC}"

