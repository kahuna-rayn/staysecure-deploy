#!/bin/bash

# Restore Seed Data Script
# Restores seed/reference data from seed.dump or seed.sql to a target database
#
# Seed data includes (reference/template data ONLY):
# - languages (reference data)
# - email_templates, email_layouts (template data)
# - template_variables, template_variable_translations (reference data)
# - products (license management)
# - breach_management_team (govern)
#
# DELIBERATELY EXCLUDED — lesson/track content:
# - lessons, lesson_nodes, lesson_answers (and all their translations)
# - learning_tracks, learning_track_lessons
#   Lesson content must come from master via sync-lesson-content, not the dev seed.
#   After onboarding, run SyncManager to push master lesson content to this client.
#
# Excluded (user-specific data, not seed):
# - email_preferences (has column defaults, function handles missing rows with COALESCE)
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

SEED_DUMP=${1:-"backups/seed.dump"}
PROJECT_REF=${2}

# PROJECT_REF is required - don't default to dev!
if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: PROJECT_REF is required${NC}"
    echo "Usage: ./restore-seed-data.sh [seed-dump-path] <project-ref>"
    echo "Example: ./restore-seed-data.sh backups/seed.dump nfgotwiefhkncoiibnfk"
    echo ""
    echo "  seed-dump-path: Path to seed.dump or seed.sql file (default: backups/seed.dump)"
    echo "  project-ref: Target Supabase project reference where data will be restored (REQUIRED)"
    echo ""
    echo "      PGPASSWORD should be set to the TARGET database password (not source)."
    exit 1
fi

# Determine if input is a .dump (custom format) or .sql file
if [ ! -f "$SEED_DUMP" ]; then
    echo -e "${RED}Error: Seed dump file not found: ${SEED_DUMP}${NC}"
    echo "Usage: ./restore-seed-data.sh [seed-dump-path] <project-ref>"
    echo "Example: ./restore-seed-data.sh backups/seed.dump nfgotwiefhkncoiibnfk"
    exit 1
fi

# Check file extension to determine format
if [[ "$SEED_DUMP" == *.dump ]]; then
    FORMAT="custom"
elif [[ "$SEED_DUMP" == *.sql ]]; then
    FORMAT="sql"
else
    echo -e "${RED}Error: Unsupported file format. Expected .dump or .sql${NC}"
    exit 1
fi

echo -e "${GREEN}Restoring seed data from ${SEED_DUMP}...${NC}"
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

# Detect connection method: direct IPv6 or session-mode pooler fallback
DB_HOSTNAME="db.${PROJECT_REF}.supabase.co"
POOLER_HOST="${POOLER_HOST:-aws-1-${REGION:-ap-southeast-1}.pooler.supabase.com}"
RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v "^\." | head -1)
if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
    export PGHOSTADDR="${RESOLVED_ADDR}"
    PG_HOST="${DB_HOSTNAME}"; PG_PORT=6543; PG_USER="postgres"
    echo -e "${GREEN}Using direct connection (IPv6): ${RESOLVED_ADDR}${NC}"
else
    PG_HOST="${POOLER_HOST}"; PG_PORT=5432; PG_USER="postgres.${PROJECT_REF}"
    echo -e "${YELLOW}Direct connection unavailable — using pooler: ${POOLER_HOST}${NC}"
fi
CONNECTION_STRING="host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres sslmode=require"
DIRECT_CONNECTION_STRING="${CONNECTION_STRING}"

# Verify seed file contains data
if [ "$FORMAT" = "custom" ]; then
    TABLE_COUNT=$(pg_restore --list "$SEED_DUMP" 2>/dev/null | grep -c "TABLE DATA" || echo "0")
    if [ "$TABLE_COUNT" -eq 0 ]; then
        echo -e "${RED}Error: Seed dump file appears to be empty (no TABLE DATA entries found)${NC}"
        exit 1
    fi
    echo -e "${GREEN}Found ${TABLE_COUNT} tables in seed dump${NC}"
    
    # Show which tables will be restored and in what order
    # pg_restore automatically handles dependency order based on the dump's TOC
    echo -e "${GREEN}Tables to restore (in dependency order from dump):${NC}"
    RESTORE_ORDER=$(pg_restore --list "$SEED_DUMP" 2>/dev/null | \
        grep "TABLE DATA public" | \
        sed 's/^[[:space:]]*\([0-9]*\);.*TABLE DATA public \([^ ]*\).*/\1 \2/' | \
        sort -n | \
        awk '{print $2}')
    
    ORDER_NUM=1
    for table in $RESTORE_ORDER; do
        printf "  %2d. %s\n" "$ORDER_NUM" "$table"
        ORDER_NUM=$((ORDER_NUM + 1))
    done
    
    # Expected dependency order (for reference)
    echo ""
    echo -e "${YELLOW}Expected dependency order (for reference):${NC}"
    echo "  1. languages (referenced by translation tables)"
    echo "  2. lessons (parent table)"
    echo "  3. lesson_nodes (depends on lessons)"
    echo "  4. lesson_answers (depends on lesson_nodes)"
    echo "  5. learning_tracks (independent)"
    echo "  6. learning_track_lessons (depends on lessons + learning_tracks)"
    echo "  7. lesson_translations (depends on lessons + languages)"
    echo "  8. lesson_node_translations (depends on lesson_nodes + languages)"
    echo "  9. lesson_answer_translations (depends on lesson_answers + languages)"
    echo "  10. template_variables (independent)"
    echo "  11. template_variable_translations (depends on template_variables + languages)"
    echo "  12. email_layouts (independent)"
    echo "  13. email_templates (depends on email_layouts)"
    
    # Try to get source row counts from dev database if available
    echo ""
    echo -e "${GREEN}Checking source row counts (from dev database)...${NC}"
    DEV_PROJECT_REF="cleqfnrbiqpxpzxkatda"
    if [ -n "$PGPASSWORD" ]; then
        DEV_CONNECTION="host=${POOLER_HOST} port=5432 user=postgres.${DEV_PROJECT_REF} dbname=postgres sslmode=require"
        for table in $RESTORE_ORDER; do
            SOURCE_COUNT=$(psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.${table};" 2>/dev/null | tr -d ' ' || echo "?")
            if [ "$SOURCE_COUNT" != "?" ]; then
                printf "    %-35s %s rows\n" "$table:" "$SOURCE_COUNT"
            fi
        done
    else
        echo -e "${YELLOW}  Set PGPASSWORD to show source row counts${NC}"
    fi
fi

# Restore seed data
if [ "$FORMAT" = "custom" ]; then
    echo -e "${GREEN}Restoring seed data from custom format dump...${NC}"
    
    # Step 1: Disable triggers that use generate_content_hash
    # These triggers fire during COPY and need the function in search_path
    echo "  Step 1: Disabling triggers that use generate_content_hash..."
    # Unset PGOPTIONS for pooler connection (pooler doesn't support options parameter)
    (unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes DISABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations DISABLE TRIGGER update_translation_content_hash_trigger;
EOF
)
    
    # Step 2: Ensure search_path is set for function access
    echo "  Step 2: Setting search_path for function access..."
    # Use direct connection for ALTER DATABASE (pooler may not support it)
    psql "${DIRECT_CONNECTION_STRING}" \
        --command "ALTER DATABASE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true
    # Also set for current role
    psql "${DIRECT_CONNECTION_STRING}" \
        --command "ALTER ROLE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true
    
    # Step 3: Clear existing seed data to avoid duplicates
    echo "  Step 3: Clearing existing seed data (if any)..."
    # Unset PGOPTIONS for pooler connection
    (unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
TRUNCATE TABLE 
    lesson_answer_translations,
    lesson_node_translations,
    lesson_translations,
    lesson_answers,
    lesson_nodes,
    learning_track_lessons,
    lessons,
    learning_tracks,
    template_variable_translations,
    template_variables,
    email_templates,
    email_layouts,
    languages
CASCADE;
EOF
)
    
    # Step 4: Restore data
    echo "  Step 4: Restoring seed data..."
    echo -e "${YELLOW}Note: Some errors are expected and can be ignored:${NC}"
    echo -e "${YELLOW}  - System trigger permission errors (RI_ConstraintTrigger) - filtered from output${NC}"
    echo ""
    
    # Set PGOPTIONS only for pg_restore (direct connection, port 5432)
    # Pooler (port 6543) doesn't support PGOPTIONS, so we unset it for pooler connections
    # This is critical for tables with triggers that use generate_content_hash
    # Note: Use direct connection (5432) instead of pooler (6543) for pg_restore
    # Pooler doesn't support PGOPTIONS and may have issues with triggers
    # Triggers are already disabled, so function errors shouldn't occur
    # Filter out expected errors from output (but still log them to file)
    # RI_ConstraintTrigger errors are system triggers managed by PostgreSQL - we can't restore them and don't need to
    PGOPTIONS="-c search_path=public,pg_catalog" pg_restore \
        --host=${PG_HOST} \
        --port=5432 \
        --user=postgres \
        --dbname=postgres \
        --no-owner \
        --data-only \
        --disable-triggers \
        "$SEED_DUMP" 2>&1 | \
        tee /tmp/restore-seed.log | \
        grep -v "RI_ConstraintTrigger.*is a system trigger" || {
            echo ""
            echo -e "${YELLOW}Analyzing restore errors...${NC}"
            
            # Count different types of errors
            SYSTEM_TRIGGER_ERRORS=$(grep -c "permission denied.*RI_ConstraintTrigger" /tmp/restore-seed.log || echo "0")
            DUPLICATE_KEY_ERRORS=$(grep -c "duplicate key value violates unique constraint" /tmp/restore-seed.log || echo "0")
            FOREIGN_KEY_ERRORS=$(grep -c "violates foreign key constraint" /tmp/restore-seed.log || echo "0")
            OTHER_ERRORS=$(grep "ERROR" /tmp/restore-seed.log | grep -v "permission denied.*RI_ConstraintTrigger" | grep -v "duplicate key value" | grep -v "violates foreign key constraint" | wc -l | tr -d ' ')
            
            if [ "$SYSTEM_TRIGGER_ERRORS" -gt "0" ]; then
                echo -e "${GREEN}  ✓ ${SYSTEM_TRIGGER_ERRORS} system trigger errors (expected, can be ignored)${NC}"
            fi
            if [ "$DUPLICATE_KEY_ERRORS" -gt "0" ]; then
                echo -e "${GREEN}  ✓ ${DUPLICATE_KEY_ERRORS} duplicate key errors (expected if data already exists)${NC}"
            fi
            if [ "$FOREIGN_KEY_ERRORS" -gt "0" ]; then
                echo -e "${YELLOW}  ⚠ ${FOREIGN_KEY_ERRORS} foreign key errors (expected for user-related tables)${NC}"
            fi
            if [ "$OTHER_ERRORS" -gt "0" ]; then
                echo -e "${RED}  ✗ ${OTHER_ERRORS} other errors (may need attention)${NC}"
                echo -e "${YELLOW}Review /tmp/restore-seed.log for details${NC}"
            fi
            
            # Check specifically for function errors on lesson tables
            FUNCTION_ERRORS=$(grep -c "function generate_content_hash.*does not exist" /tmp/restore-seed.log || echo "0")
            if [ "$FUNCTION_ERRORS" -gt "0" ]; then
                echo -e "${YELLOW}  ⚠ ${FUNCTION_ERRORS} function errors detected - attempting manual restore for lesson tables...${NC}"
                
                # Manually restore lesson tables that failed due to function errors
                # These tables have triggers that need generate_content_hash, but triggers are disabled
                # We'll restore them individually with explicit search_path
                LESSON_TABLES="lesson_nodes lesson_answers lesson_node_translations lesson_answer_translations"
                for table in $LESSON_TABLES; do
                    echo -e "${GREEN}    Attempting manual restore of ${table}...${NC}"
                    
                    # Create TOC for this table only
                    TABLE_TOC=$(mktemp)
                    pg_restore --list "$SEED_DUMP" 2>/dev/null | \
                        grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE DATA public ${table}\s" >> "${TABLE_TOC}" || true
                    
                    if [ -s "${TABLE_TOC}" ]; then
                        # Restore with explicit search_path via PGOPTIONS
                        RESTORE_OUTPUT=$(PGOPTIONS="-c search_path=public,pg_catalog" pg_restore \
                            --host=${PG_HOST} \
                            --port=5432 \
                            --user=postgres \
                            --dbname=postgres \
                            --data-only \
                            --no-owner \
                            --disable-triggers \
                            --use-list="${TABLE_TOC}" \
                            "$SEED_DUMP" 2>&1)
                        
                        # Check if restore succeeded (use direct connection for accurate count)
                        ROW_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.${table};" 2>/dev/null | tr -d ' ' || echo "0")
                        if [ "${ROW_COUNT:-0}" -gt 0 ]; then
                            echo -e "${GREEN}    ✓ Restored ${ROW_COUNT} rows to ${table}${NC}"
                        else
                            echo -e "${YELLOW}    ⚠ ${table} still empty after manual restore${NC}"
                            # Show errors
                            echo "$RESTORE_OUTPUT" | grep -E "error|ERROR|Error" | head -3 | sed 's/^/      /' || true
                        fi
                    fi
                    rm -f "${TABLE_TOC}"
                done
            fi
        }
else
    echo -e "${GREEN}Restoring seed data from SQL format...${NC}"
    # Unset PGOPTIONS for pooler connection
    (unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" \
        --single-transaction \
        --variable ON_ERROR_STOP=0 \
        --command 'SET session_replication_role = replica' \
        --file "$SEED_DUMP" 2>&1 | tee /tmp/restore-seed.log || {
            echo -e "${YELLOW}Some errors occurred during SQL restore${NC}"
            echo -e "${YELLOW}Review /tmp/restore-seed.log for details${NC}"
        })
fi

# Step 5: Re-enable triggers
echo "  Step 5: Re-enabling triggers..."
# Unset PGOPTIONS for pooler connection
(unset PGOPTIONS; PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes ENABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations ENABLE TRIGGER update_translation_content_hash_trigger;
EOF
)

# Verify restoration by checking all seed tables
# Use direct connection (5432) for verification to ensure we see committed data
# Pooler (6543) might have transaction isolation issues
echo -e "${GREEN}Verifying restoration...${NC}"
LANGUAGE_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.languages WHERE is_active = true;" 2>/dev/null | tr -d ' ' || echo "0")
LESSONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lessons;" 2>/dev/null | tr -d ' ' || echo "0")
LEARNING_TRACKS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.learning_tracks;" 2>/dev/null | tr -d ' ' || echo "0")
LEARNING_TRACK_LESSONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.learning_track_lessons;" 2>/dev/null | tr -d ' ' || echo "0")
LESSON_NODES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_nodes;" 2>/dev/null | tr -d ' ' || echo "0")
LESSON_ANSWERS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_answers;" 2>/dev/null | tr -d ' ' || echo "0")
LESSON_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_translations;" 2>/dev/null | tr -d ' ' || echo "0")
LESSON_NODE_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_node_translations;" 2>/dev/null | tr -d ' ' || echo "0")
LESSON_ANSWER_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_answer_translations;" 2>/dev/null | tr -d ' ' || echo "0")
TEMPLATE_VARIABLES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.template_variables;" 2>/dev/null | tr -d ' ' || echo "0")
TEMPLATE_VARIABLE_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.template_variable_translations;" 2>/dev/null | tr -d ' ' || echo "0")
EMAIL_TEMPLATES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.email_templates;" 2>/dev/null | tr -d ' ' || echo "0")
EMAIL_LAYOUTS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "${DIRECT_CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.email_layouts;" 2>/dev/null | tr -d ' ' || echo "0")

# Get source counts for comparison if available
DEV_PROJECT_REF="cleqfnrbiqpxpzxkatda"
DEV_CONNECTION="host=${POOLER_HOST} port=5432 user=postgres.${DEV_PROJECT_REF} dbname=postgres sslmode=require"
SOURCE_LANGUAGE_COUNT="?"
SOURCE_LESSONS_COUNT="?"
SOURCE_LEARNING_TRACKS_COUNT="?"
SOURCE_LEARNING_TRACK_LESSONS_COUNT="?"
SOURCE_LESSON_NODES_COUNT="?"
SOURCE_LESSON_ANSWERS_COUNT="?"
SOURCE_LESSON_TRANSLATIONS_COUNT="?"
SOURCE_LESSON_NODE_TRANSLATIONS_COUNT="?"
SOURCE_LESSON_ANSWER_TRANSLATIONS_COUNT="?"
SOURCE_TEMPLATE_VARIABLES_COUNT="?"
SOURCE_TEMPLATE_VARIABLE_TRANSLATIONS_COUNT="?"
SOURCE_EMAIL_TEMPLATES_COUNT="?"
SOURCE_EMAIL_LAYOUTS_COUNT="?"

if [ -n "$PGPASSWORD" ]; then
    SOURCE_LANGUAGE_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.languages WHERE is_active = true;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LESSONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.lessons;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LEARNING_TRACKS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.learning_tracks;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LEARNING_TRACK_LESSONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.learning_track_lessons;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LESSON_NODES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.lesson_nodes;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LESSON_ANSWERS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.lesson_answers;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LESSON_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.lesson_translations;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LESSON_NODE_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.lesson_node_translations;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_LESSON_ANSWER_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.lesson_answer_translations;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_TEMPLATE_VARIABLES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.template_variables;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_TEMPLATE_VARIABLE_TRANSLATIONS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.template_variable_translations;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_EMAIL_TEMPLATES_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.email_templates;" 2>/dev/null | tr -d ' ' || echo "?")
    SOURCE_EMAIL_LAYOUTS_COUNT=$(PGPASSWORD="${PGPASSWORD}" psql "$DEV_CONNECTION" -tAc "SELECT COUNT(*) FROM public.email_layouts;" 2>/dev/null | tr -d ' ' || echo "?")
fi

# Print comparison table
printf "  %-35s %10s %10s %s\n" "Table" "Source" "Restored" "Status"
printf "  %-35s %10s %10s %s\n" "-----------------------------------" "----------" "----------" "------"

compare_counts() {
    local table=$1
    local source=$2
    local restored=$3
    local status=""
    if [ "$source" = "?" ]; then
        status="${YELLOW}?${NC}"
    elif [ "$source" = "$restored" ]; then
        status="${GREEN}✓${NC}"
    else
        status="${YELLOW}⚠${NC}"
    fi
    printf "  %-35s %10s %10s %s\n" "$table" "${source}" "${restored}" "$status"
}

compare_counts "languages" "$SOURCE_LANGUAGE_COUNT" "${LANGUAGE_COUNT:-0}"
compare_counts "lessons" "$SOURCE_LESSONS_COUNT" "${LESSONS_COUNT:-0}"
compare_counts "learning_tracks" "$SOURCE_LEARNING_TRACKS_COUNT" "${LEARNING_TRACKS_COUNT:-0}"
compare_counts "learning_track_lessons" "$SOURCE_LEARNING_TRACK_LESSONS_COUNT" "${LEARNING_TRACK_LESSONS_COUNT:-0}"
compare_counts "lesson_nodes" "$SOURCE_LESSON_NODES_COUNT" "${LESSON_NODES_COUNT:-0}"
compare_counts "lesson_answers" "$SOURCE_LESSON_ANSWERS_COUNT" "${LESSON_ANSWERS_COUNT:-0}"
compare_counts "lesson_translations" "$SOURCE_LESSON_TRANSLATIONS_COUNT" "${LESSON_TRANSLATIONS_COUNT:-0}"
compare_counts "lesson_node_translations" "$SOURCE_LESSON_NODE_TRANSLATIONS_COUNT" "${LESSON_NODE_TRANSLATIONS_COUNT:-0}"
compare_counts "lesson_answer_translations" "$SOURCE_LESSON_ANSWER_TRANSLATIONS_COUNT" "${LESSON_ANSWER_TRANSLATIONS_COUNT:-0}"
compare_counts "template_variables" "$SOURCE_TEMPLATE_VARIABLES_COUNT" "${TEMPLATE_VARIABLES_COUNT:-0}"
compare_counts "template_variable_translations" "$SOURCE_TEMPLATE_VARIABLE_TRANSLATIONS_COUNT" "${TEMPLATE_VARIABLE_TRANSLATIONS_COUNT:-0}"
compare_counts "email_templates" "$SOURCE_EMAIL_TEMPLATES_COUNT" "${EMAIL_TEMPLATES_COUNT:-0}"
compare_counts "email_layouts" "$SOURCE_EMAIL_LAYOUTS_COUNT" "${EMAIL_LAYOUTS_COUNT:-0}"

# Check for critical failures
CRITICAL_ERRORS=$(grep -E "function generate_content_hash.*does not exist" /tmp/restore-seed.log 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# Count how many tables have data
TABLES_WITH_DATA=0
[ "${LANGUAGE_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LEARNING_TRACKS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LEARNING_TRACK_LESSONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSON_NODES_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSON_ANSWERS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSON_TRANSLATIONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSON_NODE_TRANSLATIONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${LESSON_ANSWER_TRANSLATIONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${TEMPLATE_VARIABLES_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${TEMPLATE_VARIABLE_TRANSLATIONS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${EMAIL_TEMPLATES_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))
[ "${EMAIL_LAYOUTS_COUNT:-0}" -gt 0 ] && TABLES_WITH_DATA=$((TABLES_WITH_DATA + 1))

if [ "$CRITICAL_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗ Restore FAILED - function errors detected${NC}"
    echo -e "${YELLOW}  ${CRITICAL_ERRORS} tables failed due to function errors${NC}"
    echo -e "${YELLOW}  Review /tmp/restore-seed.log for details${NC}"
    exit 1
elif [ "${LANGUAGE_COUNT:-0}" -eq 0 ] && [ "${LESSONS_COUNT:-0}" -eq 0 ]; then
    echo -e "${RED}✗ Restore FAILED - no data found in key tables${NC}"
    echo -e "${YELLOW}  Review /tmp/restore-seed.log for details${NC}"
    exit 1
elif [ "$TABLES_WITH_DATA" -lt 10 ]; then
    echo -e "${YELLOW}⚠ Restore PARTIAL - only ${TABLES_WITH_DATA}/13 tables have data${NC}"
    echo -e "${YELLOW}  Review /tmp/restore-seed.log for details${NC}"
else
    echo -e "${GREEN}✓ Seed data restored successfully (${TABLES_WITH_DATA}/13 tables have data)${NC}"
fi

# Show summary comparison (we can't get source row counts from custom format easily)
# But we can note which tables are empty vs have data
echo ""
echo -e "${GREEN}Restore Summary:${NC}"
EMPTY_TABLES=""
if [ "${LANGUAGE_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} languages"; fi
if [ "${LESSONS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} lessons"; fi
if [ "${LEARNING_TRACKS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} learning_tracks"; fi
if [ "${LEARNING_TRACK_LESSONS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} learning_track_lessons"; fi
if [ "${LESSON_NODES_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} lesson_nodes"; fi
if [ "${LESSON_ANSWERS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} lesson_answers"; fi
if [ "${LESSON_TRANSLATIONS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} lesson_translations"; fi
if [ "${LESSON_NODE_TRANSLATIONS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} lesson_node_translations"; fi
if [ "${LESSON_ANSWER_TRANSLATIONS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} lesson_answer_translations"; fi
if [ "${TEMPLATE_VARIABLES_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} template_variables"; fi
if [ "${TEMPLATE_VARIABLE_TRANSLATIONS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} template_variable_translations"; fi
if [ "${EMAIL_TEMPLATES_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} email_templates"; fi
if [ "${EMAIL_LAYOUTS_COUNT:-0}" -eq 0 ]; then EMPTY_TABLES="${EMPTY_TABLES} email_layouts"; fi

if [ -n "$EMPTY_TABLES" ]; then
    echo -e "${YELLOW}Empty tables:${EMPTY_TABLES}${NC}"
else
    echo -e "${GREEN}All tables have data${NC}"
fi

echo ""
echo -e "${GREEN}✓ Seed data restoration complete!${NC}"
echo "Log file: /tmp/restore-seed.log"

