#!/bin/bash

# Client Onboarding Script
# Automates the creation of a new Supabase project with all required configuration

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directory anchors — all supabase CLI commands must run from LEARN_DIR;
# relative paths for backups/ and scripts/ stay anchored to DEPLOY_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEARN_DIR="$(cd "${SCRIPT_DIR}/../../learn" && pwd)"

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
    echo "Usage: ./onboard-client.sh [prod|staging|dev] <client-name> [data-type] [region]"
    echo "Example: ./onboard-client.sh prod rayn seed"
    echo "Example: ./onboard-client.sh prod master seed"
    echo "Example: ./onboard-client.sh staging staging seed"
    echo "Example: ./onboard-client.sh dev dev demo"
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
    echo "Usage: ./onboard-client.sh [prod|staging|dev] <client-name> [data-type] [region]"
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

# Load environment variables from .env or .env.local
if [ -f ".env.local" ]; then
    echo "Loading environment variables from .env.local"
    source .env.local
elif [ -f ".env" ]; then
    echo "Loading environment variables from .env"
    source .env
else
    echo -e "${YELLOW}Warning: No .env or .env.local file found. Make sure environment variables are set.${NC}"
fi

# Use PGPASSWORD for both Supabase CLI and psql
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    echo "Please set PGPASSWORD in your environment or .zshrc"
    exit 1
fi

# If PROJECT_REF is already set (env var), skip project creation and restore to existing project
if [ -n "$PROJECT_REF" ]; then
    echo -e "${YELLOW}PROJECT_REF=${PROJECT_REF} — skipping project creation, restoring to existing project${NC}"
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
echo -e "${GREEN}Linking to project...${NC}"
pushd "${LEARN_DIR}" > /dev/null
supabase link --project-ref ${PROJECT_REF} 2>/dev/null || {
    echo -e "${YELLOW}Warning: Could not link project (Docker may not be running, but continuing anyway)${NC}"
}
popd > /dev/null

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
if [ -f "backups/schema.dump" ]; then
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
        backups/schema.dump 2>&1 | tee /tmp/restore-schema.log || {
            echo -e "${RED}Failed to restore schema${NC}"
            exit 1
        }
    
    # Restore storage schema if it exists
    if [ -f "backups/storage.dump" ]; then
        echo -e "${GREEN}Restoring storage schema...${NC}"
        pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
            --dbname=postgres \
            --verbose \
            --no-owner \
            --clean \
            --if-exists \
            backups/storage.dump 2>&1 | tee /tmp/restore-storage.log || {
                echo -e "${YELLOW}Warning: Storage schema restore had issues (may be expected)${NC}"
            }
    fi
    
    # Create required storage buckets via create-storage.sh (single source of truth for bucket config)
    echo -e "${GREEN}Ensuring storage buckets exist...${NC}"
    POOLER_HOST="${POOLER_HOST}" REGION="${REGION}" "${SCRIPT_DIR}/create-storage.sh" "${PROJECT_REF}" || {
        echo -e "${YELLOW}Warning: Failed to create storage buckets (may already exist)${NC}"
    }

    # Restore data based on type (using custom format if available, otherwise SQL)
    if [ "$DATA_TYPE" = "demo" ] && [ -f "backups/demo.dump" ]; then
        echo -e "${GREEN}Restoring demo data...${NC}"
        
        # Restore auth.users first (needed for foreign key constraints with profiles and user_roles)
        if [ -f "backups/auth.dump" ]; then
            echo -e "${GREEN}Restoring auth.users...${NC}"
            pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
                --dbname=postgres \
                --verbose \
                --no-owner \
                --data-only \
                backups/auth.dump 2>&1 | tee /tmp/restore-auth.log || {
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
            backups/demo.dump 2>&1 | tee /tmp/restore-data.log || {
                echo -e "${YELLOW}Warning: Some data restore errors occurred (may be expected)${NC}"
            }
        
        echo -e "${GREEN}✓ Demo data restored successfully${NC}"
    elif [ "$DATA_TYPE" = "seed" ] && [ -f "backups/seed.dump" ]; then
        echo -e "${GREEN}Restoring seed data (reference data only) from custom format...${NC}"
        pg_restore --host=${PG_HOST} --port=${PG_PORT} --username=${PG_USER} \
            --dbname=postgres \
            --verbose \
            --no-owner \
            --data-only \
            backups/seed.dump 2>&1 | tee /tmp/restore-data.log || {
                echo -e "${RED}Failed to restore seed data${NC}"
                exit 1
            }
    elif [ "$DATA_TYPE" = "demo" ] && [ -f "backups/demo.sql" ]; then
        echo -e "${GREEN}Restoring demo data (including users) from SQL format...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file backups/demo.sql || {
                echo -e "${RED}Failed to restore demo data${NC}"
                exit 1
            }
    elif [ "$DATA_TYPE" = "seed" ] && [ -f "backups/seed.sql" ]; then
        echo -e "${GREEN}Restoring seed data (reference data only) from SQL format...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file backups/seed.sql || {
                echo -e "${RED}Failed to restore seed data${NC}"
                exit 1
            }
    else
        echo -e "${YELLOW}Warning: No data backup found (demo.dump/seed.dump or demo.sql/seed.sql), skipping data restoration${NC}"
    fi

    # Apply post-migration fixes (fixes that aren't in the schema dump, including RLS policies, permissions, and triggers)
    # This includes the on_auth_user_created trigger
    if [ -f "scripts/post-migration-fixes.sql" ]; then
        echo -e "${GREEN}Applying post-migration fixes...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file scripts/post-migration-fixes.sql || {
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
    
    echo -e "${GREEN}✓ Backup restored successfully${NC}"
elif [ -f "backups/schema.sql" ]; then
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
        --file backups/schema.sql || {
            echo -e "${RED}Failed to restore schema${NC}"
            exit 1
        }
    
    # Restore data based on type
    if [ "$DATA_TYPE" = "demo" ] && [ -f "backups/demo.sql" ]; then
        echo -e "${GREEN}Restoring demo data (including users)...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file backups/demo.sql || {
                echo -e "${RED}Failed to restore demo data${NC}"
                exit 1
            }
    elif [ "$DATA_TYPE" = "seed" ] && [ -f "backups/seed.sql" ]; then
        echo -e "${GREEN}Restoring seed data (reference data only)...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --command 'SET session_replication_role = replica' \
            --file backups/seed.sql || {
                echo -e "${RED}Failed to restore seed data${NC}"
                exit 1
            }
    else
        echo -e "${YELLOW}Warning: demo.sql not found, skipping data restoration${NC}"
    fi
    
    # Apply post-migration fixes (fixes that aren't in the schema dump, including RLS policies, permissions, and triggers)
    # This includes the on_auth_user_created trigger
    if [ -f "scripts/post-migration-fixes.sql" ]; then
        echo -e "${GREEN}Applying post-migration fixes...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file scripts/post-migration-fixes.sql || {
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
    if [ -f "scripts/post-migration-fixes.sql" ]; then
        echo -e "${GREEN}Applying post-migration fixes...${NC}"
        psql "${CONNECTION_STRING}" \
            --single-transaction \
            --variable ON_ERROR_STOP=1 \
            --file scripts/post-migration-fixes.sql || {
                echo -e "${YELLOW}Warning: Failed to apply post-migration fixes${NC}"
            }
    else
        echo -e "${YELLOW}Warning: post-migration-fixes.sql not found, skipping${NC}"
    fi
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
    "ANTHROPIC_API_KEY"
    "CERT_RENDERER_URL"
    "CERT_RENDER_SECRET"
)


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
    --project-ref ${PROJECT_REF}

# Set certificate renderer secrets (if provided)
if [ -n "$CERT_RENDERER_URL" ] && [ -n "$CERT_RENDER_SECRET" ]; then
    supabase secrets set \
        CERT_RENDERER_URL=${CERT_RENDERER_URL} \
        CERT_RENDER_SECRET=${CERT_RENDER_SECRET} \
        --project-ref ${PROJECT_REF}
    echo -e "${GREEN}✓ Certificate renderer secrets set${NC}"
fi

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

# Get the service role key for this project (if not provided, fetch it)
if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    echo -e "${YELLOW}Service role key not provided, fetching from project...${NC}"
    SUPABASE_SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'service_role' | awk '{print $3}')
    if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
        echo -e "${RED}Error: Could not retrieve service role key for project ${PROJECT_REF}${NC}"
        exit 1
    fi
fi

FUNCTION_URL="https://${PROJECT_REF}.supabase.co/functions/v1/process-scheduled-notifications"
# Escape single quotes in the auth header for SQL
AUTH_HEADER_ESCAPED=$(echo "Bearer ${SUPABASE_SERVICE_ROLE_KEY}" | sed "s/'/''/g")
FUNCTION_URL_ESCAPED=$(echo "${FUNCTION_URL}" | sed "s/'/''/g")

psql "${CONNECTION_STRING}" <<SQL
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
DO \$\$
BEGIN
  PERFORM cron.unschedule('process-manager-notifications');
EXCEPTION
  WHEN others THEN NULL;
END
\$\$;
SELECT cron.schedule(
  'process-manager-notifications',
  '0 1 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body := jsonb_build_object(
          'notification_type', 'manager_employee_incomplete'
        )
      );
    \$cron\$,
    '${FUNCTION_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
) AS cron_job_id;
SQL

if [ $? -ne 0 ]; then
    echo -e "${RED}Error configuring pg_cron job${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Manager notification cron job scheduled (UTC 01:00 daily)${NC}"

# Schedule lesson reminders cron job
echo -e "${GREEN}Configuring lesson reminders cron job...${NC}"

LESSON_REMINDERS_FUNCTION_URL="https://${PROJECT_REF}.supabase.co/functions/v1/send-lesson-reminders"
LESSON_REMINDERS_FUNCTION_URL_ESCAPED=$(echo "${LESSON_REMINDERS_FUNCTION_URL}" | sed "s/'/''/g")

psql "${CONNECTION_STRING}" <<SQL
DO \$\$
BEGIN
  PERFORM cron.unschedule('send-daily-lesson-reminders');
EXCEPTION
  WHEN others THEN NULL;
END
\$\$;
SELECT cron.schedule(
  'send-daily-lesson-reminders',
  '0 9 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body := '{}'::jsonb
      );
    \$cron\$,
    '${LESSON_REMINDERS_FUNCTION_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
) AS cron_job_id;
SQL

if [ $? -ne 0 ]; then
    echo -e "${RED}Error configuring lesson reminders pg_cron job${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Lesson reminders cron job scheduled (UTC 09:00 daily)${NC}"

# Configure auth session timeouts via Management API (optional; requires SUPABASE_ACCESS_TOKEN)
# Time-box: max session lifetime in minutes (0 = never). Inactivity: sign out after N minutes idle (0 = never).
SESSIONS_TIMEBOX_MINUTES=${SESSIONS_TIMEBOX_MINUTES:-1440}
SESSIONS_INACTIVITY_TIMEOUT_MINUTES=${SESSIONS_INACTIVITY_TIMEOUT_MINUTES:-0}
if [ -n "$SUPABASE_ACCESS_TOKEN" ]; then
    echo -e "${GREEN}Configuring auth session timeouts (Management API)...${NC}"
    AUTH_CONFIG_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.supabase.com/v1/projects/${PROJECT_REF}/config/auth" \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"sessions_timebox\": ${SESSIONS_TIMEBOX_MINUTES}, \"sessions_inactivity_timeout\": ${SESSIONS_INACTIVITY_TIMEOUT_MINUTES}}")
    AUTH_CONFIG_HTTP_CODE=$(echo "$AUTH_CONFIG_RESPONSE" | tail -n1)
    if [ "$AUTH_CONFIG_HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ Auth session timeouts set (time-box: ${SESSIONS_TIMEBOX_MINUTES} min, inactivity: ${SESSIONS_INACTIVITY_TIMEOUT_MINUTES} min)${NC}"
    else
        echo -e "${YELLOW}Warning: Could not set auth session timeouts (HTTP ${AUTH_CONFIG_HTTP_CODE})${NC}"
        echo -e "${YELLOW}  Set them manually: Dashboard → Authentication → User Sessions${NC}"
    fi
else
    echo -e "${YELLOW}Note: Set SUPABASE_ACCESS_TOKEN (Personal Access Token) to configure auth session timeouts automatically.${NC}"
    echo -e "${YELLOW}  Or set in Dashboard → Authentication → User Sessions (time-box: ${SESSIONS_TIMEBOX_MINUTES} min, inactivity: ${SESSIONS_INACTIVITY_TIMEOUT_MINUTES} min)${NC}"
fi

# Set client service key in master database for sync-lesson-content Edge Function
# This allows the master database to sync content to this client database
if [ -n "$MASTER_PROJECT_REF" ]; then
    echo -e "${GREEN}Setting client service key in master database for sync...${NC}"
    CLIENT_SERVICE_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'service_role' | awk '{print $3}')
    
    if [ -n "$CLIENT_SERVICE_KEY" ]; then
        SECRET_NAME="CLIENT_SERVICE_KEY_${PROJECT_REF}"
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
        echo -e "${YELLOW}  Then set manually: supabase secrets set CLIENT_SERVICE_KEY_${PROJECT_REF}=<key> --project-ref ${MASTER_PROJECT_REF}${NC}"
    fi
else
    echo -e "${YELLOW}Note: MASTER_PROJECT_REF not set, skipping sync secret setup${NC}"
    echo -e "${YELLOW}  To enable content syncing, set MASTER_PROJECT_REF environment variable${NC}"
    echo -e "${YELLOW}  Then manually set: supabase secrets set CLIENT_SERVICE_KEY_${PROJECT_REF}=<service_key> --project-ref <master_ref>${NC}"
fi

# Verify restore by comparing object counts with source database
echo ""
echo -e "${GREEN}Verifying restore completeness...${NC}"

# Get source project reference (dev/reference project) — use env var, fall back to known dev ref
SOURCE_PROJECT_REF="${DEV_PROJECT_REF:-cleqfnrbiqpxpzxkatda}"
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

# Check edge functions
EXPECTED_FUNCTIONS=("create-user" "delete-user" "send-email" "send-lesson-reminders" "send-password-reset" "update-password" "update-user-password" "change-password" "request-activation-link" "translate-lesson" "translate-track" "translation-status" "get-document-url" "get-user-last-logins" "process-scheduled-notifications" "generate-certificate" "get-certificate-url" "generate-lesson" "sync-lesson-content" "org-api" "org-webhook-publisher")
FUNCTIONS_LIST=$(supabase functions list --project-ref ${PROJECT_REF} --output json 2>/dev/null | jq -r '.[].slug' 2>/dev/null || echo "")
TARGET_EDGE_FUNCTIONS=0
for func in "${EXPECTED_FUNCTIONS[@]}"; do
    if echo "$FUNCTIONS_LIST" | grep -q "^${func}$"; then
        TARGET_EDGE_FUNCTIONS=$((TARGET_EDGE_FUNCTIONS + 1))
    fi
done

# Check edge function secrets
EXPECTED_SECRETS=("GOOGLE_TRANSLATE_API_KEY" "DEEPL_API_KEY" "AUTH_LAMBDA_URL" "APP_BASE_URL" "MANAGER_NOTIFICATION_COOLDOWN_HOURS")
SECRETS_LIST=$(supabase secrets list --project-ref ${PROJECT_REF} --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo "")
TARGET_EDGE_SECRETS=0
for secret in "${EXPECTED_SECRETS[@]}"; do
    if echo "$SECRETS_LIST" | grep -q "^${secret}$"; then
        TARGET_EDGE_SECRETS=$((TARGET_EDGE_SECRETS + 1))
    fi
done

# Collect counts from source (reference) database
echo "Collecting object counts from source database (dev)..."
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

# Check edge functions in source (dev) project
SOURCE_FUNCTIONS_LIST=$(supabase functions list --project-ref ${SOURCE_PROJECT_REF} --output json 2>/dev/null | jq -r '.[].slug' 2>/dev/null || echo "")
SOURCE_EDGE_FUNCTIONS=0
for func in "${EXPECTED_FUNCTIONS[@]}"; do
    if echo "$SOURCE_FUNCTIONS_LIST" | grep -q "^${func}$"; then
        SOURCE_EDGE_FUNCTIONS=$((SOURCE_EDGE_FUNCTIONS + 1))
    fi
done

# Check edge function secrets in source (dev) project
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

# Display comparison table
echo ""
echo "┌─────────────────────────┬──────────────┬──────────────┬─────────┐"
echo "│ Object Type             │ Source (Dev) │ Target (New) │ Status  │"
echo "├─────────────────────────┼──────────────┼──────────────┼─────────┤"
printf "│ %-23s │ %12s │ %12s │" "Tables" "$SOURCE_TABLES" "$TARGET_TABLES"
if [ "$SOURCE_TABLES" = "$TARGET_TABLES" ] && [ "$SOURCE_TABLES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Policies" "$SOURCE_POLICIES" "$TARGET_POLICIES"
if [ "$SOURCE_POLICIES" = "$TARGET_POLICIES" ] && [ "$SOURCE_POLICIES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Functions" "$SOURCE_FUNCTIONS" "$TARGET_FUNCTIONS"
if [ "$SOURCE_FUNCTIONS" = "$TARGET_FUNCTIONS" ] && [ "$SOURCE_FUNCTIONS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Triggers" "$SOURCE_TRIGGERS" "$TARGET_TRIGGERS"
if [ "$SOURCE_TRIGGERS" = "$TARGET_TRIGGERS" ] && [ "$SOURCE_TRIGGERS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Indexes" "$SOURCE_INDEXES" "$TARGET_INDEXES"
if [ "$SOURCE_INDEXES" = "$TARGET_INDEXES" ] && [ "$SOURCE_INDEXES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Views" "$SOURCE_VIEWS" "$TARGET_VIEWS"
if [ "$SOURCE_VIEWS" = "$TARGET_VIEWS" ] && [ "$SOURCE_VIEWS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Types" "$SOURCE_TYPES" "$TARGET_TYPES"
if [ "$SOURCE_TYPES" = "$TARGET_TYPES" ] && [ "$SOURCE_TYPES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Storage Policies" "$SOURCE_STORAGE_POLICIES" "$TARGET_STORAGE_POLICIES"
if [ "$SOURCE_STORAGE_POLICIES" = "$TARGET_STORAGE_POLICIES" ] && [ "$SOURCE_STORAGE_POLICIES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
printf "│ %-23s │ %12s │ %12s │" "Auth Triggers" "$SOURCE_AUTH_TRIGGERS" "$TARGET_AUTH_TRIGGERS"
if [ "$SOURCE_AUTH_TRIGGERS" = "$TARGET_AUTH_TRIGGERS" ] && [ "$SOURCE_AUTH_TRIGGERS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Critical: on_auth_user_created trigger
printf "│ %-23s │ %12s │ %12s │" "on_auth_user_created ⚠" "$SOURCE_AUTH_USER_TRIGGER" "$TARGET_AUTH_USER_TRIGGER"
if [ "$TARGET_AUTH_USER_TRIGGER" = "Yes" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Edge functions
printf "│ %-23s │ %12s │ %12s │" "Edge Functions" "$SOURCE_EDGE_FUNCTIONS" "$TARGET_EDGE_FUNCTIONS"
if [ "$TARGET_EDGE_FUNCTIONS" = "$SOURCE_EDGE_FUNCTIONS" ] && [ "$TARGET_EDGE_FUNCTIONS" != "?" ] && [ "$TARGET_EDGE_FUNCTIONS" != "0" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
# Edge function secrets
printf "│ %-23s │ %12s │ %12s │" "Edge Function Secrets" "$SOURCE_EDGE_SECRETS" "$TARGET_EDGE_SECRETS"
if [ "$TARGET_EDGE_SECRETS" = "$SOURCE_EDGE_SECRETS" ] && [ "$TARGET_EDGE_SECRETS" != "?" ] && [ "$TARGET_EDGE_SECRETS" != "0" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
fi
echo "└─────────────────────────┴──────────────┴──────────────┴─────────┘"
echo ""

# Show warning if critical trigger is missing
if [ "$TARGET_AUTH_USER_TRIGGER" != "Yes" ]; then
    echo -e "${RED}⚠️  CRITICAL: on_auth_user_created trigger is MISSING${NC}"
    echo -e "${RED}  This trigger is required for automatic profile creation when users sign up.${NC}"
    echo -e "${YELLOW}  The onboarding process should have created this trigger.${NC}"
    echo ""
fi

echo -e "${GREEN}✓ Client onboarding complete!${NC}"
echo ""
echo "Project Details:"
echo "  Project Ref: ${PROJECT_REF}"
echo "  Client Name: ${CLIENT_NAME}"
echo "  Client Domain: ${CLIENT_DOMAIN}"
echo "  Environment: ${ENVIRONMENT}"
echo "  Data Type: ${DATA_TYPE}"
echo "  Region: ${REGION}"
echo "  Supabase URL: https://${PROJECT_REF}.supabase.co"
echo "  Site URL: https://${CLIENT_DOMAIN}"
echo ""

# Get anon key from Supabase
echo -e "${GREEN}Getting API keys...${NC}"
ANON_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'anon' | awk '{print $3}')

if [ -z "$ANON_KEY" ]; then
    echo -e "${YELLOW}Warning: Could not retrieve anon key automatically${NC}"
    echo "Please get the anon key from Supabase Dashboard → Settings → API"
    ANON_KEY="<get-from-supabase-dashboard>"
fi
# Configure Supabase Auth Settings (URL config not supported by CLI; session timeouts set above if SUPABASE_ACCESS_TOKEN was provided)
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}⚠️  MANUAL CONFIGURATION REQUIRED: Auth URL Settings${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Configure the following in Supabase Dashboard → Authentication → URL Configuration:${NC}"
echo -e "${GREEN}  Dashboard URL: https://supabase.com/dashboard/project/${PROJECT_REF}/auth/url-configuration${NC}"
echo ""
echo -e "${YELLOW}Site URL:${NC}"
echo -e "  https://${CLIENT_DOMAIN}"
echo ""
echo -e "${YELLOW}Redirect URLs (add each on a new line):${NC}"
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo -e "  https://${CLIENT_DOMAIN}/reset-password"
    echo -e "  https://${CLIENT_DOMAIN}/activate-account"
    echo -e "${YELLOW}Note: For single-client environments, URLs don't need /${CLIENT_NAME} prefix${NC}"
else
    echo -e "  https://${BASE_DOMAIN}/${CLIENT_NAME}/reset-password"
    echo -e "  https://${BASE_DOMAIN}/${CLIENT_NAME}/activate-account"
    echo -e "${YELLOW}Note: For production, URLs require /${CLIENT_NAME} prefix${NC}"
fi
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo ""
echo "=== CLIENT CONFIGURATION FOR VERCEL ==="
echo ""

# Determine if this is a single-client environment (dev/staging) or multi-client (production)
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    # Single-client environment: Use "default" so root path (/) works without /dev or /staging
    echo "⚠️  SINGLE-CLIENT ENVIRONMENT (${ENVIRONMENT})"
    echo "   For dev/staging, use 'default' client so root path (/) works without /${CLIENT_NAME}"
    echo ""
    echo "=== SINGLE-CLIENT CONFIG (Use 'default' for Root Path Access) ==="
    echo "This allows access at https://${CLIENT_DOMAIN} without /${CLIENT_NAME} in the URL:"
    # For staging/dev, use ENVIRONMENT as displayName (more meaningful than CLIENT_NAME which defaults to ENVIRONMENT anyway)
    DISPLAY_NAME="${ENVIRONMENT}"
    echo "{\"default\": {\"clientId\":\"default\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"${DISPLAY_NAME}\"}}"
    echo ""
    echo "✓ Root path (/) will work: https://${CLIENT_DOMAIN}"
    echo "✓ No need for /${CLIENT_NAME} in the URL"
else
    # Multi-client production: Do NOT use "default" to prevent root path access
    echo "⚠️  MULTI-CLIENT PRODUCTION ENVIRONMENT"
    echo "   Do NOT use 'default' client - require explicit client path (e.g., /rayn)"
    echo ""
    echo "=== CONFIG FOR THIS CLIENT (${CLIENT_NAME}) ==="
    echo "Use this JSON configuration for the ${CLIENT_NAME} client:"
    echo "{\"${CLIENT_NAME}\": {\"clientId\":\"${CLIENT_NAME}\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"${CLIENT_NAME}\"}}"
    echo ""
    echo "✓ Access URL: https://${CLIENT_DOMAIN}"
    echo "✓ Root path (/) will show error - prevents accidental access"
    echo ""
    echo "=== EXAMPLE: MERGING MULTIPLE CLIENTS ==="
    echo "If you already have other production clients (e.g., 'rayn'), merge this client with them:"
    echo "{\"rayn\":{\"clientId\":\"rayn\",\"supabaseUrl\":\"https://<rayn-project>.supabase.co\",\"supabaseAnonKey\":\"<rayn-anon-key>\",\"displayName\":\"rayn\"},\"${CLIENT_NAME}\":{\"clientId\":\"${CLIENT_NAME}\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"${CLIENT_NAME}\"}}"
    echo ""
    echo "⚠️  CRITICAL: Never use 'default' client in production config"
    echo "    This would allow root path (/) to access production databases"
fi
echo ""
echo "To add this client to an existing configuration, merge the JSON above."
echo ""

# Special instructions for master environment (requires new Vercel project)
if [ "$CLIENT_NAME" = "master" ]; then
    echo "=== VERCEL PROJECT SETUP FOR MASTER ==="
    echo ""
    echo "⚠️  Master requires a NEW Vercel project (separate from dev/staging/prod)"
    echo ""
    echo "Steps to create Vercel project for master:"
    echo ""
    echo "1. Go to Vercel Dashboard: https://vercel.com/dashboard"
    echo ""
    echo "2. Click 'Add New...' → 'Project'"
    echo ""
    echo "3. IMPORTANT: Select the correct repository"
    echo "   • Repository Name: staysecure-learn"
    echo "   • Repository Owner: kahuna-rayn (or your organization)"
    echo "   • Verify: This should be the SAME repository used for dev/staging projects"
    echo "   • If you don't see it, click 'Adjust GitHub App Permissions' and ensure"
    echo "     the repository is accessible"
    echo ""
    echo "4. Configure project settings:"
    echo "   • Project Name: master-staysecure-learn"
    echo "     ⚠️  CRITICAL: Use exactly 'master-staysecure-learn' (no spaces, lowercase)"
    echo "     This ensures consistency with dev/staging naming conventions"
    echo ""
    echo "   • Framework Preset: Vite (should auto-detect)"
    echo "   • Root Directory: ./ (leave as default)"
    echo "   • Build Command: npm run build (should auto-detect)"
    echo "   • Output Directory: dist (should auto-detect)"
    echo "   • Install Command: npm install (should auto-detect)"
    echo ""
    echo "   ⚠️  IMPORTANT: Configure Production Branch"
    echo "   • After creating the project, go to Project Settings → Environments"
    echo "   • Click on 'Production' environment"
    echo "   • Under 'Branch Tracking' section, click the branch dropdown"
    echo "   • Change from 'main' to '${ENVIRONMENT}' (dev or staging)"
    echo "   • This ensures master deploys from the same branch as dev/staging"
    echo "   • The text should read: 'Every commit pushed to the \`${ENVIRONMENT}\` branch"
    echo "     will create a Production Deployment.'"
    echo ""
    echo "5. Add Environment Variables (BEFORE first deployment):"
    echo "   Click 'Environment Variables' and add:"
    echo ""
    echo "   Variable: VITE_SUPABASE_URL"
    echo "   Value: https://${PROJECT_REF}.supabase.co"
    echo "   Environment: Production, Preview, Development (select all)"
    echo ""
    echo "   Variable: VITE_SUPABASE_ANON_KEY"
    echo "   Value: ${ANON_KEY}"
    echo "   Environment: Production, Preview, Development (select all)"
    echo ""
    echo "   Variable: VITE_CLIENT_CONFIGS"
    echo "   Value: {\"default\":{\"clientId\":\"default\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"Master\"}}"
    echo "   Environment: Production, Preview, Development (select all)"
    echo ""
    echo "6. Click 'Deploy' to create and deploy the project"
    echo ""
    echo "7. After deployment, configure domain:"
    echo "   • Go to Project Settings → Domains"
    echo "   • Click 'Add' and enter: master.staysecure-learn.raynsecure.com"
    echo "   • Follow DNS configuration instructions (add CNAME record)"
    echo "   • Wait for DNS propagation (may take a few minutes)"
    echo ""
    echo "8. Verify deployment and branch configuration:"
    echo "   • Check that project name is: master-staysecure-learn"
    echo "   • Check that repository is: staysecure-learn"
    echo "   • Check that domain is configured: master.staysecure-learn.raynsecure.com"
    echo ""
    echo "   ⚠️  CRITICAL: Verify Production Branch is Correct"
    echo "   • Go to: Project Settings → Environments → Production"
    echo "   • Under 'Branch Tracking', verify it shows: 'Every commit pushed to the \`${ENVIRONMENT}\` branch'"
    echo "   • If it shows 'main' branch, change it to '${ENVIRONMENT}'"
    echo ""
    echo "   • Check current deployment branch:"
    echo "     - Go to: Deployments tab"
    echo "     - Click on the latest Production deployment"
    echo "     - Look at 'Git Commit' section - it should show branch: '${ENVIRONMENT}'"
    echo "     - The commit SHA should match a commit from the '${ENVIRONMENT}' branch"
    echo ""
    echo "   • To verify in Git:"
    echo "     git log --oneline ${ENVIRONMENT} | head -5"
    echo "     Compare the commit SHA with what Vercel shows"
    echo ""
    echo "   • If wrong branch is deployed:"
    echo "     1. Fix branch in Settings → Environments → Production"
    echo "     2. Trigger a new deployment by pushing to ${ENVIRONMENT} branch"
    echo "     3. Or manually redeploy: Deployments → '...' menu → 'Redeploy'"
    echo ""
    echo "   • Test access at: https://master.staysecure-learn.raynsecure.com"
    echo ""
    echo "Note: Master uses the same codebase as dev/staging, just with different"
    echo "      environment variables pointing to the master Supabase project."
    echo ""
fi

echo "Next steps:"
echo "  1. Configure Auth Settings in Supabase Dashboard:"
echo "     • Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/auth/url-configuration"
echo "     • Set Site URL to: https://${CLIENT_DOMAIN}"
echo "     • Add Redirect URLs (one per line):"
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "       - https://${CLIENT_DOMAIN}/reset-password"
    echo "       - https://${CLIENT_DOMAIN}/activate-account"
else
    echo "       - https://${BASE_DOMAIN}/${CLIENT_NAME}/reset-password"
    echo "       - https://${BASE_DOMAIN}/${CLIENT_NAME}/activate-account"
fi
echo "  2. Copy the client configuration JSON above"
echo "  3. Update Vercel environment variable VITE_CLIENT_CONFIGS"
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "     • Use 'default' client for single-client environment"
    echo "     • Root path (/) will work at: https://${CLIENT_DOMAIN}"
else
    echo "     • Merge with existing clients if needed"
    echo "     • Ensure there is NO 'default' client in production"
fi
echo "  4. Redeploy Vercel project"
if [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "  5. Test access at: https://${CLIENT_DOMAIN} (root path should work)"
else
    echo "  5. Test access at: https://${BASE_DOMAIN}/${CLIENT_NAME}"
    echo "  6. Verify root path (/) shows error (this is expected and correct)"
fi
echo "  7. Create admin user using: ./scripts/create-admin-user.sh ${PROJECT_REF} <email> <password> [full-name] [first-name] [last-name]"
echo "  8. Test user creation and email sending"
echo "  9. Sync lesson content from master:"
echo "     • Open the Learn app connected to the MASTER database"
echo "     • Go to Admin → Lesson Sync"
echo "     • Select all learning tracks and this client (${CLIENT_NAME})"
echo "     • Click Sync — this populates lessons, tracks, and media from master"
echo "     NOTE: The seed only contains reference data (languages, email templates, etc.)."
echo "           Lesson content is NOT seeded — it must come from master via sync."

