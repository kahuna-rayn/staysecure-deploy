#!/bin/bash

# Run pending Supabase migrations across one or more client projects via psql.
#
# Tracks applied migrations using supabase_migrations.schema_migrations
# (the same table supabase db push uses), so it's safe to re-run — already-
# applied migrations are skipped.
#
# Prerequisites:
#   PGPASSWORD must be set in your environment.
#
# Usage:
#   ./run-migrations.sh --dev
#   ./run-migrations.sh --staging
#   ./run-migrations.sh --dev --staging
#   ./run-migrations.sh --master
#   ./run-migrations.sh --all-production
#   ./run-migrations.sh --all
#   ./run-migrations.sh <project-ref> [project-ref2] ...
#   ./run-migrations.sh --dry-run --all        # preview only, no changes
#
# Examples:
#   PGPASSWORD=xxx ./run-migrations.sh --dev
#   ./run-migrations.sh --all-production
#   ./run-migrations.sh --dry-run --staging

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"
MIGRATIONS_DIR="${PROJECT_ROOT}/learn/supabase/migrations"
REGION="${REGION:-ap-southeast-1}"

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

if [ ! -d "${MIGRATIONS_DIR}" ]; then
    echo -e "${RED}Error: migrations directory not found at ${MIGRATIONS_DIR}${NC}"
    exit 1
fi

# ── PGPASSWORD guard ──────────────────────────────────────────────────────────
if [ -z "${PGPASSWORD:-}" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set${NC}"
    echo "Export it before running: export PGPASSWORD=<your-db-password>"
    exit 1
fi

# ── Args ──────────────────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: at least one target is required${NC}"
    echo ""
    echo "Usage: ./run-migrations.sh [--dry-run] <target> [target2] ..."
    echo ""
    echo "Targets:"
    echo "  --dev                  Dev project (${DEV_REF})"
    echo "  --staging              Staging project (${STAGING_REF})"
    echo "  --master               Master project (${MASTER_REF})"
    echo "  --all-production       All production client projects"
    echo "  --all                  Dev + staging + master + all production"
    echo "  <project-ref>          Any raw Supabase project ref"
    echo ""
    echo "Options:"
    echo "  --dry-run              List pending migrations without applying them"
    exit 1
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
DRY_RUN=false
REFS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY_RUN=true ;;
        --dev)            REFS+=("$DEV_REF") ;;
        --staging)        REFS+=("$STAGING_REF") ;;
        --master)         REFS+=("$MASTER_REF") ;;
        --all-production)
            if [ ${#PRODUCTION_CLIENT_REFS[@]} -eq 0 ]; then
                echo -e "${YELLOW}No production client refs configured in projects.conf${NC}"
            else
                REFS+=("${PRODUCTION_CLIENT_REFS[@]}")
            fi
            ;;
        --all)
            REFS+=("$DEV_REF" "$STAGING_REF" "$MASTER_REF")
            if [ ${#PRODUCTION_CLIENT_REFS[@]} -gt 0 ]; then
                REFS+=("${PRODUCTION_CLIENT_REFS[@]}")
            fi
            ;;
        --*)
            echo -e "${RED}Unknown flag: $arg${NC}"
            exit 1
            ;;
        *)
            REFS+=("$arg")
            ;;
    esac
done

if [ ${#REFS[@]} -eq 0 ]; then
    echo -e "${RED}Error: no project refs resolved from the given targets${NC}"
    exit 1
fi

# Deduplicate refs (preserving order, bash 3 compatible)
UNIQUE_REFS=()
for ref in "${REFS[@]}"; do
    _dup=false
    for _existing in "${UNIQUE_REFS[@]:-}"; do
        [ "$_existing" = "$ref" ] && _dup=true && break
    done
    $_dup || UNIQUE_REFS+=("$ref")
done

# ── List all local migration files ───────────────────────────────────────────
MIGRATION_FILES=()
while IFS= read -r -d '' f; do
    MIGRATION_FILES+=("$f")
done < <(find "${MIGRATIONS_DIR}" -maxdepth 1 -name "*.sql" -print0 | sort -z)

if [ ${#MIGRATION_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No migration files found in ${MIGRATIONS_DIR}${NC}"
    exit 0
fi

# ── Connection helper ─────────────────────────────────────────────────────────
# Mirrors the IPv6/pooler detection in onboard-client.sh.
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

# ── Per-project loop ──────────────────────────────────────────────────────────
FAILED=()
SUCCEEDED=()

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  run-migrations.sh${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  Migrations dir : ${MIGRATIONS_DIR}"
echo -e "  Local SQL files: ${#MIGRATION_FILES[@]}"
echo -e "  Target projects: ${#UNIQUE_REFS[@]}"
for ref in "${UNIQUE_REFS[@]}"; do
    echo -e "    • ${ref}"
done
if $DRY_RUN; then
    echo -e "${YELLOW}  DRY RUN — no changes will be made${NC}"
fi
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

for PROJECT_REF in "${UNIQUE_REFS[@]}"; do
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}Project: ${PROJECT_REF}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"

    CONN=$(connect_args_for_ref "${PROJECT_REF}")
    echo -e "  Connection: ${CONN}"

    # Fetch already-applied migration versions from the DB.
    # supabase_migrations.schema_migrations.version matches the timestamp prefix
    # of the filename (e.g. "20260423000000" from "20260423000000_foo.sql").
    # Always query even in dry-run so the output shows accurate pending/skip status.
    # If we can't connect or query the table, abort for this project rather than
    # silently treating all migrations as pending (which would re-run everything).
    APPLIED_VERSIONS=""
    _versions_output=$(psql "${CONN}" -tAq \
        -c "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;" \
        2>&1)
    _psql_exit=$?
    if [ $_psql_exit -ne 0 ]; then
        echo -e "${RED}✗ Cannot query schema_migrations on ${PROJECT_REF} (exit ${_psql_exit}):${NC}"
        echo -e "${RED}  ${_versions_output}${NC}"
        echo -e "${RED}  Skipping this project to avoid re-running already-applied migrations.${NC}"
        echo -e "${YELLOW}  Check: correct PGPASSWORD? correct region in POOLER_HOST?${NC}"
        FAILED+=("${PROJECT_REF}")
        continue
    fi
    APPLIED_VERSIONS="${_versions_output}"

    project_ok=true
    applied_count=0
    skipped_count=0
    pending_count=0

    for migration_file in "${MIGRATION_FILES[@]}"; do
        filename=$(basename "${migration_file}")
        # Version is the leading digits (up to the first underscore or end of name)
        version=$(echo "${filename}" | sed 's/^\([0-9]*\).*/\1/')

        # Check if already applied
        if echo "${APPLIED_VERSIONS}" | grep -qx "${version}"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if $DRY_RUN; then
            echo -e "  ${YELLOW}pending${NC} ${filename}"
            pending_count=$((pending_count + 1))
            continue
        fi

        echo -e "  ${GREEN}apply${NC} ${filename} ..."
        if psql "${CONN}" \
            --single-transaction \
            --file "${migration_file}" \
            2>&1; then

            # Record the migration as applied (same as supabase db push does)
            psql "${CONN}" -q -c \
                "INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
                 VALUES ('${version}', '${filename}', NULL)
                 ON CONFLICT (version) DO NOTHING;" \
                2>/dev/null || true

            echo -e "  ${GREEN}✓ applied${NC} ${filename}"
            applied_count=$((applied_count + 1))
        else
            echo -e "  ${RED}✗ failed${NC}  ${filename}"
            project_ok=false
            break
        fi
    done

    if $DRY_RUN; then
        if [ "${skipped_count}" -gt 0 ]; then
            echo -e "  ${YELLOW}${skipped_count} migration file(s) already applied (not listed above)${NC}"
        fi
        if [ "${pending_count}" -eq 0 ] && [ "${skipped_count}" -gt 0 ]; then
            echo -e "  ${GREEN}Nothing pending — database is up to date${NC}"
        elif [ "${pending_count}" -gt 0 ]; then
            echo -e "  ${CYAN}Would apply ${pending_count} pending migration(s)${NC}"
        fi
        SUCCEEDED+=("${PROJECT_REF}")
    elif $project_ok; then
        if [ "${skipped_count}" -gt 0 ] && [ "${applied_count}" -eq 0 ]; then
            echo -e "${GREEN}✓ ${PROJECT_REF}: up to date (${skipped_count} already applied)${NC}"
        elif [ "${skipped_count}" -gt 0 ]; then
            echo -e "${GREEN}✓ ${PROJECT_REF}: ${applied_count} applied, ${skipped_count} already applied${NC}"
        else
            echo -e "${GREEN}✓ ${PROJECT_REF}: ${applied_count} applied${NC}"
        fi
        SUCCEEDED+=("${PROJECT_REF}")
    else
        echo -e "${RED}✗ ${PROJECT_REF}: failed — halted at failing migration${NC}"
        FAILED+=("${PROJECT_REF}")
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  Results"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    echo -e "${GREEN}  ✓ Succeeded (${#SUCCEEDED[@]}):${NC}"
    for ref in "${SUCCEEDED[@]}"; do
        echo -e "${GREEN}    • ${ref}${NC}"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}  ✗ Failed (${#FAILED[@]}):${NC}"
    for ref in "${FAILED[@]}"; do
        echo -e "${RED}    • ${ref}${NC}"
    done
    echo ""
    exit 1
fi

echo ""
