#!/bin/bash

# Cleanup Test Users Script
# Deletes users created during testing (by email pattern or CSV file)
# Usage: ./cleanup-test-users.sh <project-ref> [email-pattern] [csv-file]
# Example: ./cleanup-test-users.sh cleqfnrbiqpxpzxkatda "test-.*@example.com"
# Example: ./cleanup-test-users.sh cleqfnrbiqpxpzxkatda "" test-users.csv

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROJECT_REF="${1}"
EMAIL_PATTERN="${2}"
CSV_FILE="${3}"

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: Project reference is required${NC}"
    echo "Usage: ./cleanup-test-users.sh <project-ref> [email-pattern] [csv-file]"
    echo "Example: ./cleanup-test-users.sh cleqfnrbiqpxpzxkatda \"test-.*@example.com\""
    echo "Example: ./cleanup-test-users.sh cleqfnrbiqpxpzxkatda \"\" test-users.csv"
    exit 1
fi

# Check if Supabase CLI is available
if ! command -v supabase &> /dev/null; then
    echo -e "${RED}Error: supabase CLI not found${NC}"
    exit 1
fi

echo -e "${YELLOW}Cleaning up test users in project: ${PROJECT_REF}${NC}"
echo ""

# Get connection string
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    exit 1
fi

CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

# Collect emails to delete
EMAILS_TO_DELETE=()

if [ -n "$CSV_FILE" ] && [ -f "$CSV_FILE" ]; then
    echo -e "${GREEN}Reading emails from CSV file: ${CSV_FILE}${NC}"
    # Extract emails from CSV (assuming first column is Email)
    while IFS=',' read -r email rest || [ -n "$email" ]; do
        # Skip header and empty lines
        if [[ "$email" != "Email" ]] && [[ -n "$email" ]] && [[ "$email" != "" ]]; then
            # Remove quotes and whitespace
            email=$(echo "$email" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
            EMAILS_TO_DELETE+=("$email")
        fi
    done < "$CSV_FILE"
    echo -e "${GREEN}Found ${#EMAILS_TO_DELETE[@]} emails in CSV${NC}"
elif [ -n "$EMAIL_PATTERN" ]; then
    echo -e "${GREEN}Finding users matching pattern: ${EMAIL_PATTERN}${NC}"
    # Query database for matching emails
    QUERY="SELECT email FROM auth.users WHERE email ~ '${EMAIL_PATTERN}'"
    EMAILS_TO_DELETE=($(PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" -t -c "${QUERY}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))
    echo -e "${GREEN}Found ${#EMAILS_TO_DELETE[@]} users matching pattern${NC}"
else
    echo -e "${RED}Error: Either email-pattern or csv-file must be provided${NC}"
    exit 1
fi

if [ ${#EMAILS_TO_DELETE[@]} -eq 0 ]; then
    echo -e "${YELLOW}No users found to delete${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Users to delete:${NC}"
for email in "${EMAILS_TO_DELETE[@]}"; do
    echo "  - $email"
done
echo ""

# Confirm deletion
read -p "Are you sure you want to delete these ${#EMAILS_TO_DELETE[@]} users? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}Cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Deleting users...${NC}"

# Delete each user using the delete-user edge function
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

# Get service role key (required for admin operations)
if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    echo -e "${YELLOW}Note: SUPABASE_SERVICE_ROLE_KEY not set. Using delete-user Edge Function instead.${NC}"
    echo -e "${YELLOW}Make sure you're authenticated in the app to use the Edge Function.${NC}"
    echo ""
    echo -e "${YELLOW}Alternative: Use Supabase Dashboard to delete users:${NC}"
    echo "https://supabase.com/dashboard/project/${PROJECT_REF}/auth/users"
    echo ""
    echo -e "${YELLOW}Or set SUPABASE_SERVICE_ROLE_KEY and use direct SQL deletion${NC}"
    exit 1
fi

DELETED=0
FAILED=0

for email in "${EMAILS_TO_DELETE[@]}"; do
    echo -n "Deleting $email... "
    
    # Use delete-user edge function
    RESPONSE=$(curl -s -X POST "${SUPABASE_URL}/functions/v1/delete-user" \
        -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${email}\"}")
    
    if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        DELETED=$((DELETED + 1))
    else
        echo -e "${RED}✗${NC}"
        echo "  Error: $RESPONSE"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo -e "${GREEN}Summary:${NC}"
echo "  Deleted: $DELETED"
echo "  Failed: $FAILED"
echo ""
echo -e "${GREEN}Cleanup complete!${NC}"

