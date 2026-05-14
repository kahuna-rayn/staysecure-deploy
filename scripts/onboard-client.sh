#!/bin/bash

# Client Onboarding Script
# Automates the creation of a new Supabase project with all required configuration
#
# Create a brand-new Supabase project even if deploy/.env.local exports PROJECT_REF
# (stale ref from a deleted project causes ENOTFOUND on pooler).
#   ./scripts/onboard-client.sh --new prod ygos seed
#
# Reuse an EXISTING Supabase project (do not create a new one):
#   ./scripts/onboard-client.sh --project-ref <ref> prod <client-name> seed
#   (--project-ref overrides PROJECT_REF from the environment if both are set.)
# The script still runs DB restore when deploy/backups/* dumps exist (can overwrite data).
# To only apply secrets/functions/cron on an already-restored DB, remove or rename backups
# temporarily, or run those steps manually.

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directory anchors — paths do not depend on the shell's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
LEARN_DIR="${REPO_ROOT}/learn"
BACKUPS_DIR="${DEPLOY_DIR}/backups"
NOTIFICATIONS_SEED_SQL="${REPO_ROOT}/notifications/supabase/seed_email_templates.sql"

# Optional flags (parsed first; remaining args are positional)
PROJECT_REF_ARG=""
FORCE_NEW_PROJECT=false
SUMMARY_ONLY=false
REMAINING_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --new|--create-project)
      FORCE_NEW_PROJECT=true
      shift
      ;;
    --project-ref)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --project-ref requires a value (Supabase project ref)${NC}" >&2
        exit 1
      fi
      PROJECT_REF_ARG="$2"
      shift 2
      ;;
    --project-ref=*)
      PROJECT_REF_ARG="${1#*=}"
      shift
      ;;
    --summary)
      SUMMARY_ONLY=true
      shift
      ;;
    -h|--help)
      echo "Usage: onboard-client.sh [options] [prod|staging|dev] <client-name> [data-type] [region]"
      echo ""
      echo "Options:"
      echo "  --new                 Create a new Supabase project. Ignores PROJECT_REF in .env —"
      echo "                        use this if .env.local still has a ref from a deleted project."
      echo "  --project-ref <ref>   Resume onboarding against this existing project (no create)."
      echo "                        Ref is the project id from the Dashboard URL."
      echo "                        PGPASSWORD must be that project's database password."
      echo "  --summary             Skip all setup steps; print only the post-onboarding handover"
      echo "                        summary for an already-onboarded project. Requires the same"
      echo "                        positional args as a normal run so variables are set correctly."
      echo "  -h, --help            Show this help."
      echo ""
      echo "  Do not put PROJECT_REF in deploy/.env.local unless you always want resume behavior;"
      echo "  prefer --project-ref for one-off resumes, or use --new when creating a fresh client."
      echo ""
      echo "Examples (new project):"
      echo "  ./onboard-client.sh prod rayn seed"
      echo "  ./onboard-client.sh --new prod rayn seed    # if .env has a stale PROJECT_REF"
      echo ""
      echo "Examples (existing project — no supabase projects create):"
      echo "  ./onboard-client.sh --project-ref abcdefghijklmnop prod rayn seed"
      echo ""
      echo "Note: If ${DEPLOY_DIR}/backups/*.dump exists, restore still runs (can overwrite the DB)."
      echo "      Move backups aside if you only want secrets, functions, and cron."
      exit 0
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${REMAINING_ARGS[@]}"

# Configuration
ENVIRONMENT=${1:-prod}  # prod, staging, dev (demo is a data-type, not an environment)
CLIENT_NAME_PARAM=${2:-""}
DATA_TYPE_PARAM=${3:-""}
REGION_PARAM=${4:-""}

# Base domain for all clients
BASE_DOMAIN="staysecure-learn.raynsecure.com"

# Parse parameters with consistent order regardless of environment
# Order: [environment] <client-name> [data-type] [region]

# CLIENT_NAME: Required for all environments
if [ -z "$CLIENT_NAME_PARAM" ]; then
    echo -e "${RED}Error: Client name is required${NC}"
    echo "Usage: ./onboard-client.sh [--new] [--project-ref <ref>] [prod|staging|dev] <client-name> [data-type] [region]"
    echo "       ./onboard-client.sh --help"
    echo ""
    echo "Example: ./onboard-client.sh prod rayn seed"
    echo "Example: ./onboard-client.sh --new prod rayn seed"
    echo "Example: ./onboard-client.sh --project-ref abcdefghijklmnop prod rayn seed"
    exit 1
else
    CLIENT_NAME="$CLIENT_NAME_PARAM"
fi

# DATA_TYPE and REGION parsing (simplified - no domain parameter)
DATA_TYPE=${DATA_TYPE_PARAM:-seed}
REGION=${REGION_PARAM:-ap-southeast-1}

# Auto-construct CLIENT_DOMAIN based on environment
# Production: staysecure-learn.raynsecure.com/<client-name>
# Dev/Staging: <environment>.staysecure-learn.raynsecure.com
if [ "$ENVIRONMENT" = "prod" ]; then
    CLIENT_DOMAIN="${BASE_DOMAIN}/${CLIENT_NAME}"
else
    # Dev or staging: use subdomain format (e.g., dev.staysecure-learn.raynsecure.com)
    CLIENT_DOMAIN="${ENVIRONMENT}.${BASE_DOMAIN}"
fi

# Validate data type
if [ "$DATA_TYPE" != "seed" ] && [ "$DATA_TYPE" != "demo" ]; then
    echo -e "${RED}Error: Data type must be 'seed' or 'demo'${NC}"
    echo "Usage: ./onboard-client.sh [--new] [--project-ref <ref>] [prod|staging|dev] <client-name> [data-type] [region]"
    echo "  client-name: Required for all environments"
    echo "  data-type: 'seed' for new clients (schema + reference data only)"
    echo "            'demo' for internal/demo (schema + all data including users)"
    echo "  region: Optional, defaults to ap-southeast-1"
    echo ""
    echo "Domain is auto-constructed:"
    echo "  - Production: staysecure-learn.raynsecure.com/<client-name>"
    echo "  - Dev/Staging: <environment>.staysecure-learn.raynsecure.com"
    exit 1
fi

echo -e "${GREEN}Onboarding client: ${CLIENT_NAME} in ${ENVIRONMENT} environment${NC}"

# Load environment variables: prefer deploy/.env*, then cwd
if [ -f "${DEPLOY_DIR}/.env.local" ]; then
    echo "Loading environment variables from ${DEPLOY_DIR}/.env.local"
    set -a
    # shellcheck source=/dev/null
    source "${DEPLOY_DIR}/.env.local"
    set +a
elif [ -f "${DEPLOY_DIR}/.env" ]; then
    echo "Loading environment variables from ${DEPLOY_DIR}/.env"
    set -a
    # shellcheck source=/dev/null
    source "${DEPLOY_DIR}/.env"
    set +a
elif [ -f ".env.local" ]; then
    echo "Loading environment variables from .env.local (cwd)"
    set -a
    # shellcheck source=/dev/null
    source ".env.local"
    set +a
elif [ -f ".env" ]; then
    echo "Loading environment variables from .env (cwd)"
    set -a
    # shellcheck source=/dev/null
    source ".env"
    set +a
else
    echo -e "${YELLOW}Warning: No .env or .env.local in ${DEPLOY_DIR} or cwd. Make sure environment variables are set.${NC}"
fi

# Load shared edge function secrets (canonical file for all client projects).
# Uses a filtered loader — skips empty/placeholder values so they don't
# clobber variables that were already set (or fail the REQUIRED_VARS check).
SHARED_SECRETS_FILE="${LEARN_DIR}/secrets/shared-secrets.env"
if [ -f "${SHARED_SECRETS_FILE}" ]; then
    echo "Loading shared secrets from ${SHARED_SECRETS_FILE}"
    while IFS= read -r _line || [ -n "${_line:-}" ]; do
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        _line="${_line#export }"
        [[ "$_line" != *=* ]] && continue
        _key="${_line%%=*}"
        _val="${_line#*=}"
        if [[ "$_val" == '"'*'"' ]]; then _val="${_val:1:${#_val}-2}"; fi
        if [[ "$_val" == "'"*"'" ]]; then _val="${_val:1:${#_val}-2}"; fi
        # Skip empty or placeholder values
        if [ -z "$_val" ] || [[ "$_val" == your_* ]] || [[ "$_val" == your-* ]]; then continue; fi
        export "$_key=$_val"
    done < "${SHARED_SECRETS_FILE}"
else
    echo -e "${YELLOW}Warning: ${SHARED_SECRETS_FILE} not found.${NC}"
    echo -e "${YELLOW}  Fill in learn/secrets/shared-secrets.env with your edge function secrets.${NC}"
fi

# CLI project targeting:
#   --new                  → clear PROJECT_REF so we always create (fixes stale PROJECT_REF in .env.local)
#   --project-ref          → explicit resume target
#   else                   → PROJECT_REF from .env is used if set (resume)
if [ "${FORCE_NEW_PROJECT}" = true ] && [ -n "${PROJECT_REF_ARG:-}" ]; then
    echo -e "${RED}Error: use either --new (create a new project) or --project-ref (resume), not both.${NC}"
    exit 1
fi

if [ "${FORCE_NEW_PROJECT}" = true ]; then
    unset PROJECT_REF
    PROJECT_REF=""
    export PROJECT_REF
    echo -e "${GREEN}--new: will create a new Supabase project (ignoring PROJECT_REF from environment / .env)${NC}"
fi

# CLI --project-ref wins over PROJECT_REF from the environment / .env
if [ -n "${PROJECT_REF_ARG:-}" ]; then
    PROJECT_REF="$PROJECT_REF_ARG"
    export PROJECT_REF
    echo -e "${GREEN}Using --project-ref=${PROJECT_REF}${NC}"
fi

if [ -n "${PROJECT_REF:-}" ] && [ "${FORCE_NEW_PROJECT}" != true ] && [ -z "${PROJECT_REF_ARG:-}" ]; then
    echo -e "${YELLOW}Note: PROJECT_REF is set (${PROJECT_REF}) — skipping project creation (resume mode).${NC}"
    echo -e "${YELLOW}  To create a new client DB instead: use ${GREEN}--new${YELLOW} or remove PROJECT_REF from deploy/.env.local.${NC}"
fi

# Use PGPASSWORD for both Supabase CLI and psql
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    echo "Please set PGPASSWORD in your environment or .zshrc"
    exit 1
fi

# --summary: skip all setup, jump straight to the handover output
if [ "${SUMMARY_ONLY}" = true ]; then
    if [ -z "${PROJECT_REF:-}" ]; then
        echo -e "${RED}Error: --summary requires PROJECT_REF to be set (via .env.local or --project-ref).${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}--summary: skipping setup, printing handover summary for ${PROJECT_REF}${NC}"
    # shellcheck disable=SC2317
    :
fi

# If PROJECT_REF is already set (env var or --project-ref), skip project creation

if [ "${SUMMARY_ONLY}" != true ]; then

# If PROJECT_REF is already set (env var or --project-ref), skip project creation
if [ -n "$PROJECT_REF" ]; then
    echo -e "${YELLOW}Resume: PROJECT_REF=${PROJECT_REF} — skipping project creation${NC}"
    echo -e "${YELLOW}  If ${BACKUPS_DIR}/*.dump exists, restore steps still run (can overwrite DB objects). Use a fresh project or move backups aside if you only want secrets/functions.${NC}"
else
    # Create Supabase project
    echo -e "${GREEN}Creating Supabase project...${NC}"
    echo "Using PGPASSWORD for database operations"
    echo -e "${YELLOW}Note: The database password is set during project creation.${NC}"
    echo -e "${YELLOW}      To reset it later: Supabase Dashboard → Settings → Database → Database Password${NC}"
    echo ""

    # Determine project name
    if [ "$ENVIRONMENT" = "staging" ] || [ "$ENVIRONMENT" = "dev" ]; then
        PROJECT_NAME="${ENVIRONMENT}"
    else
        if [ "$CLIENT_NAME" = "$ENVIRONMENT" ]; then
            PROJECT_NAME="${CLIENT_NAME}"
        else
            PROJECT_NAME="${CLIENT_NAME}-${ENVIRONMENT}"
        fi
    fi

    echo "Creating project with name: '${PROJECT_NAME}'"
    echo "Region: ${REGION}"
    echo "Org ID: ${SUPABASE_ORG_ID}"
    PROJECT_REF=$(supabase projects create "${PROJECT_NAME}" --region ${REGION} --org-id ${SUPABASE_ORG_ID} --db-password "${PGPASSWORD}" --output json | jq -r '.id')

    if [ -z "$PROJECT_REF" ] || [ "$PROJECT_REF" = "null" ]; then
        echo -e "${RED}Failed to create Supabase project${NC}"
        exit 1
    fi

    echo -e "${GREEN}Created project: ${PROJECT_REF}${NC}"

    # Wait for project to be ready
    echo -e "${GREEN}Waiting for project to be ready...${NC}"
    echo "This may take 2-3 minutes for the database to be fully initialized..."

    MAX_ATTEMPTS=30
    ATTEMPT=0
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        STATUS=$(supabase projects list --output json | jq -r ".[] | select(.id == \"${PROJECT_REF}\") | .status")
        echo "Project status: $STATUS (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS)"

        if [ "$STATUS" = "Active" ] || [ "$STATUS" = "ACTIVE_HEALTHY" ]; then
            echo -e "${GREEN}Project is ready!${NC}"
            break
        fi

        if [ $ATTEMPT -eq $((MAX_ATTEMPTS - 1)) ]; then
            echo -e "${RED}Project did not become ready within expected time${NC}"
            exit 1
        fi

        sleep 10
        ATTEMPT=$((ATTEMPT + 1))
    done
fi

# Link to the project (now that it's ready)
# Note: This is optional for cloud-only operations, but some CLI commands may require it
# If Docker is not available, this will fail but we continue anyway

# ---------------------------------------------------------------------------
# Update projects.conf with the new client ref (idempotent — skips if already present)
# ---------------------------------------------------------------------------
_update_projects_conf() {
    local ref="$1" name="$2" conf_file="$3"
    local var_name
    var_name="$(echo "$name" | tr '[:lower:]-' '[:upper:]_')_REF"

    if grep -q "^${var_name}=" "$conf_file" 2>/dev/null; then
        echo -e "${YELLOW}Note: ${var_name} already in projects.conf — skipping update.${NC}"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"

    # Insert var line before PRODUCTION_CLIENT_REFS=( and add array entry before closing )
    awk -v var="${var_name}" -v ref="${ref}" -v nm="${name}" '
      /^PRODUCTION_CLIENT_REFS=\(/ {
          print var "=\"" ref "\""
          print ""
          print $0
          next
      }
      /^\)$/ {
          print "    \"$" var "\"  # " nm
          print $0
          next
      }
      { print }
    ' "$conf_file" > "$tmp" && mv "$tmp" "$conf_file"

    echo -e "${GREEN}✓ projects.conf updated: ${var_name}=\"${ref}\"${NC}"
}

echo -e "${GREEN}Linking to project...${NC}"
pushd "${LEARN_DIR}" > /dev/null
supabase link --project-ref ${PROJECT_REF} --password "${PGPASSWORD}" 2>/dev/null || {
    echo -e "${YELLOW}Warning: Could not link project (Docker may not be running, but continuing anyway)${NC}"
}
popd > /dev/null

# Session pooler hostname must use this project's Supabase region. The 4th CLI argument
# defaults to ap-southeast-1 when omitted — wrong region causes:
#   FATAL (ENOTFOUND) tenant/user postgres.<ref> not found
# When IPv6 direct works, we never hit the pooler; network changes can flip you to pooler + bug.
# If POOLER_HOST is set in the environment, it wins (full override, e.g. aws-0 vs aws-1 from Dashboard).
if [ -z "${POOLER_HOST:-}" ] && [ -n "${PROJECT_REF}" ] && command -v supabase >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    _region_from_cli=$(supabase projects list --output json 2>/dev/null | jq -r --arg ref "$PROJECT_REF" '.[] | select((.id == $ref) or (.ref == $ref)) | .region' | head -1)
    if [ -n "${_region_from_cli}" ] && [ "${_region_from_cli}" != "null" ]; then
        REGION="${_region_from_cli}"
        echo -e "${GREEN}Resolved DB region for pooler (Supabase CLI): ${REGION}${NC}"
    fi
fi

# Detect connection method: direct IPv6 or session-mode pooler fallback
# Newer Supabase projects use IPv6-only direct connections; fall back to pooler when IPv6 routing unavailable
DB_HOSTNAME="db.${PROJECT_REF}.supabase.co"
POOLER_HOST="${POOLER_HOST:-aws-1-${REGION:-ap-southeast-1}.pooler.supabase.com}"
RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v "^\." | head -1)
if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
    export PGHOSTADDR="${RESOLVED_ADDR}"
    PG_HOST="${DB_HOSTNAME}"; PG_PORT=6543; PG_USER="postgres"
    echo -e "${GREEN}Using direct connection (IPv6): ${RESOLVED_ADDR}${NC}"
else
    PG_HOST="${POOLER_HOST}"; PG_PORT=5432; PG_USER="postgres.${PROJECT_REF}"
    echo -e "${YELLOW}Direct connection unavailable — using pooler: ${POOLER_HOST}${NC}"
fi
CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"

# Restore from backup (if available) or apply schema files
# Check for custom format dumps first, then fall back to SQL format
if [ -f "${BACKUPS_DIR}/schema.dump" ]; then
    echo -e "${GREEN}Restoring from custom format backup (${DATA_TYPE} data)...${NC}"
    # PGPASSWORD is already set globally, no need to export again
    echo "Using PGPASSWORD for database restoration"
    echo -e "${YELLOW}Note: If connection fails, verify PGPASSWORD matches the database password set during project creation.${NC}"
    echo -e "${YELLOW}      Reset password if needed: Supabase Dashboard → Settings → Database → Database Password${NC}"
    echo ""
    
    # Create connection string using direct database connection (not pooler)
    # PGPASSWORD environment variable will be used for authentication
    CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"

    # Restore schema using pg_restore (custom format preserves dependencies and metadata better)
    echo -e "${GREEN}Restoring schema from custom format dump...${NC}"
    # Note: --clean --if-exists may show errors on fresh databases (trying to drop non-existent objects)
    # These errors are safe to ignore, but we'll capture them in the log
    pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
        --dbname=postgres \
        --verbose \
        --no-owner \
        --clean \
        --if-exists \
        ${BACKUPS_DIR}/schema.dump 2>&1 | tee /tmp/restore-schema.log || {
            echo -e "${RED}Failed to restore schema${NC}"
            exit 1
        }
    
    # Restore storage schema if it exists
    if [ -f "${BACKUPS_DIR}/storage.dump" ]; then
        echo -e "${GREEN}Restoring storage schema...${NC}"
        pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
            --dbname=postgres \
            --verbose \
            --no-owner \
            --clean \
            --if-exists \
            ${BACKUPS_DIR}/storage.dump 2>&1 | tee /tmp/restore-storage.log || {
                echo -e "${YELLOW}Warning: Storage schema restore had issues (may be expected)${NC}"
            }
    fi
    
    # Create required storage buckets via create-storage.sh (single source of truth for bucket config)
    echo -e "${GREEN}Ensuring storage buckets exist...${NC}"
    POOLER_HOST="${POOLER_HOST}" REGION="${REGION}" "${SCRIPT_DIR}/create-storage.sh" "${PROJECT_REF}" || {
        echo -e "${YELLOW}Warning: Failed to create storage buckets (may already exist)${NC}"
    }

    # Restore data based on type (using custom format if available, otherwise SQL)
    if [ "$DATA_TYPE" = "demo" ] && [ -f "${BACKUPS_DIR}/demo.dump" ]; then
        echo -e "${GREEN}Restoring demo data...${NC}"
        
        # Restore auth.users first (needed for foreign key constraints with profiles and user_roles)
        if [ -f "${BACKUPS_DIR}/auth.dump" ]; then
            echo -e "${GREEN}Restoring auth.users...${NC}"
            pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
                --dbname=postgres \
                --verbose \
                --no-owner \
                --data-only \
                ${BACKUPS_DIR}/auth.dump 2>&1 | tee /tmp/restore-auth.log || {
                    echo -e "${YELLOW}Warning: Some errors restoring auth.users (may be expected)${NC}"
                }
        else
            echo -e "${YELLOW}Warning: auth.dump not found, skipping auth.users restore${NC}"
            echo -e "${YELLOW}         Profiles and user_roles may fail to restore due to missing foreign keys${NC}"
        fi
        
        # Restore all demo data from public schema (auth.users already restored from auth.dump)
        # Using --schema=public excludes auth.users which is in auth schema
        echo -e "${GREEN}Restoring demo data (public schema only, excluding auth.users)...${NC}"
        pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
            --dbname=postgres \
            --verbose \
            --no-owner \
            --data-only \
            --schema=public \
            ${BACKUPS_DIR}/demo.dump 2>&1 | tee /tmp/restore-data.log || {
                echo -e "${YELLOW}Warning: Some data restore errors occurred (may be expected)${NC}"
            }
        
        echo -e "${GREEN}✓ Demo data restored successfully${NC}"
    elif [ "$DATA_TYPE" = "seed" ] && [ -f "${BACKUPS_DIR}/seed.dump" ]; then
        echo -e "${GREEN}Restoring seed data (reference data only) from custom format...${NC}"
        pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
            --dbname=postgres \
            --verbose \
            --no-owner \
            --data-only \
            ${BACKUPS_DIR}/seed.dump 2>&1 | tee /tmp/restore-data.log || {
                echo -e "${RED}Failed to restore seed data${NC}"
                exit 1
            }
    elif [ "$DATA_TYPE" = "demo" ] && [ -f "${BACKUPS_DIR}/demo.sql" ]; then
        echo -e "${GREEN}Restoring demo data (including users) from SQL format...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file "${BACKUPS_DIR}/demo.sql" || {
                echo -e "${RED}Failed to restore demo data${NC}"
                exit 1
            }
    elif [ "$DATA_TYPE" = "seed" ] && [ -f "${BACKUPS_DIR}/seed.sql" ]; then
        echo -e "${GREEN}Restoring seed data (reference data only) from SQL format...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file "${BACKUPS_DIR}/seed.sql" || {
                echo -e "${RED}Failed to restore seed data${NC}"
                exit 1
            }
    else
        echo -e "${YELLOW}Warning: No data backup found (demo.dump/seed.dump or demo.sql/seed.sql), skipping data restoration${NC}"
    fi

    # Apply post-migration fixes (fixes that aren't in the schema dump, including RLS policies, permissions, and triggers)
    # This includes the on_auth_user_created trigger
    if [ -f "${SCRIPT_DIR}/post-migration-fixes.sql" ]; then
        echo -e "${GREEN}Applying post-migration fixes...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file "${SCRIPT_DIR}/post-migration-fixes.sql" || {
                echo -e "${RED}Error: Failed to apply post-migration fixes${NC}"
                exit 1
            }
        
        # Verify critical trigger was created
        echo "Verifying on_auth_user_created trigger was created..."
        TRIGGER_EXISTS=$(psql "${CONNECTION_STRING}" -t -c "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');" 2>&1 | grep -v "ERROR" | tr -d ' \n' | head -1)
        if [ "$TRIGGER_EXISTS" != "t" ]; then
            echo -e "${RED}Error: on_auth_user_created trigger was not created${NC}"
            echo -e "${YELLOW}Attempting to create trigger manually...${NC}"
            psql "${CONNECTION_STRING}" \
                --command "DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users; CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();" || {
                    echo -e "${RED}Failed to create trigger manually${NC}"
                    exit 1
                }
            echo -e "${GREEN}Trigger created successfully${NC}"
        else
            echo -e "${GREEN}✓ on_auth_user_created trigger verified${NC}"
        fi
    else
        echo -e "${RED}Error: post-migration-fixes.sql not found${NC}"
        exit 1
    fi

    # Seed notification email preferences and templates (idempotent — safe to re-run)
    if [ -f "${NOTIFICATIONS_SEED_SQL}" ]; then
        echo -e "${GREEN}Seeding email preferences and notification templates...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file "${NOTIFICATIONS_SEED_SQL}" || {
                echo -e "${RED}Error: Failed to seed email templates${NC}"
                exit 1
            }
        echo -e "${GREEN}✓ Email preferences and notification templates seeded${NC}"
    else
        echo -e "${YELLOW}Warning: seed_email_templates.sql not found — email_preferences will not be seeded${NC}"
    fi

    # CHH is now served from RAYN master storage — no per-client upload needed.
    # The seed migration (20260423000002_seed_standard_documents.sql) sets the url
    # directly to the master project's public documents bucket.

    echo -e "${GREEN}✓ Backup restored successfully${NC}"
elif [ -f "${BACKUPS_DIR}/schema.sql" ]; then
    echo -e "${GREEN}Restoring from SQL format backup (${DATA_TYPE} data)...${NC}"
    # PGPASSWORD is already set globally, no need to export again
    echo "Using PGPASSWORD for database restoration"
    echo -e "${YELLOW}Note: If connection fails, verify PGPASSWORD matches the database password set during project creation.${NC}"
    echo -e "${YELLOW}      Reset password if needed: Supabase Dashboard → Settings → Database → Database Password${NC}"
    echo ""
    
    # Create connection string using direct database connection (not pooler)
    # PGPASSWORD environment variable will be used for authentication
    CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"

    # Restore schema
    echo -e "${GREEN}Restoring schema from SQL...${NC}"
    psql "${CONNECTION_STRING}" \
        --single-transaction \
        --variable ON_ERROR_STOP=1 \
        --file "${BACKUPS_DIR}/schema.sql" || {
            echo -e "${RED}Failed to restore schema${NC}"
            exit 1
        }
    
    # Restore data based on type
    if [ "$DATA_TYPE" = "demo" ] && [ -f "${BACKUPS_DIR}/demo.sql" ]; then
        echo -e "${GREEN}Restoring demo data (including users)...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file "${BACKUPS_DIR}/demo.sql" || {
                echo -e "${RED}Failed to restore demo data${NC}"
                exit 1
            }
    elif [ "$DATA_TYPE" = "seed" ] && [ -f "${BACKUPS_DIR}/seed.sql" ]; then
        echo -e "${GREEN}Restoring seed data (reference data only)...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file "${BACKUPS_DIR}/seed.sql" || {
                echo -e "${RED}Failed to restore seed data${NC}"
                exit 1
            }
    else
        echo -e "${YELLOW}Warning: demo.sql not found, skipping data restoration${NC}"
    fi
    
    # Apply post-migration fixes (fixes that aren't in the schema dump, including RLS policies, permissions, and triggers)
    # This includes the on_auth_user_created trigger
    if [ -f "${SCRIPT_DIR}/post-migration-fixes.sql" ]; then
        echo -e "${GREEN}Applying post-migration fixes...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file "${SCRIPT_DIR}/post-migration-fixes.sql" || {
                echo -e "${RED}Error: Failed to apply post-migration fixes${NC}"
                exit 1
            }
        
        # Verify critical trigger was created
        echo "Verifying on_auth_user_created trigger was created..."
        TRIGGER_EXISTS=$(psql "${CONNECTION_STRING}" -t -c "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');" 2>&1 | grep -v "ERROR" | tr -d ' \n' | head -1)
        if [ "$TRIGGER_EXISTS" != "t" ]; then
            echo -e "${RED}Error: on_auth_user_created trigger was not created${NC}"
            echo -e "${YELLOW}Attempting to create trigger manually...${NC}"
            psql "${CONNECTION_STRING}" \
                --command "DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users; CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();" || {
                    echo -e "${RED}Failed to create trigger manually${NC}"
                    exit 1
                }
            echo -e "${GREEN}Trigger created successfully${NC}"
        else
            echo -e "${GREEN}✓ on_auth_user_created trigger verified${NC}"
        fi
    else
        echo -e "${RED}Error: post-migration-fixes.sql not found${NC}"
        exit 1
    fi

    # Seed notification email preferences and templates (idempotent — safe to re-run)
    if [ -f "${NOTIFICATIONS_SEED_SQL}" ]; then
        echo -e "${GREEN}Seeding email preferences and notification templates...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file "${NOTIFICATIONS_SEED_SQL}" || {
                echo -e "${RED}Error: Failed to seed email templates${NC}"
                exit 1
            }
        echo -e "${GREEN}✓ Email preferences and notification templates seeded${NC}"
    else
        echo -e "${YELLOW}Warning: seed_email_templates.sql not found — email_preferences will not be seeded${NC}"
    fi

    # CHH is now served from RAYN master storage — no per-client upload needed.
    # The seed migration (20260423000002_seed_standard_documents.sql) sets the url
    # directly to the master project's public documents bucket.

    echo -e "${GREEN}✓ Backup restored successfully${NC}"
else
    echo -e "${YELLOW}No backup found, applying schema files...${NC}"
    FILES=(
        "01_tables.sql"
        "02_functions.sql"
        "03_demo.sql"
        "04_rls_policies.sql"
        "05_foreign_keys.sql"
        "06_primary_keys.sql"
        "07_triggers.sql"
    )

    pushd "${LEARN_DIR}" > /dev/null
    for file in "${FILES[@]}"; do
        if [ -f "${DEPLOY_DIR}/$file" ]; then
            echo "Applying $file..."
            supabase db execute --file "${DEPLOY_DIR}/$file" --project-ref ${PROJECT_REF} || {
                echo -e "${RED}Failed to apply $file${NC}"
                popd > /dev/null
                exit 1
            }
        else
            echo -e "${YELLOW}Warning: $file not found${NC}"
        fi
    done
    popd > /dev/null
    
    # Apply post-migration fixes (fixes that aren't in the schema dump, including RLS policies, permissions, and triggers)
    CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"
    if [ -f "${SCRIPT_DIR}/post-migration-fixes.sql" ]; then
        echo -e "${GREEN}Applying post-migration fixes...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file "${SCRIPT_DIR}/post-migration-fixes.sql" || {
                echo -e "${YELLOW}Warning: Failed to apply post-migration fixes${NC}"
            }
    else
        echo -e "${YELLOW}Warning: post-migration-fixes.sql not found, skipping${NC}"
    fi
fi

# Bootstrap the Supabase migration tracking table if it doesn't exist.
# A fresh Supabase project restored from pg_dump does NOT have
# supabase_migrations.schema_migrations — the Supabase CLI normally creates it,
# but we're restoring via psql, not the CLI. Without this table, both
# --baseline and the subsequent run-migrations.sh call silently fail (the
# psql query errors, the project is added to FAILED, and the loop continues),
# leaving the DB with no migration tracking at all.
echo -e "${GREEN}Bootstrapping migration tracking table...${NC}"
if psql "${CONNECTION_STRING}" -q -c "
    CREATE SCHEMA IF NOT EXISTS supabase_migrations;
    CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
        version    text NOT NULL PRIMARY KEY,
        name       text,
        statements text[]
    );
" 2>&1; then
    echo -e "${GREEN}✓ supabase_migrations.schema_migrations ready${NC}"
else
    echo -e "${RED}✗ Could not bootstrap schema_migrations — baseline will likely fail${NC}"
    echo -e "${YELLOW}  Fix manually in the SQL editor:${NC}"
    echo -e "${YELLOW}    CREATE SCHEMA IF NOT EXISTS supabase_migrations;${NC}"
    echo -e "${YELLOW}    CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (version text PRIMARY KEY, name text, statements text[]);${NC}"
fi

# Stamp every local migration file as already-applied (no SQL executed).
# The schema came from the dump, so re-running the migrations would fail on
# duplicate objects. --baseline just inserts rows into schema_migrations so
# future run-migrations.sh calls know what's already in place.
echo -e "${GREEN}Baselining migration history (recording all versions as applied)...${NC}"
if "${SCRIPT_DIR}/run-migrations.sh" --baseline "${PROJECT_REF}"; then
    echo -e "${GREEN}✓ Migration history baselined${NC}"
else
    echo -e "${RED}✗ Could not baseline migration history — check PGPASSWORD and connectivity${NC}"
    echo -e "${YELLOW}  Fix manually: ./run-migrations.sh --baseline ${PROJECT_REF}${NC}"
fi

# If any migrations were added to the repo AFTER the dump was taken, baseline
# won't have seen them (they didn't exist at baseline time). Run once more to
# apply any such stragglers. This is a no-op when the dump is fully up-to-date.
echo -e "${GREEN}Applying any migrations added after the dump was taken...${NC}"
if "${SCRIPT_DIR}/run-migrations.sh" "${PROJECT_REF}"; then
    echo -e "${GREEN}✓ Migrations up to date${NC}"
else
    echo -e "${RED}✗ Post-dump migrations failed — check output above${NC}"
    echo -e "${YELLOW}  Fix manually: ./run-migrations.sh ${PROJECT_REF}${NC}"
fi


# Set Edge Function secrets
echo -e "${GREEN}Setting Edge Function secrets...${NC}"
# Set APP_BASE_URL based on client domain
APP_BASE_URL="https://${CLIENT_DOMAIN}"

# Default manager notification cooldown (can override via env)
MANAGER_NOTIFICATION_COOLDOWN_HOURS=${MANAGER_NOTIFICATION_COOLDOWN_HOURS:-120}
echo "Using manager notification cooldown: ${MANAGER_NOTIFICATION_COOLDOWN_HOURS} hours"

# Note: SMTP configuration must be set in Supabase Dashboard for email functions to work
echo -e "${YELLOW}Note: Configure SMTP settings in Supabase Dashboard for email functionality${NC}"

# Set AUTH_LAMBDA_URL if not provided (placeholder for centralized email service)
if [ -z "$AUTH_LAMBDA_URL" ]; then
    echo -e "${YELLOW}Warning: AUTH_LAMBDA_URL not set, using placeholder${NC}"
    AUTH_LAMBDA_URL="https://nsvovgtia6cx7lel75yzt5mc4q0fhsyh.lambda-url.ap-southeast-1.on.aws/"
fi

# Check for required environment variables
REQUIRED_VARS=(
    "SUPABASE_SERVICE_ROLE_KEY"
    "SUPABASE_DB_URL"
    "AUTH_LAMBDA_URL"
    "GOOGLE_TRANSLATE_API_KEY"
    "DEEPL_API_KEY"
    "APP_BASE_URL"
    "MANAGER_NOTIFICATION_COOLDOWN_HOURS"
    "PHISHINGBOX_API_TOKEN"
    "CERT_RENDERER_URL"
    "CERT_RENDER_SECRET"
)
# Optional: ANTHROPIC_API_KEY, SB_SECRET, SB_PUB_KEY


MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo -e "${RED}Error: Missing required environment variables:${NC}"
    printf '%s\n' "${MISSING_VARS[@]}"
    echo -e "${YELLOW}Please set these variables before running the script${NC}"
    exit 1
fi

pushd "${LEARN_DIR}" > /dev/null

echo -e "${GREEN}Setting Edge Function secrets...${NC}"
# Note: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are automatically provided by Supabase
# and cannot be set manually (they're created when the project is created).
# Edge Functions can access them via Deno.env.get('SUPABASE_URL') and Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

supabase secrets set \
    GOOGLE_TRANSLATE_API_KEY=${GOOGLE_TRANSLATE_API_KEY} \
    DEEPL_API_KEY=${DEEPL_API_KEY} \
    AUTH_LAMBDA_URL=${AUTH_LAMBDA_URL} \
    APP_BASE_URL=${APP_BASE_URL} \
    MANAGER_NOTIFICATION_COOLDOWN_HOURS=${MANAGER_NOTIFICATION_COOLDOWN_HOURS} \
    PHISHINGBOX_API_TOKEN=${PHISHINGBOX_API_TOKEN} \
    CERT_RENDERER_URL=${CERT_RENDERER_URL} \
    CERT_RENDER_SECRET=${CERT_RENDER_SECRET} \
    --project-ref ${PROJECT_REF}

# Set Supabase new-format keys (sb_secret_… / sb_publishable_…) when provided.
# These replace the JWT-based SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY as Supabase
# migrates away from JWTs. Edge functions read SB_SECRET first as a fallback.
if [ -n "${SB_SECRET:-}" ]; then
    supabase secrets set \
        SB_SECRET=${SB_SECRET} \
        --project-ref ${PROJECT_REF}
fi
if [ -n "${SB_PUB_KEY:-}" ]; then
    supabase secrets set \
        SB_PUB_KEY=${SB_PUB_KEY} \
        --project-ref ${PROJECT_REF}
fi
echo -e "${GREEN}✓ Core secrets set${NC}"

# Set Anthropic API key (if provided)
if [ -n "$ANTHROPIC_API_KEY" ]; then
    supabase secrets set \
        ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY} \
        --project-ref ${PROJECT_REF}
    echo -e "${GREEN}✓ Anthropic API key set${NC}"
fi

# Deploy Edge Functions (not included in database dumps)
# Delegates to deploy-functions.sh so this list never gets out of sync.
echo -e "${GREEN}Deploying Edge Functions...${NC}"
"${SCRIPT_DIR}/deploy-functions.sh" "${PROJECT_REF}"

popd > /dev/null

# Ensure pg_cron is enabled and schedule manager notification job
echo -e "${GREEN}Configuring manager notification cron job...${NC}"

# Delegate all cron job setup to setup-cron-jobs.sh (single source of truth)
echo -e "${GREEN}Configuring pg_cron scheduled jobs...${NC}"
"${SCRIPT_DIR}/setup-cron-jobs.sh" "${PROJECT_REF}"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error configuring pg_cron jobs${NC}"
    exit 1
fi

# Configure auth session timeouts and JWT expiry via Management API (optional; requires SUPABASE_ACCESS_TOKEN)
# Session timeout values are Go duration strings (e.g. "30m", "1h", "0" = disabled).
# Time-box: hard cap on session lifetime regardless of activity (0 = disabled).
# Inactivity: sign out after this period of no token-refresh activity.
# JWT expiry must be short enough that the Supabase client auto-refreshes well within
# the inactivity window. The client refreshes ~90s before expiry (ticks every 30s,
# triggers at <3 ticks remaining). Setting jwt_exp equal to the inactivity timeout
# means a refresh fires ~90s before the window closes — enough buffer in practice.
# Do not go below 300s (5 min): clock skew and refresh overhead cause spurious logouts.
# jwt_exp is in seconds (integer): 900 = 15 minutes.
# Keeping jwt_exp at half the inactivity timeout ensures the client refreshes
# well before the 30-minute inactivity window closes, avoiding race conditions.
SESSIONS_TIMEBOX=${SESSIONS_TIMEBOX:-0}
SESSIONS_INACTIVITY_TIMEOUT=${SESSIONS_INACTIVITY_TIMEOUT:-0.5h}
JWT_EXP_SECONDS=${JWT_EXP_SECONDS:-900}
if [ -n "$SUPABASE_ACCESS_TOKEN" ]; then
    echo -e "${GREEN}Configuring auth session timeouts and JWT expiry (Management API)...${NC}"
    AUTH_CONFIG_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.supabase.com/v1/projects/${PROJECT_REF}/config/auth" \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"sessions_timebox\": \"${SESSIONS_TIMEBOX}\", \"sessions_inactivity_timeout\": \"${SESSIONS_INACTIVITY_TIMEOUT}\", \"jwt_exp\": ${JWT_EXP_SECONDS}}")
    AUTH_CONFIG_HTTP_CODE=$(echo "$AUTH_CONFIG_RESPONSE" | tail -n1)
    if [ "$AUTH_CONFIG_HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ Auth config set (time-box: ${SESSIONS_TIMEBOX}, inactivity: ${SESSIONS_INACTIVITY_TIMEOUT}, JWT expiry: ${JWT_EXP_SECONDS}s)${NC}"
    else
        echo -e "${YELLOW}Warning: Could not set auth config (HTTP ${AUTH_CONFIG_HTTP_CODE})${NC}"
        echo -e "${YELLOW}  Set them manually — see manual steps below${NC}"
    fi
else
    echo -e "${YELLOW}Note: Set SUPABASE_ACCESS_TOKEN (Personal Access Token) to configure auth settings automatically.${NC}"
    echo -e "${YELLOW}  Or set manually — see manual steps below${NC}"
fi

# Configure PostgREST API settings via Management API (optional; requires SUPABASE_ACCESS_TOKEN)
POSTGREST_MAX_ROWS=${POSTGREST_MAX_ROWS:-10000}
if [ -n "$SUPABASE_ACCESS_TOKEN" ]; then
    echo -e "${GREEN}Configuring PostgREST max_rows (Management API)...${NC}"
    POSTGREST_CONFIG_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.supabase.com/v1/projects/${PROJECT_REF}/config/postgrest" \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"max_rows\": ${POSTGREST_MAX_ROWS}}")
    POSTGREST_CONFIG_HTTP_CODE=$(echo "$POSTGREST_CONFIG_RESPONSE" | tail -n1)
    if [ "$POSTGREST_CONFIG_HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ PostgREST max_rows set to ${POSTGREST_MAX_ROWS}${NC}"
    else
        echo -e "${YELLOW}Warning: Could not set PostgREST config (HTTP ${POSTGREST_CONFIG_HTTP_CODE})${NC}"
    fi
fi

# Set client service key in master database for sync-lesson-content Edge Function
# This allows the master database to sync content to this client database
# Secret name uses CLIENT_NAME (short_name) not PROJECT_REF so it's human-readable
CLIENT_NAME_UPPER="$(echo "${CLIENT_NAME}" | tr '[:lower:]-' '[:upper:]_')"
if [ -n "$MASTER_PROJECT_REF" ]; then
    echo -e "${GREEN}Setting client service key in master database for sync...${NC}"
    CLIENT_SERVICE_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'service_role' | awk '{print $3}')
    
    if [ -n "$CLIENT_SERVICE_KEY" ]; then
        SECRET_NAME="CLIENT_SERVICE_KEY_${CLIENT_NAME_UPPER}"
        echo "Setting secret ${SECRET_NAME} in master project ${MASTER_PROJECT_REF}"
        supabase secrets set ${SECRET_NAME}=${CLIENT_SERVICE_KEY} \
            --project-ref ${MASTER_PROJECT_REF} 2>&1 | tee /tmp/set-sync-secret.log
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Client service key stored in master Edge Function secrets${NC}"
            echo -e "${GREEN}  Secret name: ${SECRET_NAME}${NC}"
        else
            echo -e "${YELLOW}Warning: Failed to set client service key in master database${NC}"
            echo -e "${YELLOW}  You may need to set this manually:${NC}"
            echo -e "${YELLOW}  supabase secrets set ${SECRET_NAME}=${CLIENT_SERVICE_KEY} --project-ref ${MASTER_PROJECT_REF}${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: Could not retrieve client service key${NC}"
        echo -e "${YELLOW}  Get it from: Supabase Dashboard → Settings → API → service_role key${NC}"
        echo -e "${YELLOW}  Then set manually: supabase secrets set CLIENT_SERVICE_KEY_${CLIENT_NAME_UPPER}=<key> --project-ref ${MASTER_PROJECT_REF}${NC}"
    fi

    # Set MASTER_SUPABASE_URL and MASTER_SUPABASE_SERVICE_ROLE_KEY on the CLIENT project
    # Required by create-user and delete-user edge functions to write seats_used back
    # to the master database after every user creation or deletion.
    echo -e "${GREEN}Setting master DB secrets on client project for license write-back...${NC}"
    MASTER_SUPABASE_URL="https://${MASTER_PROJECT_REF}.supabase.co"
    # Retrieve master service role key (same way we retrieved the client key above)
    MASTER_SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref ${MASTER_PROJECT_REF} | grep 'service_role' | awk '{print $3}')

    if [ -n "$MASTER_SERVICE_ROLE_KEY" ]; then
        supabase secrets set \
            MASTER_SUPABASE_URL=${MASTER_SUPABASE_URL} \
            MASTER_SUPABASE_SERVICE_ROLE_KEY=${MASTER_SERVICE_ROLE_KEY} \
            --project-ref ${PROJECT_REF} 2>&1 | tee /tmp/set-master-secrets.log

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Master DB secrets set on client project${NC}"
            echo -e "${GREEN}  MASTER_SUPABASE_URL = ${MASTER_SUPABASE_URL}${NC}"
        else
            echo -e "${YELLOW}Warning: Failed to set master DB secrets on client project${NC}"
            echo -e "${YELLOW}  Set manually:${NC}"
            echo -e "${YELLOW}  supabase secrets set MASTER_SUPABASE_URL=${MASTER_SUPABASE_URL} MASTER_SUPABASE_SERVICE_ROLE_KEY=<key> --project-ref ${PROJECT_REF}${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: Could not retrieve master service role key${NC}"
        echo -e "${YELLOW}  Set manually:${NC}"
        echo -e "${YELLOW}  supabase secrets set MASTER_SUPABASE_URL=${MASTER_SUPABASE_URL} MASTER_SUPABASE_SERVICE_ROLE_KEY=<key> --project-ref ${PROJECT_REF}${NC}"
    fi
else
    echo -e "${YELLOW}Note: MASTER_PROJECT_REF not set, skipping sync secret setup${NC}"
    echo -e "${YELLOW}  To enable content syncing, set MASTER_PROJECT_REF environment variable${NC}"
    echo -e "${YELLOW}  Then manually set: supabase secrets set CLIENT_SERVICE_KEY_${CLIENT_NAME_UPPER}=<service_key> --project-ref <master_ref>${NC}"
    echo -e "${YELLOW}  Also set on client: supabase secrets set MASTER_SUPABASE_URL=https://<master_ref>.supabase.co MASTER_SUPABASE_SERVICE_ROLE_KEY=<key> --project-ref ${PROJECT_REF}${NC}"
fi

# Verify restore by comparing object counts with source database
echo ""
echo -e "${GREEN}Verifying restore completeness...${NC}"

# Get source project reference for verification comparison.
# Staging is the source of truth for new client dumps; fall back to STAGING_REF from projects.conf,
# then to the known staging ref if projects.conf wasn't loaded.
PROJECTS_CONF="${LEARN_DIR}/secrets/projects.conf"
[ -f "${PROJECTS_CONF}" ] && source "${PROJECTS_CONF}"
SOURCE_PROJECT_REF="${STAGING_REF:-yondlkjtwdtuwwkgxifh}"
CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"

# Collect counts from target (newly restored) database
echo "Collecting object counts from target database..."
TARGET_TABLES=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_POLICIES=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_FUNCTIONS=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace;" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_TRIGGERS=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'public' AND tgisinternal = false;" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_INDEXES=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_VIEWS=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'public';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_TYPES=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype = 'c';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_STORAGE_POLICIES=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TARGET_AUTH_TRIGGERS=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'auth';" 2>&1 | grep -v "ERROR" | tr -d ' \n')

# Check critical trigger in target
echo "Checking critical components..."
TARGET_AUTH_USER_TRIGGER=$(psql "${CONNECTION_STRING}" -t -c "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');" 2>&1 | grep -v "ERROR" | tr -d ' \n' | head -1)
[ "$TARGET_AUTH_USER_TRIGGER" = "t" ] && TARGET_AUTH_USER_TRIGGER="Yes" || TARGET_AUTH_USER_TRIGGER="No"

# Check edge functions — derive list from deploy-functions.sh (single source of truth)
# (read loop instead of mapfile: macOS /bin/bash is 3.2 and has no mapfile)
EXPECTED_FUNCTIONS=()
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && EXPECTED_FUNCTIONS+=("$line")
done < <("${SCRIPT_DIR}/deploy-functions.sh" --list 2>/dev/null)
FUNCTIONS_LIST=$(supabase functions list --project-ref ${PROJECT_REF} --output json 2>/dev/null | jq -r '.[].slug' 2>/dev/null || echo "")
TARGET_EDGE_FUNCTIONS=0
TARGET_MISSING_FUNCTIONS=()
for func in "${EXPECTED_FUNCTIONS[@]}"; do
    if echo "$FUNCTIONS_LIST" | grep -q "^${func}$"; then
        TARGET_EDGE_FUNCTIONS=$((TARGET_EDGE_FUNCTIONS + 1))
    else
        TARGET_MISSING_FUNCTIONS+=("$func")
    fi
done

# Check storage buckets (status = target has all required ids — not "match staging")
EXPECTED_BUCKETS=("avatars" "documents" "certificates" "logos" "lesson-media")
EXPECTED_BUCKET_COUNT=${#EXPECTED_BUCKETS[@]}
TARGET_STORAGE_BUCKETS=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM storage.buckets WHERE id IN ('avatars','documents','certificates','logos','lesson-media');" 2>&1 | grep -v "ERROR" | tr -d ' \n')

# Check edge function secrets
# MASTER_SUPABASE_URL and MASTER_SUPABASE_SERVICE_ROLE_KEY are only present when MASTER_PROJECT_REF was set
if [ -n "$MASTER_PROJECT_REF" ]; then
    EXPECTED_SECRETS=("GOOGLE_TRANSLATE_API_KEY" "DEEPL_API_KEY" "AUTH_LAMBDA_URL" "APP_BASE_URL" "MANAGER_NOTIFICATION_COOLDOWN_HOURS" "MASTER_SUPABASE_URL" "MASTER_SUPABASE_SERVICE_ROLE_KEY")
else
    EXPECTED_SECRETS=("GOOGLE_TRANSLATE_API_KEY" "DEEPL_API_KEY" "AUTH_LAMBDA_URL" "APP_BASE_URL" "MANAGER_NOTIFICATION_COOLDOWN_HOURS")
fi
SECRETS_LIST=$(supabase secrets list --project-ref ${PROJECT_REF} --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo "")
TARGET_EDGE_SECRETS=0
for secret in "${EXPECTED_SECRETS[@]}"; do
    if echo "$SECRETS_LIST" | grep -q "^${secret}$"; then
        TARGET_EDGE_SECRETS=$((TARGET_EDGE_SECRETS + 1))
    fi
done

# Collect counts from source (reference) database
echo "Collecting object counts from source database (staging)..."
SOURCE_CONNECTION_STRING="host=${POOLER_HOST} port=5432 user=postgres.${SOURCE_PROJECT_REF} dbname=postgres sslmode=require"
SOURCE_TABLES=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_POLICIES=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_FUNCTIONS=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace;" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_TRIGGERS=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'public' AND tgisinternal = false;" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_INDEXES=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_VIEWS=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'public';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_TYPES=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype = 'c';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_STORAGE_POLICIES=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
SOURCE_AUTH_TRIGGERS=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'auth';" 2>&1 | grep -v "ERROR" | tr -d ' \n')

# Check critical trigger in source
SOURCE_AUTH_USER_TRIGGER=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');" 2>&1 | grep -v "ERROR" | tr -d ' \n' | head -1)
[ "$SOURCE_AUTH_USER_TRIGGER" = "t" ] && SOURCE_AUTH_USER_TRIGGER="Yes" || SOURCE_AUTH_USER_TRIGGER="No"

# Check edge functions in source (staging) project
SOURCE_FUNCTIONS_LIST=$(supabase functions list --project-ref ${SOURCE_PROJECT_REF} --output json 2>/dev/null | jq -r '.[].slug' 2>/dev/null || echo "")
SOURCE_EDGE_FUNCTIONS=0
for func in "${EXPECTED_FUNCTIONS[@]}"; do
    if echo "$SOURCE_FUNCTIONS_LIST" | grep -q "^${func}$"; then
        SOURCE_EDGE_FUNCTIONS=$((SOURCE_EDGE_FUNCTIONS + 1))
    fi
done

# Check storage buckets in source
SOURCE_STORAGE_BUCKETS=$(psql "${SOURCE_CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM storage.buckets WHERE id IN ('avatars','documents','certificates','logos','lesson-media');" 2>&1 | grep -v "ERROR" | tr -d ' \n')

# Check edge function secrets in source (staging) project
SOURCE_SECRETS_LIST=$(supabase secrets list --project-ref ${SOURCE_PROJECT_REF} --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo "")
SOURCE_EDGE_SECRETS=0
for secret in "${EXPECTED_SECRETS[@]}"; do
    if echo "$SOURCE_SECRETS_LIST" | grep -q "^${secret}$"; then
        SOURCE_EDGE_SECRETS=$((SOURCE_EDGE_SECRETS + 1))
    fi
done

# Default empty values to "?" if queries failed
[ -z "$TARGET_TABLES" ] && TARGET_TABLES="?"
[ -z "$SOURCE_TABLES" ] && SOURCE_TABLES="?"
[ -z "$TARGET_POLICIES" ] && TARGET_POLICIES="?"
[ -z "$SOURCE_POLICIES" ] && SOURCE_POLICIES="?"
[ -z "$TARGET_FUNCTIONS" ] && TARGET_FUNCTIONS="?"
[ -z "$SOURCE_FUNCTIONS" ] && SOURCE_FUNCTIONS="?"
[ -z "$TARGET_TRIGGERS" ] && TARGET_TRIGGERS="?"
[ -z "$SOURCE_TRIGGERS" ] && SOURCE_TRIGGERS="?"
[ -z "$TARGET_INDEXES" ] && TARGET_INDEXES="?"
[ -z "$SOURCE_INDEXES" ] && SOURCE_INDEXES="?"
[ -z "$TARGET_VIEWS" ] && TARGET_VIEWS="?"
[ -z "$SOURCE_VIEWS" ] && SOURCE_VIEWS="?"
[ -z "$TARGET_TYPES" ] && TARGET_TYPES="?"
[ -z "$SOURCE_TYPES" ] && SOURCE_TYPES="?"
[ -z "$TARGET_STORAGE_POLICIES" ] && TARGET_STORAGE_POLICIES="?"
[ -z "$SOURCE_STORAGE_POLICIES" ] && SOURCE_STORAGE_POLICIES="?"
[ -z "$TARGET_AUTH_TRIGGERS" ] && TARGET_AUTH_TRIGGERS="?"
[ -z "$SOURCE_AUTH_TRIGGERS" ] && SOURCE_AUTH_TRIGGERS="?"
[ -z "$TARGET_AUTH_USER_TRIGGER" ] && TARGET_AUTH_USER_TRIGGER="?"
[ -z "$SOURCE_AUTH_USER_TRIGGER" ] && SOURCE_AUTH_USER_TRIGGER="?"
[ -z "$TARGET_EDGE_FUNCTIONS" ] && TARGET_EDGE_FUNCTIONS="?"
[ -z "$SOURCE_EDGE_FUNCTIONS" ] && SOURCE_EDGE_FUNCTIONS="?"
[ -z "$TARGET_EDGE_SECRETS" ] && TARGET_EDGE_SECRETS="?"
[ -z "$SOURCE_EDGE_SECRETS" ] && SOURCE_EDGE_SECRETS="?"
[ -z "$TARGET_STORAGE_BUCKETS" ] && TARGET_STORAGE_BUCKETS="?"
[ -z "$SOURCE_STORAGE_BUCKETS" ] && SOURCE_STORAGE_BUCKETS="?"

# Display comparison table
echo ""
echo "┌─────────────────────────┬──────────────────┬──────────────┬─────────┐"
echo "│ Object Type             │ Source (Staging) │ Target (New) │ Status  │"
echo "├─────────────────────────┼──────────────────┼──────────────┼─────────┤"
printf "│ %-23s │ %16s │ %12s │" "Tables" "$SOURCE_TABLES" "$TARGET_TABLES"
if [ "$SOURCE_TABLES" = "$TARGET_TABLES" ] && [ "$SOURCE_TABLES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Policies" "$SOURCE_POLICIES" "$TARGET_POLICIES"
if [ "$SOURCE_POLICIES" = "$TARGET_POLICIES" ] && [ "$SOURCE_POLICIES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Functions" "$SOURCE_FUNCTIONS" "$TARGET_FUNCTIONS"
if [ "$SOURCE_FUNCTIONS" = "$TARGET_FUNCTIONS" ] && [ "$SOURCE_FUNCTIONS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Triggers" "$SOURCE_TRIGGERS" "$TARGET_TRIGGERS"
if [ "$SOURCE_TRIGGERS" = "$TARGET_TRIGGERS" ] && [ "$SOURCE_TRIGGERS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Indexes" "$SOURCE_INDEXES" "$TARGET_INDEXES"
if [ "$SOURCE_INDEXES" = "$TARGET_INDEXES" ] && [ "$SOURCE_INDEXES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Views" "$SOURCE_VIEWS" "$TARGET_VIEWS"
if [ "$SOURCE_VIEWS" = "$TARGET_VIEWS" ] && [ "$SOURCE_VIEWS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Types" "$SOURCE_TYPES" "$TARGET_TYPES"
if [ "$SOURCE_TYPES" = "$TARGET_TYPES" ] && [ "$SOURCE_TYPES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Storage Policies" "$SOURCE_STORAGE_POLICIES" "$TARGET_STORAGE_POLICIES"
# Staging can lag; extra policies on the new project are OK (numeric compare).
if [ "$SOURCE_STORAGE_POLICIES" != "?" ] && [ "$TARGET_STORAGE_POLICIES" != "?" ] && \
    [ "$TARGET_STORAGE_POLICIES" -ge "$SOURCE_STORAGE_POLICIES" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %16s │ %12s │" "Auth Triggers" "$SOURCE_AUTH_TRIGGERS" "$TARGET_AUTH_TRIGGERS"
if [ "$SOURCE_AUTH_TRIGGERS" = "$TARGET_AUTH_TRIGGERS" ] && [ "$SOURCE_AUTH_TRIGGERS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Critical: on_auth_user_created trigger
printf "│ %-23s │ %16s │ %12s │" "on_auth_user_created ⚠" "$SOURCE_AUTH_USER_TRIGGER" "$TARGET_AUTH_USER_TRIGGER"
if [ "$TARGET_AUTH_USER_TRIGGER" = "Yes" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Edge functions — pass when every slug from deploy-functions.sh exists on target (staging may be behind).
printf "│ %-23s │ %16s │ %12s │" "Edge Functions" "$SOURCE_EDGE_FUNCTIONS" "$TARGET_EDGE_FUNCTIONS"
EXPECTED_FUNCTION_COUNT=${#EXPECTED_FUNCTIONS[@]}
if [ "${EXPECTED_FUNCTION_COUNT}" -gt 0 ] && [ ${#TARGET_MISSING_FUNCTIONS[@]} -eq 0 ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Edge function secrets — pass when target has full expected set for this run (not vs staging count).
printf "│ %-23s │ %16s │ %12s │" "Edge Function Secrets" "$SOURCE_EDGE_SECRETS" "$TARGET_EDGE_SECRETS"
EXPECTED_SECRET_COUNT=${#EXPECTED_SECRETS[@]}
if [ "$TARGET_EDGE_SECRETS" != "?" ] && [ "$EXPECTED_SECRET_COUNT" -gt 0 ] && \
    [ "$TARGET_EDGE_SECRETS" -eq "$EXPECTED_SECRET_COUNT" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Storage buckets — show present/required; staging often missing optional buckets.
printf "│ %-23s │ %16s │ %12s │" "Storage Buckets" "${SOURCE_STORAGE_BUCKETS}/${EXPECTED_BUCKET_COUNT}" "${TARGET_STORAGE_BUCKETS}/${EXPECTED_BUCKET_COUNT}"
if [ "$TARGET_STORAGE_BUCKETS" != "?" ] && [ "$TARGET_STORAGE_BUCKETS" -eq "$EXPECTED_BUCKET_COUNT" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
echo "└─────────────────────────┴──────────────────┴──────────────┴─────────┘"
echo ""

# Show named missing edge functions
if [ ${#TARGET_MISSING_FUNCTIONS[@]} -gt 0 ]; then
    echo -e "${RED}⚠️  Missing Edge Functions (${#TARGET_MISSING_FUNCTIONS[@]}):${NC}"
    for f in "${TARGET_MISSING_FUNCTIONS[@]}"; do
        echo -e "   ${RED}✗${NC} $f"
    done
    echo ""
fi

# Show warning if critical trigger is missing
if [ "$TARGET_AUTH_USER_TRIGGER" != "Yes" ]; then
    echo -e "${RED}⚠️  CRITICAL: on_auth_user_created trigger is MISSING${NC}"
    echo -e "${RED}  This trigger is required for automatic profile creation when users sign up.${NC}"
    echo -e "${YELLOW}  The onboarding process should have created this trigger.${NC}"
    echo ""
fi

# ---------------------------------------------------------------------------
# Register client in projects.conf and provision API keys — done here so
# these only run after the DB is fully migrated and edge functions are live.
# ---------------------------------------------------------------------------

# Only update for production clients (dev/staging/master already have fixed entries)
if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "master" ]]; then
    _update_projects_conf "${PROJECT_REF}" "${CLIENT_NAME}" "${PROJECTS_CONF}"
fi

# Provision LEARN_API_KEY, GOVERN_API_KEY, and IMPORT_INTERNAL_TOKEN for the integration
echo -e "${GREEN}Provisioning LEARN_API_KEY, GOVERN_API_KEY, and IMPORT_INTERNAL_TOKEN for the integration...${NC}"
"${SCRIPT_DIR}/provision-api-keys.sh" "${PROJECT_REF}" "${CLIENT_NAME}"

fi  # end of [ "${SUMMARY_ONLY}" != true ] setup block

echo -e "${GREEN}✓ Client onboarding complete!${NC}"
echo ""

# Get anon key from Supabase
ANON_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'anon' | awk '{print $3}' 2>/dev/null || echo "")
if [ -z "$ANON_KEY" ]; then
    echo -e "${YELLOW}Warning: Could not retrieve anon key — using placeholder. Get it from Supabase Dashboard → Settings → API.${NC}"
    ANON_KEY="<get-from-supabase-dashboard>"
fi

VAULT_SECRET_NAME="client_${CLIENT_NAME}_anon_key"

# Build client config JSON
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    DISPLAY_NAME="${ENVIRONMENT}"
    CLIENT_CONFIG_JSON="{\"default\":{\"clientId\":\"default\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"${DISPLAY_NAME}\"}}"
else
    DISPLAY_NAME="${CLIENT_NAME}"
    CLIENT_CONFIG_JSON="{\"${CLIENT_NAME}\":{\"clientId\":\"${CLIENT_NAME}\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"${DISPLAY_NAME}\"}}"
fi

DIV="${CYAN}════════════════════════════════════════════════════════════════${NC}"

echo -e "$DIV"
echo -e "${CYAN}  PROJECT DETAILS${NC}"
echo -e "$DIV"
echo "  Ref:     ${PROJECT_REF}"
echo "  Client:  ${CLIENT_NAME}"
echo "  Env:     ${ENVIRONMENT}"
echo "  URL:     https://${CLIENT_DOMAIN}"
echo "  Supabase: https://supabase.com/dashboard/project/${PROJECT_REF}"
echo ""

echo -e "$DIV"
echo -e "${CYAN}  PHASE 1 — SUPABASE DASHBOARD${NC}"
echo -e "$DIV"
echo ""
echo -e "  ${BOLD}1a. Auth → URL Configuration${NC}"
echo -e "      ${GREEN}https://supabase.com/dashboard/project/${PROJECT_REF}/auth/url-configuration${NC}"
echo "      Site URL:  https://${CLIENT_DOMAIN}"
echo "      Redirect URLs (add each):"
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "        https://${CLIENT_DOMAIN}/reset-password"
    echo "        https://${CLIENT_DOMAIN}/activate-account"
    echo "        https://${CLIENT_DOMAIN}/auth/callback"
else
    echo "        https://${BASE_DOMAIN}/${CLIENT_NAME}/reset-password"
    echo "        https://${BASE_DOMAIN}/${CLIENT_NAME}/activate-account"
    echo "        https://${BASE_DOMAIN}/${CLIENT_NAME}/auth/callback"
fi
echo ""
echo -e "  ${BOLD}1b. Auth → Sessions${NC} (skip if already set via Management API)"
echo -e "      ${GREEN}https://supabase.com/dashboard/project/${PROJECT_REF}/auth/sessions${NC}"
echo "      Time-box: 0 (disabled)   Inactivity timeout: 30 min"
echo ""
echo -e "  ${BOLD}1c. Auth → JWT expiry${NC} (skip if already set via Management API)"
echo -e "      ${GREEN}https://supabase.com/dashboard/project/${PROJECT_REF}/settings/jwt/legacy${NC}"
echo "      JWT expiry: 1800s (30 min)"
echo ""
echo -e "  ${BOLD}1d. Data API → Max Rows${NC} (skip if already set via Management API)"
echo -e "      ${GREEN}https://supabase.com/dashboard/project/${PROJECT_REF}/settings/api${NC}"
echo "      Project Settings → Data API → Settings → Max Rows: 10000"
echo ""
echo -e "$DIV"
echo -e "${CYAN}  PHASE 2 — SUPABASE EDGE FUNCTION SECRETS (CLI)${NC}"
echo -e "$DIV"
echo -e "  ${BOLD}2a. Verify license write-back secrets:${NC}"
echo "      supabase secrets list --project-ref ${PROJECT_REF} | grep MASTER"
echo -e "      ${YELLOW}If MASTER_SUPABASE_URL / MASTER_SUPABASE_SERVICE_ROLE_KEY are missing:${NC}"
echo "        supabase secrets set MASTER_SUPABASE_URL=https://oownotmpcqcgojhrzqaj.supabase.co \\"
echo "          MASTER_SUPABASE_SERVICE_ROLE_KEY=<key> --project-ref ${PROJECT_REF}"
echo ""
echo -e "  ${BOLD}2b. LEARN_API_KEY, GOVERN_API_KEY, and IMPORT_INTERNAL_TOKEN${NC}"
echo "      These were provisioned above. If the handover block was printed, save those"
echo "      values now — the CLI cannot retrieve existing secret values later."
echo "      To re-print / rotate:"
echo "        ${SCRIPT_DIR}/provision-api-keys.sh ${PROJECT_REF} ${CLIENT_NAME} --rotate"
echo ""

echo -e "$DIV"
echo -e "${CYAN}  PHASE 3 — VERCEL${NC}"
echo -e "$DIV"
echo ""
echo -e "  ${BOLD}3a. Update VITE_CLIENT_CONFIGS${NC} in the Vercel project:"
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "      Use 'default' key so root path (/) works without /${CLIENT_NAME} prefix."
    echo ""
    echo "      ${CLIENT_CONFIG_JSON}"
else
    echo "      Production clients are now vault-backed — the learn app fetches config from"
    echo "      the master edge function at boot, so VITE_CLIENT_CONFIGS is optional."
    echo "      If the vault step above succeeded, you can skip updating VITE_CLIENT_CONFIGS."
    echo "      If it failed, add this entry as a fallback:"
    echo ""
    echo "      ${CLIENT_CONFIG_JSON}"
fi
echo ""
echo -e "  ${BOLD}3b. Redeploy Vercel project${NC} (or it will pick up on next push)."
echo ""
echo -e "  ${BOLD}3c. Test:${NC} https://${CLIENT_DOMAIN}"
if [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "staging" ]; then
    echo "       Root path (/) should show an error — this is expected and correct."
fi
echo ""

# Special instructions for master environment
if [ "$CLIENT_NAME" = "master" ]; then
echo -e "$DIV"
echo -e "${CYAN}  MASTER: NEW VERCEL PROJECT REQUIRED${NC}"
echo -e "$DIV"
echo ""
echo "  Master needs its own Vercel project (separate from dev/staging/prod)."
echo ""
echo "  1. Vercel Dashboard → Add New → Project → repo: staysecure-learn"
echo "  2. Project name: master-staysecure-learn"
echo "  3. Settings → Environments → Production → Branch Tracking → '${ENVIRONMENT}'"
echo "  4. Add env vars:"
echo "       VITE_SUPABASE_URL     = https://${PROJECT_REF}.supabase.co"
echo "       VITE_SUPABASE_ANON_KEY = ${ANON_KEY}"
echo "       VITE_CLIENT_CONFIGS   = {\"default\":{\"clientId\":\"default\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"Master\"}}"
echo "  5. Deploy → Settings → Domains → add: master.staysecure-learn.raynsecure.com"
echo "  6. Verify: https://master.staysecure-learn.raynsecure.com"
echo ""
fi

echo -e "$DIV"
echo -e "${CYAN}  PHASE 4 — INITIALIZE${NC}"
echo -e "$DIV"
echo ""
echo -e "  ${BOLD}4a. Create admin user:${NC}"
echo "        ${SCRIPT_DIR}/create-admin-user.sh ${PROJECT_REF} <email> <password> [full-name] [first] [last]"
echo ""
echo -e "  ${BOLD}4b. Test user creation + email delivery${NC} (invite a test user, verify email arrives)."
echo ""
echo -e "  ${BOLD}4c. Sync lesson content from master:${NC}"
echo "        Open Learn → MASTER database → Admin → Lesson Sync"
echo "        → select all tracks → select client '${CLIENT_NAME}' → Sync"
echo "        NOTE: seed data only contains reference data (languages, templates, etc.)."
echo "              Lesson content must come from master via this sync step."
echo ""

echo -e "$DIV"
echo -e "${CYAN}  PHASE 5 — LICENSE APP (license.raynsecure.com)${NC}"
echo -e "$DIV"
echo ""
echo -e "  ${BOLD}5a. Set client service key on master${NC} (required for sync to work):"
echo "        LENTOR_KEY=\$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep service_role | awk '{print \$3}')"
echo "        supabase secrets set CLIENT_SERVICE_KEY_${CLIENT_NAME_UPPER}=\"\${LENTOR_KEY}\" --project-ref ${MASTER_REF}"
echo ""
echo -e "  ${BOLD}5b. Create customer record:${NC}"
echo "        Open https://license.raynsecure.com → Customers"
echo "        → click 'people icon' → Add Customer → fill in client info"
echo "        → Supabase Project Ref: ${PROJECT_REF}"
echo "        → Anon Key:             ${ANON_KEY}"
echo "          (stored in Vault as '${VAULT_SECRET_NAME}' automatically on save)"
echo "        → sync to client DB happens automatically"
echo ""
echo -e "  ${BOLD}5c. Add license:${NC}"
echo "        On the customer → click 'key icon' → Add License"
echo "        → select product, seats, term, start date"
echo "        → sync to client DB happens automatically"
echo ""
echo -e "  ${YELLOW}Note: steps 5b/5c will 500 until 5a is done — the sync function needs${NC}"
echo -e "  ${YELLOW}      CLIENT_SERVICE_KEY_${CLIENT_NAME_UPPER} on master to connect to the client DB.${NC}"
echo ""
