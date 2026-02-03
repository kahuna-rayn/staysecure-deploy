#!/bin/bash

# Fix Missing Lesson Tables Script
# Restores lesson_nodes, lesson_answers, lesson_node_translations, lesson_answer_translations
# that may have failed during initial seed data restore
# Usage: ./fix-missing-lesson-tables.sh <project-ref> [seed-dump-path]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROJECT_REF="${1}"
SEED_DUMP="${2:-backups/seed.dump}"

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: Project reference is required${NC}"
    echo "Usage: ./fix-missing-lesson-tables.sh <project-ref> [seed-dump-path]"
    echo "Example: ./fix-missing-lesson-tables.sh cleqfnrbiqpxpzxkatda"
    exit 1
fi

if [ ! -f "$SEED_DUMP" ]; then
    echo -e "${RED}Error: Seed dump file not found: ${SEED_DUMP}${NC}"
    exit 1
fi

# Check prerequisites
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    exit 1
fi

CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"
DIRECT_CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=5432 user=postgres dbname=postgres sslmode=require"

echo -e "${GREEN}Fixing missing lesson tables in project: ${PROJECT_REF}${NC}"
echo ""

# Step 1: Disable triggers
echo -e "${GREEN}Step 1: Disabling triggers...${NC}"
psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes DISABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations DISABLE TRIGGER update_translation_content_hash_trigger;
EOF

# Step 2: Set search_path
echo -e "${GREEN}Step 2: Setting search_path...${NC}"
psql "${DIRECT_CONNECTION_STRING}" \
    --command "ALTER DATABASE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true
psql "${DIRECT_CONNECTION_STRING}" \
    --command "ALTER ROLE postgres SET search_path = public, pg_catalog;" >/dev/null 2>&1 || true

# Step 3: Clear existing data (if any)
echo -e "${GREEN}Step 3: Clearing existing data from lesson tables...${NC}"
psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
TRUNCATE TABLE 
    lesson_answer_translations,
    lesson_node_translations,
    lesson_answers,
    lesson_nodes
CASCADE;
EOF

# Step 4: Restore each table individually
echo -e "${GREEN}Step 4: Restoring lesson tables individually...${NC}"
export PGOPTIONS="-c search_path=public,pg_catalog"

LESSON_TABLES="lesson_nodes lesson_answers lesson_node_translations lesson_answer_translations"

for table in $LESSON_TABLES; do
    echo -e "${YELLOW}  Restoring ${table}...${NC}"
    
    # Create TOC for this table only
    TABLE_TOC=$(mktemp)
    pg_restore --list "$SEED_DUMP" 2>/dev/null | \
        grep -E "^\s*[0-9]+;\s+[0-9]+\s+[0-9]+\s+TABLE DATA public ${table}\s" >> "${TABLE_TOC}" || true
    
    if [ -s "${TABLE_TOC}" ]; then
        # Restore with explicit search_path
        RESTORE_OUTPUT=$(PGOPTIONS="-c search_path=public,pg_catalog" pg_restore \
            --host=db.${PROJECT_REF}.supabase.co \
            --port=5432 \
            --user=postgres \
            --dbname=postgres \
            --data-only \
            --no-owner \
            --disable-triggers \
            --use-list="${TABLE_TOC}" \
            "$SEED_DUMP" 2>&1)
        
        # Check for errors
        if echo "$RESTORE_OUTPUT" | grep -qE "error|ERROR|Error" && ! echo "$RESTORE_OUTPUT" | grep -q "RI_ConstraintTrigger"; then
            echo -e "${RED}    ✗ Errors during restore:${NC}"
            echo "$RESTORE_OUTPUT" | grep -E "error|ERROR|Error" | head -3 | sed 's/^/      /'
        fi
        
        # Verify rows were inserted
        ROW_COUNT=$(psql "${CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.${table};" 2>/dev/null | tr -d ' ')
        if [ "${ROW_COUNT:-0}" -gt 0 ]; then
            echo -e "${GREEN}    ✓ Restored ${ROW_COUNT} rows to ${table}${NC}"
        else
            echo -e "${YELLOW}    ⚠ ${table} is still empty${NC}"
        fi
    else
        echo -e "${YELLOW}    ⚠ No data found for ${table} in seed dump${NC}"
    fi
    
    rm -f "${TABLE_TOC}"
done

# Step 5: Re-enable triggers
echo -e "${GREEN}Step 5: Re-enabling triggers...${NC}"
psql "${CONNECTION_STRING}" <<EOF 2>&1 | grep -v "does not exist" || true
ALTER TABLE public.lesson_nodes ENABLE TRIGGER update_node_content_hash_trigger;
ALTER TABLE public.lesson_node_translations ENABLE TRIGGER update_translation_content_hash_trigger;
EOF

# Step 6: Verify
echo ""
echo -e "${GREEN}Verification:${NC}"
LESSON_NODES_COUNT=$(psql "${CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_nodes;" 2>/dev/null | tr -d ' ')
LESSON_ANSWERS_COUNT=$(psql "${CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_answers;" 2>/dev/null | tr -d ' ')
LESSON_NODE_TRANSLATIONS_COUNT=$(psql "${CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_node_translations;" 2>/dev/null | tr -d ' ')
LESSON_ANSWER_TRANSLATIONS_COUNT=$(psql "${CONNECTION_STRING}" -tAc "SELECT COUNT(*) FROM public.lesson_answer_translations;" 2>/dev/null | tr -d ' ')

printf "  %-35s %10s\n" "Table" "Row Count"
printf "  %-35s %10s\n" "-----------------------------------" "----------"
printf "  %-35s %10s\n" "lesson_nodes" "${LESSON_NODES_COUNT:-0}"
printf "  %-35s %10s\n" "lesson_answers" "${LESSON_ANSWERS_COUNT:-0}"
printf "  %-35s %10s\n" "lesson_node_translations" "${LESSON_NODE_TRANSLATIONS_COUNT:-0}"
printf "  %-35s %10s\n" "lesson_answer_translations" "${LESSON_ANSWER_TRANSLATIONS_COUNT:-0}"

echo ""
if [ "${LESSON_NODES_COUNT:-0}" -gt 0 ] && [ "${LESSON_ANSWERS_COUNT:-0}" -gt 0 ]; then
    echo -e "${GREEN}✓ Lesson tables restored successfully!${NC}"
else
    echo -e "${YELLOW}⚠ Some lesson tables may still be empty${NC}"
    echo -e "${YELLOW}  Check the errors above for details${NC}"
fi

