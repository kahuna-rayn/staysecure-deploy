#!/bin/bash
# Set Edge Function secrets on a Supabase project from a local env file.
#
# Usage:
#   ./set-secrets.sh <target> [--secrets-file <path>]
#
# Target (required):
#   --dev        Dev project
#   --staging    Staging project
#   --master     Master project
#   --<client>   Any client defined in projects.conf (e.g. --ygos, --nexus)
#   <ref>        Raw 20-char Supabase project ref
#
# --secrets-file <path>   Path to the env file containing secret values.
#                         Defaults to learn/secrets/<name>-secrets.env
#                         (e.g. --staging → staging-secrets.env)
#
# Env file format:
#   KEY=value  — one per line; blank lines and # comments are ignored.
#   VITE_* keys are skipped (those are Vercel build-time vars, not edge secrets).
#
# Examples:
#   ./set-secrets.sh --staging
#   ./set-secrets.sh --ygos --secrets-file ~/private/ygos-edge.env
#   ./set-secrets.sh cleqfnrbiqpxpzxkatda --secrets-file learn/secrets/dev-secrets.env

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"
SECRETS_DIR="${PROJECT_ROOT}/learn/secrets"

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

# ── Parse args ────────────────────────────────────────────────────────────────
TARGET_ARG=""
SECRETS_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --secrets-file)
            shift
            SECRETS_FILE="$1"
            shift
            ;;
        --*)
            if [ -n "$TARGET_ARG" ]; then
                echo -e "${RED}Error: only one target allowed${NC}" >&2
                exit 1
            fi
            TARGET_ARG="$1"
            shift
            ;;
        *)
            if [ -n "$TARGET_ARG" ]; then
                echo -e "${RED}Error: only one target allowed${NC}" >&2
                exit 1
            fi
            TARGET_ARG="$1"
            shift
            ;;
    esac
done

if [ -z "$TARGET_ARG" ]; then
    echo -e "${RED}Error: a target project is required${NC}"
    echo ""
    echo "Usage: $0 <target> [--secrets-file <path>]"
    echo ""
    echo "  Targets: --dev, --staging, --master, --<client>, or a raw project ref"
    exit 1
fi

# ── Resolve project ref + short name ─────────────────────────────────────────
TARGET_NAME="${TARGET_ARG#--}"   # strip leading --

case "$TARGET_ARG" in
    --dev)        PROJECT_REF="$DEV_REF" ;;
    --staging)    PROJECT_REF="$STAGING_REF" ;;
    --master)     PROJECT_REF="$MASTER_REF" ;;
    --*)
        var_name="$(echo "${TARGET_ARG#--}" | tr '[:lower:]-' '[:upper:]_')_REF"
        PROJECT_REF="${!var_name:-}"
        if [ -z "$PROJECT_REF" ]; then
            echo -e "${RED}Unknown flag: ${TARGET_ARG} (no ${var_name} defined in projects.conf)${NC}" >&2
            exit 1
        fi
        ;;
    *)
        if [[ "$TARGET_ARG" =~ ^[a-z0-9]{20}$ ]]; then
            PROJECT_REF="$TARGET_ARG"
            TARGET_NAME="$TARGET_ARG"
        else
            echo -e "${RED}Error: '${TARGET_ARG}' is not a valid flag or 20-char project ref${NC}" >&2
            exit 1
        fi
        ;;
esac

# ── Resolve secrets file ──────────────────────────────────────────────────────
if [ -z "$SECRETS_FILE" ]; then
    SECRETS_FILE="${SECRETS_DIR}/shared-secrets.env"
fi

if [ ! -f "$SECRETS_FILE" ]; then
    echo -e "${RED}Error: secrets file not found: ${SECRETS_FILE}${NC}"
    echo -e "Fill in learn/secrets/shared-secrets.env with your edge function secrets."
    exit 1
fi

# ── Load secrets from file ────────────────────────────────────────────────────
# Collect KEY=value pairs, skipping:
#   - blank lines / comments
#   - VITE_* keys (Vercel build vars, not edge secrets)
#   - empty or placeholder values
SECRET_ARGS=()
SKIPPED=()

while IFS= read -r line || [ -n "${line:-}" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$value" == '"'*'"' ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$value" == "'"*"'" ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$key" == VITE_* ]]; then SKIPPED+=("$key"); continue; fi
    if [ -z "$value" ] || [[ "$value" == your_* ]] || [[ "$value" == your-* ]]; then
        SKIPPED+=("${key} (empty/placeholder)")
        continue
    fi
    SECRET_ARGS+=("${key}=${value}")
done < "$SECRETS_FILE"

if [ ${#SECRET_ARGS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No secrets found to set in ${SECRETS_FILE}${NC}"
    echo -e "  (VITE_* keys skipped; all other values were empty or placeholders)"
    exit 0
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  set-secrets.sh${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  Project : ${PROJECT_REF} (${TARGET_NAME})"
echo -e "  File    : ${SECRETS_FILE}"
echo -e "  Keys    : ${#SECRET_ARGS[@]} to set"
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo -e "  Skipped : ${#SKIPPED[@]} (VITE_*, empty, or placeholders)"
fi
echo ""

echo -e "Keys to be set:"
for arg in "${SECRET_ARGS[@]}"; do
    key="${arg%%=*}"
    echo -e "  ${GREEN}+${NC} ${key}"
done
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
if [ -t 0 ]; then
    read -r -p "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    echo ""
fi

# ── Push to Supabase ──────────────────────────────────────────────────────────
echo -e "${GREEN}Setting secrets on ${PROJECT_REF}...${NC}"

if supabase secrets set "${SECRET_ARGS[@]}" --project-ref "${PROJECT_REF}"; then
    echo ""
    echo -e "${GREEN}${BOLD}✓ ${#SECRET_ARGS[@]} secret(s) set on ${PROJECT_REF}${NC}"
else
    echo ""
    echo -e "${RED}✗ Failed to set secrets on ${PROJECT_REF}${NC}"
    exit 1
fi

# ── Remind about generated secrets not in env files ───────────────────────────
HAS_LEARN=false
HAS_GOVERN=false
for arg in "${SECRET_ARGS[@]}"; do
    [[ "$arg" == LEARN_API_KEY=* ]] && HAS_LEARN=true
    [[ "$arg" == GOVERN_API_KEY=* ]] && HAS_GOVERN=true
done
if ! $HAS_LEARN || ! $HAS_GOVERN; then
    echo ""
    echo -e "${YELLOW}Note: LEARN_API_KEY / GOVERN_API_KEY / IMPORT_INTERNAL_TOKEN were not in the secrets file.${NC}"
    echo -e "  These are generated (not read from file) — run separately if not yet provisioned:"
    echo -e "  ${CYAN}./provision-api-keys.sh --${TARGET_NAME}${NC}"
fi
