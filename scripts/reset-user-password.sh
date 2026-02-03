#!/bin/bash

# Script to reset a user's password directly (bypasses email workflow)
# Usage: ./reset-user-password.sh <email> <new-password> [project-ref]

set -e

EMAIL="${1}"
NEW_PASSWORD="${2}"
PROJECT_REF="${3:-nfbidnlkwdeyziydxcoj}"
SUPABASE_SERVICE_ROLE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5mYmlkbmxrd2RleXppeWR4Y29qIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2MzIwODI3MSwiZXhwIjoyMDc4Nzg0MjcxfQ.UFOq0Gqgx5kaCLBybg44kJrC8oz-huuaLCz9rBaP55E"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ -z "$EMAIL" ]; then
    echo -e "${RED}Error: Email address required${NC}"
    echo "Usage: $0 <email> <new-password> [project-ref]"
    exit 1
fi

if [ -z "$NEW_PASSWORD" ]; then
    echo -e "${RED}Error: New password required${NC}"
    echo "Usage: $0 <email> <new-password> [project-ref]"
    exit 1
fi

# Check if SUPABASE_SERVICE_ROLE_KEY is set
if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    echo -e "${RED}Error: SUPABASE_SERVICE_ROLE_KEY environment variable not set${NC}"
    echo ""
    echo "To find your service role key:"
    echo "1. Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/settings/api"
    echo "2. Copy the 'service_role' key (secret, not the anon key)"
    echo "3. Export it: export SUPABASE_SERVICE_ROLE_KEY='your-key-here'"
    echo ""
    exit 1
fi

SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

echo -e "${YELLOW}Resetting password for: ${EMAIL}${NC}"
echo -e "${YELLOW}Project: ${PROJECT_REF}${NC}"
echo ""

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed${NC}"
    echo "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

echo "Finding user..."
# Get user by email using admin API
USER_RESPONSE=$(curl -s -X GET "${SUPABASE_URL}/auth/v1/admin/users?email=${EMAIL}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json")

USER_ID=$(echo "$USER_RESPONSE" | jq -r '.users[0].id // empty' 2>/dev/null || echo "")

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
    echo -e "${RED}Error: User not found${NC}"
    echo "Response: $USER_RESPONSE"
    exit 1
fi

echo "Found user ID: $USER_ID"
echo ""

echo "Resetting password..."
# Update user password directly
RESET_RESPONSE=$(curl -s -X PUT "${SUPABASE_URL}/auth/v1/admin/users/${USER_ID}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${NEW_PASSWORD}\",\"email_confirm\":true}")

# Check if successful
if echo "$RESET_RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Password reset successfully${NC}"
    echo ""
    echo "User can now login with:"
    echo "  Email: ${EMAIL}"
    echo "  Password: ${NEW_PASSWORD}"
    echo ""
    
    # Optionally test login
    read -p "Test login? (y/n): " TEST_LOGIN
    if [ "$TEST_LOGIN" = "y" ] || [ "$TEST_LOGIN" = "Y" ]; then
        echo ""
        echo "Testing login..."
        
        # Get anon key for login test
        if [ -z "$VITE_SUPABASE_ANON_KEY" ]; then
            echo -e "${YELLOW}Note: VITE_SUPABASE_ANON_KEY not set, skipping login test${NC}"
            echo "To test login, you can use the Supabase Dashboard or the app"
        else
            LOGIN_RESPONSE=$(curl -s -X POST "${SUPABASE_URL}/auth/v1/token?grant_type=password" \
              -H "apikey: ${VITE_SUPABASE_ANON_KEY}" \
              -H "Content-Type: application/json" \
              -d "{\"email\":\"${EMAIL}\",\"password\":\"${NEW_PASSWORD}\"}")
            
            if echo "$LOGIN_RESPONSE" | jq -e '.access_token' > /dev/null 2>&1; then
                echo -e "${GREEN}✅ Login test successful!${NC}"
                echo "Access token received (truncated): $(echo "$LOGIN_RESPONSE" | jq -r '.access_token' | cut -c1-50)..."
            else
                echo -e "${YELLOW}⚠️  Login test failed${NC}"
                echo "Response: $LOGIN_RESPONSE"
                echo ""
                echo "User may need to confirm email or account may be banned"
            fi
        fi
    fi
else
    echo -e "${RED}Error: Failed to reset password${NC}"
    echo "Response: $RESET_RESPONSE"
    exit 1
fi

