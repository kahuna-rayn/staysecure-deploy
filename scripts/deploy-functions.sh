#!/bin/bash

# Deploy Edge Functions to Existing Supabase Projects
# Usage:
#   Deploy ALL functions to one or more projects:
#     ./deploy-functions.sh <project-ref> [project-ref2] ...
#   Deploy ONE function (e.g. change-password) to one or more projects:
#     ./deploy-functions.sh change-password <project-ref> [project-ref2] ...
# Example: ./deploy-functions.sh cxpnrwjqkggitqbfnsuy ptectyngjnovskdtkxcq
# Example: ./deploy-functions.sh change-password cxpnrwjqkggitqbfnsuy ptectyngjnovskdtkxcq

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper function to suppress Docker warnings from Supabase CLI
supabase_cmd() {
    "$@" 2> >(grep -v -iE "(docker.*not.*running|bouncer.*config.*error|WARNING.*[Dd]ocker|docker.*is.*not.*running)" >&2 || true)
}

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project reference is required${NC}"
    echo "Usage: ./deploy-functions.sh [function-name] <project-ref> [project-ref2] ..."
    echo "  Deploy all functions:        ./deploy-functions.sh REF1 REF2"
    echo "  Deploy one function:         ./deploy-functions.sh change-password REF1 REF2"
    echo "  Deploy to all prod projects: ./deploy-functions.sh --all-production"
    echo "  Deploy to every project:     ./deploy-functions.sh --all"
    echo "  List function names:         ./deploy-functions.sh --list"
    exit 1
fi

# Get project root; supabase/functions may be at root or under learn/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd)"

if [ -d "${PROJECT_ROOT}/learn/supabase/functions" ]; then
    FUNC_BASE="${PROJECT_ROOT}/learn"
else
    FUNC_BASE="${PROJECT_ROOT}"
fi
cd "${FUNC_BASE}"

# If first arg contains a hyphen it's a function name; otherwise it's a project ref (deploy all).
# Supabase project refs are 20-char alphanumeric strings with no hyphens.
# Function names always contain hyphens (e.g. change-password, get-document-url).
ALL_FUNCTIONS=("create-user" "delete-user" "send-email" "send-lesson-reminders" "send-password-reset" "translate-lesson" "translate-track" "translation-status" "update-user-password" "update-password" "change-password" "process-scheduled-notifications" "get-document-url" "generate-certificate" "get-certificate-url" "sync-lesson-content" "generate-lesson" "get-user-last-logins" "org-api" "org-webhook-publisher" "request-activation-link" "reset-user-mfa")

# --list: print the canonical function list (one per line) and exit.
# Used by onboard-client.sh to avoid hardcoding the list in two places.
if [ "$1" = "--list" ]; then
    for f in "${ALL_FUNCTIONS[@]}"; do echo "$f"; done
    exit 0
fi

# Expand --all-production / --all into project ref lists (bash 3.2 compatible)
if [ "$1" = "--all-production" ]; then
    echo -e "${GREEN}Querying Supabase for production projects (*-prod)...${NC}"
    RESOLVED=()
    while IFS= read -r ref; do
        [ -n "$ref" ] && RESOLVED+=("$ref")
    done < <(supabase projects list --output json 2>/dev/null \
        | jq -r '.[] | select(.name | endswith("-prod")) | .id')
    if [ ${#RESOLVED[@]} -eq 0 ]; then
        echo -e "${RED}Error: No projects with names ending in '-prod' found.${NC}"; exit 1
    fi
    echo -e "${GREEN}Found ${#RESOLVED[@]} production project(s):${NC}"
    supabase projects list --output json 2>/dev/null \
        | jq -r '.[] | select(.name | endswith("-prod")) | "  \(.id)  \(.name)"'
    echo ""
    set -- "${RESOLVED[@]}"
elif [ "$1" = "--all" ]; then
    echo -e "${GREEN}Querying Supabase for all projects...${NC}"
    RESOLVED=()
    while IFS= read -r ref; do
        [ -n "$ref" ] && RESOLVED+=("$ref")
    done < <(supabase projects list --output json 2>/dev/null | jq -r '.[].id')
    if [ ${#RESOLVED[@]} -eq 0 ]; then
        echo -e "${RED}Error: No projects found.${NC}"; exit 1
    fi
    echo -e "${GREEN}Found ${#RESOLVED[@]} project(s):${NC}"
    supabase projects list --output json 2>/dev/null \
        | jq -r '.[] | "  \(.id)  \(.name)"'
    echo ""
    set -- "${RESOLVED[@]}"
fi

if [[ "$1" == *"-"* ]]; then
    # Treat as a function name — validate it exists before proceeding
    FUNC_PATH="supabase/functions/${1}"
    if [ ! -d "${FUNC_PATH}" ] || [ ! -f "${FUNC_PATH}/index.ts" ]; then
        echo -e "${RED}Error: Function '${1}' not found at ${FUNC_BASE}/${FUNC_PATH}${NC}"
        echo ""
        echo "Available functions:"
        for f in "${ALL_FUNCTIONS[@]}"; do
            if [ -f "supabase/functions/${f}/index.ts" ]; then
                echo -e "  ${GREEN}✓${NC} ${f}"
            else
                echo -e "  ${YELLOW}✗${NC} ${f} (missing locally)"
            fi
        done
        exit 1
    fi
    SINGLE_FUNC="$1"
    shift
    FUNCTIONS=("${SINGLE_FUNC}")
    echo -e "${GREEN}Deploying only: ${SINGLE_FUNC}${NC}"
else
    FUNCTIONS=("${ALL_FUNCTIONS[@]}")
fi

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project reference is required${NC}"
    echo "Usage: ./deploy-functions.sh [function-name] <project-ref> [project-ref2] ..."
    exit 1
fi

# Deploy to each project
for PROJECT_REF in "$@"; do
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Deploying functions to project: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    
    for func in "${FUNCTIONS[@]}"; do
        FUNC_PATH="supabase/functions/${func}"
        if [ -d "${FUNC_PATH}" ] && [ -f "${FUNC_PATH}/index.ts" ]; then
            echo -e "${GREEN}Deploying ${func}...${NC}"
            # supabase functions deploy updates existing functions or creates new ones
            # It won't fail if the function already exists - it will just update it
            supabase_cmd supabase functions deploy "${func}" --no-verify-jwt --project-ref ${PROJECT_REF} || {
                echo -e "${YELLOW}Warning: Failed to deploy ${func} to ${PROJECT_REF}, continuing...${NC}"
            }
        else
            echo -e "${YELLOW}Warning: Function ${func} not found, skipping...${NC}"
        fi
    done
    
    echo -e "${GREEN}✓ Completed deployment to ${PROJECT_REF}${NC}"
done

echo ""
echo -e "${GREEN}✓ All deployments completed${NC}"

