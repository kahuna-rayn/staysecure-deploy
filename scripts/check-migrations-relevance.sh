#!/bin/bash
# Check which migration files are still relevant by comparing with dev database
# Since dev is the source of truth, if changes are already in dev, migrations can be archived

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
DEV_PROJECT_REF=${1:-"cleqfnrbiqpxpzxkatda"}  # Default to dev project
REGION=${2:-"ap-southeast-1"}

echo -e "${GREEN}Checking migration relevance against dev database...${NC}"
echo -e "${CYAN}Dev Project: ${DEV_PROJECT_REF}${NC}"
echo ""

# Check if PGPASSWORD is set
if [ -z "$PGPASSWORD" ]; then
    echo -e "${YELLOW}Warning: PGPASSWORD not set. You may need to enter password.${NC}"
    echo -e "${YELLOW}Set PGPASSWORD or enter password when prompted.${NC}"
    echo ""
fi

CONNECTION_STRING="host=db.${DEV_PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

# Function to run a SQL query and return result
run_query() {
    local query="$1"
    psql "${CONNECTION_STRING}" -t -A -c "$query" 2>/dev/null || echo "ERROR"
}

# Function to check if a table exists
table_exists() {
    local table_name="$1"
    local result=$(run_query "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${table_name}');")
    [ "$result" = "t" ]
}

# Function to check if a column exists in a table
column_exists() {
    local table_name="$1"
    local column_name="$2"
    local result=$(run_query "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '${table_name}' AND column_name = '${column_name}');")
    [ "$result" = "t" ]
}

# Function to check if a function exists
function_exists() {
    local function_name="$1"
    local result=$(run_query "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = '${function_name}');")
    [ "$result" = "t" ]
}

# Function to check table structure (key columns)
check_email_preferences_structure() {
    local has_id=false
    local has_user_id_nullable=false
    local has_track_completions=false
    
    if column_exists "email_preferences" "id"; then
        has_id=true
    fi
    
    if column_exists "email_preferences" "user_id"; then
        local nullable=$(run_query "SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'email_preferences' AND column_name = 'user_id';")
        if [ "$nullable" = "YES" ]; then
            has_user_id_nullable=true
        fi
    fi
    
    # Check for track_completions (new name) or course_completions (old name)
    if column_exists "email_preferences" "track_completions"; then
        has_track_completions=true
    elif column_exists "email_preferences" "course_completions"; then
        has_track_completions=true  # Old name, but column exists
    fi
    
    echo "$has_id|$has_user_id_nullable|$has_track_completions"
}

echo -e "${BLUE}=== Checking Migration Status ===${NC}"
echo ""

# Track results
ARCHIVED=()
KEEP=()
UNKNOWN=()

# 1. Check email_preferences migrations (Jan 2025)
echo -e "${CYAN}1. Email Preferences Migrations${NC}"

if table_exists "email_preferences"; then
    structure=$(check_email_preferences_structure)
    has_id=$(echo "$structure" | cut -d'|' -f1)
    has_user_id_nullable=$(echo "$structure" | cut -d'|' -f2)
    has_completions=$(echo "$structure" | cut -d'|' -f3)
    
    if [ "$has_id" = "true" ] && [ "$has_user_id_nullable" = "true" ]; then
        echo -e "  ✅ ${GREEN}20250115_consolidate_email_preferences.sql${NC} - Already applied (consolidated structure exists)"
        ARCHIVED+=("20250115_consolidate_email_preferences.sql")
    else
        echo -e "  ⚠️  ${YELLOW}20250115_consolidate_email_preferences.sql${NC} - Check needed (structure differs)"
        UNKNOWN+=("20250115_consolidate_email_preferences.sql")
    fi
    
    if [ "$has_id" = "false" ]; then
        echo -e "  ⚠️  ${YELLOW}20250113_fix_email_preferences.sql${NC} - May be needed (old structure)"
        UNKNOWN+=("20250113_fix_email_preferences.sql")
    else
        echo -e "  ✅ ${GREEN}20250113_fix_email_preferences.sql${NC} - Already applied (new structure exists)"
        ARCHIVED+=("20250113_fix_email_preferences.sql")
    fi
else
    echo -e "  ❌ ${RED}email_preferences table does not exist!${NC}"
    KEEP+=("20250113_fix_email_preferences.sql")
    KEEP+=("20250115_consolidate_email_preferences.sql")
fi

# Check lesson_reminder_config (should be dropped)
if table_exists "lesson_reminder_config"; then
    echo -e "  ⚠️  ${YELLOW}20250115_drop_lesson_reminder_config.sql${NC} - Still needed (table exists, should be dropped)"
    KEEP+=("20250115_drop_lesson_reminder_config.sql")
else
    echo -e "  ✅ ${GREEN}20250115_drop_lesson_reminder_config.sql${NC} - Already applied (table is dropped)"
    ARCHIVED+=("20250115_drop_lesson_reminder_config.sql")
fi

# Check function
if function_exists "get_users_needing_lesson_reminders"; then
    echo -e "  ✅ ${GREEN}20250113_fix_lesson_reminders_function.sql${NC} - Function exists (likely applied)"
    ARCHIVED+=("20250113_fix_lesson_reminders_function.sql")
else
    echo -e "  ❌ ${RED}20250113_fix_lesson_reminders_function.sql${NC} - Function missing!"
    KEEP+=("20250113_fix_lesson_reminders_function.sql")
fi

echo ""

# 2. Check notification system migrations (Oct 2024)
echo -e "${CYAN}2. Notification System Migrations${NC}"

if table_exists "notification_rules"; then
    echo -e "  ✅ ${GREEN}20251015_notification_rules.sql${NC} - Already applied (table exists)"
    ARCHIVED+=("20251015_notification_rules.sql")
else
    echo -e "  ❌ ${RED}20251015_notification_rules.sql${NC} - Table missing!"
    KEEP+=("20251015_notification_rules.sql")
fi

if table_exists "notification_history"; then
    echo -e "  ✅ ${GREEN}notification_history${NC} - Table exists (referenced in code)"
    # Note: No specific migration file for this, likely in backup
else
    echo -e "  ⚠️  ${YELLOW}notification_history${NC} - Table missing (check if needed)"
fi

# Check if email_templates has new columns from enhance_email_templates
if table_exists "email_templates"; then
    if column_exists "email_templates" "layout_id"; then
        echo -e "  ✅ ${GREEN}20251015_enhance_email_templates.sql${NC} - Already applied (layout_id exists)"
        ARCHIVED+=("20251015_enhance_email_templates.sql")
    else
        echo -e "  ⚠️  ${YELLOW}20251015_enhance_email_templates.sql${NC} - Check needed (layout_id missing)"
        UNKNOWN+=("20251015_enhance_email_templates.sql")
    fi
else
    echo -e "  ❌ ${RED}email_templates table does not exist!${NC}"
    KEEP+=("20251015_enhance_email_templates.sql")
fi

if table_exists "email_layouts"; then
    echo -e "  ✅ ${GREEN}20251016_email_layouts.sql${NC} - Already applied (table exists)"
    ARCHIVED+=("20251016_email_layouts.sql")
else
    echo -e "  ❌ ${RED}20251016_email_layouts.sql${NC} - Table missing!"
    KEEP+=("20251016_email_layouts.sql")
fi

echo ""

# 3. Check lesson reminders migrations
echo -e "${CYAN}3. Lesson Reminders Migrations${NC}"

if table_exists "lesson_reminder_history"; then
    echo -e "  ✅ ${GREEN}20251008_lesson_reminders.sql${NC} - Already applied (table exists)"
    ARCHIVED+=("20251008_lesson_reminders.sql")
else
    echo -e "  ⚠️  ${YELLOW}20251008_lesson_reminders.sql${NC} - Check needed"
    UNKNOWN+=("20251008_lesson_reminders.sql")
fi

if function_exists "get_users_needing_lesson_reminders"; then
    echo -e "  ✅ ${GREEN}Lesson reminder functions${NC} - Functions exist"
    # Archive related function migrations
    ARCHIVED+=("fix_lesson_reminders_function.sql")
    ARCHIVED+=("deploy_7day_reminder_system.sql")
    ARCHIVED+=("update_reminder_function_7days.sql")
else
    echo -e "  ⚠️  ${YELLOW}Lesson reminder functions${NC} - Check needed"
    KEEP+=("fix_lesson_reminders_function.sql")
    KEEP+=("deploy_7day_reminder_system.sql")
    KEEP+=("update_reminder_function_7days.sql")
fi

# Check cron jobs (pg_cron)
cron_count=$(run_query "SELECT COUNT(*) FROM cron.job WHERE jobname IN ('process-manager-notifications', 'send-daily-lesson-reminders');" 2>/dev/null || echo "0")
if [ "$cron_count" != "0" ] && [ "$cron_count" != "ERROR" ]; then
    echo -e "  ✅ ${GREEN}20251008_lesson_reminders_cron.sql${NC} - Cron jobs exist"
    ARCHIVED+=("20251008_lesson_reminders_cron.sql")
else
    echo -e "  ⚠️  ${YELLOW}20251008_lesson_reminders_cron.sql${NC} - Check needed"
    UNKNOWN+=("20251008_lesson_reminders_cron.sql")
fi

echo ""

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo ""

if [ ${#ARCHIVED[@]} -gt 0 ]; then
    echo -e "${GREEN}✅ Can be archived (already in dev):${NC}"
    for file in "${ARCHIVED[@]}"; do
        echo -e "   - $file"
    done
    echo ""
fi

if [ ${#KEEP[@]} -gt 0 ]; then
    echo -e "${RED}❌ Keep (not yet in dev or needed):${NC}"
    for file in "${KEEP[@]}"; do
        echo -e "   - $file"
    done
    echo ""
fi

if [ ${#UNKNOWN[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Needs manual verification:${NC}"
    for file in "${UNKNOWN[@]}"; do
        echo -e "   - $file"
    done
    echo ""
fi

# Recommendation
echo -e "${CYAN}Recommendation:${NC}"
echo ""
if [ ${#ARCHIVED[@]} -gt 0 ]; then
    echo -e "${GREEN}Archive these files since changes are already in dev:${NC}"
    echo "  mkdir -p supabase/migrations/archived"
    for file in "${ARCHIVED[@]}"; do
        if [ -f "supabase/migrations/$file" ]; then
            echo "  mv supabase/migrations/$file supabase/migrations/archived/"
        fi
    done
    echo ""
fi

if [ ${#KEEP[@]} -gt 0 ]; then
    echo -e "${RED}These need to be applied to dev first (if not already):${NC}"
    for file in "${KEEP[@]}"; do
        echo "  - $file"
    done
    echo -e "${YELLOW}Then recreate backup from dev and archive the migrations.${NC}"
    echo ""
fi

echo -e "${BLUE}Note: This is a best-effort check. Verify manually if unsure.${NC}"

