#!/bin/bash
# Analyze migration files to determine which are still relevant
# Based on whether changes are already in dev database (source of truth)

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Analyzing migration files...${NC}"
echo ""

MIGRATIONS_DIR="supabase/migrations"
RECENT_MIGRATIONS=$(find "$MIGRATIONS_DIR" -name "*.sql" -type f ! -path "*/archived/*" | sort | tail -20)

echo -e "${BLUE}Recent Migration Files:${NC}"
echo ""

for file in $RECENT_MIGRATIONS; do
    filename=$(basename "$file")
    echo -e "${YELLOW}$filename${NC}"
    
    # Extract what the migration does
    first_line=$(head -n 3 "$file" | grep -v "^--" | head -n 1 | sed 's/^[[:space:]]*//' | head -c 100)
    
    # Check for common patterns
    if grep -q "CREATE TABLE" "$file"; then
        tables=$(grep -oP "CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(?:public\.)?(\w+)" "$file" | sed 's/CREATE TABLE.*//' | sed 's/.*\.//' | sort -u | tr '\n' ',' | sed 's/,$//')
        echo "  Creates tables: ${tables:-none}"
    fi
    
    if grep -q "CREATE OR REPLACE FUNCTION" "$file"; then
        functions=$(grep -oP "CREATE OR REPLACE FUNCTION\s+(?:public\.)?(\w+)" "$file" | sed 's/CREATE OR REPLACE FUNCTION.*//' | sed 's/.*\.//' | sort -u | tr '\n' ',' | sed 's/,$//')
        echo "  Creates/replaces functions: ${functions:-none}"
    fi
    
    if grep -q "ALTER TABLE" "$file"; then
        echo "  Alters tables (check manually)"
    fi
    
    if grep -q "DROP TABLE" "$file"; then
        tables=$(grep -oP "DROP TABLE\s+(?:IF EXISTS\s+)?(?:public\.)?(\w+)" "$file" | sed 's/DROP TABLE.*//' | sed 's/.*\.//' | sort -u | tr '\n' ',' | sed 's/,$//')
        echo "  Drops tables: ${tables:-none}"
    fi
    
    # Check if referenced in code/docs
    refs=$(grep -r "$filename" . --include="*.sh" --include="*.md" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$refs" -gt 0 ]; then
        echo "  Referenced in $refs file(s)"
    fi
    
    echo ""
done

echo -e "${BLUE}Summary:${NC}"
echo ""
echo "Migration files are relevant if:"
echo "  1. They contain fixes not yet in dev database"
echo "  2. They need to be applied to existing databases (created before fix)"
echo "  3. They're referenced in scripts/documentation"
echo ""
echo -e "${YELLOW}Since dev is the source of truth and new databases are built from backups:${NC}"
echo "  - If changes are already in dev → migration can be archived"
echo "  - If changes are NOT in dev → migration should be applied to dev first"
echo "  - Migrations are only needed for existing databases that predate the changes"
echo ""

