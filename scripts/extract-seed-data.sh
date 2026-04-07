#!/bin/bash

# Extract Seed Data from Demo Dump
# Extracts seed/reference data tables from demo.dump into seed.dump
#
# Seed data includes (reference/template data ONLY):
# - languages (reference data)
# - email_templates, email_layouts (template data)
# - template_variables, template_variable_translations, template_performance (reference data)
# - products (for license management)
# - breach_management_team (for govern)
#
# DELIBERATELY EXCLUDED — lesson/track content:
# - lessons, lesson_nodes, lesson_answers (and all their translations)
# - learning_tracks, learning_track_lessons
#   Lesson content must ALWAYS come from the master DB via sync-lesson-content.
#   Seeding lesson content from the dev DB introduces stale or test data into
#   client instances and causes count mismatches (dev ≠ master lesson counts).
#   Run SyncManager (or sync-lesson-content Edge Function) after onboarding.
#
# Excluded (user-specific data, not seed):
# - email_notifications (user-specific notifications)
# - learning_track_assignments, learning_track_department_assignments, learning_track_role_assignments (user-specific)
# - user_learning_track_progress, user_lesson_progress (user-specific)
# - lesson_reminder_counts, lesson_reminder_history (user-specific)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEMO_DUMP=${1:-"backups/demo.dump"}
OUTPUT_DIR=${2:-"backups"}
SEED_DUMP="${OUTPUT_DIR}/seed.dump"
SCHEMA_DUMP="${OUTPUT_DIR}/schema.dump"

if [ ! -f "$DEMO_DUMP" ]; then
    echo -e "${RED}Error: Demo dump file not found: ${DEMO_DUMP}${NC}"
    echo "Usage: ./extract-seed-data.sh [demo-dump-path] [output-dir] [project-ref]"
    echo "Example: ./extract-seed-data.sh backups/demo.dump backups"
    echo ""
    echo "  demo-dump-path: Path to demo.dump file (default: backups/demo.dump)"
    echo "  output-dir: Output directory (default: backups)"
    echo "  project-ref: Supabase project reference (default: cleqfnrbiqpxpzxkatda or DEV_PROJECT_REF env var)"
    echo ""
    echo "Note: Uses dev database (cleqfnrbiqpxpzxkatda) as default for temporary database operations."
    exit 1
fi

if [ ! -f "$SCHEMA_DUMP" ]; then
    echo -e "${RED}Error: Schema dump file not found: ${SCHEMA_DUMP}${NC}"
    echo "The schema.dump file is required to restore table definitions."
    echo "Please ensure backups/schema.dump exists (created by create-backup.sh)."
    exit 1
fi

echo -e "${GREEN}Extracting seed data from ${DEMO_DUMP}...${NC}"

# Create output directory
mkdir -p ${OUTPUT_DIR}

# Get database password from environment variable or prompt
if [ -z "$PGPASSWORD" ]; then
    echo "Enter database password (for temporary database operations):"
    read -s DB_PASSWORD
    export PGPASSWORD="$DB_PASSWORD"
else
    echo "Using database password from PGPASSWORD environment variable"
fi

# We need a temporary database to restore to, then dump from
# Use the same connection details as create-backup.sh expects
# Default to dev database PROJECT_REF if available, or use dev project ref
PROJECT_REF=${3:-${DEV_PROJECT_REF:-"cleqfnrbiqpxpzxkatda"}}
echo -e "${GREEN}Using PROJECT_REF: ${PROJECT_REF}${NC}"
EXTRACT_TO_SQL=false

# Detect connection method: direct IPv6 or pooler fallback (same logic as create-backup.sh)
DB_HOSTNAME="db.${PROJECT_REF}.supabase.co"
POOLER_HOST="${POOLER_HOST:-aws-1-${REGION:-ap-southeast-1}.pooler.supabase.com}"
RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v "^\." | head -1)
if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
    export PGHOSTADDR="${RESOLVED_ADDR}"
    PG_HOST="${DB_HOSTNAME}"; PG_PORT=5432; PG_USER="postgres"
    echo -e "${GREEN}Using direct connection (IPv6): ${RESOLVED_ADDR}${NC}"
else
    PG_HOST="${POOLER_HOST}"; PG_PORT=5432; PG_USER="postgres.${PROJECT_REF}"
    echo -e "${YELLOW}Direct connection unavailable — using pooler: ${POOLER_HOST}${NC}"
fi
CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"

# Create TOC file with only seed data tables
TOC_FILE=$(mktemp)
TOC_DATA_FILE=$(mktemp)

# Hard-coded list of seed tables (reference/template data only)
# These are the exact tables we need for new client onboarding.
# IMPORTANT: Order matters for foreign key dependencies!
#
# Lesson/track tables are intentionally excluded — content comes from sync, not dev seed.
# Dependency order:
#   1. languages (referenced by email template translations if any)
#   2. email_layouts, email_templates (independent)
#   3. template_variables, template_variable_translations (independent)
#   4. notification_rules (depends on email_templates)
#   5. products (independent) - for license management
#   6. breach_management_team (independent) - for govern
#
# email_preferences is included but user-specific rows are stripped before dumping
# (see cleanup step below), leaving only the org-level row (user_id IS NULL).
SEED_TABLES="languages email_layouts email_templates template_variables template_variable_translations notification_rules email_preferences products breach_management_team"

# Verify these tables exist in the dump
echo -e "${GREEN}Verifying seed tables exist in dump...${NC}"
AVAILABLE_TABLES=$(pg_restore --list "$DEMO_DUMP" 2>/dev/null | \
    grep "TABLE DATA public" | \
    sed 's/.*TABLE DATA public \([^ ]*\).*/\1/' | sort -u)

MISSING_IN_DUMP=""
for table in $SEED_TABLES; do
    if ! echo "$AVAILABLE_TABLES" | grep -q "^${table}$"; then
        MISSING_IN_DUMP="${MISSING_IN_DUMP} ${table}"
        echo -e "${YELLOW}Warning: Table ${table} not found in dump${NC}"
    fi
done

if [ -n "$MISSING_IN_DUMP" ]; then
    echo -e "${YELLOW}Warning: Some seed tables not found in dump:${NC}"
    echo "$MISSING_IN_DUMP"
    echo -e "${YELLOW}Continuing with available tables...${NC}"
fi

# Count tables found
TABLE_COUNT=$(echo "$SEED_TABLES" | wc -w)
echo -e "${GREEN}Found ${TABLE_COUNT} seed data tables${NC}"

# Show which tables will be extracted
echo -e "${GREEN}Tables to extract:${NC}"
for table in $SEED_TABLES; do
    echo "  - ${table}"
done

# Create TOC for schema (all tables, but we'll restore only seed data)
# First, restore full schema to temp database, then restore only seed data
SCHEMA_TOC=$(mktemp)
# Get all TABLE entries (schema) - we need the full schema for foreign keys
pg_restore --list "$DEMO_DUMP" 2>/dev/null | \
    grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE public " > "${SCHEMA_TOC}" || true

# Create TOC for seed data only
for table in $SEED_TABLES; do
    pg_restore --list "$DEMO_DUMP" 2>/dev/null | \
        grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE DATA public ${table}\s" >> "${TOC_DATA_FILE}" || true
done

# Extract to custom format (requires temporary database)
echo -e "${GREEN}Extracting to custom format: ${SEED_DUMP}${NC}"
echo -e "${YELLOW}Note: This requires a temporary database connection to ${PROJECT_REF}${NC}"

# Create a temporary database or use existing one
TEMP_DB="temp_seed_extract_$$"

# Restore seed data to temporary database
echo -e "${GREEN}Restoring seed data to temporary database...${NC}"
psql "${CONNECTION_STRING}" \
    --command "CREATE DATABASE ${TEMP_DB};" 2>&1 || {
        echo -e "${YELLOW}Database may already exist, continuing...${NC}"
    }

TEMP_CONNECTION="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=${TEMP_DB} sslmode=require"

# Restore schema first from schema.dump, then data from demo.dump
# This ensures tables exist before data is loaded
# Note: auth schema errors are expected - auth schema is managed by Supabase and doesn't exist in fresh databases
# Note: account_inventory and other non-seed table errors are expected - they're not in seed data
# Note: public schema already exists by default, CREATE SCHEMA public errors can be ignored
echo -e "${GREEN}Restoring schema from ${SCHEMA_DUMP} to temporary database...${NC}"
pg_restore \
    --dbname="${TEMP_CONNECTION}" \
    --no-owner \
    --no-acl \
    "$SCHEMA_DUMP" 2>&1 | \
    grep -v "schema \"auth\" does not exist" | \
    grep -v "schema \"public\" already exists" | \
    grep -vE "relation \"public\.(account_inventory|learning_track_department_assignments|learning_track_role_assignments|learning_track_assignments|user_learning_track_progress|user_lesson_progress|email_notifications|lesson_reminder_counts|lesson_reminder_history|profiles|users|departments|roles)\" does not exist" | \
    tee /tmp/restore_schema.log | \
    grep -E "(CREATE TABLE|CREATE TYPE|CREATE FUNCTION|error|ERROR)" | \
    grep -v "schema \"auth\" does not exist" | \
    grep -v "schema \"public\" already exists" | \
    tail -30 || {
        echo -e "${YELLOW}Some warnings during schema restore (may be expected)${NC}"
    }

# Verify seed tables exist after schema restore
echo -e "${GREEN}Verifying seed tables exist after schema restore...${NC}"
MISSING_TABLES=""
for table in $SEED_TABLES; do
    TABLE_EXISTS=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${table}');" 2>/dev/null || echo "f")
    if [ "$TABLE_EXISTS" != "t" ]; then
        MISSING_TABLES="${MISSING_TABLES} ${table}"
        echo -e "${YELLOW}Table ${table} not found after schema restore${NC}"
    fi
done

if [ -n "$MISSING_TABLES" ]; then
    echo -e "${RED}Error: The following seed tables do not exist after schema restore:${NC}"
    echo "$MISSING_TABLES"
    echo -e "${RED}This may indicate the demo.dump does not contain these table definitions.${NC}"
    echo -e "${YELLOW}Attempting to restore data anyway...${NC}"
fi

# Enable required extensions (pgcrypto is needed for generate_content_hash function)
echo -e "${GREEN}Enabling required PostgreSQL extensions...${NC}"
psql "${TEMP_CONNECTION}" \
    --command "CREATE EXTENSION IF NOT EXISTS pgcrypto;" 2>&1 || {
    echo -e "${YELLOW}Warning: Failed to enable pgcrypto extension (may already exist)${NC}"
}

# Verify critical functions exist after schema restore
echo -e "${GREEN}Verifying critical functions exist...${NC}"
FUNCTION_EXISTS=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM pg_proc WHERE proname = 'generate_content_hash' AND pronamespace = 'public'::regnamespace);" 2>/dev/null || echo "f")
if [ "$FUNCTION_EXISTS" != "t" ]; then
    echo -e "${RED}Error: generate_content_hash function not found in public schema after schema restore${NC}"
    echo -e "${YELLOW}This function is required for lesson_nodes and lesson_node_translations${NC}"
    exit 1
else
    echo -e "${GREEN}✓ generate_content_hash function verified in public schema${NC}"
fi

# Ensure search_path includes public schema for function calls
echo -e "${GREEN}Setting search_path and verifying function accessibility...${NC}"
psql "${TEMP_CONNECTION}" \
    --command "ALTER DATABASE ${TEMP_DB} SET search_path = public, pg_catalog;" 2>&1 || true

# Test that the function is callable (requires pgcrypto extension)
FUNCTION_TEST=$(psql "${TEMP_CONNECTION}" -tAc "SELECT public.generate_content_hash('test', 'test');" 2>/dev/null || echo "ERROR")
if [[ "$FUNCTION_TEST" == "ERROR" ]] || [ -z "$FUNCTION_TEST" ]; then
    echo -e "${RED}Error: generate_content_hash function is not callable${NC}"
    echo -e "${YELLOW}Checking if pgcrypto extension is enabled...${NC}"
    EXTENSION_EXISTS=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM pg_extension WHERE extname = 'pgcrypto');" 2>/dev/null || echo "f")
    if [ "$EXTENSION_EXISTS" != "t" ]; then
        echo -e "${RED}pgcrypto extension is not enabled - attempting to enable...${NC}"
        psql "${TEMP_CONNECTION}" \
            --command "CREATE EXTENSION IF NOT EXISTS pgcrypto CASCADE;" 2>&1 || {
            echo -e "${RED}Failed to enable pgcrypto extension - this will cause restore errors${NC}"
            exit 1
        }
        echo -e "${GREEN}✓ pgcrypto extension enabled${NC}"
    fi
    # Test again
    FUNCTION_TEST=$(psql "${TEMP_CONNECTION}" -tAc "SELECT public.generate_content_hash('test', 'test');" 2>/dev/null || echo "ERROR")
    if [[ "$FUNCTION_TEST" == "ERROR" ]] || [ -z "$FUNCTION_TEST" ]; then
        echo -e "${RED}Function test still failed after enabling pgcrypto - this may cause restore errors${NC}"
    else
        echo -e "${GREEN}✓ generate_content_hash function is now callable${NC}"
    fi
else
    echo -e "${GREEN}✓ generate_content_hash function is callable${NC}"
fi

# Now restore data - but ONLY for seed tables, not all tables
# Restore in dependency order to avoid foreign key violations
# Temporarily disable foreign key constraint enforcement
echo -e "${GREEN}Restoring seed data to temporary database (seed tables only, in dependency order)...${NC}"

# Ensure search_path is set for all connections (including pg_restore)
# Set it at the database level AND ensure it's in the default schema
echo -e "${GREEN}Ensuring search_path is set for function access...${NC}"
psql "${TEMP_CONNECTION}" <<EOF 2>&1 | grep -v "ALTER DATABASE" || true
-- Set search_path for the database (affects new connections)
ALTER DATABASE ${TEMP_DB} SET search_path = public, pg_catalog;

-- Also set it for the current session
SET search_path = public, pg_catalog;

-- Verify function is accessible
SELECT public.generate_content_hash('test', 'test') IS NOT NULL AS function_works;
EOF

# Create TOC file with seed tables in dependency order
SEED_DATA_TOC=$(mktemp)
for table in $SEED_TABLES; do
    pg_restore --list "$DEMO_DUMP" 2>/dev/null | \
        grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE DATA public ${table}\s" >> "${SEED_DATA_TOC}" || true
done

# Restore tables in dependency order (one at a time)
# Some may fail due to FK constraints on created_by/updated_by - we'll fix those after
echo -e "${GREEN}Restoring tables in dependency order (one at a time)...${NC}"

# Set search_path globally for all connections to this database
# This is critical for triggers/functions that use generate_content_hash
psql "${TEMP_CONNECTION}" \
    --command "ALTER DATABASE ${TEMP_DB} SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true

# Also set it as a user default (affects new connections)
psql "${TEMP_CONNECTION}" \
    --command "ALTER ROLE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true

# Disable triggers that use generate_content_hash before restore
# These triggers fire during COPY even with --disable-triggers in some cases
echo -e "${GREEN}Disabling triggers that use generate_content_hash...${NC}"
psql "${TEMP_CONNECTION}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes DISABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations DISABLE TRIGGER update_translation_content_hash_trigger;
EOF

# Use PGOPTIONS to set search_path for pg_restore connections
export PGOPTIONS="-c search_path=public,pg_catalog"
export PGDATABASE=${TEMP_DB}
FAILED_TABLES=""
for table in $SEED_TABLES; do
    echo -e "${GREEN}  Restoring ${table}...${NC}"
    
    # Create TOC for this table only
    TABLE_TOC=$(mktemp)
    pg_restore --list "$DEMO_DUMP" 2>/dev/null | \
        grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE DATA public ${table}\s" >> "${TABLE_TOC}" || true
    
    if [ -s "${TABLE_TOC}" ]; then
        # Restore with FK checks disabled
        # PGOPTIONS is already exported to include search_path=public,pg_catalog
        # This ensures functions can be found during COPY/triggers
        # For tables that use generate_content_hash in triggers, we've disabled those triggers
        RESTORE_OUTPUT=$(pg_restore \
            --host=${PG_HOST} \
            --port=${PG_PORT} \
            --user=${PG_USER} \
            --dbname=${TEMP_DB} \
            --data-only \
            --no-owner \
            --no-acl \
            --disable-triggers \
            --use-list="${TABLE_TOC}" \
            "$DEMO_DUMP" 2>&1) || {
            echo -e "${YELLOW}    Restore had errors for ${table} (checking output...)${NC}"
        }
        
        # If function error persists, the trigger is trying to call the function but can't find it
        # This happens because pg_restore's COPY doesn't respect PGOPTIONS in some cases
        # We'll mark these tables to be restored via SQL COPY instead
        if echo "$RESTORE_OUTPUT" | grep -q "function generate_content_hash.*does not exist"; then
            echo -e "${YELLOW}    Function error for ${table} - trigger can't find function during COPY${NC}"
            FAILED_TABLES="${FAILED_TABLES} ${table}"
            # Verify function exists and is callable
            FUNC_CHECK=$(psql "${TEMP_CONNECTION}" -tAc "SELECT public.generate_content_hash('test', 'test');" 2>/dev/null || echo "ERROR")
            if [ "$FUNC_CHECK" = "ERROR" ] || [ -z "$FUNC_CHECK" ]; then
                echo -e "${RED}    Function is not callable - this is a critical issue${NC}"
            else
                echo -e "${GREEN}    Function is callable - will restore via SQL COPY with explicit search_path${NC}"
            fi
        fi
        
        # Show errors but filter expected ones
        ERRORS=$(echo "$RESTORE_OUTPUT" | \
            grep -v "RI_ConstraintTrigger.*is a system trigger" | \
            grep -vE "relation \"public\.(learning_track_department_assignments|learning_track_role_assignments|learning_track_assignments|user_learning_track_progress|user_lesson_progress|email_notifications|lesson_reminder_counts|lesson_reminder_history|account_inventory)\" does not exist" | \
            grep -E "error|ERROR|Error|failed|Failed|FAILED" || true)
        
        if [ -n "$ERRORS" ]; then
            echo "$ERRORS" | head -3 | sed 's/^/      /'
        fi
        
        # Check for FK violations (especially created_by/updated_by)
        if echo "$RESTORE_OUTPUT" | grep -q "violates foreign key constraint.*created_by\|violates foreign key constraint.*updated_by"; then
            echo -e "${YELLOW}    FK violation on audit columns for ${table} (will fix after restore)${NC}"
            FAILED_TABLES="${FAILED_TABLES} ${table}"
        elif echo "$RESTORE_OUTPUT" | grep -q "violates foreign key constraint"; then
            echo -e "${YELLOW}    FK violation for ${table} (may resolve after parent tables restored)${NC}"
            FAILED_TABLES="${FAILED_TABLES} ${table}"
        fi
        
        if echo "$RESTORE_OUTPUT" | grep -q "function generate_content_hash"; then
            echo -e "${RED}    Function errors for ${table} - this is problematic${NC}"
        fi
        
        # Check if data was actually inserted
        ROW_COUNT=$(psql "${TEMP_CONNECTION}" -tAc "SELECT COUNT(*) FROM public.${table};" 2>/dev/null || echo "0")
        if [ "${ROW_COUNT:-0}" -gt 0 ]; then
            echo -e "${GREEN}    ✓ Restored ${ROW_COUNT} rows to ${table}${NC}"
        else
            echo -e "${YELLOW}    No rows in ${table} after restore${NC}"
        fi
    else
        echo -e "${YELLOW}  No data found for ${table}${NC}"
    fi
    
    rm -f "${TABLE_TOC}"
done

rm -f "${SEED_DATA_TOC}"

# Nullify created_by and updated_by columns in seed tables
# These reference users table which isn't in seed data, causing FK violations
echo -e "${GREEN}Nullifying created_by and updated_by columns in seed tables...${NC}"
for table in $SEED_TABLES; do
    # Check if table has created_by column
    HAS_CREATED_BY=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '${table}' AND column_name = 'created_by');" 2>/dev/null || echo "f")
    if [ "$HAS_CREATED_BY" = "t" ]; then
        echo -e "${GREEN}  Nullifying created_by in ${table}...${NC}"
        psql "${TEMP_CONNECTION}" \
            --command "UPDATE public.${table} SET created_by = NULL WHERE created_by IS NOT NULL;" 2>&1 | grep -v "UPDATE" || true
    fi
    
    # Check if table has updated_by column
    HAS_UPDATED_BY=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '${table}' AND column_name = 'updated_by');" 2>/dev/null || echo "f")
    if [ "$HAS_UPDATED_BY" = "t" ]; then
        echo -e "${GREEN}  Nullifying updated_by in ${table}...${NC}"
        psql "${TEMP_CONNECTION}" \
            --command "UPDATE public.${table} SET updated_by = NULL WHERE updated_by IS NOT NULL;" 2>&1 | grep -v "UPDATE" || true
    fi
done
echo -e "${GREEN}✓ Nullified audit columns in seed tables${NC}"

# Strip user-specific email_preferences rows — only the org-level row (user_id IS NULL)
# belongs in the seed. User rows from the demo DB must not carry over to new clients.
EP_EXISTS=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'email_preferences');" 2>/dev/null || echo "f")
if [ "$EP_EXISTS" = "t" ]; then
    DELETED=$(psql "${TEMP_CONNECTION}" -tAc "DELETE FROM public.email_preferences WHERE user_id IS NOT NULL; SELECT COUNT(*) FROM public.email_preferences;" 2>/dev/null | tr -d ' ' || echo "?")
    echo -e "${GREEN}Stripped user-specific email_preferences rows — ${DELETED} org-level row(s) remain${NC}"
fi

# Nullify member column in breach_management_team (references profiles.id which isn't in seed data)
BREACH_TEAM_EXISTS=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'breach_management_team');" 2>/dev/null || echo "f")
if [ "$BREACH_TEAM_EXISTS" = "t" ]; then
    HAS_MEMBER=$(psql "${TEMP_CONNECTION}" -tAc "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'breach_management_team' AND column_name = 'member');" 2>/dev/null || echo "f")
    if [ "$HAS_MEMBER" = "t" ]; then
        echo -e "${GREEN}Nullifying member in breach_management_team...${NC}"
        psql "${TEMP_CONNECTION}" \
            --command "UPDATE public.breach_management_team SET member = NULL WHERE member IS NOT NULL;" 2>&1 | grep -v "UPDATE" || true
        echo -e "${GREEN}✓ Nullified member column in breach_management_team${NC}"
    fi
fi

# Retry restoring failed tables (now that audit columns are nullified)
# Retry in dependency order to ensure parent tables are restored before child tables
if [ -n "$FAILED_TABLES" ]; then
    echo -e "${GREEN}Retrying restore for tables that failed...${NC}"
    
    # Ensure search_path is definitely set before retry
    psql "${TEMP_CONNECTION}" \
        --command "ALTER DATABASE ${TEMP_DB} SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true
    
    for table in $SEED_TABLES; do
        # Only retry tables that failed
        if echo "$FAILED_TABLES" | grep -qw "${table}"; then
            echo -e "${GREEN}  Retrying ${table}...${NC}"
            
            TABLE_TOC=$(mktemp)
            pg_restore --list "$DEMO_DUMP" 2>/dev/null | \
                grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE DATA public ${table}\s" >> "${TABLE_TOC}" || true
            
            if [ -s "${TABLE_TOC}" ]; then
                # Use PGOPTIONS to ensure search_path is set for generated columns
                # This is critical for tables with generated columns that use functions
                RESTORE_OUTPUT=$(PGOPTIONS="-c search_path=public,pg_catalog" pg_restore \
                    --host=${PG_HOST} \
                    --port=${PG_PORT} \
                    --user=${PG_USER} \
                    --dbname=${TEMP_DB} \
                    --data-only \
                    --no-owner \
                    --no-acl \
                    --disable-triggers \
                    --use-list="${TABLE_TOC}" \
                    "$DEMO_DUMP" 2>&1)
                
                # Check for function errors
                if echo "$RESTORE_OUTPUT" | grep -q "function generate_content_hash.*does not exist"; then
                    echo -e "${YELLOW}    Function still not accessible via pg_restore COPY${NC}"
                    echo -e "${YELLOW}    Trying SQL-based restore with explicit search_path...${NC}"
                    
                    # Extract data to SQL and restore via psql with search_path set
                    # This bypasses pg_restore's COPY and uses psql COPY which respects search_path
                    SQL_OUTPUT=$(pg_restore --data-only --use-list="${TABLE_TOC}" "$DEMO_DUMP" 2>/dev/null | \
                        grep -A 10000 "COPY public.${table}" | \
                        head -10000 || echo "")
                    
                    if [ -n "$SQL_OUTPUT" ]; then
                        # Restore via psql with search_path explicitly set
                        echo "$SQL_OUTPUT" | psql "${TEMP_CONNECTION}" \
                            --command "SET search_path = public, pg_catalog;" \
                            --single-transaction 2>&1 | \
                            grep -v "COPY\|SET\|COMMIT\|BEGIN" | \
                            grep -E "error|ERROR|Error" | head -3 || {
                            echo -e "${GREEN}    ✓ SQL restore successful${NC}"
                        }
                        
                        # Verify rows
                        ROW_COUNT=$(psql "${TEMP_CONNECTION}" -tAc "SELECT COUNT(*) FROM public.${table};" 2>/dev/null || echo "0")
                        if [ "${ROW_COUNT:-0}" -gt 0 ]; then
                            echo -e "${GREEN}    ✓ Restored ${ROW_COUNT} rows to ${table} via SQL${NC}"
                        fi
                    else
                        echo -e "${RED}    Could not extract SQL data for ${table}${NC}"
                    fi
                else
                    echo "$RESTORE_OUTPUT" | \
                        grep -v "RI_ConstraintTrigger.*is a system trigger" | \
                        grep -v "duplicate key value" | \
                        grep -E "error|ERROR|Error" | head -3 || {
                        echo -e "${GREEN}    ✓ Retry successful${NC}"
                    }
                    
                    # Verify rows were inserted
                    ROW_COUNT=$(psql "${TEMP_CONNECTION}" -tAc "SELECT COUNT(*) FROM public.${table};" 2>/dev/null || echo "0")
                    if [ "${ROW_COUNT:-0}" -gt 0 ]; then
                        echo -e "${GREEN}    ✓ Restored ${ROW_COUNT} rows to ${table}${NC}"
                    fi
                fi
            fi
            
            rm -f "${TABLE_TOC}"
        fi
    done
    echo -e "${GREEN}✓ Retry complete${NC}"
fi

# Dump only seed tables from temp database to seed.dump
echo -e "${GREEN}Creating seed.dump from temporary database (seed tables only)...${NC}"

# Build --table arguments for each seed table
TABLE_ARGS=""
for table in $SEED_TABLES; do
    TABLE_ARGS="${TABLE_ARGS} --table=public.${table}"
done

pg_dump \
    --host=${PG_HOST} \
    --port=${PG_PORT} \
    --user=${PG_USER} \
    --dbname=${TEMP_DB} \
    --data-only \
    --format=custom \
    --no-owner \
    ${TABLE_ARGS} \
    --file="${SEED_DUMP}" \
    --verbose 2>&1 | tail -20

# Verify seed.dump contains expected tables
echo -e "${GREEN}Verifying seed.dump contents...${NC}"
DUMP_TABLES=$(pg_restore --list "${SEED_DUMP}" 2>/dev/null | \
    grep "TABLE DATA public" | \
    sed 's/.*TABLE DATA public \([^ ]*\).*/\1/' | sort -u)

echo -e "${GREEN}Tables in seed.dump:${NC}"
echo "$DUMP_TABLES" | sed 's/^/  - /'

# Check if all expected tables are present
MISSING_IN_DUMP=""
for table in $SEED_TABLES; do
    if ! echo "$DUMP_TABLES" | grep -q "^${table}$"; then
        MISSING_IN_DUMP="${MISSING_IN_DUMP} ${table}"
    fi
done

if [ -n "$MISSING_IN_DUMP" ]; then
    echo -e "${YELLOW}Warning: Expected tables not found in seed.dump:${NC}"
    echo "$MISSING_IN_DUMP"
else
    echo -e "${GREEN}✓ All expected seed tables are present in seed.dump${NC}"
fi

# Count records in seed.dump (approximate - each table data entry represents data)
echo -e "${GREEN}Data entries in seed.dump:${NC}"
for table in $SEED_TABLES; do
    COUNT=$(pg_restore --list "${SEED_DUMP}" 2>/dev/null | grep -c "TABLE DATA public ${table}" || echo "0")
    if [ "$COUNT" -gt "0" ]; then
        echo "  - ${table}: ${COUNT} data entry(ies)"
    fi
done

# Clean up temporary database
echo -e "${GREEN}Cleaning up temporary database...${NC}"
psql "${CONNECTION_STRING}" \
    --command "DROP DATABASE IF EXISTS ${TEMP_DB};" 2>&1 || true

echo -e "${GREEN}✓ Seed data extracted to ${SEED_DUMP}${NC}"

rm -f "${TOC_FILE}" "${TOC_DATA_FILE}" "${SCHEMA_TOC}" /tmp/restore_errors.log

echo ""
echo -e "${GREEN}✓ Seed data extraction complete!${NC}"
echo "Files:"
echo "  - ${SEED_DUMP}"

