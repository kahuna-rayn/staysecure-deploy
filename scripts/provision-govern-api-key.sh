#!/bin/bash
# Provision (or rotate) API keys for a client's Supabase project.
#
# Generates two keys:
#   LEARN_API_KEY    — Govern calls the profile-lookup and auth Edge Functions
#   GOVERN_API_KEY   — Govern calls the device-ingest Edge Function
#
# Usage:
#   ./provision-govern-api-key.sh <project-ref> [client-name]
#   ./provision-govern-api-key.sh <project-ref> [client-name] --rotate
#
# Arguments:
#   project-ref   Required. The Supabase project reference (e.g. cleqfnrbiqpxpzxkatda)
#   client-name   Optional. Used for display only (e.g. rayn). Defaults to project-ref.
#   --rotate      Optional. Generate new keys even if they already exist.
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
# Check which keys already exist
# ---------------------------------------------------------------------------
echo -e "${GREEN}Checking existing secrets for project ${PROJECT_REF}...${NC}"

SECRETS_JSON=$(supabase secrets list --project-ref "$PROJECT_REF" --output json 2>/dev/null || echo "[]")

EXISTING_LEARN=""
EXISTING_GOVERN=""
if echo "$SECRETS_JSON" | jq -e '.[] | select(.name == "LEARN_API_KEY")' &>/dev/null; then
    EXISTING_LEARN="exists"
fi
if echo "$SECRETS_JSON" | jq -e '.[] | select(.name == "GOVERN_API_KEY")' &>/dev/null; then
    EXISTING_GOVERN="exists"
fi

if [ -n "$EXISTING_LEARN" ] && [ -n "$EXISTING_GOVERN" ] && [ "$ROTATE" = false ]; then
    echo ""
    echo -e "${YELLOW}⚠️  Both LEARN_API_KEY and GOVERN_API_KEY already exist for project ${PROJECT_REF} (${CLIENT_NAME}).${NC}"
    echo ""
    echo -e "  To view current keys: ${CYAN}Supabase Dashboard → Project ${PROJECT_REF} → Settings → Edge Functions → Secrets${NC}"
    echo -e "  To replace them with new keys, re-run with ${BOLD}--rotate${NC}:"
    echo -e "    ${CYAN}$0 ${PROJECT_REF} ${CLIENT_NAME} --rotate${NC}"
    echo ""
    echo -e "${YELLOW}Exiting without changes.${NC}"
    exit 0
fi

if [ "$ROTATE" = true ]; then
    echo -e "${YELLOW}--rotate flag set — generating new keys to replace any existing ones.${NC}"
    echo -e "${YELLOW}⚠️  The Govern team will need to update their environment variables.${NC}"
    echo ""
fi

# ---------------------------------------------------------------------------
# Generate keys (skip if already exists and not rotating)
# ---------------------------------------------------------------------------
LEARN_API_KEY=""
GOVERN_API_KEY=""

if [ -z "$EXISTING_LEARN" ] || [ "$ROTATE" = true ]; then
    LEARN_API_KEY=$(openssl rand -hex 32)
    echo -e "${GREEN}Generated new LEARN_API_KEY.${NC}"
else
    echo -e "${YELLOW}LEARN_API_KEY already exists — skipping (use --rotate to replace).${NC}"
fi

if [ -z "$EXISTING_GOVERN" ] || [ "$ROTATE" = true ]; then
    GOVERN_API_KEY=$(openssl rand -hex 32)
    echo -e "${GREEN}Generated new GOVERN_API_KEY.${NC}"
else
    echo -e "${YELLOW}GOVERN_API_KEY already exists — skipping (use --rotate to replace).${NC}"
fi

# ---------------------------------------------------------------------------
# Set secrets in Supabase
# ---------------------------------------------------------------------------
if [ -n "$LEARN_API_KEY" ]; then
    echo -e "${GREEN}Setting LEARN_API_KEY in project ${PROJECT_REF}...${NC}"
    supabase secrets set "LEARN_API_KEY=${LEARN_API_KEY}" --project-ref "$PROJECT_REF"
    echo -e "${GREEN}✓ LEARN_API_KEY set successfully.${NC}"
fi

if [ -n "$GOVERN_API_KEY" ]; then
    echo -e "${GREEN}Setting GOVERN_API_KEY in project ${PROJECT_REF}...${NC}"
    supabase secrets set "GOVERN_API_KEY=${GOVERN_API_KEY}" --project-ref "$PROJECT_REF"
    echo -e "${GREEN}✓ GOVERN_API_KEY set successfully.${NC}"
fi

# ---------------------------------------------------------------------------
# Output handover information
# ---------------------------------------------------------------------------
PROFILE_LOOKUP_URL="https://${PROJECT_REF}.supabase.co/functions/v1/profile-lookup"
DEVICE_INGEST_URL="https://${PROJECT_REF}.supabase.co/functions/v1/device-ingest"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  GOVERN API KEYS — HANDOVER DETAILS FOR: ${CLIENT_NAME}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Client:${NC}       ${CLIENT_NAME}"
echo -e "  ${BOLD}Project ref:${NC}  ${PROJECT_REF}"
echo ""
echo -e "  ${BOLD}── Profile Lookup (read) ──────────────────────────────────${NC}"
echo -e "  ${BOLD}Base URL:${NC}     ${CYAN}${PROFILE_LOOKUP_URL}${NC}"
if [ -n "$LEARN_API_KEY" ]; then
    echo -e "  ${BOLD}LEARN_API_KEY:${NC}"
    echo -e "  ${CYAN}${LEARN_API_KEY}${NC}"
else
    echo -e "  ${BOLD}LEARN_API_KEY:${NC} (unchanged — already set)"
fi
echo ""
echo -e "  ${BOLD}── Device Ingest (write) ──────────────────────────────────${NC}"
echo -e "  ${BOLD}Base URL:${NC}     ${CYAN}${DEVICE_INGEST_URL}${NC}"
if [ -n "$GOVERN_API_KEY" ]; then
    echo -e "  ${BOLD}GOVERN_API_KEY:${NC}"
    echo -e "  ${CYAN}${GOVERN_API_KEY}${NC}"
else
    echo -e "  ${BOLD}GOVERN_API_KEY:${NC} (unchanged — already set)"
fi
echo ""
echo -e "${YELLOW}  ⚠️  Send keys securely (encrypted channel / password manager).${NC}"
echo -e "${YELLOW}     Do NOT send over plain email or Slack.${NC}"
echo -e "${YELLOW}     Do NOT commit to source control.${NC}"
echo ""
echo -e "  ${BOLD}Govern team should set these in their environment:${NC}"
[ -n "$LEARN_API_KEY" ]  && echo -e "    ${CYAN}LEARN_API_KEY=${LEARN_API_KEY}${NC}"
[ -n "$GOVERN_API_KEY" ] && echo -e "    ${CYAN}GOVERN_API_KEY=${GOVERN_API_KEY}${NC}"
echo -e "    ${CYAN}LEARN_API_BASE_URL=${PROFILE_LOOKUP_URL}${NC}"
echo -e "    ${CYAN}DEVICE_INGEST_URL=${DEVICE_INGEST_URL}${NC}"
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Verify secrets are set:${NC}"
echo -e "  ${CYAN}supabase secrets list --project-ref ${PROJECT_REF}${NC}"
echo ""
if [ "$ROTATE" = true ] && { [ -n "$EXISTING_LEARN" ] || [ -n "$EXISTING_GOVERN" ]; }; then
    echo -e "${RED}  ⚠️  KEY(S) ROTATED — notify the Govern team immediately.${NC}"
    echo -e "${RED}     Old keys are now invalid. Govern must update their environment.${NC}"
    echo ""
fi
