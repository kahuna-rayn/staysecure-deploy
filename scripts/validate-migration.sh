#!/bin/bash
# Migration Validation Script
# Compares two Supabase project databases for schema parity plus checks that
# mirror onboard-client.sh post-restore verification. Primary output is the same
# ASCII table as onboard-client.sh (then constraint diffs + schema_migrations notes).
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
        --dev)        echo "$DEV_REF"; return ;;
        --staging)    echo "$STAGING_REF"; return ;;
        --master)     echo "$MASTER_REF"; return ;;
        --*)
            local var_name
            var_name="$(echo "${input#--}" | tr '[:lower:]-' '[:upper:]_')_REF"
            local ref="${!var_name}"
            if [ -n "$ref" ]; then echo "$ref"; return; fi
            ;;
    esac
    if [[ "$input" =~ ^[a-z0-9]{20}$ ]]; then
        echo "$input"; return
    fi
    # Try bare name as a projects.conf lookup (e.g. "lentor" → LENTOR_REF) before hitting the API
    local var_name
    var_name="$(echo "$input" | tr '[:lower:]-' '[:upper:]_')_REF"
    local conf_ref="${!var_name:-}"
    if [ -n "$conf_ref" ]; then echo "$conf_ref"; return; fi
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

# Short labels for column headers (strip --, truncate raw refs)
SOURCE_SHORT="${1#--}"
TARGET_SHORT="${2#--}"
[[ "${SOURCE_SHORT}" =~ ^[a-z0-9]{20}$ ]] && SOURCE_SHORT="${SOURCE_SHORT:0:8}.."
[[ "${TARGET_SHORT}" =~ ^[a-z0-9]{20}$ ]] && TARGET_SHORT="${TARGET_SHORT:0:8}.."

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

# ── SQL helpers ───────────────────────────────────────────────────────────────
query() {
    local conn="$1"
    local sql="$2"
    psql "${conn}" -tAq -c "${sql}" 2>/dev/null | tr -d '[:space:]' || echo ""
}

query_raw() {
    local conn="$1"
    local sql="$2"
    psql "${conn}" -tAq -c "${sql}" 2>/dev/null | head -1 | tr -d '[:space:]' || echo ""
}

list_values() {
    local conn="$1"
    local sql="$2"
    psql "${conn}" -tAq -c "${sql}" 2>/dev/null | grep -v '^$' | sort || true
}

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

_SQL_TRIG_PUBL='SELECT COUNT(*) FROM pg_trigger t
     JOIN pg_class c ON t.tgrelid = c.oid
     JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE n.nspname = '"'"'public'"'"' AND NOT t.tgisinternal;'

_SQL_TRIG_AUTH='SELECT COUNT(*) FROM pg_trigger t
     JOIN pg_class c ON t.tgrelid = c.oid
     JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE n.nspname = '"'"'auth'"'"';'

_SQL_STORAGE_POLICIES_LIST="SELECT tablename || '.' || policyname FROM pg_policies WHERE schemaname='storage' ORDER BY 1;"

_SQL_TABLES_LIST="SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;"
_SQL_POLICIES_LIST="SELECT tablename || '.' || policyname FROM pg_policies WHERE schemaname='public' ORDER BY 1;"
_SQL_FUNCTIONS_LIST="SELECT proname || '(' || pg_get_function_identity_arguments(oid) || ')' FROM pg_proc WHERE pronamespace='public'::regnamespace ORDER BY 1;"
_SQL_TRIGGERS_LIST="SELECT c.relname || '.' || t.tgname FROM pg_trigger t JOIN pg_class c ON t.tgrelid=c.oid JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname='public' AND NOT t.tgisinternal ORDER BY 1;"
_SQL_INDEXES_LIST="SELECT tablename || '.' || indexname FROM pg_indexes WHERE schemaname='public' ORDER BY 1;"
_SQL_VIEWS_LIST="SELECT table_name FROM information_schema.views WHERE table_schema='public' ORDER BY 1;"
_SQL_TYPES_LIST="SELECT typname FROM pg_type WHERE typnamespace='public'::regnamespace AND typtype='c' ORDER BY 1;"
_SQL_AUTH_TRIGGERS_LIST="SELECT c.relname || '.' || t.tgname FROM pg_trigger t JOIN pg_class c ON t.tgrelid=c.oid JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname='auth' ORDER BY 1;"

_SQL_BUCKETS_CANONICAL="SELECT COUNT(*) FROM storage.buckets WHERE id IN ('avatars','documents','certificates','logos','lesson-media');"

_constraints_sql="SELECT table_name || '.' || constraint_name
     FROM information_schema.table_constraints
     WHERE constraint_schema = 'public'
       AND constraint_name !~ '^\d+_\d+_\d+_not_null$'
     ORDER BY 1;"

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  validate-migration.sh${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "  Source : ${SOURCE_LABEL}"
echo -e "  Target : ${TARGET_LABEL}"
echo ""

FAILURES=0

# ── Collect counts (queries aligned with onboard-client.sh) ───────────────────
SOURCE_TABLES=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")
TARGET_TABLES=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")
[ -z "$SOURCE_TABLES" ] && SOURCE_TABLES="?"
[ -z "$TARGET_TABLES" ] && TARGET_TABLES="?"

SOURCE_POLICIES=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';")
TARGET_POLICIES=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public';")
[ -z "$SOURCE_POLICIES" ] && SOURCE_POLICIES="?"
[ -z "$TARGET_POLICIES" ] && TARGET_POLICIES="?"

SOURCE_FUNCTIONS=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace;")
TARGET_FUNCTIONS=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace;")
[ -z "$SOURCE_FUNCTIONS" ] && SOURCE_FUNCTIONS="?"
[ -z "$TARGET_FUNCTIONS" ] && TARGET_FUNCTIONS="?"

SOURCE_TRIGGERS=$(query "$SOURCE_CONN" "$_SQL_TRIG_PUBL")
TARGET_TRIGGERS=$(query "$TARGET_CONN" "$_SQL_TRIG_PUBL")
[ -z "$SOURCE_TRIGGERS" ] && SOURCE_TRIGGERS="?"
[ -z "$TARGET_TRIGGERS" ] && TARGET_TRIGGERS="?"

SOURCE_INDEXES=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';")
TARGET_INDEXES=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public';")
[ -z "$SOURCE_INDEXES" ] && SOURCE_INDEXES="?"
[ -z "$TARGET_INDEXES" ] && TARGET_INDEXES="?"

SOURCE_VIEWS=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'public';")
TARGET_VIEWS=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'public';")
[ -z "$SOURCE_VIEWS" ] && SOURCE_VIEWS="?"
[ -z "$TARGET_VIEWS" ] && TARGET_VIEWS="?"

SOURCE_TYPES=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype = 'c';")
TARGET_TYPES=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype = 'c';")
[ -z "$SOURCE_TYPES" ] && SOURCE_TYPES="?"
[ -z "$TARGET_TYPES" ] && TARGET_TYPES="?"

SOURCE_STORAGE_POLICIES=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage';")
TARGET_STORAGE_POLICIES=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'storage';")
[ -z "$SOURCE_STORAGE_POLICIES" ] && SOURCE_STORAGE_POLICIES="?"
[ -z "$TARGET_STORAGE_POLICIES" ] && TARGET_STORAGE_POLICIES="?"

SOURCE_AUTH_TRIGGERS=$(query "$SOURCE_CONN" "$_SQL_TRIG_AUTH")
TARGET_AUTH_TRIGGERS=$(query "$TARGET_CONN" "$_SQL_TRIG_AUTH")
[ -z "$SOURCE_AUTH_TRIGGERS" ] && SOURCE_AUTH_TRIGGERS="?"
[ -z "$TARGET_AUTH_TRIGGERS" ] && TARGET_AUTH_TRIGGERS="?"

_src_au_raw=$(query_raw "$SOURCE_CONN" "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');")
_tgt_au_raw=$(query_raw "$TARGET_CONN" "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created');")
[ "$_src_au_raw" = "t" ] && SOURCE_AUTH_USER_TRIGGER="Yes" || SOURCE_AUTH_USER_TRIGGER="No"
[ "$_tgt_au_raw" = "t" ] && TARGET_AUTH_USER_TRIGGER="Yes" || TARGET_AUTH_USER_TRIGGER="No"

EXPECTED_BUCKETS_COUNT=4
SOURCE_STORAGE_BUCKETS=$(query "$SOURCE_CONN" "$_SQL_BUCKETS_CANONICAL")
TARGET_STORAGE_BUCKETS=$(query "$TARGET_CONN" "$_SQL_BUCKETS_CANONICAL")
[ -z "$SOURCE_STORAGE_BUCKETS" ] && SOURCE_STORAGE_BUCKETS="?"
[ -z "$TARGET_STORAGE_BUCKETS" ] && TARGET_STORAGE_BUCKETS="?"

# Edge functions + secrets (Supabase CLI)
EXPECTED_FUNCTIONS=()
TARGET_MISSING_FUNCTIONS=()
TARGET_MISSING_SECRETS=()
SOURCE_EDGE_FUNCTIONS="?"
TARGET_EDGE_FUNCTIONS="?"
SOURCE_EDGE_SECRETS="?"
TARGET_EDGE_SECRETS="?"
CLI_SKIPPED=true
EXPECTED_SECRET_COUNT=0
EXPECTED_SECRETS=()

if command -v supabase >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    CLI_SKIPPED=false
    DEPLOY_FN="${SCRIPT_DIR}/deploy-functions.sh"
    if [ -f "${DEPLOY_FN}" ]; then
        while IFS= read -r line || [ -n "${line:-}" ]; do
            [ -n "$line" ] && EXPECTED_FUNCTIONS+=("$line")
        done < <(bash "${DEPLOY_FN}" --list 2>/dev/null || true)
    fi

    _src_fl=$(supabase functions list --project-ref "${SOURCE_REF}" --output json 2>/dev/null | jq -r '.[].slug' 2>/dev/null || true)
    _tgt_fl=$(supabase functions list --project-ref "${TARGET_REF}" --output json 2>/dev/null | jq -r '.[].slug' 2>/dev/null || true)

    SOURCE_EDGE_FUNCTIONS=0
    TARGET_EDGE_FUNCTIONS=0
    for _fn in "${EXPECTED_FUNCTIONS[@]}"; do
        echo "$_src_fl" | grep -qx "${_fn}" && SOURCE_EDGE_FUNCTIONS=$((SOURCE_EDGE_FUNCTIONS + 1))
        if echo "$_tgt_fl" | grep -qx "${_fn}"; then
            TARGET_EDGE_FUNCTIONS=$((TARGET_EDGE_FUNCTIONS + 1))
        else
            TARGET_MISSING_FUNCTIONS+=("$_fn")
        fi
    done

    _src_sl=$(supabase secrets list --project-ref "${SOURCE_REF}" --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
    _tgt_sl=$(supabase secrets list --project-ref "${TARGET_REF}" --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)

    # Supabase auto-injects these into every project — they're never user-set and
    # will always appear as "missing" on a fresh project. Exclude them from the diff.
    _SUPABASE_DEFAULT_SECRETS="SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY SUPABASE_DB_URL SUPABASE_PUBLISHABLE_KEYS SUPABASE_SECRET_KEYS SUPABASE_JWKS AWS_REGION"

    # Derive expected secrets from source — any secret present on source must be on target.
    EXPECTED_SECRETS=()
    while IFS= read -r _sn; do
        [ -z "$_sn" ] && continue
        # Skip Supabase default secrets
        _skip=false
        for _d in $_SUPABASE_DEFAULT_SECRETS; do
            [ "$_sn" = "$_d" ] && _skip=true && break
        done
        [ "$_skip" = false ] && EXPECTED_SECRETS+=("$_sn")
    done <<< "$_src_sl"
    EXPECTED_SECRET_COUNT=${#EXPECTED_SECRETS[@]}

    TARGET_MISSING_SECRETS=()
    SOURCE_EDGE_SECRETS=${#EXPECTED_SECRETS[@]}
    TARGET_EDGE_SECRETS=0
    for _sn in "${EXPECTED_SECRETS[@]}"; do
        if echo "$_tgt_sl" | grep -qx "${_sn}"; then
            TARGET_EDGE_SECRETS=$((TARGET_EDGE_SECRETS + 1))
        else
            TARGET_MISSING_SECRETS+=("$_sn")
        fi
    done
fi

EXPECTED_FUNCTION_COUNT=${#EXPECTED_FUNCTIONS[@]}

# ── Comparison table (same layout / order as onboard-client.sh) ────────────────
echo ""
echo "┌─────────────────────────┬──────────────────┬──────────────┬─────────┐"
printf "│ %-23s │ %-16s │ %-12s │ Status  │\n" "Object Type" "Source (${SOURCE_SHORT})" "Target (${TARGET_SHORT})"
echo "├─────────────────────────┼──────────────────┼──────────────┼─────────┤"

# Tables
printf "│ %-23s │ %16s │ %12s │" "Tables" "$SOURCE_TABLES" "$TARGET_TABLES"
if [ "$SOURCE_TABLES" = "$TARGET_TABLES" ] && [ "$SOURCE_TABLES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Policies (public)
printf "│ %-23s │ %16s │ %12s │" "Policies" "$SOURCE_POLICIES" "$TARGET_POLICIES"
if [ "$SOURCE_POLICIES" = "$TARGET_POLICIES" ] && [ "$SOURCE_POLICIES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Functions
printf "│ %-23s │ %16s │ %12s │" "Functions" "$SOURCE_FUNCTIONS" "$TARGET_FUNCTIONS"
if [ "$SOURCE_FUNCTIONS" = "$TARGET_FUNCTIONS" ] && [ "$SOURCE_FUNCTIONS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Triggers (public, non-internal)
printf "│ %-23s │ %16s │ %12s │" "Triggers" "$SOURCE_TRIGGERS" "$TARGET_TRIGGERS"
if [ "$SOURCE_TRIGGERS" = "$TARGET_TRIGGERS" ] && [ "$SOURCE_TRIGGERS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Indexes
printf "│ %-23s │ %16s │ %12s │" "Indexes" "$SOURCE_INDEXES" "$TARGET_INDEXES"
if [ "$SOURCE_INDEXES" = "$TARGET_INDEXES" ] && [ "$SOURCE_INDEXES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Views
printf "│ %-23s │ %16s │ %12s │" "Views" "$SOURCE_VIEWS" "$TARGET_VIEWS"
if [ "$SOURCE_VIEWS" = "$TARGET_VIEWS" ] && [ "$SOURCE_VIEWS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Types
printf "│ %-23s │ %16s │ %12s │" "Types" "$SOURCE_TYPES" "$TARGET_TYPES"
if [ "$SOURCE_TYPES" = "$TARGET_TYPES" ] && [ "$SOURCE_TYPES" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Storage policies (target >= source — same rule as onboard-client.sh)
printf "│ %-23s │ %16s │ %12s │" "Storage Policies" "$SOURCE_STORAGE_POLICIES" "$TARGET_STORAGE_POLICIES"
if [ "$SOURCE_STORAGE_POLICIES" != "?" ] && [ "$TARGET_STORAGE_POLICIES" != "?" ] && \
    [ "$TARGET_STORAGE_POLICIES" -ge "$SOURCE_STORAGE_POLICIES" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Auth triggers
printf "│ %-23s │ %16s │ %12s │" "Auth Triggers" "$SOURCE_AUTH_TRIGGERS" "$TARGET_AUTH_TRIGGERS"
if [ "$SOURCE_AUTH_TRIGGERS" = "$TARGET_AUTH_TRIGGERS" ] && [ "$SOURCE_AUTH_TRIGGERS" != "?" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# on_auth_user_created — same pass rule as onboard-client.sh (target must be Yes)
printf "│ %-23s │ %16s │ %12s │" "on_auth_user_created ⚠" "$SOURCE_AUTH_USER_TRIGGER" "$TARGET_AUTH_USER_TRIGGER"
if [ "$TARGET_AUTH_USER_TRIGGER" = "Yes" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

# Edge functions
if $CLI_SKIPPED; then
    printf "│ %-23s │ %16s │ %12s │" "Edge Functions" "—" "—"
    echo -e " ${YELLOW}—${NC}     │"
else
    printf "│ %-23s │ %16s │ %12s │" "Edge Functions" "$SOURCE_EDGE_FUNCTIONS" "$TARGET_EDGE_FUNCTIONS"
    if [ "${EXPECTED_FUNCTION_COUNT}" -gt 0 ] && [ ${#TARGET_MISSING_FUNCTIONS[@]} -eq 0 ]; then
        echo -e " ${GREEN}✓${NC}     │"
    else
        echo -e " ${RED}✗${NC}     │"
        FAILURES=$((FAILURES + 1))
    fi
fi

# Edge secrets
if $CLI_SKIPPED; then
    printf "│ %-23s │ %16s │ %12s │" "Edge Function Secrets" "—" "—"
    echo -e " ${YELLOW}—${NC}     │"
else
    printf "│ %-23s │ %16s │ %12s │" "Edge Function Secrets" "$SOURCE_EDGE_SECRETS" "$TARGET_EDGE_SECRETS"
    if [ "$TARGET_EDGE_SECRETS" != "?" ] && [ "$EXPECTED_SECRET_COUNT" -gt 0 ] && \
        [ "$TARGET_EDGE_SECRETS" -eq "$EXPECTED_SECRET_COUNT" ]; then
        echo -e " ${GREEN}✓${NC}     │"
    else
        echo -e " ${RED}✗${NC}     │"
        FAILURES=$((FAILURES + 1))
    fi
fi

# Storage buckets x/5
printf "│ %-23s │ %16s │ %12s │" "Storage Buckets" "${SOURCE_STORAGE_BUCKETS}/${EXPECTED_BUCKETS_COUNT}" "${TARGET_STORAGE_BUCKETS}/${EXPECTED_BUCKETS_COUNT}"
if [ "$TARGET_STORAGE_BUCKETS" != "?" ] && [ "$TARGET_STORAGE_BUCKETS" -eq "$EXPECTED_BUCKETS_COUNT" ]; then
    echo -e " ${GREEN}✓${NC}     │"
else
    echo -e " ${RED}✗${NC}     │"
    FAILURES=$((FAILURES + 1))
fi

echo "└─────────────────────────┴──────────────────┴──────────────┴─────────┘"
echo ""

# ── Diffs for every failing check ─────────────────────────────────────────────

_print_diff() {
    local label="$1" src_list="$2" tgt_list="$3"
    local only_src only_tgt
    only_src=$(comm -23 <(echo "$src_list") <(echo "$tgt_list") | grep -v '^$' || true)
    only_tgt=$(comm -13 <(echo "$src_list") <(echo "$tgt_list") | grep -v '^$' || true)
    if [ -n "$only_src" ] || [ -n "$only_tgt" ]; then
        echo -e "  ${BOLD}${label}${NC}"
        if [ -n "$only_src" ]; then
            echo -e "    ${YELLOW}in source only:${NC}"
            echo "$only_src" | while IFS= read -r item; do echo "      - $item"; done
        fi
        if [ -n "$only_tgt" ]; then
            echo -e "    ${YELLOW}in target only:${NC}"
            echo "$only_tgt" | while IFS= read -r item; do echo "      - $item"; done
        fi
        echo ""
    fi
}

if [ "$SOURCE_TABLES" != "$TARGET_TABLES" ]; then
    _print_diff "Tables" \
        "$(list_values "$SOURCE_CONN" "$_SQL_TABLES_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_TABLES_LIST")"
fi

if [ "$SOURCE_POLICIES" != "$TARGET_POLICIES" ]; then
    _print_diff "Policies" \
        "$(list_values "$SOURCE_CONN" "$_SQL_POLICIES_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_POLICIES_LIST")"
fi

if [ "$SOURCE_FUNCTIONS" != "$TARGET_FUNCTIONS" ]; then
    _print_diff "Functions" \
        "$(list_values "$SOURCE_CONN" "$_SQL_FUNCTIONS_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_FUNCTIONS_LIST")"
fi

if [ "$SOURCE_TRIGGERS" != "$TARGET_TRIGGERS" ]; then
    _print_diff "Triggers" \
        "$(list_values "$SOURCE_CONN" "$_SQL_TRIGGERS_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_TRIGGERS_LIST")"
fi

if [ "$SOURCE_INDEXES" != "$TARGET_INDEXES" ]; then
    _print_diff "Indexes" \
        "$(list_values "$SOURCE_CONN" "$_SQL_INDEXES_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_INDEXES_LIST")"
fi

if [ "$SOURCE_VIEWS" != "$TARGET_VIEWS" ]; then
    _print_diff "Views" \
        "$(list_values "$SOURCE_CONN" "$_SQL_VIEWS_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_VIEWS_LIST")"
fi

if [ "$SOURCE_TYPES" != "$TARGET_TYPES" ]; then
    _print_diff "Types" \
        "$(list_values "$SOURCE_CONN" "$_SQL_TYPES_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_TYPES_LIST")"
fi

if [ "$SOURCE_STORAGE_POLICIES" != "$TARGET_STORAGE_POLICIES" ] && \
   [ "$TARGET_STORAGE_POLICIES" -lt "$SOURCE_STORAGE_POLICIES" ] 2>/dev/null; then
    _print_diff "Storage Policies" \
        "$(list_values "$SOURCE_CONN" "$_SQL_STORAGE_POLICIES_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_STORAGE_POLICIES_LIST")"
fi

if [ "$SOURCE_AUTH_TRIGGERS" != "$TARGET_AUTH_TRIGGERS" ]; then
    _print_diff "Auth Triggers" \
        "$(list_values "$SOURCE_CONN" "$_SQL_AUTH_TRIGGERS_LIST")" \
        "$(list_values "$TARGET_CONN" "$_SQL_AUTH_TRIGGERS_LIST")"
fi

if ! $CLI_SKIPPED && [ "$TARGET_AUTH_USER_TRIGGER" != "Yes" ]; then
    echo -e "${RED}⚠️  CRITICAL: on_auth_user_created trigger is MISSING on target${NC}"
    echo -e "${RED}  Required for automatic profile creation on sign-up.${NC}"
    echo ""
fi

if ! $CLI_SKIPPED && [ ${#TARGET_MISSING_FUNCTIONS[@]} -gt 0 ]; then
    echo -e "  ${BOLD}Edge Functions missing on target:${NC}"
    for f in "${TARGET_MISSING_FUNCTIONS[@]}"; do
        echo -e "    ${RED}✗${NC} $f"
    done
    echo ""
fi

if ! $CLI_SKIPPED && [ ${#TARGET_MISSING_SECRETS[@]} -gt 0 ]; then
    echo -e "  ${BOLD}Edge Function Secrets missing on target:${NC}"
    for s in "${TARGET_MISSING_SECRETS[@]}"; do
        echo -e "    ${RED}✗${NC} $s"
    done
    echo ""
fi

# ── Constraints (public) ───────────────────────────────────────────────────────
echo -e "  ${BOLD}Constraints — named only (public)${NC}"
SRC_CO=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM information_schema.table_constraints
     WHERE constraint_schema = 'public' AND constraint_name !~ '^\d+_\d+_\d+_not_null$';")
TGT_CO=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM information_schema.table_constraints
     WHERE constraint_schema = 'public' AND constraint_name !~ '^\d+_\d+_\d+_not_null$';")
if [ "$SRC_CO" = "$TGT_CO" ] && [ -n "$SRC_CO" ]; then
    echo -e "  ${PASS} count: ${SRC_CO}"
else
    echo -e "  ${FAIL} count: source=${SRC_CO}  target=${TGT_CO}"
    FAILURES=$((FAILURES + 1))
fi
diff_lists \
    "$(list_values "$SOURCE_CONN" "$_constraints_sql")" \
    "$(list_values "$TARGET_CONN" "$_constraints_sql")"
echo ""

# ── schema_migrations (informational) ──────────────────────────────────────────
if $CLI_SKIPPED; then
    echo -e "  ${YELLOW}⚠ Edge functions/secrets rows skipped — install \`supabase\` and \`jq\`, re-run for those checks.${NC}"
    echo ""
fi

echo -e "  ${BOLD}schema_migrations tracking${NC} ${BOLD}(informational — not scored above)${NC}"
echo -e "    Table ${BOLD}supabase_migrations.schema_migrations${NC} records which migration"
echo -e "    files were applied by ${BOLD}supabase db push${NC} / ${BOLD}run-migrations.sh${NC}; it is not DDL."
echo -e "    Target count ${BOLD}0${NC} is common after ${BOLD}pg_restore${NC} until repair / migrations run."
echo ""

SRC_MIGS=$(query "$SOURCE_CONN" "SELECT COUNT(*) FROM supabase_migrations.schema_migrations;")
TGT_MIGS=$(query "$TARGET_CONN" "SELECT COUNT(*) FROM supabase_migrations.schema_migrations;")

if ! psql "${SOURCE_CONN}" -tAq -c "SELECT 1 FROM supabase_migrations.schema_migrations LIMIT 1;" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠ source: cannot read supabase_migrations.schema_migrations${NC}"
elif ! psql "${TARGET_CONN}" -tAq -c "SELECT 1 FROM supabase_migrations.schema_migrations LIMIT 1;" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠ target: cannot read supabase_migrations.schema_migrations (common after restore)${NC}"
elif [ "$SRC_MIGS" = "$TGT_MIGS" ]; then
    echo -e "  ${PASS} tracked migration rows: ${SRC_MIGS}"
else
    echo -e "  ${YELLOW}⚠ tracked row count differs: source=${SRC_MIGS}  target=${TGT_MIGS}${NC}"
fi
echo ""

# ── Result ────────────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
if [ "${FAILURES}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  All checks passed${NC}"
else
    echo -e "${RED}${BOLD}  ${FAILURES} check(s) failed — see diff output above${NC}"
    exit 1
fi
echo ""
