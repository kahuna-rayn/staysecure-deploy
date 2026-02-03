#!/bin/bash

# Test script for sync-lesson-content Edge Function
# This manually triggers the sync function to test syncing lessons to client databases

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}Testing sync-lesson-content Edge Function${NC}"
echo ""

# Hardcoded configuration
PROJECT_REF="oownotmpcqcgojhrzqaj"  # Master database (where Edge Function runs)
CLIENT_SHORT_NAME="dev"  # Client short_name (from customers.short_name)

echo "Master project: ${PROJECT_REF}"
echo "Client short_name: ${CLIENT_SHORT_NAME}"
echo ""

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

FUNCTION_URL="https://${PROJECT_REF}.supabase.co/functions/v1/sync-lesson-content"

echo -e "${BLUE}What would you like to sync?${NC}"
echo "1. Sync by lesson IDs"
echo "2. Sync by learning track IDs"
read -p "Enter choice (1 or 2): " SYNC_TYPE

OWNERS_ARRAY="[\"${CLIENT_SHORT_NAME}\"]"
LESSON_IDS=""
TRACK_IDS=""

if [ "$SYNC_TYPE" = "1" ]; then
  echo ""
  read -p "Enter lesson IDs (comma-separated): " LESSON_IDS_INPUT
  LESSON_IDS=$(echo "$LESSON_IDS_INPUT" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
  LESSON_IDS_ARRAY="[${LESSON_IDS}]"
  TRACK_IDS_ARRAY="[]"
else
  echo ""
  read -p "Enter learning track IDs (comma-separated): " TRACK_IDS_INPUT
  TRACK_IDS=$(echo "$TRACK_IDS_INPUT" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
  TRACK_IDS_ARRAY="[${TRACK_IDS}]"
  LESSON_IDS_ARRAY="[]"
fi

# Build request body
REQUEST_BODY=$(cat <<EOF
{
  "owners": ${OWNERS_ARRAY},
  "lesson_ids": ${LESSON_IDS_ARRAY},
  "track_ids": ${TRACK_IDS_ARRAY},
  "incremental": false
}
EOF
)

echo ""
echo -e "${GREEN}Triggering sync-lesson-content...${NC}"
echo "Function URL: ${FUNCTION_URL}"
echo "Request body:"
echo "$REQUEST_BODY" | jq '.' 2>/dev/null || echo "$REQUEST_BODY"
echo ""

# Call the Edge Function
echo -e "${YELLOW}Calling Edge Function (this may take a while)...${NC}"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "${FUNCTION_URL}" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
# Extract response body (all but last line) - using sed for macOS compatibility
BODY=$(echo "$RESPONSE" | sed '$d')

echo ""
echo -e "${GREEN}HTTP Status Code: ${HTTP_CODE}${NC}"
echo ""
echo "Response:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo ""

if [ "$HTTP_CODE" -eq 200 ]; then
  # Parse response to check if actually successful
  if command -v jq &> /dev/null; then
    SUCCESS=$(echo "$BODY" | jq -r '.success // false')
    CLIENTS_SYNCED=$(echo "$BODY" | jq -r '.clients_synced // 0')
    LESSONS_SYNCED=$(echo "$BODY" | jq -r '.lessons_synced // 0')
    TRACKS_SYNCED=$(echo "$BODY" | jq -r '.tracks_synced // 0')
    ERROR_COUNT=$(echo "$BODY" | jq -r '.errors | length' 2>/dev/null || echo "0")
    
    echo "Summary:"
    echo "  Success: ${SUCCESS}"
    echo "  Clients synced: ${CLIENTS_SYNCED}"
    echo "  Lessons synced: ${LESSONS_SYNCED}"
    echo "  Tracks synced: ${TRACKS_SYNCED}"
    echo ""
    
    # Show errors if any
    ERRORS=$(echo "$BODY" | jq -r '.errors[]?' 2>/dev/null)
    if [ ! -z "$ERRORS" ]; then
      echo -e "${RED}Errors:${NC}"
      echo "$ERRORS" | sed 's/^/  /'
      echo ""
    fi
    
    # Show individual results
    echo "Individual client results:"
    echo "$BODY" | jq -r '.results[]? | "  \(.owner): \(.status) - \(.lessons_synced) lessons, \(.tracks_synced // 0) tracks"' 2>/dev/null
    echo ""
    
    # Only show next steps if actually successful (no errors)
    if [ "$SUCCESS" = "true" ] && [ "$ERROR_COUNT" -eq 0 ]; then
      echo -e "${GREEN}✅ Sync completed successfully!${NC}"
      echo ""
      echo -e "${YELLOW}Next steps:${NC}"
      echo "1. Verify synced data in client databases:"
      echo "   Check lessons, lesson_nodes, and related tables in client Supabase projects"
      echo ""
      echo "2. Check media files were copied:"
      echo "   Verify media URLs point to client storage buckets (not master bucket)"
    else
      echo -e "${RED}❌ Sync failed${NC}"
      echo ""
      echo "Check Edge Function logs for details:"
      echo "  https://app.supabase.com/project/${PROJECT_REF}/functions/sync-lesson-content/logs"
    fi
  else
    # jq not available, show basic message
    echo -e "${GREEN}✅ Function executed (HTTP 200)${NC}"
    echo ""
    echo "Note: Install 'jq' for detailed parsing of the response"
  fi
else
  echo -e "${RED}❌ Function returned error status ${HTTP_CODE}${NC}"
  echo ""
  echo "Check the response above for error details"
  echo "Check Edge Function logs in the dashboard:"
  echo "  https://app.supabase.com/project/${PROJECT_REF}/functions/sync-lesson-content/logs"
fi

