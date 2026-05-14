#!/bin/bash

# Create First Admin User Script
# Creates a super_admin user in a Supabase project

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

usage() {
    echo "Usage: $0 <target> <email> <password> [full-name] [first-name] [last-name]"
    echo ""
    echo "  target: --dev | --staging | --master | --<client> | <20-char-ref>"
    echo ""
    echo "Examples:"
    echo "  $0 --lentor admin@example.com SecurePass123 \"John Doe\" John Doe"
    echo "  $0 --staging admin@example.com SecurePass123"
    echo "  $0 vgrdwmbhsjoezkfojvcr admin@example.com SecurePass123"
}

# ── Resolve target → PROJECT_REF ──────────────────────────────────────────────
TARGET_ARG="${1:-}"
if [ -z "$TARGET_ARG" ]; then
    echo -e "${RED}Error: target is required${NC}"
    usage; exit 1
fi
shift

case "$TARGET_ARG" in
    --dev)     PROJECT_REF="$DEV_REF" ;;
    --staging) PROJECT_REF="$STAGING_REF" ;;
    --master)  PROJECT_REF="$MASTER_REF" ;;
    --*)
        var_name="$(echo "${TARGET_ARG#--}" | tr '[:lower:]-' '[:upper:]_')_REF"
        PROJECT_REF="${!var_name:-}"
        if [ -z "$PROJECT_REF" ]; then
            echo -e "${RED}Error: unknown flag ${TARGET_ARG} (no ${var_name} in projects.conf)${NC}" >&2
            exit 1
        fi
        ;;
    *)
        if [[ "$TARGET_ARG" =~ ^[a-z0-9]{20}$ ]]; then
            PROJECT_REF="$TARGET_ARG"
        else
            echo -e "${RED}Error: '${TARGET_ARG}' is not a valid flag or 20-char project ref${NC}" >&2
            usage; exit 1
        fi
        ;;
esac

EMAIL="${1:-}"
PASSWORD="${2:-}"
FULL_NAME="${3:-}"
FIRST_NAME="${4:-}"
LAST_NAME="${5:-}"

# Validate inputs
if [ -z "$EMAIL" ]; then
    echo -e "${RED}Error: email is required${NC}"; usage; exit 1
fi
if [ -z "$PASSWORD" ]; then
    echo -e "${RED}Error: password is required${NC}"; usage; exit 1
fi

# Set defaults for optional fields
if [ -z "$FULL_NAME" ]; then
    FULL_NAME=$(echo "$EMAIL" | cut -d'@' -f1)
fi
if [ -z "$FIRST_NAME" ]; then
    FIRST_NAME=$(echo "$FULL_NAME" | awk '{print $1}')
fi
if [ -z "$LAST_NAME" ]; then
    LAST_NAME=$(echo "$FULL_NAME" | awk '{print $NF}')
    [ "$LAST_NAME" = "$FIRST_NAME" ] && LAST_NAME=""
fi

# ── Resolve SUPABASE_SERVICE_ROLE_KEY for the target project ──────────────────
# Fetch from the CLI so we always use the correct key regardless of .env.local
echo -e "${GREEN}Fetching service role key for ${PROJECT_REF}...${NC}"
SUPABASE_SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref "${PROJECT_REF}" 2>/dev/null \
    | grep 'service_role' | awk '{print $3}' || true)

if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    # Fall back to .env.local (useful in offline/dev scenarios)
    if [ -f "${SCRIPT_DIR}/../.env.local" ]; then source "${SCRIPT_DIR}/../.env.local"
    elif [ -f ".env.local" ]; then source .env.local
    fi
fi

if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    echo -e "${RED}Error: could not retrieve SUPABASE_SERVICE_ROLE_KEY for ${PROJECT_REF}${NC}"
    echo "  • Run: supabase projects api-keys --project-ref ${PROJECT_REF}"
    echo "  • Or set SUPABASE_SERVICE_ROLE_KEY in deploy/.env.local"
    exit 1
fi
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
CREATE_USER_URL="${SUPABASE_URL}/functions/v1/create-user"

echo -e "${GREEN}Creating super_admin user...${NC}"
echo "  Project: ${PROJECT_REF}"
echo "  Email: ${EMAIL}"
echo "  Full Name: ${FULL_NAME}"
echo "  Edge Function URL: ${CREATE_USER_URL}"
echo ""

# Check if Edge Function endpoint is reachable (basic connectivity test)
echo -e "${YELLOW}Checking Edge Function endpoint...${NC}"
TEST_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${CREATE_USER_URL}" 2>&1)
TEST_CODE=$(echo "$TEST_RESPONSE" | tail -n1)

if [ "$TEST_CODE" = "404" ]; then
    echo -e "${YELLOW}⚠ Warning: Edge Function endpoint returned 404${NC}"
    echo "  This likely means the 'create-user' Edge Function is not deployed"
    echo ""
    echo "To deploy it, run:"
    echo "  supabase functions deploy create-user --no-verify-jwt --project-ref ${PROJECT_REF}"
    echo ""
    echo "Or verify deployment:"
    echo "  supabase functions list --project-ref ${PROJECT_REF}"
    echo ""
elif [ "$TEST_CODE" = "401" ] || [ "$TEST_CODE" = "403" ]; then
    echo -e "${GREEN}✓ Edge Function endpoint is accessible${NC}"
    echo "  (Authentication check passed)"
elif [ "$TEST_CODE" = "400" ] || [ "$TEST_CODE" = "500" ]; then
    echo -e "${GREEN}✓ Edge Function endpoint is accessible${NC}"
    echo "  (Endpoint exists, will attempt user creation)"
else
    echo -e "${YELLOW}⚠ Could not verify Edge Function availability (HTTP ${TEST_CODE})${NC}"
    echo "  Continuing with user creation attempt..."
fi
echo ""

# Check if jq is available for proper JSON encoding
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq not found. Using basic JSON encoding (may fail with special characters).${NC}"
    echo -e "${YELLOW}Consider installing jq for better password handling: brew install jq${NC}"
    echo ""
    
    # Fallback: escape common problematic characters
    ESCAPED_PASSWORD=$(echo "$PASSWORD" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_EMAIL=$(echo "$EMAIL" | sed 's/"/\\"/g')
    ESCAPED_FULL_NAME=$(echo "$FULL_NAME" | sed 's/"/\\"/g')
    ESCAPED_FIRST_NAME=$(echo "$FIRST_NAME" | sed 's/"/\\"/g')
    ESCAPED_LAST_NAME=$(echo "$LAST_NAME" | sed 's/"/\\"/g')
    
    JSON_BODY="{
        \"email\": \"${ESCAPED_EMAIL}\",
        \"password\": \"${ESCAPED_PASSWORD}\",
        \"full_name\": \"${ESCAPED_FULL_NAME}\",
        \"first_name\": \"${ESCAPED_FIRST_NAME}\",
        \"last_name\": \"${ESCAPED_LAST_NAME}\",
        \"access_level\": \"Super Admin\",
        \"status\": \"Active\"
    }"
else
    # Use jq for proper JSON encoding (handles all special characters)
    JSON_BODY=$(jq -n \
        --arg email "$EMAIL" \
        --arg password "$PASSWORD" \
        --arg full_name "$FULL_NAME" \
        --arg first_name "$FIRST_NAME" \
        --arg last_name "$LAST_NAME" \
        '{
            email: $email,
            password: $password,
            full_name: $full_name,
            first_name: $first_name,
            last_name: $last_name,
            access_level: "Super Admin",
            status: "Active"
        }')
fi

# Call the create-user Edge Function
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -d "${JSON_BODY}" \
    "${CREATE_USER_URL}")

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
# Extract response body (all but last line)
BODY=$(echo "$RESPONSE" | sed '$d')

echo ""
echo "Raw Response:"
echo "HTTP Status: ${HTTP_CODE}"
echo "Response Body: ${BODY}"
echo ""

# Parse error message from response if available
ERROR_MSG=""
if command -v jq &> /dev/null; then
    ERROR_MSG=$(echo "$BODY" | jq -r '.error // .message // empty' 2>/dev/null)
fi

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
    # Check if response contains error
    if echo "$BODY" | grep -qi '"error"'; then
        echo -e "${RED}✗ Error in response (despite ${HTTP_CODE} status)${NC}"
        echo ""
        if [ -n "$ERROR_MSG" ]; then
            echo -e "${RED}Error Message: ${ERROR_MSG}${NC}"
            echo ""
        fi
        echo "Full Response:"
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "  1. Check Edge Function logs:"
        echo "     https://supabase.com/dashboard/project/${PROJECT_REF}/logs/edge-functions"
        echo "  2. Verify the create-user Edge Function is deployed correctly"
        echo "  3. Check if user already exists: ./scripts/verify-user.sh ${PROJECT_REF} ${EMAIL}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ User created successfully!${NC}"
    echo ""
    echo "User Details:"
    echo "  Email: ${EMAIL}"
    echo "  Name: ${FULL_NAME}"
    echo "  Role: super_admin"
    echo ""
    
    # Try to extract user ID from response if available
    USER_ID=$(echo "$BODY" | jq -r '.user?.id // .userId // empty' 2>/dev/null)
    if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
        echo "  User ID: ${USER_ID}"
    fi
    
    echo ""
    echo -e "${YELLOW}Note: If email sending is configured, an activation email will be sent to ${EMAIL}${NC}"
    echo -e "${YELLOW}      Otherwise, you can log in directly with the password you provided.${NC}"
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo "  1. Verify user was created: ./scripts/verify-user.sh ${PROJECT_REF} ${EMAIL}"
    echo "  2. Try logging in at: https://${PROJECT_REF}.supabase.co/auth/v1/login"
    echo "  3. If login fails, check:"
    echo "     • Email confirmation status (may need to confirm email)"
    echo "     • Auth settings in Supabase Dashboard"
else
    echo -e "${RED}✗ Failed to create user${NC}"
    echo ""
    echo -e "${RED}HTTP Status: ${HTTP_CODE}${NC}"
    
    # Provide specific error messages based on status code
    case "$HTTP_CODE" in
        400)
            echo -e "${RED}Error: Bad Request (400)${NC}"
            echo ""
            echo "This usually means:"
            echo "  • Invalid request format or missing required fields"
            echo "  • Email format is invalid"
            echo "  • Password doesn't meet requirements"
            echo ""
            if [ -n "$ERROR_MSG" ]; then
                echo -e "${RED}Error Details: ${ERROR_MSG}${NC}"
                echo ""
            fi
            ;;
        401)
            echo -e "${RED}Error: Unauthorized (401)${NC}"
            echo ""
            echo "This means:"
            echo "  • SUPABASE_SERVICE_ROLE_KEY is incorrect or expired"
            echo "  • The service role key doesn't have permission to call this function"
            echo ""
            echo "To fix:"
            echo "  1. Get the correct Service Role Key from:"
            echo "     https://supabase.com/dashboard/project/${PROJECT_REF}/settings/api"
            echo "  2. Update SUPABASE_SERVICE_ROLE_KEY environment variable"
            echo "  3. Make sure you're using the 'service_role' key (not 'anon' key)"
            ;;
        403)
            echo -e "${RED}Error: Forbidden (403)${NC}"
            echo ""
            echo "This means:"
            echo "  • The Edge Function exists but access is denied"
            echo "  • Check Edge Function configuration and permissions"
            ;;
        404)
            echo -e "${RED}Error: Not Found (404)${NC}"
            echo ""
            echo "This means:"
            echo "  • The 'create-user' Edge Function is not deployed"
            echo "  • The project reference might be incorrect"
            echo ""
            echo "To fix:"
            echo "  1. Deploy the Edge Function:"
            echo "     supabase functions deploy create-user --no-verify-jwt --project-ref ${PROJECT_REF}"
            echo ""
            echo "  2. Verify it's deployed:"
            echo "     supabase functions list --project-ref ${PROJECT_REF}"
            echo ""
            echo "  3. Check Edge Functions dashboard:"
            echo "     https://supabase.com/dashboard/project/${PROJECT_REF}/functions"
            ;;
        500|502|503|504)
            echo -e "${RED}Error: Server Error (${HTTP_CODE})${NC}"
            echo ""
            echo "This means:"
            echo "  • The Edge Function encountered an internal error"
            echo "  • There may be a bug in the function code"
            echo "  • Database connection or query may have failed"
            echo ""
            echo "To debug:"
            echo "  1. Check Edge Function logs:"
            echo "     https://supabase.com/dashboard/project/${PROJECT_REF}/logs/edge-functions"
            echo "  2. Filter by function name: 'create-user'"
            echo "  3. Look for error messages or stack traces"
            echo ""
            echo "Common issues:"
            echo "  • Database trigger 'on_auth_user_created' not created"
            echo "  • Function 'handle_new_user()' doesn't exist"
            echo "  • Missing required database tables (profiles, user_roles)"
            ;;
        *)
            echo -e "${RED}Error: Unexpected status code${NC}"
            ;;
    esac
    
    echo ""
    echo "Full Response:"
    if command -v jq &> /dev/null && echo "$BODY" | jq '.' > /dev/null 2>&1; then
        echo "$BODY" | jq '.'
    else
        echo "$BODY"
    fi
    echo ""
    echo -e "${YELLOW}Additional Troubleshooting:${NC}"
    echo "  1. Verify project reference is correct: ${PROJECT_REF}"
    echo "  2. Check Edge Function exists:"
    echo "     curl -H 'Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}' ${CREATE_USER_URL}"
    echo "  3. Check Edge Function logs:"
    echo "     https://supabase.com/dashboard/project/${PROJECT_REF}/logs/edge-functions"
    echo "  4. Verify database setup:"
    echo "     • Trigger 'on_auth_user_created' exists"
    echo "     • Function 'handle_new_user()' exists"
    echo "     • Tables 'profiles' and 'user_roles' exist"
    exit 1
fi

