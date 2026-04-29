#!/bin/bash
# Migration Validation Script
# Compares two Supabase project databases to ensure schema completeness
# (tables, functions, triggers, RLS policies, indexes, constraints).
#
# Usage:
#   ./validate-migration.sh <source> <target>
#
# Source and target can be named shortcuts or raw project refs:
#   --dev           Dev project
#   --staging       Staging project
#   --all-production  (not valid here — requires exactly two targets)
#   <project-ref>   Any raw 20-char Supabase project ref
#
# Examples:
#   ./validate-migration.sh --dev --staging
#   ./validate-migration.sh --staging omnihealth-prod
#   ./validate-migration.sh cleqfnrbiqpxpzxkatda xndppktxfaetwvffytxv
#
# PGPASSWORD must be set in the environment (or in deploy/.env.local).

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

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"
REGION="${REGION:-ap-southeast-1}"

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

# ── Load env ──────────────────────────────────────────────────────────────────
if [ -f "${SCRIPT_DIR}/../.env.local" ]; then
    source "${SCRIPT_DIR}/../.env.local"
elif [ -f "${SCRIPT_DIR}/../.env" ]; then
    source "${SCRIPT_DIR}/../.env"
fi

if [ -z "${PGPASSWORD:-}" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set${NC}"
    echo "Export it before running: export PGPASSWORD=<your-db-password>"
    exit 1
fi

# ── Args ──────────────────────────────────────────────────────────────────────
if [ $# -ne 2 ]; then
    echo -e "${RED}Error: exactly two project targets are required${NC}"
    echo ""
    echo "Usage: $0 <source> <target>"
    echo ""
    echo "  source / target can be:"
    echo "    --dev            Dev project     (${DEV_REF})"
    echo "    --staging        Staging project (${STAGING_REF})"
    echo "    --master         Master project  (${MASTER_REF})"
    echo "    <project-ref>    Raw 20-char Supabase project ref"
    echo "    <project-name>   Project name as shown in 'supabase projects list'"
    echo ""
    echo "Examples:"
    echo "  $0 --dev --staging"
    echo "  $0 --staging xndppktxfaetwvffytxv"
    echo "  $0 ${DEV_REF} ${STAGING_REF}"
    exit 1
fi

# ── Resolve named shortcuts → refs ────────────────────────────────────────────
resolve_ref() {
    local input="$1"
    case "$input" in
        --dev)     echo "$DEV_REF"; return ;;
        --staging) echo "$STAGING_REF"; return ;;
        --master)  echo "$MASTER_REF"; return ;;
    esac
    # Raw 20-char ref
    if [[ "$input" =~ ^[a-z0-9]{20}$ ]]; then
        echo "$input"; return
    fi
    # Project name lookup via CLI
    local ref
    ref=$(supabase projects list --output json 2>/dev/null \
        | jq -r --arg name "$input" '.[] | select(.name == $name) | .id' | head -1)
    if [ -z "$ref" ]; then
        echo -e "${RED}Error: No project found matching \"${input}\"${NC}" >&2
        echo -e "${YELLOW}Tip: Run 'supabase projects list' to see available names and refs.${NC}" >&2
        exit 1
    fi
    echo "$ref"
}

SOURCE_REF=$(resolve_ref "$1")
TARGET_REF=$(resolve_ref "$2")

# ── Human-readable labels ─────────────────────────────────────────────────────
label_for_ref() {
    local ref="$1"
    local name
    name=$(supabase projects list --output json 2>/dev/null \
        | jq -r --arg ref "$ref" '.[] | select(.id == $ref) | .name' 2>/dev/null | head -1 || true)
    if [ -n "$name" ]; then echo "${name} (${ref})"; else echo "${ref}"; fi
}

SOURCE_LABEL=$(label_for_ref "$SOURCE_REF")
TARGET_LABEL=$(label_for_ref "$TARGET_REF")

# ── Connection helper (matches run-migrations.sh pattern) ─────────────────────
conn_for_ref() {
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

SOURCE_CONN=$(conn_for_ref "$SOURCE_REF")
TARGET_CONN=$(conn_for_ref "$TARGET_REF")

# ── SQL helper ────────────────────────────────────────────────────────────────
query() {
    local conn="$1"
    local sql="$2"
    psql "${conn}" -tAq -c "${sql}" 2>/dev/null | tr -d '[:space:]' || echo "0"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  validate-migration.sh${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "  Source : ${SOURCE_LABEL}"
echo -e "  Target : ${TARGET_LABEL}"
echo ""

FAILURES=0

# ── Helpers ───────────────────────────────────────────────────────────────────

# Compare a scalar count; increments FAILURES if they differ.
check_count() {
    local label="$1"
    local sql="$2"
    local src_count target_count
    src_count=$(query  "$SOURCE_CONN" "$sql")
    target_count=$(query "$TARGET_CONN" "$sql")
    if [ "$src_count" = "$target_count" ]; then
        echo -e "  ${PASS} ${label}: ${src_count}"
    else
        echo -e "  ${FAIL} ${label}: source=${src_count}  target=${target_count}"
        FAILURES=$((FAILURES + 1))
    fi
}

# Fetch a sorted list of values from one connection.
list_values() {
    local conn="$1"
    local sql="$2"
    psql "${conn}" -tAq -c "${sql}" 2>/dev/null | grep -v '^$' | sort || true
}

# Print items that exist in one list but not the other.
diff_lists() {
    local src_list="$1"
    local tgt_list="$2"
    local only_src only_tgt
    only_src=$(comm -23 <(echo "$src_list") <(echo "$tgt_list") | grep -v '^$' || true)
    only_tgt=$(comm -13 <(echo "$src_list") <(echo "$tgt_list") | grep -v '^$' || true)
    if [ -n "$only_src" ]; then
        echo -e "    ${YELLOW}in source only:${NC}"
        echo "$only_src" | while IFS= read -r item; do echo "      - $item"; done
    fi
    if [ -n "$only_tgt" ]; then
        echo -e "    ${YELLOW}in target only:${NC}"
        echo "$only_tgt" | while IFS= read -r item; do echo "      - $item"; done
    fi
}

# ── 1. Tables ─────────────────────────────────────────────────────────────────
echo -e "  ${BOLD}Tables (public)${NC}"
check_count "count" \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema = 'public' AND table_type = 'BASE TABLE';"

diff_lists \
    "$(list_values "$SOURCE_CONN" \
        "SELECT table_name FROM information_schema.tables
         WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;")" \
    "$(list_values "$TARGET_CONN" \
        "SELECT table_name FROM information_schema.tables
         WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;")"

# ── 2. Functions ──────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Functions (public)${NC}"
check_count "count" \
    "SELECT COUNT(*) FROM information_schema.routines
     WHERE routine_schema = 'public' AND routine_type = 'FUNCTION';"

diff_lists \
    "$(list_values "$SOURCE_CONN" \
        "SELECT routine_name FROM information_schema.routines
         WHERE routine_schema='public' AND routine_type='FUNCTION' ORDER BY 1;")" \
    "$(list_values "$TARGET_CONN" \
        "SELECT routine_name FROM information_schema.routines
         WHERE routine_schema='public' AND routine_type='FUNCTION' ORDER BY 1;")"

# ── 3. Triggers ───────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Triggers (public + auth)${NC}"
check_count "count" \
    "SELECT COUNT(*) FROM information_schema.triggers
     WHERE trigger_schema IN ('public','auth');"

diff_lists \
    "$(list_values "$SOURCE_CONN" \
        "SELECT event_object_table || '.' || trigger_name
         FROM information_schema.triggers
         WHERE trigger_schema IN ('public','auth') ORDER BY 1;")" \
    "$(list_values "$TARGET_CONN" \
        "SELECT event_object_table || '.' || trigger_name
         FROM information_schema.triggers
         WHERE trigger_schema IN ('public','auth') ORDER BY 1;")"

# ── 4. RLS Policies ───────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}RLS Policies (public)${NC}"
check_count "count" \
    "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';"

diff_lists \
    "$(list_values "$SOURCE_CONN" \
        "SELECT tablename || '.' || policyname
         FROM pg_policies WHERE schemaname='public' ORDER BY 1;")" \
    "$(list_values "$TARGET_CONN" \
        "SELECT tablename || '.' || policyname
         FROM pg_policies WHERE schemaname='public' ORDER BY 1;")"

# ── 5. Indexes ────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Indexes (public)${NC}"
check_count "count" \
    "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';"

diff_lists \
    "$(list_values "$SOURCE_CONN" \
        "SELECT tablename || '.' || indexname
         FROM pg_indexes WHERE schemaname='public' ORDER BY 1;")" \
    "$(list_values "$TARGET_CONN" \
        "SELECT tablename || '.' || indexname
         FROM pg_indexes WHERE schemaname='public' ORDER BY 1;")"

# ── 6. Constraints (named only — OID-auto-named NOT NULL constraints excluded) ─
# Postgres auto-names NOT NULL constraints as <oid>_<oid>_<n>_not_null; these
# names differ between databases even when the constraints are identical.
# Filtering them removes hundreds of false positives and surfaces only
# meaningful named constraints (PKs, FKs, UNIQUEs, CHECKs, etc.).
echo ""
echo -e "  ${BOLD}Constraints — named only (public)${NC}"
_constraints_sql="SELECT table_name || '.' || constraint_name
     FROM information_schema.table_constraints
     WHERE constraint_schema = 'public'
       AND constraint_name !~ '^\d+_\d+_\d+_not_null$'
     ORDER BY 1;"
check_count "count" \
    "SELECT COUNT(*) FROM information_schema.table_constraints
     WHERE constraint_schema = 'public'
       AND constraint_name !~ '^\d+_\d+_\d+_not_null$';"

diff_lists \
    "$(list_values "$SOURCE_CONN" "$_constraints_sql")" \
    "$(list_values "$TARGET_CONN" "$_constraints_sql")"

# ── 7. schema_migrations status ───────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}schema_migrations tracking${NC}"
SRC_MIGS=$(query "$SOURCE_CONN" \
    "SELECT COUNT(*) FROM supabase_migrations.schema_migrations;" 2>/dev/null || echo "?")
TGT_MIGS=$(query "$TARGET_CONN" \
    "SELECT COUNT(*) FROM supabase_migrations.schema_migrations;" 2>/dev/null || echo "?")

if [ "$SRC_MIGS" = "?" ]; then
    echo -e "  ${YELLOW}⚠ source: schema_migrations table does not exist${NC}"
elif [ "$TGT_MIGS" = "?" ]; then
    echo -e "  ${YELLOW}⚠ target: schema_migrations table does not exist${NC}"
elif [ "$SRC_MIGS" = "$TGT_MIGS" ]; then
    echo -e "  ${PASS} tracked migrations: ${SRC_MIGS}"
else
    echo -e "  ${YELLOW}⚠ tracked migration count differs: source=${SRC_MIGS}  target=${TGT_MIGS}${NC}"
    echo -e "  ${YELLOW}  (this may be expected if backfill is still pending on target)${NC}"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
if [ "${FAILURES}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  All schema checks passed${NC}"
else
    echo -e "${RED}${BOLD}  ${FAILURES} check(s) failed — target schema differs from source${NC}"
    exit 1
fi
echo ""
