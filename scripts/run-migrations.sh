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
#   ./run-migrations.sh --baseline ssakvcueucdwntrrqkfa
#       Record every local migration version in schema_migrations without
#       running SQL — use when the DB already matches this repo (e.g. restored
#       from backup) but tracking rows are missing.
#   ./run-migrations.sh --force-full-migrations ssakvcueucdwntrrqkfa
#       With empty migration history, still run all .sql files even if public
#       already has core tables (dangerous; only for intentional replays).
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
    echo "Usage: ./run-migrations.sh [options] <target> [target2] ..."
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
    echo "  --dry-run                  List pending migrations without applying them"
    echo "  --baseline                 Record versions in schema_migrations only (no .sql)"
    echo "  --force-full-migrations    Empty history + existing tables: still run every .sql"
    exit 1
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
DRY_RUN=false
BASELINE_MODE=false
FORCE_FULL_MIGRATIONS=false
REFS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run)                  DRY_RUN=true ;;
        --baseline)                 BASELINE_MODE=true ;;
        --force-full-migrations)    FORCE_FULL_MIGRATIONS=true ;;
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
            # Dynamic lookup: --foo → FOO_REF, --foo-bar → FOO_BAR_REF
            var_name="$(echo "${arg#--}" | tr '[:lower:]-' '[:upper:]_')_REF"
            ref="${!var_name}"
            if [ -n "$ref" ]; then
                REFS+=("$ref")
            else
                echo -e "${RED}Unknown flag: $arg (no ${var_name} defined in projects.conf)${NC}" >&2
                exit 1
            fi
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
if $BASELINE_MODE; then
    echo -e "${YELLOW}  BASELINE — only recording versions (no SQL execution)${NC}"
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
    # If the table doesn't exist yet (fresh project restored from pg_dump), create
    # it automatically rather than failing — pg_dump doesn't capture the
    # supabase_migrations schema, so it's always missing on newly onboarded DBs.
    APPLIED_VERSIONS=""
    _psql_exit=0
    _versions_output=$(
      psql "${CONN}" -tAq \
        -c "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;" \
        2>&1
    ) || _psql_exit=$?
    if [ $_psql_exit -ne 0 ]; then
        # Check whether the failure is specifically a missing relation.
        if echo "${_versions_output}" | grep -q 'supabase_migrations\|does not exist\|relation'; then
            echo -e "${YELLOW}  supabase_migrations.schema_migrations not found — bootstrapping it now...${NC}"
            if psql "${CONN}" -q -c "
                CREATE SCHEMA IF NOT EXISTS supabase_migrations;
                CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
                    version    text NOT NULL PRIMARY KEY,
                    name       text,
                    statements text[]
                );
            " 2>&1; then
                echo -e "${GREEN}  ✓ schema_migrations bootstrapped${NC}"
                _versions_output=""
                _psql_exit=0
            else
                echo -e "${RED}✗ Could not bootstrap schema_migrations on ${PROJECT_REF}${NC}"
                echo -e "${YELLOW}  Check PGPASSWORD and connectivity, then create manually:${NC}"
                echo -e "${YELLOW}    CREATE SCHEMA IF NOT EXISTS supabase_migrations;${NC}"
                echo -e "${YELLOW}    CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (version text PRIMARY KEY, name text, statements text[]);${NC}"
                FAILED+=("${PROJECT_REF}")
                continue
            fi
        else
            echo -e "${RED}✗ Cannot query schema_migrations on ${PROJECT_REF} (exit ${_psql_exit}):${NC}"
            echo -e "${RED}  ${_versions_output}${NC}"
            echo -e "${RED}  Skipping this project to avoid re-running already-applied migrations.${NC}"
            echo -e "${YELLOW}  Check: correct PGPASSWORD? correct region in POOLER_HOST?${NC}"
            FAILED+=("${PROJECT_REF}")
            continue
        fi
    fi
    APPLIED_VERSIONS="${_versions_output}"

    HISTORY_COUNT=$(printf '%s\n' "${APPLIED_VERSIONS}" | grep -E '^[0-9]+$' | wc -l | tr -d ' ' || echo "0")

    # Empty tracking + real Learn schema = replaying every file will explode on
    # "already exists". Baseline records versions without SQL; --force-full-migrations
    # opts into a dangerous full replay.
    if [ "${HISTORY_COUNT}" -eq 0 ] && [ "$BASELINE_MODE" = false ] && [ "$FORCE_FULL_MIGRATIONS" = false ]; then
        _has_profiles=$(
          psql "${CONN}" -tAq \
            -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'profiles');" \
            2>&1
        ) || _has_profiles="f"
        if [ "${_has_profiles}" = "t" ]; then
            echo -e "${RED}✗ ${PROJECT_REF}: migration history is empty but \`public.profiles\` exists.${NC}"
            echo -e "${YELLOW}  Replaying all ${#MIGRATION_FILES[@]} SQL files will normally fail (duplicate objects).${NC}"
            echo -e "${YELLOW}  If the schema already matches this repo, run:${NC}"
            echo -e "    ${GREEN}./run-migrations.sh --dry-run --baseline ${PROJECT_REF}${NC}  ${YELLOW}# preview${NC}"
            echo -e "    ${GREEN}./run-migrations.sh --baseline ${PROJECT_REF}${NC}           ${YELLOW}# record versions only${NC}"
            echo -e "${YELLOW}  Advanced: ${GREEN}--force-full-migrations${NC} to execute every file anyway.${NC}"
            FAILED+=("${PROJECT_REF}")
            continue
        fi
    fi

    if $BASELINE_MODE && [ "${HISTORY_COUNT}" -eq 0 ]; then
        _hp=$(
          psql "${CONN}" -tAq \
            -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'profiles');" \
            2>&1
        ) || _hp="f"
        if [ "${_hp}" != "t" ]; then
            echo -e "${YELLOW}  WARNING: --baseline with no rows in schema_migrations and no public.profiles —${NC}"
            echo -e "${YELLOW}  only do this if the DB schema already exists (e.g. restore) without tracking.${NC}"
        fi
    fi

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

        if $BASELINE_MODE; then
            if $DRY_RUN; then
                echo -e "  ${YELLOW}baseline${NC} would record ${filename}"
                pending_count=$((pending_count + 1))
            else
                echo -e "  ${GREEN}baseline${NC} record ${filename} ..."
                if psql "${CONN}" -q -c \
                    "INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
                     VALUES ('${version}', '${filename}', NULL)
                     ON CONFLICT (version) DO NOTHING;" 2>&1; then
                    echo -e "  ${GREEN}✓ recorded${NC} ${filename}"
                    applied_count=$((applied_count + 1))
                else
                    echo -e "  ${RED}✗ baseline failed${NC}  ${filename}"
                    project_ok=false
                    break
                fi
            fi
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
            --set ON_ERROR_STOP=on \
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
            if $BASELINE_MODE; then
                echo -e "  ${CYAN}Would record ${pending_count} migration version(s) (--baseline)${NC}"
            else
                echo -e "  ${CYAN}Would apply ${pending_count} pending migration(s)${NC}"
            fi
        fi
        SUCCEEDED+=("${PROJECT_REF}")
    elif $project_ok; then
        if $BASELINE_MODE && [ "${applied_count}" -gt 0 ]; then
            echo -e "${GREEN}✓ ${PROJECT_REF}: ${applied_count} version(s) recorded (--baseline), ${skipped_count} already in history${NC}"
        elif [ "${skipped_count}" -gt 0 ] && [ "${applied_count}" -eq 0 ]; then
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
