#!/bin/bash

# Script to verify JWT configuration matches between projects
# This helps diagnose why auth.uid() returns NULL

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_REF=${1:-""}

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: Project reference is required${NC}"
    echo "Usage: ./verify-jwt-config.sh <project-ref>"
    echo "Example: ./verify-jwt-config.sh lcpotivitdpdslbqhifs"
    exit 1
fi

echo -e "${GREEN}Verifying JWT configuration for project: ${PROJECT_REF}${NC}"
echo ""

# Check if we can get project info
echo -e "${YELLOW}1. Checking project info...${NC}"
PROJECT_INFO=$(supabase projects list --format json 2>/dev/null | jq -r ".[] | select(.id == \"${PROJECT_REF}\") | .name" 2>/dev/null || echo "")

if [ -z "$PROJECT_INFO" ]; then
    echo -e "${YELLOW}   Could not fetch project info via CLI${NC}"
    echo -e "${YELLOW}   This is OK - we'll check other things${NC}"
else
    echo -e "${GREEN}   Project found: ${PROJECT_INFO}${NC}"
fi

echo ""

# Get the JWT secret from Supabase API settings
echo -e "${YELLOW}2. JWT Secret Configuration${NC}"
echo -e "${YELLOW}   �ℹ️  JWT secrets are managed by Supabase and cannot be accessed via CLI${NC}"
echo -e "${YELLOW}   To check JWT secret:${NC}"
echo -e "${GREEN}   1. Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/settings/api${NC}"
echo -e "${GREEN}   2. Scroll to 'JWT Settings' section${NC}"
echo -e "${GREEN}   3. Check the 'JWT Secret' value${NC}"
echo ""

# Check if we can query the database
echo -e "${YELLOW}3. Testing database connection and auth.uid()...${NC}"
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}   PGPASSWORD not set - cannot test database connection${NC}"
    echo -e "${YELLOW}   Set PGPASSWORD to test auth.uid()${NC}"
else
    CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"
    
    echo -e "${GREEN}   Testing auth.uid() function...${NC}"
    AUTH_UID_RESULT=$(psql "${CONNECTION_STRING}" -t -A -c "SELECT auth.uid();" 2>&1 || echo "ERROR")
    
    if echo "$AUTH_UID_RESULT" | grep -qi "error\|failed\|permission"; then
        echo -e "${RED}   ✗ Failed to query auth.uid():${NC}"
        echo "   $AUTH_UID_RESULT"
    elif [ -z "$AUTH_UID_RESULT" ] || echo "$AUTH_UID_RESULT" | grep -qiE "(null|^$)"; then
        echo -e "${YELLOW}   ⚠️  auth.uid() returns NULL (expected if not authenticated)${NC}"
        echo -e "${YELLOW}   This is normal when running direct SQL queries${NC}"
    else
        echo -e "${GREEN}   ✓ auth.uid() returned: ${AUTH_UID_RESULT}${NC}"
    fi
fi

echo ""

# Check anon key
echo -e "${YELLOW}4. Checking anon key configuration...${NC}"
echo -e "${YELLOW}   ⚠️  Important: The anon key must match the project${NC}"
echo -e "${YELLOW}   To get the correct anon key:${NC}"
echo -e "${GREEN}   1. Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/settings/api${NC}"
echo -e "${GREEN}   2. Find 'Project API keys' section${NC}"
echo -e "${GREEN}   3. Copy the 'anon' 'public' key${NC}"
echo -e "${YELLOW}   This key should be used in VITE_CLIENT_CONFIGS for this project${NC}"
echo ""

# Check if PostgREST is configured correctly
echo -e "${YELLOW}5. PostgREST Configuration${NC}"
echo -e "${YELLOW}   PostgREST automatically uses the JWT secret from Supabase project settings${NC}"
echo -e "${YELLOW}   No manual configuration needed - Supabase handles this automatically${NC}"
echo ""

# Summary
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Key Points:${NC}"
echo "1. Each Supabase project has its own JWT secret (automatically generated)"
echo "2. PostgREST uses the project's JWT secret to validate tokens"
echo "3. If auth.uid() returns NULL, it means PostgREST cannot validate the JWT"
echo ""
echo -e "${YELLOW}Common Causes:${NC}"
echo "• Frontend using wrong anon key (from different project)"
echo "• JWT issuer mismatch (JWT issued by different project)"
echo "• Token not being sent in Authorization header"
echo ""
echo -e "${YELLOW}How to Verify:${NC}"
echo "1. Check that frontend uses correct anon key for project ${PROJECT_REF}"
echo "2. Check JWT issuer matches: https://${PROJECT_REF}.supabase.co/auth/v1"
echo "3. Check Network tab - Authorization header should be present"
echo ""

