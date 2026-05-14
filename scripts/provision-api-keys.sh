#!/bin/bash
# Provision (or rotate) API keys for a client's Supabase project.
#
# When provisioning (either key missing, or --rotate), BOTH keys are always
# regenerated and set so both values appear in the handover (Supabase never
# returns existing secret values to the CLI).
#
# Usage:
#   ./provision-api-keys.sh <target> [client-short-name] [--rotate]
#
# Target (required):
#   --dev        Dev project
#   --staging    Staging project
#   --master     Master project
#   --<client>   Any client defined in projects.conf (e.g. --ygos, --nexus)
#   <ref>        Raw 20-char Supabase project ref
#
# client-short-name  Optional label used in the handover output.
#                    Defaults to the flag name (e.g. --ygos → "ygos") or the raw ref.
#
# Examples:
#   ./provision-api-keys.sh --staging
#   ./provision-api-keys.sh --ygos
#   ./provision-api-keys.sh --ygos --rotate
#   ./provision-api-keys.sh cleqfnrbiqpxpzxkatda rayn

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
# Load projects.conf
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ROTATE=false
PROJECT_REF=""
CLIENT_NAME=""

for arg in "$@"; do
    case "$arg" in
        --rotate) ROTATE=true ;;
        --dev)
            PROJECT_REF="$DEV_REF"
            [ -z "$CLIENT_NAME" ] && CLIENT_NAME="dev"
            ;;
        --staging)
            PROJECT_REF="$STAGING_REF"
            [ -z "$CLIENT_NAME" ] && CLIENT_NAME="staging"
            ;;
        --master)
            PROJECT_REF="$MASTER_REF"
            [ -z "$CLIENT_NAME" ] && CLIENT_NAME="master"
            ;;
        --*)
            var_name="$(echo "${arg#--}" | tr '[:lower:]-' '[:upper:]_')_REF"
            ref="${!var_name:-}"
            if [ -n "$ref" ]; then
                PROJECT_REF="$ref"
                [ -z "$CLIENT_NAME" ] && CLIENT_NAME="${arg#--}"
            else
                echo -e "${RED}Unknown flag: $arg (no ${var_name} defined in projects.conf)${NC}" >&2
                exit 1
            fi
            ;;
        *)
            # Raw 20-char project ref or explicit client-short-name override
            if [[ "$arg" =~ ^[a-z0-9]{20}$ ]] && [ -z "$PROJECT_REF" ]; then
                PROJECT_REF="$arg"
            elif [ -n "$PROJECT_REF" ] && [ -z "$CLIENT_NAME" ]; then
                CLIENT_NAME="$arg"
            else
                echo -e "${RED}Unexpected argument: $arg${NC}" >&2
                exit 1
            fi
            ;;
    esac
done

# Default CLIENT_NAME to the raw ref if not set by a flag or positional arg
[ -z "$CLIENT_NAME" ] && CLIENT_NAME="$PROJECT_REF"

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: a target project is required${NC}"
    echo ""
    echo "Usage: $0 <target> [client-short-name] [--rotate] [--write-client-keys]"
    echo ""
    echo "  Targets: --dev, --staging, --master, --<client> (from projects.conf), or raw ref"
    echo ""
    echo "Examples:"
    echo "  $0 --staging"
    echo "  $0 --ygos --rotate"
    echo "  $0 cleqfnrbiqpxpzxkatda rayn"
    exit 1
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
EXISTING_IMPORT_INTERNAL=""
if echo "$SECRETS_JSON" | jq -e '.[] | select(.name == "LEARN_API_KEY")' &>/dev/null; then
    EXISTING_LEARN="exists"
fi
if echo "$SECRETS_JSON" | jq -e '.[] | select(.name == "GOVERN_API_KEY")' &>/dev/null; then
    EXISTING_GOVERN="exists"
fi
if echo "$SECRETS_JSON" | jq -e '.[] | select(.name == "IMPORT_INTERNAL_TOKEN")' &>/dev/null; then
    EXISTING_IMPORT_INTERNAL="exists"
fi

if [ -n "$EXISTING_LEARN" ] && [ -n "$EXISTING_GOVERN" ] && [ -n "$EXISTING_IMPORT_INTERNAL" ] && [ "$ROTATE" = false ]; then
    echo ""
    echo -e "${YELLOW}⚠️  LEARN_API_KEY, GOVERN_API_KEY, and IMPORT_INTERNAL_TOKEN already exist for project ${PROJECT_REF} (${CLIENT_NAME}).${NC}"
    echo ""
    echo -e "  ${BOLD}No \"GOVERN API KEYS — HANDOVER\" block is printed:${NC} values were set earlier and"
    echo -e "  the Supabase CLI cannot read secret values back. You must open the Dashboard to"
    echo -e "  copy them, or rotate so new keys are generated and shown here."
    echo ""
    echo -e "  To view current keys: ${CYAN}Supabase Dashboard → Project ${PROJECT_REF} → Settings → Edge Functions → Secrets${NC}"
    echo -e "  To replace them with new keys, re-run with ${BOLD}--rotate${NC}:"
    echo -e "    ${CYAN}$0 --${CLIENT_NAME} --rotate${NC}"
    echo ""
    echo -e "${YELLOW}Exiting without changes.${NC}"
    exit 0
fi

if [ "$ROTATE" = true ]; then
    echo -e "${YELLOW}--rotate flag set — generating new keys to replace any existing ones.${NC}"
    echo -e "${YELLOW}⚠️  The Govern / device-ingest consumers must update their environment.${NC}"
    echo ""
fi

# ---------------------------------------------------------------------------
# Generate keys — always mint BOTH when provisioning so values can be shared
# (e.g. with a 3rd-party developer). Supabase never returns existing secret
# values; partial updates left one key unknown in the handover output.
# ---------------------------------------------------------------------------
LEARN_API_KEY=$(openssl rand -hex 32)
GOVERN_API_KEY=$(openssl rand -hex 32)
IMPORT_INTERNAL_TOKEN=$(openssl rand -hex 32)
echo -e "${GREEN}Generated new LEARN_API_KEY, GOVERN_API_KEY, and IMPORT_INTERNAL_TOKEN.${NC}"

# ---------------------------------------------------------------------------
# Set secrets in Supabase
# ---------------------------------------------------------------------------
echo -e "${GREEN}Setting LEARN_API_KEY, GOVERN_API_KEY, and IMPORT_INTERNAL_TOKEN in project ${PROJECT_REF}...${NC}"
supabase secrets set \
    "LEARN_API_KEY=${LEARN_API_KEY}" \
    "GOVERN_API_KEY=${GOVERN_API_KEY}" \
    "IMPORT_INTERNAL_TOKEN=${IMPORT_INTERNAL_TOKEN}" \
    --project-ref "$PROJECT_REF"
echo -e "${GREEN}✓ All three keys set successfully.${NC}"

# ---------------------------------------------------------------------------
# Persist keys to client-api-keys.json
# ---------------------------------------------------------------------------
KEYS_FILE="${PROJECT_ROOT}/learn/secrets/client-api-keys.json"
if [ ! -f "$KEYS_FILE" ]; then
    echo "{}" > "$KEYS_FILE"
fi
# Upsert the entry for this client (creates or overwrites)
KEYS_TMP=$(mktemp)
jq --arg key "$CLIENT_NAME" \
   --arg ref "$PROJECT_REF" \
   --arg learn "$LEARN_API_KEY" \
   --arg govern "$GOVERN_API_KEY" \
   --arg import_token "$IMPORT_INTERNAL_TOKEN" \
   '.[$key] = {"project_ref": $ref, "LEARN_API_KEY": $learn, "GOVERN_API_KEY": $govern, "IMPORT_INTERNAL_TOKEN": $import_token}' \
   "$KEYS_FILE" > "$KEYS_TMP" && mv "$KEYS_TMP" "$KEYS_FILE"
echo -e "${GREEN}✓ client-api-keys.json updated for '${CLIENT_NAME}'.${NC}"
echo -e "${YELLOW}  ⚠️  Back up learn/secrets/client-api-keys.json to a secure location (e.g. 1Password).${NC}"

if [ "$ROTATE" = false ] && { [ -n "$EXISTING_LEARN" ] || [ -n "$EXISTING_GOVERN" ]; }; then
    echo ""
    echo -e "${YELLOW}⚠️  One or both keys already existed — both were replaced so you get two fresh values to share.${NC}"
    echo -e "${YELLOW}    Update Govern / any 3rd-party env; redeploy consumers as needed.${NC}"
fi

# ---------------------------------------------------------------------------
# Output handover information
# ---------------------------------------------------------------------------
PROFILE_LOOKUP_URL="https://${PROJECT_REF}.supabase.co/functions/v1/profile-lookup"
DEVICE_INGEST_URL="https://${PROJECT_REF}.supabase.co/functions/v1/device-ingest"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  LEARN, GOVERN, AND IMPORT_INTERNAL API KEYS — HANDOVER DETAILS FOR: ${CLIENT_NAME}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Client:${NC}       ${CLIENT_NAME}"
echo -e "  ${BOLD}Project ref:${NC}  ${PROJECT_REF}"
echo ""
echo -e "  ${BOLD}── Profile Lookup (read) ──────────────────────────────────${NC}"
echo -e "  ${BOLD}Base URL:${NC}     ${CYAN}${PROFILE_LOOKUP_URL}${NC}"
echo -e "  ${BOLD}LEARN_API_KEY:${NC}"
echo -e "  ${CYAN}${LEARN_API_KEY}${NC}"
echo ""
echo -e "  ${BOLD}── Device Ingest (write) ──────────────────────────────────${NC}"
echo -e "  ${BOLD}Base URL:${NC}     ${CYAN}${DEVICE_INGEST_URL}${NC}"
echo -e "  ${BOLD}GOVERN_API_KEY:${NC}"
echo -e "  ${CYAN}${GOVERN_API_KEY}${NC}"
echo ""
echo -e "${YELLOW}  ⚠️  Send keys securely (encrypted channel / password manager).${NC}"
echo -e "${YELLOW}     Do NOT send over plain email or Slack.${NC}"
echo -e "${YELLOW}     Do NOT commit to source control.${NC}"
echo ""
echo -e "  ${BOLD}3rd-party / Govern env (copy as needed):${NC}"
echo -e "    ${CYAN}LEARN_API_KEY=${LEARN_API_KEY}${NC}"
echo -e "    ${CYAN}GOVERN_API_KEY=${GOVERN_API_KEY}${NC}"
echo -e "    ${CYAN}LEARN_API_BASE_URL=${PROFILE_LOOKUP_URL}${NC}"
echo -e "    ${CYAN}DEVICE_INGEST_URL=${DEVICE_INGEST_URL}${NC}"
echo ""
echo -e "${BOLD}── Plain copy lines (no color) ──────────────────────────────${NC}"
echo "LEARN_API_KEY=${LEARN_API_KEY}"
echo "GOVERN_API_KEY=${GOVERN_API_KEY}"
echo "IMPORT_INTERNAL_TOKEN=${IMPORT_INTERNAL_TOKEN}"
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
