#!/bin/bash

# Test script for process-scheduled-notifications Edge Function
# This manually triggers the same function that the cron job calls

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Testing process-scheduled-notifications Edge Function${NC}"
echo ""

# Get project reference
read -p "Enter your Supabase project reference (e.g., yondlkjtwdtuwwkgxifh): " PROJECT_REF

if [ -z "$PROJECT_REF" ]; then
  echo -e "${RED}Error: Project reference is required${NC}"
  exit 1
fi

# Get service role key
echo ""
echo -e "${YELLOW}Fetching service role key...${NC}"
SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'service_role' | awk '{print $3}')

if [ -z "$SERVICE_ROLE_KEY" ]; then
  echo -e "${RED}Error: Could not retrieve service role key${NC}"
  echo "You can also provide it manually:"
  read -p "Enter service role key manually (or press Enter to exit): " SERVICE_ROLE_KEY
  if [ -z "$SERVICE_ROLE_KEY" ]; then
    exit 1
  fi
fi

FUNCTION_URL="https://${PROJECT_REF}.supabase.co/functions/v1/process-scheduled-notifications"

echo ""
echo -e "${GREEN}Triggering process-scheduled-notifications...${NC}"
echo "Function URL: ${FUNCTION_URL}"
echo "Notification Type: manager_employee_incomplete"
echo ""

# Call the Edge Function
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "${FUNCTION_URL}" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "notification_type": "manager_employee_incomplete"
  }')

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
# Extract response body (all but last line) - using sed for macOS compatibility
BODY=$(echo "$RESPONSE" | sed '$d')

echo -e "${GREEN}HTTP Status Code: ${HTTP_CODE}${NC}"
echo ""
echo "Response:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo ""

if [ "$HTTP_CODE" -eq 200 ]; then
  echo -e "${GREEN}✅ Function executed successfully!${NC}"
  echo ""
  echo -e "${YELLOW}Next steps:${NC}"
  echo "1. Check Supabase Edge Function logs for detailed output:"
  echo "   https://app.supabase.com/project/${PROJECT_REF}/functions/process-scheduled-notifications/logs"
  echo ""
  echo "2. Check if emails were sent in the database:"
  echo "   SELECT * FROM notification_history WHERE trigger_event = 'manager_employee_incomplete' ORDER BY created_at DESC LIMIT 10;"
  echo ""
  echo "3. Check your email inbox for manager notification emails"
else
  echo -e "${RED}❌ Function returned error status ${HTTP_CODE}${NC}"
  echo ""
  echo "Check the response above for error details"
  echo "Check Edge Function logs in the dashboard:"
  echo "  https://app.supabase.com/project/${PROJECT_REF}/functions/process-scheduled-notifications/logs"
fi

