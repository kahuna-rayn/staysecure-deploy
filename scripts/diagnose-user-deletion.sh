#!/bin/bash

# Script to diagnose why a user cannot be deleted
# Usage: ./diagnose-user-deletion.sh <email>

set -e

EMAIL="${1:-richard@raynsecure.com}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Diagnosing user deletion issue for: ${EMAIL}${NC}"
echo ""

# Check if Supabase CLI is available
if ! command -v supabase &> /dev/null; then
    echo -e "${RED}Error: supabase CLI not found. Please install it first.${NC}"
    exit 1
fi

# Get project ref from user or use default
read -p "Enter Supabase project ref (or press Enter for master nfbidnlkwdeyziydxcoj): " PROJECT_REF
PROJECT_REF=${PROJECT_REF:-nfbidnlkwdeyziydxcoj}

echo ""
echo -e "${YELLOW}Querying project: ${PROJECT_REF}${NC}"
echo ""

# SQL query to find user and check for blocking records
SQL_QUERY=$(cat <<EOF
-- Find user ID
DO \$\$
DECLARE
    user_uuid UUID;
    user_email TEXT;
BEGIN
    -- Get user ID from email
    SELECT id, email INTO user_uuid, user_email
    FROM auth.users
    WHERE email = '${EMAIL}';
    
    IF user_uuid IS NULL THEN
        RAISE NOTICE 'User not found in auth.users';
        RETURN;
    END IF;
    
    RAISE NOTICE 'Found user: % (ID: %)', user_email, user_uuid;
    
    -- Check for records in various tables
    RAISE NOTICE '';
    RAISE NOTICE '=== Checking for blocking records ===';
    
    -- Lessons table (owner field)
    IF EXISTS (SELECT 1 FROM lessons WHERE owner = (SELECT org_short_name FROM org_profile LIMIT 1) AND created_by = user_uuid) THEN
        RAISE NOTICE '⚠️  lessons table has records with created_by = %', user_uuid;
        RAISE NOTICE '   Count: %', (SELECT COUNT(*) FROM lessons WHERE created_by = user_uuid);
    END IF;
    
    -- Check lessons with owner
    IF EXISTS (SELECT 1 FROM lessons WHERE owner IS NOT NULL) THEN
        RAISE NOTICE '⚠️  lessons table has owner field - checking if user created lessons...';
        RAISE NOTICE '   Lessons created by user: %', (SELECT COUNT(*) FROM lessons WHERE created_by = user_uuid);
    END IF;
    
    -- Check other common blocking tables
    DECLARE
        table_name TEXT;
        count_val INTEGER;
    BEGIN
        FOR table_name IN 
            SELECT unnest(ARRAY[
                'user_roles',
                'user_departments',
                'user_profile_roles',
                'user_learning_track_progress',
                'user_lesson_progress',
                'physical_location_access',
                'learning_track_assignments',
                'document_assignments',
                'certificates',
                'quiz_attempts',
                'user_answer_responses',
                'user_behavior_analytics',
                'breach_team_members',
                'hib_checklist',
                'hib_results',
                'csba_answers',
                'document_users',
                'email_notifications',
                'email_preferences',
                'product_license_assignments',
                'user_phishing_scores',
                'hardware_inventory',
                'account_inventory',
                'lesson_reminder_history',
                'lesson_reminder_counts'
            ])
        LOOP
            EXECUTE format('SELECT COUNT(*) FROM %I WHERE user_id = $1', table_name) INTO count_val USING user_uuid;
            IF count_val > 0 THEN
                RAISE NOTICE '⚠️  % has % records', table_name, count_val;
            END IF;
        END LOOP;
    END;
    
    -- Check reference tables (created_by, modified_by, etc.)
    RAISE NOTICE '';
    RAISE NOTICE '=== Checking reference tables ===';
    
    DECLARE
        ref_table TEXT;
        ref_column TEXT;
        ref_count INTEGER;
    BEGIN
        FOR ref_table, ref_column IN 
            SELECT 'account_inventory', 'created_by' UNION ALL
            SELECT 'account_inventory', 'modified_by' UNION ALL
            SELECT 'account_inventory', 'authorized_by' UNION ALL
            SELECT 'key_dates', 'created_by' UNION ALL
            SELECT 'key_dates', 'modified_by' UNION ALL
            SELECT 'learning_tracks', 'created_by' UNION ALL
            SELECT 'departments', 'manager_id' UNION ALL
            SELECT 'document_assignments', 'assigned_by' UNION ALL
            SELECT 'learning_track_assignments', 'assigned_by' UNION ALL
            SELECT 'lessons', 'created_by'
        LOOP
            BEGIN
                EXECUTE format('SELECT COUNT(*) FROM %I WHERE %I = $1', ref_table, ref_column) 
                    INTO ref_count USING user_uuid;
                IF ref_count > 0 THEN
                    RAISE NOTICE '⚠️  %.% has % records', ref_table, ref_column, ref_count;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                -- Table or column doesn't exist, skip
                NULL;
            END;
        END LOOP;
    END;
    
END \$\$;
EOF
)

# Execute query
echo "Running diagnostic query..."
echo ""

supabase db execute "$SQL_QUERY" --project-ref "$PROJECT_REF" 2>&1 || {
    echo -e "${RED}Error executing query. Trying alternative method...${NC}"
    echo ""
    echo "Please run this SQL query manually in Supabase SQL Editor:"
    echo ""
    echo "$SQL_QUERY"
}

echo ""
echo -e "${GREEN}Diagnostic complete!${NC}"
echo ""
echo "If you see blocking records, you can:"
echo "1. Update the delete-user Edge Function to handle those tables"
echo "2. Manually delete/update those records"
echo "3. Use the fix-user-deletion.sh script to clean up"

