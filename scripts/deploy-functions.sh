#!/bin/bash

# Deploy Edge Functions to Existing Supabase Projects
# Usage:
#   Deploy ALL learn functions to one or more client projects:
#     ./deploy-functions.sh <project-ref> [project-ref2] ...
#   Deploy ONE function (e.g. change-password) to one or more projects:
#     ./deploy-functions.sh change-password <project-ref> [project-ref2] ...
#   Deploy license-app functions (reconcile-license-usage, sync-customer-license-data) to master:
#     ./deploy-functions.sh --master
#   Named environment shortcuts:
#     ./deploy-functions.sh --dev        # deploy to dev project
#     ./deploy-functions.sh --staging    # deploy to staging project
#     ./deploy-functions.sh --all        # deploy to dev + staging + all production clients
#     ./deploy-functions.sh --all-production  # deploy to production clients only
# Example: ./deploy-functions.sh --dev
# Example: ./deploy-functions.sh --staging
# Example: ./deploy-functions.sh change-password --dev --staging

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

# ── Known project refs (sourced from shared config) ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONF="${SCRIPT_DIR}/../../learn/secrets/projects.conf"
if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"
# ─────────────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project reference or flag is required${NC}"
    echo "Usage: ./deploy-functions.sh [function-name] <--dev|--staging|project-ref> ..."
    echo "  Deploy to dev:               ./deploy-functions.sh --dev"
    echo "  Deploy to staging:           ./deploy-functions.sh --staging"
    echo "  Deploy to dev + staging:     ./deploy-functions.sh --dev --staging"
    echo "  Deploy to all prod clients:  ./deploy-functions.sh --all-production"
    echo "  Deploy to every project:     ./deploy-functions.sh --all"
    echo "  Deploy one function:         ./deploy-functions.sh change-password --dev"
    echo "  Deploy by raw ref:           ./deploy-functions.sh REF1 REF2"
    echo "  List function names:         ./deploy-functions.sh --list"
    echo "  Deploy license-app funcs:    ./deploy-functions.sh --master"
    echo "    (deploys reconcile-license-usage + sync-customer-license-data to master DB)"
    exit 1
fi

# Get project root; supabase/functions may be at root or under learn/
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
# Learn client-DB edge functions — deployed to every client project.
# create-user  : enforces seat limits + writes seats_used to master DB
# delete-user  : decrements seats_used on master DB after user removal
ALL_FUNCTIONS=("create-user" "delete-user" "send-email" "send-lesson-reminders" "send-password-reset" "translate-lesson" "translate-track" "translation-status" "update-user-password" "update-password" "change-password" "process-scheduled-notifications" "get-document-url" "generate-certificate" "get-certificate-url" "sync-lesson-content" "generate-lesson" "import-from-document" "get-user-last-logins" "org-api" "org-webhook-publisher" "request-activation-link" "reset-user-mfa" "profile-lookup")

# License-app / master-DB edge functions — NOT deployed to client projects.
# Deploy these separately to the MASTER project ref:
#   supabase functions deploy sync-customer-license-data --project-ref <master_ref>
#   supabase functions deploy reconcile-license-usage    --project-ref <master_ref>
# reconcile-license-usage: queries each client DB for the real product_license_assignments
#   count and resets seats_used on customer_product_licenses in the master DB.
# Source: license/supabase/functions/reconcile-license-usage/
LICENSE_APP_FUNCTIONS=("sync-customer-license-data" "reconcile-license-usage")

# --list: print the canonical function list (one per line) and exit.
# Used by onboard-client.sh to avoid hardcoding the list in two places.
if [ "$1" = "--list" ]; then
    for f in "${ALL_FUNCTIONS[@]}"; do echo "$f"; done
    exit 0
fi

# --master <project-ref>: deploy license-app functions to the master project.
# These live in license/supabase/functions/, not in learn/supabase/functions/.
if [ "$1" = "--master" ]; then
    MASTER_REF="${2:-$MASTER_PROJECT_REF}"
    LICENSE_FUNC_BASE="${PROJECT_ROOT}/license"
    if [ ! -d "${LICENSE_FUNC_BASE}/supabase/functions" ]; then
        echo -e "${RED}Error: license/supabase/functions not found at ${LICENSE_FUNC_BASE}${NC}"
        exit 1
    fi
    echo -e "${GREEN}Deploying license-app functions to master project: ${MASTER_REF}${NC}"
    cd "${LICENSE_FUNC_BASE}"
    for func in "${LICENSE_APP_FUNCTIONS[@]}"; do
        FUNC_PATH="supabase/functions/${func}"
        if [ -d "${FUNC_PATH}" ] && [ -f "${FUNC_PATH}/index.ts" ]; then
            echo -e "${GREEN}Deploying ${func}...${NC}"
            supabase_cmd supabase functions deploy "${func}" --no-verify-jwt --project-ref ${MASTER_REF} || {
                echo -e "${YELLOW}Warning: Failed to deploy ${func}, continuing...${NC}"
            }
        else
            echo -e "${YELLOW}Warning: ${func} not found at ${LICENSE_FUNC_BASE}/${FUNC_PATH}, skipping...${NC}"
        fi
    done
    echo -e "${GREEN}✓ License-app functions deployed to master project ${MASTER_REF}${NC}"
    exit 0
fi

# Expand named shortcuts and --all-production / --all into project ref lists.
# Replace any --dev / --staging tokens in the args with the actual refs.
EXPANDED=()
for arg in "$@"; do
    case "$arg" in
        --dev)     EXPANDED+=("$DEV_REF") ;;
        --staging) EXPANDED+=("$STAGING_REF") ;;
        *)         EXPANDED+=("$arg") ;;
    esac
done
set -- "${EXPANDED[@]}"

if [ "$1" = "--all-production" ]; then
    if [ ${#PRODUCTION_CLIENT_REFS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No production client refs configured yet. Add them to PRODUCTION_CLIENT_REFS in this script.${NC}"
        exit 0
    fi
    echo -e "${GREEN}Deploying to ${#PRODUCTION_CLIENT_REFS[@]} production client(s)...${NC}"
    set -- "${PRODUCTION_CLIENT_REFS[@]}"
elif [ "$1" = "--all" ]; then
    ALL_REFS=("$DEV_REF" "$STAGING_REF" "${PRODUCTION_CLIENT_REFS[@]}")
    echo -e "${GREEN}Deploying to all known projects (dev + staging + ${#PRODUCTION_CLIENT_REFS[@]} production client(s))...${NC}"
    set -- "${ALL_REFS[@]}"
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

