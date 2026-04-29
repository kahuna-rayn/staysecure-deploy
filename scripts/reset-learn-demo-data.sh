#!/usr/bin/env bash
#
# Wipe learner progress / assignments / quiz / reminder / phishing demo tables on a Learn DB.
# Safe for staging-as-demo: does NOT touch lessons, learning_tracks, profiles, or auth.
#
# Prerequisites: PGPASSWORD set to the target database password.
#
# Usage:
#   ./reset-learn-demo-data.sh
#   ./reset-learn-demo-data.sh --dry-run
#   ./reset-learn-demo-data.sh --yes
#   ./reset-learn-demo-data.sh --with-email-notifications
#   ./reset-learn-demo-data.sh --staging
#
# Optional: regenerate fresh charts after reset:
#   ./generate-analytics-data.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"
SQL_FILE="${SCRIPT_DIR}/sql/reset-learn-demo-data.sql"
SQL_WITH_NOTIFICATIONS="${SCRIPT_DIR}/sql/reset-learn-demo-data-with-notifications.sql"
REGION="${REGION:-ap-southeast-1}"

DEMO_TABLES=(
  lesson_reminder_history
  lesson_reminder_counts
  user_answer_responses
  user_behavior_analytics
  certificates
  quiz_attempts
  user_lesson_progress
  user_learning_track_progress
  learning_track_assignments
  learning_track_department_assignments
  learning_track_role_assignments
  user_phishing_scores
)

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${PROJECTS_CONF}"

if [ ! -f "${SQL_FILE}" ]; then
    echo -e "${RED}Error: SQL file not found at ${SQL_FILE}${NC}" >&2
    exit 1
fi

usage() {
    echo "Usage: $0 [--dry-run] [--yes] [--with-email-notifications] [--staging]" >&2
    echo "       $0 [--dry-run] [--yes] [--with-email-notifications] <staging-project-ref>" >&2
    echo "" >&2
    echo "Staging only — must match STAGING_REF in learn/secrets/projects.conf." >&2
    echo "Omit target to use STAGING_REF from projects.conf automatically." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --dry-run                     show row counts only; no changes" >&2
    echo "  --yes                         skip confirmation (use in automation only)" >&2
    echo "  --with-email-notifications   also TRUNCATE public.email_notifications" >&2
    echo "  -h, --help                    show this help" >&2
    exit 1
}

for _help in "$@"; do
    case "$_help" in
        -h|--help) usage ;;
    esac
done

if [ -z "${PGPASSWORD:-}" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set${NC}" >&2
    echo "Export it before running: export PGPASSWORD=<db-password>" >&2
    exit 1
fi

DRY_RUN=false
ASSUME_YES=false
WITH_EMAIL_NOTIFICATIONS=false
REFS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run)                DRY_RUN=true ;;
        --yes)                    ASSUME_YES=true ;;
        --with-email-notifications) WITH_EMAIL_NOTIFICATIONS=true ;;
        --staging)                REFS+=("$STAGING_REF") ;;
        --dev|--master|--all-production|--all)
            echo -e "${RED}Error: demo reset is restricted to staging (${STAGING_REF}) only.${NC}" >&2
            exit 1
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo -e "${RED}Unknown flag: ${arg}${NC}" >&2
            usage
            ;;
        *)
            REFS+=("$arg")
            ;;
    esac
done

if [ ${#REFS[@]} -eq 0 ]; then
    REFS+=("$STAGING_REF")
fi

for ref in "${REFS[@]}"; do
    if [ "$ref" != "$STAGING_REF" ]; then
        echo -e "${RED}Error: ref ${ref} is not staging. Only STAGING_REF (${STAGING_REF}) is allowed.${NC}" >&2
        exit 1
    fi
done

# Deduplicate refs (preserving order; bash 3 compatible)
UNIQUE_REFS=()
for ref in "${REFS[@]}"; do
    _dup=false
    for _existing in "${UNIQUE_REFS[@]:-}"; do
        [ "$_existing" = "$ref" ] && _dup=true && break
    done
    $_dup || UNIQUE_REFS+=("$ref")
done

connect_args_for_ref() {
    local ref="$1"
    local db_host="db.${ref}.supabase.co"
    local pooler_host="${POOLER_HOST:-aws-1-${REGION}.pooler.supabase.com}"
    local resolved
    resolved=$(dig AAAA +short "${db_host}" 2>/dev/null | grep -v '^\.' | head -1 || true)
    if [ -n "$resolved" ] && ping6 -c 1 -W 2 "${resolved}" &>/dev/null 2>&1; then
        export PGHOSTADDR="${resolved}"
        echo "host=${db_host} port=6543 user=postgres dbname=postgres sslmode=require"
    else
        unset PGHOSTADDR
        echo "host=${pooler_host} port=5432 user=postgres.${ref} dbname=postgres sslmode=require"
    fi
}

run_counts() {
    local conn="$1"
    local ref="$2"
    echo -e "  ${CYAN}Row counts (${ref}):${NC}"
    local total=0
    for tbl in "${DEMO_TABLES[@]}"; do
        local n
        n=$(psql "${conn}" -tAq -c "SELECT COUNT(*)::text FROM public.\"${tbl}\";" 2>&1) || {
            echo -e "    ${RED}✗${NC} ${tbl}: ${n}"
            return 1
        }
        n=$(echo "${n}" | tr -d ' ')
        total=$((total + n))
        echo -e "    ${tbl}: ${n}"
    done
    if $WITH_EMAIL_NOTIFICATIONS; then
        local en
        en=$(psql "${conn}" -tAq -c "SELECT COUNT(*)::text FROM public.email_notifications;" 2>&1) || true
        en=$(echo "${en}" | tr -d ' ')
        echo -e "    ${YELLOW}email_notifications (optional):${NC} ${en}"
    fi
    echo -e "  ${CYAN}Subtotal (listed tables): ${total} rows${NC}"
}

for PROJECT_REF in "${UNIQUE_REFS[@]}"; do
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  reset-learn-demo-data — ${PROJECT_REF}${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

    CONN=$(connect_args_for_ref "${PROJECT_REF}")
    echo -e "  Connection: ${CONN}"

    if $DRY_RUN; then
        echo -e "${YELLOW}  DRY RUN — no changes${NC}"
        run_counts "${CONN}" "${PROJECT_REF}" || exit 1
        continue
    fi

    echo -e "${RED}  This permanently deletes all rows in learner-activity tables (see sql/reset-learn-demo-data.sql).${NC}"
    echo -e "${RED}  Project: ${PROJECT_REF}${NC}"
    if $WITH_EMAIL_NOTIFICATIONS; then
        echo -e "${RED}  Also truncating: email_notifications${NC}"
    fi

    if ! $ASSUME_YES; then
        echo -e "${YELLOW}  Type the project ref exactly to confirm:${NC} "
        read -r confirm
        if [ "${confirm}" != "${PROJECT_REF}" ]; then
            echo -e "${RED}  Aborted (confirmation did not match).${NC}"
            exit 1
        fi
    fi

    echo -e "  ${GREEN}Applying reset SQL...${NC}"
    if $WITH_EMAIL_NOTIFICATIONS; then
        if [ ! -f "${SQL_WITH_NOTIFICATIONS}" ]; then
            echo -e "${RED}Missing ${SQL_WITH_NOTIFICATIONS}${NC}" >&2
            exit 1
        fi
        psql "${CONN}" --single-transaction --file "${SQL_WITH_NOTIFICATIONS}"
    else
        psql "${CONN}" --single-transaction --file "${SQL_FILE}"
    fi

    echo -e "${GREEN}  ✓ Reset complete for ${PROJECT_REF}${NC}"
    echo -e "${CYAN}  Tip: ./generate-analytics-data.sh${NC}"
done

echo ""
