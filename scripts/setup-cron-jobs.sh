#!/bin/bash
# Sets up all pg_cron scheduled jobs for one or more StaySecure Learn Supabase projects.
#
# Safe to re-run at any time — each job is unscheduled then rescheduled (idempotent).
# Use this to:
#   • Fix a project that is missing one or more cron jobs
#   • Apply a new job to all production projects at once
#   • Called automatically by onboard-client.sh for new projects
#
# Usage:
#   ./setup-cron-jobs.sh <project-ref> [project-ref2] ...
#   ./setup-cron-jobs.sh --all-production   (all projects with name ending in -prod)
#   ./setup-cron-jobs.sh --all              (every project in the org)
#   ./setup-cron-jobs.sh --master           (master DB only: reconcile + expiry digest)
#
# PGPASSWORD must be set in the environment (or in deploy/.env.local / deploy/.env).
# The service role key is fetched automatically via `supabase projects api-keys`.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Known project refs (sourced from shared config) ──────────────────────────
PROJECTS_CONF="${SCRIPT_DIR}/../../learn/secrets/projects.conf"
if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

# ── Resolve project name → ref ────────────────────────────────────────────────
# Accepts either a 20-char project ref (used as-is) or a project name (looked up).
# Prints the resolved ref, or an empty string if not found.
resolve_ref() {
    local input="$1"
    # A Supabase project ref is exactly 20 lowercase alphanumeric chars
    if [[ "$input" =~ ^[a-z0-9]{20}$ ]]; then
        echo "$input"
        return
    fi
    # Treat as project name — look it up
    local ref
    ref=$(supabase projects list --output json 2>/dev/null \
        | jq -r --arg name "$input" '.[] | select(.name == $name) | .id' | head -1)
    if [ -z "$ref" ]; then
        echo -e "${RED}Error: No project found with name \"${input}\"${NC}" >&2
        echo -e "${YELLOW}Tip: Run 'supabase projects list' to see available names and refs.${NC}" >&2
    fi
    echo "$ref"
}

# ── Args ──────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project name, ref, or flag is required${NC}"
    echo "Usage:"
    echo "  ./setup-cron-jobs.sh <project-name-or-ref> [...]"
    echo "  ./setup-cron-jobs.sh --dev"
    echo "  ./setup-cron-jobs.sh --staging"
    echo "  ./setup-cron-jobs.sh --all-production"
    echo "  ./setup-cron-jobs.sh --all"
    echo "  ./setup-cron-jobs.sh --master"
    echo ""
    echo "  --dev             Dev project (${DEV_REF})"
    echo "  --staging         Staging project (${STAGING_REF})"
    echo "  --all-production  All production clients (from learn/secrets/projects.conf)"
    echo "  --all             Dev + staging + all production clients"
    echo "  --master          Master DB only (reconcile-license-usage + expiry digest)"
    echo ""
    echo "Examples:"
    echo "  ./setup-cron-jobs.sh --dev"
    echo "  ./setup-cron-jobs.sh acme-prod            # project name resolved via Supabase CLI"
    echo "  ./setup-cron-jobs.sh cleqfnrbiqpxpzxkatda # raw ref also accepted"
    exit 1
fi

# ── Master DB cron setup ───────────────────────────────────────────────────────

if [ "$1" = "--master" ]; then
    echo -e "${GREEN}Setting up cron jobs for master DB: ${MASTER_PROJECT_REF}${NC}"

    # Load env
    if [ -f "${SCRIPT_DIR}/../.env.local" ]; then
        source "${SCRIPT_DIR}/../.env.local"
    elif [ -f "${SCRIPT_DIR}/../.env" ]; then
        source "${SCRIPT_DIR}/../.env"
    fi

    if [ -z "$PGPASSWORD" ]; then
        echo -e "${RED}Error: PGPASSWORD is not set${NC}"; exit 1
    fi

    SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref "${MASTER_PROJECT_REF}" 2>/dev/null \
        | grep 'service_role' | awk '{print $3}')

    if [ -z "$SERVICE_ROLE_KEY" ]; then
        echo -e "${RED}Error: Could not retrieve service role key for master project${NC}"; exit 1
    fi

    REGION="${REGION:-ap-southeast-1}"
    POOLER_HOST="${POOLER_HOST:-aws-1-${REGION}.pooler.supabase.com}"
    DB_HOSTNAME="db.${MASTER_PROJECT_REF}.supabase.co"

    RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v '^\.' | head -1)
    if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
        export PGHOSTADDR="${RESOLVED_ADDR}"
        PG_HOST="${DB_HOSTNAME}"; PG_PORT=6543; PG_USER="postgres"
    else
        unset PGHOSTADDR
        PG_HOST="${POOLER_HOST}"; PG_PORT=5432; PG_USER="postgres.${MASTER_PROJECT_REF}"
    fi

    CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"
    AUTH_HEADER_ESCAPED=$(echo "Bearer ${SERVICE_ROLE_KEY}" | sed "s/'/''/g")
    RECONCILE_URL_ESCAPED=$(echo "https://${MASTER_PROJECT_REF}.supabase.co/functions/v1/reconcile-license-usage" | sed "s/'/''/g")

    psql "${CONNECTION_STRING}" <<SQL
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- reconcile-license-usage + expiry digest (02:00 UTC daily)
DO \$\$ BEGIN PERFORM cron.unschedule('reconcile-license-usage'); EXCEPTION WHEN others THEN NULL; END \$\$;
SELECT cron.schedule(
  'reconcile-license-usage',
  '0 2 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body    := '{}'::jsonb
      );
    \$cron\$,
    '${RECONCILE_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
);
SQL

    psql "${CONNECTION_STRING}" -c "
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'reconcile-license-usage';
" 2>/dev/null || true

    echo -e "${GREEN}✓ Master cron jobs configured${NC}"
    echo "  reconcile-license-usage → 02:00 UTC daily (reconcile seats_used + expiry digest)"
    exit 0
fi

# Expand --dev / --staging shortcuts before flag processing
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
        echo -e "${YELLOW}No production client refs configured yet. Add them to learn/secrets/projects.conf.${NC}"
        exit 0
    fi
    echo -e "${GREEN}Setting up cron jobs for ${#PRODUCTION_CLIENT_REFS[@]} production client(s)...${NC}"
    set -- "${PRODUCTION_CLIENT_REFS[@]}"
elif [ "$1" = "--all" ]; then
    ALL_REFS=("$DEV_REF" "$STAGING_REF" "${PRODUCTION_CLIENT_REFS[@]}")
    echo -e "${GREEN}Setting up cron jobs for all known projects (dev + staging + ${#PRODUCTION_CLIENT_REFS[@]} production client(s))...${NC}"
    set -- "${ALL_REFS[@]}"
else
    # Resolve any project names in the argument list to refs
    RESOLVED=()
    for arg in "$@"; do
        ref=$(resolve_ref "$arg")
        if [ -z "$ref" ]; then
            echo -e "${RED}Aborting: could not resolve \"${arg}\"${NC}"; exit 1
        fi
        RESOLVED+=("$ref")
    done
    set -- "${RESOLVED[@]}"
fi

# ── Load env (for PGPASSWORD, POOLER_HOST, REGION) ───────────────────────────

if [ -f "${SCRIPT_DIR}/../.env.local" ]; then
    source "${SCRIPT_DIR}/../.env.local"
elif [ -f "${SCRIPT_DIR}/../.env" ]; then
    source "${SCRIPT_DIR}/../.env"
fi

if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set${NC}"
    echo "Set it in deploy/.env.local or export it before running this script."
    exit 1
fi

# ── Per-project setup ─────────────────────────────────────────────────────────

for PROJECT_REF in "$@"; do
    PROJECT_NAME=$(supabase projects list --output json 2>/dev/null \
        | jq -r --arg ref "$PROJECT_REF" '.[] | select(.id == $ref) | .name' | head -1)
    DISPLAY="${PROJECT_NAME:-$PROJECT_REF} (${PROJECT_REF})"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Setting up cron jobs for: ${DISPLAY}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    # Fetch service role key for this project
    SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref "${PROJECT_REF}" 2>/dev/null \
        | grep 'service_role' | awk '{print $3}')

    if [ -z "$SERVICE_ROLE_KEY" ]; then
        echo -e "${RED}Error: Could not retrieve service role key for ${DISPLAY} — skipping${NC}"
        echo "Ensure you are logged into the Supabase CLI and have access to this project."
        continue
    fi

    # Build connection string — prefer direct IPv6, fall back to session-mode pooler
    REGION="${REGION:-ap-southeast-1}"
    POOLER_HOST="${POOLER_HOST:-aws-1-${REGION}.pooler.supabase.com}"
    DB_HOSTNAME="db.${PROJECT_REF}.supabase.co"

    RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v '^\.' | head -1)
    if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
        export PGHOSTADDR="${RESOLVED_ADDR}"
        PG_HOST="${DB_HOSTNAME}"; PG_PORT=6543; PG_USER="postgres"
        echo -e "${GREEN}Using direct connection (IPv6): ${RESOLVED_ADDR}${NC}"
    else
        unset PGHOSTADDR
        PG_HOST="${POOLER_HOST}"; PG_PORT=5432; PG_USER="postgres.${PROJECT_REF}"
        echo -e "${YELLOW}Direct connection unavailable — using pooler: ${POOLER_HOST}${NC}"
    fi

    CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"

    # Escape single quotes for SQL format()
    AUTH_HEADER_ESCAPED=$(echo "Bearer ${SERVICE_ROLE_KEY}" | sed "s/'/''/g")
    NOTIFICATIONS_URL_ESCAPED=$(echo "https://${PROJECT_REF}.supabase.co/functions/v1/process-scheduled-notifications" | sed "s/'/''/g")
    REMINDERS_URL_ESCAPED=$(echo "https://${PROJECT_REF}.supabase.co/functions/v1/send-lesson-reminders" | sed "s/'/''/g")

    psql "${CONNECTION_STRING}" <<SQL
-- Ensure required extensions are present
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ── Remove legacy / misnamed jobs ────────────────────────────────────────────
-- 'send-lesson-reminders': manually-created job with wrong body; replaced by
--   'send-daily-lesson-reminders'.
-- 'send-notification-reminders': pointed at a non-existent edge function;
--   superseded by 'process-manager-notifications'.
-- Each job gets its own block so one missing job doesn't skip the others.
DO \$\$ BEGIN PERFORM cron.unschedule('send-lesson-reminders');      EXCEPTION WHEN others THEN NULL; END \$\$;
DO \$\$ BEGIN PERFORM cron.unschedule('send-notification-reminders'); EXCEPTION WHEN others THEN NULL; END \$\$;

-- ── Job 1: manager_employee_incomplete  (01:00 UTC daily) ────────────────────
DO \$\$
BEGIN
  PERFORM cron.unschedule('process-manager-notifications');
EXCEPTION WHEN others THEN NULL;
END \$\$;
SELECT cron.schedule(
  'process-manager-notifications',
  '0 1 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body    := jsonb_build_object('notification_type', 'manager_employee_incomplete')
      );
    \$cron\$,
    '${NOTIFICATIONS_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
);

-- ── Job 2: manager_staff_pending  (01:00 UTC daily) ──────────────────────────
DO \$\$
BEGIN
  PERFORM cron.unschedule('process-staff-pending-notifications');
EXCEPTION WHEN others THEN NULL;
END \$\$;
SELECT cron.schedule(
  'process-staff-pending-notifications',
  '0 1 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body    := jsonb_build_object('notification_type', 'manager_staff_pending')
      );
    \$cron\$,
    '${NOTIFICATIONS_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
);

-- ── Job 3: send-lesson-reminders  (09:00 UTC daily) ──────────────────────────
DO \$\$
BEGIN
  PERFORM cron.unschedule('send-daily-lesson-reminders');
EXCEPTION WHEN others THEN NULL;
END \$\$;
SELECT cron.schedule(
  'send-daily-lesson-reminders',
  '0 9 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body    := '{}'::jsonb
      );
    \$cron\$,
    '${REMINDERS_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
);

-- ── Job 4: license_expiry  (08:00 UTC daily) ──────────────────────────────────
DO \$\$
BEGIN
  PERFORM cron.unschedule('process-license-expiry-notifications');
EXCEPTION WHEN others THEN NULL;
END \$\$;
SELECT cron.schedule(
  'process-license-expiry-notifications',
  '0 8 * * *',
  format(
    \$cron\$
      SELECT net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', %L
        ),
        body    := jsonb_build_object('notification_type', 'license_expiry')
      );
    \$cron\$,
    '${NOTIFICATIONS_URL_ESCAPED}',
    '${AUTH_HEADER_ESCAPED}'
  )
);
SQL

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: cron job setup failed for ${DISPLAY}${NC}"
        continue
    fi

    # Verify
    echo ""
    psql "${CONNECTION_STRING}" -c "
SELECT jobname, schedule, active
FROM cron.job
WHERE jobname IN (
  'process-manager-notifications',
  'process-staff-pending-notifications',
  'send-daily-lesson-reminders',
  'process-license-expiry-notifications'
)
ORDER BY jobname;
" 2>/dev/null || true

    echo -e "${GREEN}✓ Cron jobs configured for ${DISPLAY}${NC}"
    echo "  process-license-expiry-notifications → 08:00 UTC daily (license_expiry)"
    echo "  process-manager-notifications        → 01:00 UTC daily (manager_employee_incomplete)"
    echo "  process-staff-pending-notifications  → 01:00 UTC daily (manager_staff_pending)"
    echo "  send-daily-lesson-reminders          → 09:00 UTC daily (lesson reminders)"
done

echo ""
echo -e "${GREEN}✓ All projects done${NC}"
