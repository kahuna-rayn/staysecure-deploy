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
    echo "  Deploy all functions:  ./deploy-functions.sh REF1 REF2"
    echo "  Deploy one function:   ./deploy-functions.sh change-password REF1 REF2"
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

# If first arg is a function dir (e.g. change-password), deploy only that; else deploy all
if [ -d "supabase/functions/${1}" ] && [ -f "supabase/functions/${1}/index.ts" ]; then
    SINGLE_FUNC="$1"
    shift
    FUNCTIONS=("${SINGLE_FUNC}")
    echo -e "${GREEN}Deploying only: ${SINGLE_FUNC}${NC}"
else
    FUNCTIONS=("create-user" "delete-user" "send-email" "send-lesson-reminders" "send-password-reset" "translate-lesson" "translation-status" "update-user-password" "update-password" "change-password" "process-scheduled-notifications")
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

