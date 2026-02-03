#!/bin/bash

# Restore Demo Data Script
# Restores full demo data from demo.dump or demo.sql to a target database
#
# Demo data includes:
# - All seed data (languages, lessons, learning_tracks, etc.)
# - User-specific data (profiles, user_roles, assignments, progress, etc.)
# - Auth users (if auth.dump is available)
#
# This is a complete demo dataset for testing/demo purposes.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEMO_DUMP=${1:-"backups/demo.dump"}
PROJECT_REF=${2}
AUTH_DUMP=${3:-"backups/auth.dump"}

# PROJECT_REF is required - don't default to dev!
if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: PROJECT_REF is required${NC}"
    echo "Usage: ./restore-demo-data.sh [demo-dump-path] <project-ref> [auth-dump-path]"
    echo "Example: ./restore-demo-data.sh backups/demo.dump nfgotwiefhkncoiibnfk"
    echo ""
    echo "  demo-dump-path: Path to demo.dump or demo.sql file (default: backups/demo.dump)"
    echo "  project-ref: Target Supabase project reference where data will be restored (REQUIRED)"
    echo "  auth-dump-path: Path to auth.dump file for auth.users (default: backups/auth.dump, optional)"
    echo ""
    echo "      PGPASSWORD should be set to the TARGET database password (not source)."
    exit 1
fi

# Determine if input is a .dump (custom format) or .sql file
if [ ! -f "$DEMO_DUMP" ]; then
    echo -e "${RED}Error: Demo dump file not found: ${DEMO_DUMP}${NC}"
    echo "Usage: ./restore-demo-data.sh [demo-dump-path] <project-ref> [auth-dump-path]"
    echo "Example: ./restore-demo-data.sh backups/demo.dump nfgotwiefhkncoiibnfk"
    exit 1
fi

# Check file extension to determine format
if [[ "$DEMO_DUMP" == *.dump ]]; then
    FORMAT="custom"
elif [[ "$DEMO_DUMP" == *.sql ]]; then
    FORMAT="sql"
else
    echo -e "${RED}Error: Unsupported file format. Expected .dump or .sql${NC}"
    exit 1
fi

echo -e "${GREEN}Restoring demo data from ${DEMO_DUMP}...${NC}"
echo -e "${GREEN}Using PROJECT_REF: ${PROJECT_REF}${NC}"
echo -e "${YELLOW}Note: This will restore to the target database (${PROJECT_REF})${NC}"
echo -e "${YELLOW}      Use the password for the TARGET database, not the source${NC}"

# Get database password from environment variable or prompt
# IMPORTANT: This is the password for the TARGET database (where we're restoring TO)
if [ -z "$PGPASSWORD" ]; then
    echo "Enter database password for ${PROJECT_REF} (target database):"
    read -s DB_PASSWORD
    export PGPASSWORD="$DB_PASSWORD"
else
    echo "Using database password from PGPASSWORD environment variable"
fi

# Use pooler connection (port 6543) for database operations, matching onboard script
# Note: For pg_restore, we may need direct connection (5432) if PGOPTIONS is needed
CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"
DIRECT_CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=5432 user=postgres dbname=postgres sslmode=require"

# Verify demo file contains data
if [ "$FORMAT" = "custom" ]; then
    TABLE_COUNT=$(pg_restore --list "$DEMO_DUMP" 2>/dev/null | grep -c "TABLE DATA" || echo "0")
    if [ "$TABLE_COUNT" -eq 0 ]; then
        echo -e "${RED}Error: Demo dump file appears to be empty (no TABLE DATA entries found)${NC}"
        exit 1
    fi
    echo -e "${GREEN}Found ${TABLE_COUNT} tables in demo dump${NC}"
fi

# Restore auth.users first if auth.dump is available (needed for foreign key constraints)
if [ "$FORMAT" = "custom" ] && [ -f "$AUTH_DUMP" ]; then
    echo -e "${GREEN}Restoring auth.users from ${AUTH_DUMP}...${NC}"
    pg_restore \
        --host=db.${PROJECT_REF}.supabase.co \
        --port=5432 \
        --user=postgres \
        --dbname=postgres \
        --no-owner \
        --data-only \
        "$AUTH_DUMP" 2>&1 | \
        tee /tmp/restore-auth.log | \
        grep -v "RI_ConstraintTrigger.*is a system trigger" || {
            echo -e "${YELLOW}Some errors occurred during auth.users restore (may be expected)${NC}"
        }
    echo -e "${GREEN}✓ Auth users restored${NC}"
elif [ "$FORMAT" = "custom" ]; then
    echo -e "${YELLOW}Note: auth.dump not found (${AUTH_DUMP}), skipping auth.users restore${NC}"
    echo -e "${YELLOW}      Profiles and user_roles may have FK issues, but will still work${NC}"
fi

# Restore demo data
if [ "$FORMAT" = "custom" ]; then
    echo -e "${GREEN}Restoring demo data from custom format dump...${NC}"
    
    # Step 1: Disable triggers that use generate_content_hash
    echo "  Step 1: Disabling triggers that use generate_content_hash..."
    (unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes DISABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations DISABLE TRIGGER update_translation_content_hash_trigger;
EOF
)
    
    # Step 2: Ensure search_path is set for function access
    echo "  Step 2: Setting search_path for function access..."
    psql "${DIRECT_CONNECTION_STRING}" \
        --command "ALTER DATABASE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true
    psql "${DIRECT_CONNECTION_STRING}" \
        --command "ALTER ROLE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true
    
    # Step 3: Restore all public schema data (excluding auth.users which we already restored)
    echo "  Step 3: Restoring demo data (public schema only)..."
    echo -e "${YELLOW}Note: Some errors are expected and can be ignored:${NC}"
    echo -e "${YELLOW}  - System trigger permission errors (RI_ConstraintTrigger) - filtered from output${NC}"
    echo ""
    
    # Restore public schema data only (excludes auth.users)
    PGOPTIONS="-c search_path=public,pg_catalog" pg_restore \
        --host=db.${PROJECT_REF}.supabase.co \
        --port=5432 \
        --user=postgres \
        --dbname=postgres \
        --no-owner \
        --data-only \
        --schema=public \
        --disable-triggers \
        "$DEMO_DUMP" 2>&1 | \
        tee /tmp/restore-demo.log | \
        grep -v "RI_ConstraintTrigger.*is a system trigger" || {
            echo ""
            echo -e "${YELLOW}Analyzing restore errors...${NC}"
            
            # Count different types of errors
            SYSTEM_TRIGGER_ERRORS=$(grep -c "permission denied.*RI_ConstraintTrigger" /tmp/restore-demo.log || echo "0")
            DUPLICATE_KEY_ERRORS=$(grep -c "duplicate key value violates unique constraint" /tmp/restore-demo.log || echo "0")
            FOREIGN_KEY_ERRORS=$(grep -c "violates foreign key constraint" /tmp/restore-demo.log || echo "0")
            OTHER_ERRORS=$(grep "ERROR" /tmp/restore-demo.log | grep -v "permission denied.*RI_ConstraintTrigger" | grep -v "duplicate key value" | grep -v "violates foreign key constraint" | wc -l | tr -d ' ')
            
            if [ "$SYSTEM_TRIGGER_ERRORS" -gt "0" ]; then
                echo -e "${GREEN}  ✓ ${SYSTEM_TRIGGER_ERRORS} system trigger errors (expected, can be ignored)${NC}"
            fi
            if [ "$DUPLICATE_KEY_ERRORS" -gt "0" ]; then
                echo -e "${YELLOW}  ⚠ ${DUPLICATE_KEY_ERRORS} duplicate key errors (data may already exist)${NC}"
            fi
            if [ "$FOREIGN_KEY_ERRORS" -gt "0" ]; then
                echo -e "${YELLOW}  ⚠ ${FOREIGN_KEY_ERRORS} foreign key errors (may be expected if auth.users missing)${NC}"
            fi
            if [ "$OTHER_ERRORS" -gt "0" ]; then
                echo -e "${RED}  ✗ ${OTHER_ERRORS} other errors (may need attention)${NC}"
                echo -e "${YELLOW}Review /tmp/restore-demo.log for details${NC}"
            fi
        }
else
    echo -e "${GREEN}Restoring demo data from SQL format...${NC}"
    # Unset PGOPTIONS for pooler connection
    (unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" \
        --single-transaction \
        --variable ON_ERROR_STOP=0 \
        --command 'SET session_replication_role = replica' \
        --file "$DEMO_DUMP" 2>&1 | tee /tmp/restore-demo.log || {
            echo -e "${YELLOW}Some errors occurred during SQL restore${NC}"
            echo -e "${YELLOW}Review /tmp/restore-demo.log for details${NC}"
        })
fi

# Step 4: Re-enable triggers
echo "  Step 4: Re-enabling triggers..."
(unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes ENABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations ENABLE TRIGGER update_translation_content_hash_trigger;
EOF
)

# Verify restoration by checking key tables
echo -e "${GREEN}Verifying restoration...${NC}"
PROFILES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.profiles;" 2>/dev/null | tr -d ' ' || echo "0")
LESSONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lessons;" 2>/dev/null | tr -d ' ' || echo "0")
LEARNING_TRACKS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.learning_tracks;" 2>/dev/null | tr -d ' ' || echo "0")
USER_PROGRESS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.user_lesson_progress;" 2>/dev/null | tr -d ' ' || echo "0")
ASSIGNMENTS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.learning_track_assignments;" 2>/dev/null | tr -d ' ' || echo "0")

# Print verification table
printf "  %-35s %10s %s\n" "Table" "Row Count" "Status"
printf "  %-35s %10s %s\n" "-----------------------------------" "----------" "------"

check_table() {
    local table=$1
    local count=$2
    local status=""
    if [ "${count:-0}" -eq 0 ]; then
        status="${YELLOW}⚠ Empty${NC}"
    else
        status="${GREEN}✓${NC}"
    fi
    printf "  %-35s %10s %s\n" "$table" "${count}" "$status"
}

check_table "profiles" "${PROFILES_COUNT:-0}"
check_table "lessons" "${LESSONS_COUNT:-0}"
check_table "learning_tracks" "${LEARNING_TRACKS_COUNT:-0}"
check_table "user_lesson_progress" "${USER_PROGRESS_COUNT:-0}"
check_table "learning_track_assignments" "${ASSIGNMENTS_COUNT:-0}"

# Check for critical failures
CRITICAL_ERRORS=$(grep -E "function generate_content_hash.*does not exist" /tmp/restore-demo.log 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# Count how many key tables have data
TABLES_WITH_DATA=0
[ "${PROFILES_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LEARNING_TRACKS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${USER_PROGRESS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${ASSIGNMENTS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))

if [ "$CRITICAL_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗ Restore FAILED - function errors detected${NC}"
    echo -e "${YELLOW}  ${CRITICAL_ERRORS} tables failed due to function errors${NC}"
    echo -e "${YELLOW}  Review /tmp/restore-demo.log for details${NC}"
    exit 1
elif [ "${LESSONS_COUNT:-0}" -eq 0 ] && [ "${PROFILES_COUNT:-0}" -eq 0 ]; then
    echo -e "${RED}✗ Restore FAILED - no data found in key tables${NC}"
    echo -e "${YELLOW}  Review /tmp/restore-demo.log for details${NC}"
    exit 1
elif [ "$TABLES_WITH_DATA" -lt 3 ]; then
    echo -e "${YELLOW}⚠ Restore PARTIAL - only ${TABLES_WITH_DATA}/5 key tables have data${NC}"
    echo -e "${YELLOW}  Review /tmp/restore-demo.log for details${NC}"
else
    echo -e "${GREEN}✓ Demo data restored successfully (${TABLES_WITH_DATA}/5 key tables have data)${NC}"
fi

echo ""
echo -e "${GREEN}✓ Demo data restoration complete!${NC}"
echo "Log file: /tmp/restore-demo.log"

