#!/bin/bash
# Validate that the username→email schema refactor has been applied correctly.
# Runs checks DB-01 to DB-05 from learn/docs/test-plan-username-email-refactor.md.
#
# Usage:
#   ./check-schema.sh [--dev|--staging|<project-ref>]
#
# Authentication:
#   Set PGPASSWORD env var before running, or enter it when prompted.
#   e.g.  PGPASSWORD=xxx ./check-schema.sh --dev

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONF="${SCRIPT_DIR}/../../learn/secrets/projects.conf"
if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}"
    exit 1
fi
source "${PROJECTS_CONF}"

if [ $# -eq 0 ]; then
    echo "Usage: ./check-schema.sh [--dev|--staging|<project-ref>]"
    echo "  --dev       Validate dev project (${DEV_REF})"
    echo "  --staging   Validate staging project (${STAGING_REF})"
    exit 1
fi

case "$1" in
    --dev)     PROJECT_REF="${DEV_REF}" ;;
    --staging) PROJECT_REF="${STAGING_REF}" ;;
    *)         PROJECT_REF="$1" ;;
esac

REGION="${SUPABASE_REGION:-ap-southeast-1}"
CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

if [ -z "$PGPASSWORD" ]; then
    echo -e "${YELLOW}PGPASSWORD not set. Enter DB password for project ${PROJECT_REF}:${NC}"
    read -s PGPASSWORD
    export PGPASSWORD
    echo ""
fi

run_query() {
    psql "${CONNECTION_STRING}" -t -A -c "$1" 2>/dev/null || echo "ERROR"
}

column_exists() {
    local result=$(run_query "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${1}' AND column_name='${2}');")
    [ "$result" = "t" ]
}

PASS=0
FAIL=0

check() {
    local id="$1" description="$2" query="$3" expected="$4"
    local result
    result=$(run_query "$query" | tr -d '[:space:]')
    if [ "$result" = "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} ${id}: ${description}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} ${id}: ${description}"
        echo -e "      Expected: ${BOLD}${expected}${NC}"
        echo -e "      Got:      ${BOLD}${result:-<empty>}${NC}"
        FAIL=$((FAIL + 1))
    fi
}

check_contains() {
    local id="$1" description="$2" query="$3" must_contain="$4" must_not_contain="$5"
    local result ok=true
    result=$(run_query "$query")
    [ -n "$must_contain" ]     && ! echo "$result" | grep -q "$must_contain"     && ok=false
    [ -n "$must_not_contain" ] &&   echo "$result" | grep -q "$must_not_contain" && ok=false
    if $ok; then
        echo -e "  ${GREEN}✓${NC} ${id}: ${description}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} ${id}: ${description}"
        [ -n "$must_contain" ]     && echo -e "      Must contain:     ${BOLD}${must_contain}${NC}"
        [ -n "$must_not_contain" ] && echo -e "      Must NOT contain: ${BOLD}${must_not_contain}${NC}"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo -e "${BOLD}Schema validation — project: ${PROJECT_REF}${NC}"
echo "────────────────────────────────────────────────────"

echo ""
echo -e "${CYAN}1. Column renames${NC}"

check "DB-01" \
    "profiles.email exists, profiles.username does not" \
    "SELECT string_agg(column_name,',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name IN ('username','email')" \
    "email"

check "DB-02" \
    "account_inventory.email exists, account_inventory.username_email does not" \
    "SELECT string_agg(column_name,',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='account_inventory' AND column_name IN ('username_email','email')" \
    "email"

echo ""
echo -e "${CYAN}2. Indexes${NC}"

check "DB-03" \
    "profiles_email_key unique index exists" \
    "SELECT COUNT(*) FROM pg_indexes WHERE tablename='profiles' AND indexname='profiles_email_key'" \
    "1"

echo ""
echo -e "${CYAN}3. Enum values${NC}"

check "DB-04" \
    "app_role enum contains all lowercase values" \
    "SELECT string_agg(enumlabel,',' ORDER BY enumlabel) FROM pg_enum JOIN pg_type ON pg_enum.enumtypid=pg_type.oid WHERE pg_type.typname='app_role'" \
    "admin,author,client_admin,manager,super_admin,user"

echo ""
echo -e "${CYAN}4. handle_new_user trigger${NC}"

check_contains "DB-05a" \
    "handle_new_user inserts into email column, not username" \
    "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='handle_new_user'" \
    "email" ""

check_contains "DB-05b" \
    "handle_new_user assigns lowercase 'author' enum value (not 'Author')" \
    "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='handle_new_user'" \
    "assigned_role := 'author'" "assigned_role := 'Author'"

echo ""
echo "────────────────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All ${TOTAL} checks passed.${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}${FAIL} of ${TOTAL} checks failed.${NC}"
    exit 1
fi
echo ""
