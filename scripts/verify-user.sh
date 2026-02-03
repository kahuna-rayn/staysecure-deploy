#!/bin/bash

# Verify User Script
# Checks if a user exists and is properly configured

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_REF=${1:-""}
EMAIL=${2:-""}

if [ -z "$PROJECT_REF" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}Usage: ./verify-user.sh <project-ref> <email>${NC}"
    exit 1
fi

# Load environment variables (check current dir and parent dir)
if [ -f ".env.local" ]; then
    source .env.local
elif [ -f "../.env.local" ]; then
    source ../.env.local
elif [ -f ".env" ]; then
    source .env
elif [ -f "../.env" ]; then
    source ../.env
fi

if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    echo -e "${RED}Error: SUPABASE_SERVICE_ROLE_KEY not set${NC}"
    exit 1
fi

SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

echo -e "${GREEN}Verifying user: ${EMAIL}${NC}"
echo ""

# Use psql directly instead of supabase db execute (more reliable)
echo "Checking auth.users..."
echo "Running query: SELECT id, email, email_confirmed_at, created_at FROM auth.users WHERE email = '${EMAIL}';"
echo ""

# Build connection string
CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

# Check if PGPASSWORD is set
if [ -z "$PGPASSWORD" ]; then
    echo -e "${YELLOW}Warning: PGPASSWORD not set, queries may fail${NC}"
    echo -e "${YELLOW}Note: Database password can be reset in Supabase Dashboard → Settings → Database → Database Password${NC}"
fi

USER_INFO=$(psql "${CONNECTION_STRING}" -t -A -c "SELECT id, email, email_confirmed_at, created_at FROM auth.users WHERE email = '${EMAIL}';" 2>&1)
EXIT_CODE=$?

# Debug: show raw output
echo "Raw query output (exit code: ${EXIT_CODE}):"
echo "$USER_INFO"
echo ""

# Check if query succeeded and returned data
if [ $EXIT_CODE -ne 0 ]; then
    echo -e "${RED}✗ Query failed with exit code ${EXIT_CODE}${NC}"
    echo "$USER_INFO"
    echo ""
    echo -e "${YELLOW}Continuing with other checks...${NC}"
elif echo "$USER_INFO" | grep -qi "error\|failed\|permission denied"; then
    echo -e "${RED}✗ Error in query output${NC}"
    echo "$USER_INFO"
    echo ""
    echo -e "${YELLOW}Continuing with other checks...${NC}"
elif [ -z "$USER_INFO" ] || echo "$USER_INFO" | grep -qiE "(0 rows|no rows|no matching)"; then
    echo -e "${RED}✗ User not found in auth.users${NC}"
    echo ""
    echo -e "${YELLOW}Continuing with other checks anyway...${NC}"
else
    echo -e "${GREEN}✓ User found in auth.users${NC}"
    echo "$USER_INFO"
fi

echo ""
echo "Checking profiles..."
PROFILE_INFO=$(psql "${CONNECTION_STRING}" -t -A -c "SELECT id, username, status FROM public.profiles WHERE id IN (SELECT id FROM auth.users WHERE email = '${EMAIL}');" 2>&1)

if [ -z "$PROFILE_INFO" ] || echo "$PROFILE_INFO" | grep -q "0 rows"; then
    echo -e "${RED}✗ Profile not found${NC}"
else
    echo -e "${GREEN}✓ Profile found${NC}"
    echo "$PROFILE_INFO"
fi

echo ""
echo "Checking user_roles (using service role to bypass RLS)..."
# Get user ID first - extract from the USER_INFO we already got
USER_ID=$(echo "$USER_INFO" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

# If we didn't get it from USER_INFO, try direct query
if [ -z "$USER_ID" ]; then
    USER_ID_QUERY=$(psql "${CONNECTION_STRING}" -t -A -c "SELECT id FROM auth.users WHERE email = '${EMAIL}';" 2>&1)
    USER_ID=$(echo "$USER_ID_QUERY" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
fi

if [ -z "$USER_ID" ]; then
    echo -e "${RED}✗ Could not find user ID from query output${NC}"
    echo -e "${YELLOW}Trying alternative method to get user ID...${NC}"
    # Try using known user ID from images if email matches
    if [ "$EMAIL" = "kahuna@raynsecure.com" ]; then
        USER_ID="85031a7b-b584-408b-b896-c2417b90b2e2"
        echo -e "${GREEN}Using known user ID for kahuna: ${USER_ID}${NC}"
    else
        echo -e "${RED}Cannot proceed without user ID${NC}"
        exit 1
    fi
fi

if [ -n "$USER_ID" ]; then
    echo "User ID: ${USER_ID}"
    
    # Check if trigger exists
    echo ""
    echo "Checking if trigger exists on auth.users..."
    TRIGGER_EXISTS=$(psql "${CONNECTION_STRING}" -t -A -c "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');" 2>&1 | tr -d ' \n' | head -1)
    
    if [ "$TRIGGER_EXISTS" = "t" ]; then
        echo -e "${GREEN}✓ Trigger 'on_auth_user_created' exists${NC}"
    else
        echo -e "${RED}✗ Trigger 'on_auth_user_created' NOT FOUND - This is likely the problem!${NC}"
        echo -e "${YELLOW}   The trigger needs to be created for new users to get profiles and roles${NC}"
    fi
    
    # Check user_roles using service role (bypasses RLS)
    echo ""
    echo "Checking user_roles table (bypassing RLS)..."
    ROLE_INFO=$(psql "${CONNECTION_STRING}" -t -A -c "SELECT user_id, role FROM public.user_roles WHERE user_id = '${USER_ID}';" 2>&1)
    
    if [ -z "$ROLE_INFO" ] || echo "$ROLE_INFO" | grep -q "0 rows" || echo "$ROLE_INFO" | grep -qi "no rows"; then
        echo -e "${RED}✗ Role not found in user_roles table${NC}"
        echo -e "${YELLOW}   This means the trigger didn't fire when the user was created${NC}"
        echo -e "${YELLOW}   Solution: Create the trigger and manually insert the role${NC}"
    else
        echo -e "${GREEN}✓ Role found in user_roles${NC}"
        echo "$ROLE_INFO"
        
        # Extract role from output
        USER_ROLE=$(echo "$ROLE_INFO" | grep -oE "(super_admin|client_admin|manager|user)" | head -1)
        if [ "$USER_ROLE" = "super_admin" ]; then
            echo -e "${GREEN}✓ User has super_admin role in database${NC}"
        else
            echo -e "${YELLOW}⚠ User role is: ${USER_ROLE} (not super_admin)${NC}"
        fi
    fi
    
    # Test RLS - try to query as the user themselves
    echo ""
    echo "Testing RLS policy (can user read their own role?)..."
    echo -e "${YELLOW}   (This requires testing from the frontend or with user's JWT token)${NC}"
fi

echo ""
echo -e "${GREEN}=== Summary ===${NC}"
echo "To fix if trigger is missing:"
echo "  DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;"
echo "  CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();"
echo ""
echo "To manually fix if role is missing:"
echo "  INSERT INTO public.user_roles (user_id, role) VALUES ('${USER_ID}', 'super_admin') ON CONFLICT (user_id) DO UPDATE SET role = 'super_admin';"

