#!/bin/bash

# Script to unban a user in Supabase
# Usage: ./unban-user.sh <email> [project-ref]

set -e

EMAIL="${1}"
PROJECT_REF="${2:-nfbidnlkwdeyziydxcoj}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ -z "$EMAIL" ]; then
    echo -e "${RED}Error: Email address required${NC}"
    echo "Usage: $0 <email> [project-ref]"
    exit 1
fi

echo -e "${YELLOW}Unbanning user: ${EMAIL}${NC}"
echo -e "${YELLOW}Project: ${PROJECT_REF}${NC}"
echo ""

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

echo "Finding user ID..."
# Get user ID from email
USER_RESPONSE=$(curl -s -X POST "${SUPABASE_URL}/auth/v1/admin/users" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\"}")

USER_ID=$(echo "$USER_RESPONSE" | jq -r '.users[0].id // empty' 2>/dev/null || echo "")

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
    echo -e "${RED}Error: User not found${NC}"
    echo "Response: $USER_RESPONSE"
    exit 1
fi

echo "Found user ID: $USER_ID"
echo ""

echo "Unbanning user..."
# Try to unban by setting ban_duration to 0 or removing ban
# Note: Supabase Admin API may require different approach
UNBAN_RESPONSE=$(curl -s -X PUT "${SUPABASE_URL}/auth/v1/admin/users/${USER_ID}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"ban_duration": "0h"}')

# Check if successful
if echo "$UNBAN_RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
    echo -e "${GREEN}✅ User unbanned successfully${NC}"
    echo ""
    echo "User details:"
    echo "$UNBAN_RESPONSE" | jq '.'
else
    echo -e "${YELLOW}API method may not work. Use Supabase Dashboard instead:${NC}"
    echo ""
    echo "1. Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/auth/users"
    echo "2. Search for: ${EMAIL}"
    echo "3. Click on the user"
    echo "4. Click 'Unban' or set ban duration to 0"
    echo ""
    echo "Or run this SQL in SQL Editor:"
    echo "UPDATE auth.users SET ban_until = NULL WHERE email = '${EMAIL}';"
    echo ""
    echo "API Response: $UNBAN_RESPONSE"
fi

