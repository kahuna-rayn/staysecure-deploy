#!/bin/bash
# Provision (or rotate) the LEARN_API_KEY for a client's Supabase project.
#
# This key is the Bearer token the Govern team uses to call the profile-lookup
# and auth Edge Functions. One unique key per client deployment.
#
# Usage:
#   ./provision-govern-api-key.sh <project-ref> [client-name]
#   ./provision-govern-api-key.sh <project-ref> [client-name] --rotate
#
# Arguments:
#   project-ref   Required. The Supabase project reference (e.g. cleqfnrbiqpxpzxkatda)
#   client-name   Optional. Used for display only (e.g. rayn). Defaults to project-ref.
#   --rotate      Optional. Generate a new key even if one already exists.
#
# Examples:
#   ./provision-govern-api-key.sh cleqfnrbiqpxpzxkatda rayn
#   ./provision-govern-api-key.sh abc123xyz newclient --rotate

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
PROJECT_REF="${1:-}"
CLIENT_NAME="${2:-}"
ROTATE=false

# Parse flags (allow --rotate in any position after the first arg)
for arg in "$@"; do
    if [ "$arg" = "--rotate" ]; then
        ROTATE=true
    fi
done

# Strip --rotate from CLIENT_NAME if it was accidentally passed there
CLIENT_NAME="${CLIENT_NAME/--rotate/}"
# trim leading/trailing whitespace
CLIENT_NAME="${CLIENT_NAME#"${CLIENT_NAME%%[![:space:]]*}"}"
CLIENT_NAME="${CLIENT_NAME%"${CLIENT_NAME##*[![:space:]]}"}"

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: project-ref is required${NC}"
    echo ""
    echo "Usage: $0 <project-ref> [client-name] [--rotate]"
    echo ""
    echo "  project-ref   Supabase project reference (e.g. cleqfnrbiqpxpzxkatda)"
    echo "  client-name   Display name for output (e.g. rayn). Defaults to project-ref."
    echo "  --rotate      Generate a new key, replacing any existing one."
    echo ""
    echo "Examples:"
    echo "  $0 cleqfnrbiqpxpzxkatda rayn"
    echo "  $0 abc123xyz acmecorp --rotate"
    exit 1
fi

# Default client name to project ref if not provided
if [ -z "$CLIENT_NAME" ]; then
    CLIENT_NAME="$PROJECT_REF"
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in supabase openssl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Error: '$cmd' is required but not installed.${NC}"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Check if a key already exists
# ---------------------------------------------------------------------------
echo -e "${GREEN}Checking existing secrets for project ${PROJECT_REF}...${NC}"

EXISTING_KEY=""
SECRETS_JSON=$(supabase secrets list --project-ref "$PROJECT_REF" --output json 2>/dev/null || echo "[]")
if echo "$SECRETS_JSON" | jq -e '.[] | select(.name == "LEARN_API_KEY")' &>/dev/null; then
    EXISTING_KEY="exists"
fi

if [ -n "$EXISTING_KEY" ] && [ "$ROTATE" = false ]; then
    echo ""
    echo -e "${YELLOW}⚠️  LEARN_API_KEY already exists for project ${PROJECT_REF} (${CLIENT_NAME}).${NC}"
    echo ""
    echo -e "  To view the current key: ${CYAN}Supabase Dashboard → Project ${PROJECT_REF} → Settings → Edge Functions → Secrets${NC}"
    echo -e "  To replace it with a new key, re-run with ${BOLD}--rotate${NC}:"
    echo -e "    ${CYAN}$0 ${PROJECT_REF} ${CLIENT_NAME} --rotate${NC}"
    echo ""
    echo -e "${YELLOW}Exiting without changes.${NC}"
    exit 0
fi

if [ -n "$EXISTING_KEY" ] && [ "$ROTATE" = true ]; then
    echo -e "${YELLOW}--rotate flag set — generating a new key to replace the existing one.${NC}"
    echo -e "${YELLOW}⚠️  The Govern team will need to update their LEARN_API_KEY environment variable.${NC}"
    echo ""
fi

# ---------------------------------------------------------------------------
# Generate key
# ---------------------------------------------------------------------------
# 32 bytes = 64 hex characters — same format as the existing dev key
LEARN_API_KEY=$(openssl rand -hex 32)

echo -e "${GREEN}Generated new LEARN_API_KEY.${NC}"

# ---------------------------------------------------------------------------
# Set secret in Supabase
# ---------------------------------------------------------------------------
echo -e "${GREEN}Setting LEARN_API_KEY in project ${PROJECT_REF}...${NC}"

supabase secrets set "LEARN_API_KEY=${LEARN_API_KEY}" --project-ref "$PROJECT_REF"

echo -e "${GREEN}✓ LEARN_API_KEY set successfully.${NC}"

# ---------------------------------------------------------------------------
# Output handover information
# ---------------------------------------------------------------------------
BASE_URL="https://${PROJECT_REF}.supabase.co/functions/v1/profile-lookup"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  GOVERN API KEY — HANDOVER DETAILS FOR: ${CLIENT_NAME}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Client:${NC}       ${CLIENT_NAME}"
echo -e "  ${BOLD}Project ref:${NC}  ${PROJECT_REF}"
echo ""
echo -e "  ${BOLD}API Base URL:${NC}"
echo -e "  ${CYAN}${BASE_URL}${NC}"
echo ""
echo -e "  ${BOLD}LEARN_API_KEY:${NC}"
echo -e "  ${CYAN}${LEARN_API_KEY}${NC}"
echo ""
echo -e "${YELLOW}  ⚠️  Send this key securely (encrypted channel / password manager).${NC}"
echo -e "${YELLOW}     Do NOT send it over plain email or Slack.${NC}"
echo -e "${YELLOW}     Do NOT commit it to source control.${NC}"
echo ""
echo -e "  ${BOLD}Govern team should set this in their environment:${NC}"
echo -e "    ${CYAN}LEARN_API_KEY=${LEARN_API_KEY}${NC}"
echo -e "    ${CYAN}LEARN_API_BASE_URL=${BASE_URL}${NC}"
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Verify the secret is set:${NC}"
echo -e "  ${CYAN}supabase secrets list --project-ref ${PROJECT_REF}${NC}"
echo ""
if [ "$ROTATE" = true ] && [ -n "$EXISTING_KEY" ]; then
    echo -e "${RED}  ⚠️  KEY ROTATED — notify the Govern team immediately.${NC}"
    echo -e "${RED}     Old key is now invalid. Govern must update LEARN_API_KEY.${NC}"
    echo ""
fi
