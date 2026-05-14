#!/bin/bash
# Validate that the device-ingest migrations have been applied correctly on one
# or more Supabase projects.
#
# Checks:
#   1. (Informational by default) device-ingest rows in supabase_migrations.schema_migrations
#   2. hardware_inventory has all expected device-ingest columns
#   3. org_profile has all expected integration columns
#   4. public.get_vault_secret() and public.upsert_vault_secret() RPCs exist
#   5. device-sync-nightly cron job is registered
#
# Migration ledger (1) does not fail the script by default — restores/dumps often
# lack those rows even when DDL matches. Use --strict-migrations to fail on missing
# migration history (e.g. CI).
#
# Checks (2)–(5) are always blocking: missing hardware_inventory / org_profile
# columns, Vault RPCs, or cron will fail the run.
#
# Usage:
#   ./validate-device-ingest.sh --dev
#   ./validate-device-ingest.sh --staging
#   ./validate-device-ingest.sh --master
#   ./validate-device-ingest.sh --all-production
#   ./validate-device-ingest.sh --all
#   ./validate-device-ingest.sh <project-ref>
#   ./validate-device-ingest.sh --strict-migrations --dev
#
# Targets and projects.conf resolution match run-migrations.sh.
# PGPASSWORD must be set (export or deploy/.env.local).

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"

# ── Paths (same as run-migrations.sh) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"
REGION="${REGION:-ap-southeast-1}"

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

# ── Optional: load PGPASSWORD from deploy env files (run-migrations uses export only)
if [ -z "${PGPASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env.local" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/../.env.local"
elif [ -z "${PGPASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/../.env"
fi

if [ -z "${PGPASSWORD:-}" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set${NC}"
    echo "Export it before running: export PGPASSWORD=<your-db-password>"
    exit 1
fi

# ── Args (aligned with run-migrations.sh targets) ─────────────────────────────
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: at least one target is required${NC}"
    echo ""
    echo "Usage: $0 [--strict-migrations] <target> [target2] ..."
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
    echo "  --strict-migrations    Fail if device-ingest rows are missing from"
    echo "                         supabase_migrations.schema_migrations (default: warn only)"
    exit 1
fi

STRICT_MIGRATIONS=false
REFS=()

for arg in "$@"; do
    case "$arg" in
        --strict-migrations)
            STRICT_MIGRATIONS=true
            ;;
        --dev)
            REFS+=("$DEV_REF")
            ;;
        --staging)
            REFS+=("$STAGING_REF")
            ;;
        --master)
            REFS+=("$MASTER_REF")
            ;;
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

# Deduplicate refs (preserving order, bash 3 compatible — same as run-migrations.sh)
UNIQUE_REFS=()
for ref in "${REFS[@]}"; do
    _dup=false
    for _existing in "${UNIQUE_REFS[@]:-}"; do
        [ "$_existing" = "$ref" ] && _dup=true && break
    done
    $_dup || UNIQUE_REFS+=("$ref")
done

# ── Connection helper (same logic as run-migrations.sh connect_args_for_ref) ──
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

# ── SQL helper — returns trimmed single value, empty string on error ──────────
query() {
    local conn="$1"
    local sql="$2"
    psql "${conn}" -tAq -c "${sql}" 2>/dev/null | tr -d '[:space:]' || true
}

# ── What we expect ────────────────────────────────────────────────────────────

EXPECTED_MIGRATIONS=(
    "20260424000000"
    "20260424000001"
    "20260424000002"
    "20260424000003"
    "20260424000004"
)

EXPECTED_HW_COLUMNS=(
    source external_id os_type asset_location domain_workgroup
    ip_address mac_addresses last_seen_at last_logged_user
    processor memory antivirus last_synced_at
)

EXPECTED_ORG_COLUMNS=(
    device_source intune_client_id intune_client_secret
    atera_api_key atera_customer_id device_last_synced_at
)

EXPECTED_RPCS=(
    get_vault_secret
    upsert_vault_secret
)

# ── Per-project validation ────────────────────────────────────────────────────

PASSED=()
FAILED=()

echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  validate-device-ingest.sh${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
if $STRICT_MIGRATIONS; then
    echo -e "  ${BOLD}strict-migrations:${NC} on (missing ledger rows will fail the run)"
else
    echo -e "  ${BOLD}strict-migrations:${NC} off (migration ledger is informational only)"
fi
echo -e "  Checking ${#UNIQUE_REFS[@]} project(s)"
for ref in "${UNIQUE_REFS[@]}"; do echo -e "    • ${ref}"; done
echo ""

for PROJECT_REF in "${UNIQUE_REFS[@]}"; do
    PROJECT_NAME=$(supabase projects list --output json 2>/dev/null \
        | jq -r --arg ref "$PROJECT_REF" '.[] | select(.id == $ref) | .name' 2>/dev/null \
        | head -1 || true)
    DISPLAY="${PROJECT_NAME:-$PROJECT_REF} (${PROJECT_REF})"

    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}${BOLD}${DISPLAY}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"

    CONN=$(connect_args_for_ref "${PROJECT_REF}")
    project_failures=0

    # ── 1. Migration records (non-fatal unless --strict-migrations) ───────────
    echo -e "\n  ${BOLD}Migrations (supabase_migrations.schema_migrations)${NC}"
    if ! $STRICT_MIGRATIONS; then
        echo -e "  ${YELLOW}(warnings only — use --strict-migrations to fail on missing rows)${NC}"
    fi
    for version in "${EXPECTED_MIGRATIONS[@]}"; do
        result=$(query "${CONN}" \
            "SELECT COUNT(*) FROM supabase_migrations.schema_migrations WHERE version = '${version}';")
        if [ "${result}" = "1" ]; then
            echo -e "  ${PASS} ${version}"
        else
            if $STRICT_MIGRATIONS; then
                echo -e "  ${FAIL} ${version} — ${RED}NOT FOUND${NC}"
                project_failures=$((project_failures + 1))
            else
                echo -e "  ${WARN} ${version} — ${YELLOW}NOT FOUND (ignored)${NC}"
            fi
        fi
    done

    # ── 2. hardware_inventory columns ─────────────────────────────────────────
    echo -e "\n  ${BOLD}hardware_inventory columns${NC}"
    for col in "${EXPECTED_HW_COLUMNS[@]}"; do
        result=$(query "${CONN}" \
            "SELECT COUNT(*) FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = 'hardware_inventory'
               AND column_name  = '${col}';")
        if [ "${result}" = "1" ]; then
            echo -e "  ${PASS} ${col}"
        else
            echo -e "  ${FAIL} ${col} — ${RED}MISSING${NC}"
            project_failures=$((project_failures + 1))
        fi
    done

    # ── 3. org_profile columns ───────────────────────────────────────────────
    echo -e "\n  ${BOLD}org_profile columns${NC}"
    for col in "${EXPECTED_ORG_COLUMNS[@]}"; do
        result=$(query "${CONN}" \
            "SELECT COUNT(*) FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = 'org_profile'
               AND column_name  = '${col}';")
        if [ "${result}" = "1" ]; then
            echo -e "  ${PASS} ${col}"
        else
            echo -e "  ${FAIL} ${col} — ${RED}MISSING${NC}"
            project_failures=$((project_failures + 1))
        fi
    done

    # ── 4. Vault RPC helpers ─────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Vault RPC helpers${NC}"
    for fn in "${EXPECTED_RPCS[@]}"; do
        result=$(query "${CONN}" \
            "SELECT COUNT(*) FROM information_schema.routines
             WHERE routine_schema = 'public'
               AND routine_name   = '${fn}';")
        if [ "${result}" = "1" ]; then
            echo -e "  ${PASS} public.${fn}()"
        else
            echo -e "  ${FAIL} public.${fn}() — ${RED}MISSING${NC}"
            project_failures=$((project_failures + 1))
        fi
    done

    # ── 5. Cron job ───────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Cron job${NC}"
    cron_result=$(query "${CONN}" \
        "SELECT schedule FROM cron.job WHERE jobname = 'device-sync-nightly';")
    if [ -n "${cron_result}" ]; then
        echo -e "  ${PASS} device-sync-nightly (${cron_result})"
    else
        echo -e "  ${FAIL} device-sync-nightly — ${RED}NOT REGISTERED${NC}"
        echo -e "       ${YELLOW}Run: ./setup-cron-jobs.sh ${PROJECT_REF}${NC}"
        project_failures=$((project_failures + 1))
    fi

    # ── Project result ───────────────────────────────────────────────────────
    echo ""
    if [ "${project_failures}" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}All blocking checks passed${NC}"
        PASSED+=("${DISPLAY}")
    else
        echo -e "  ${RED}${BOLD}${project_failures} blocking check(s) failed${NC}"
        FAILED+=("${DISPLAY}")
    fi
done

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  Summary${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"

if [ ${#PASSED[@]} -gt 0 ]; then
    echo -e "${GREEN}  ✓ Passed (${#PASSED[@]}):${NC}"
    for p in "${PASSED[@]}"; do echo -e "${GREEN}    • ${p}${NC}"; done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}  ✗ Failed (${#FAILED[@]}):${NC}"
    for f in "${FAILED[@]}"; do echo -e "${RED}    • ${f}${NC}"; done
    echo ""
    exit 1
fi

echo ""
exit 0
