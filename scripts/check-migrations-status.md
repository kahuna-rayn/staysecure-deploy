# Migration Files Status Check

## How to Determine if a Migration is Still Relevant

Since **dev database is the source of truth** and all new databases are built from dev's backup:

### ✅ Can be archived if:
- Changes are already in dev database
- No existing databases were created before the change

### ⚠️ Still needed if:
- Changes are NOT yet in dev database (apply to dev first, then archive)
- You have existing databases created before the change that need updating

## Recent Migration Files to Check

### January 2025 (Most Recent)
1. **20250113_fix_email_preferences.sql**
   - Creates/fixes `email_preferences` table with RLS policies
   - **Check dev:** Does `email_preferences` table exist with correct structure?

2. **20250113_fix_lesson_reminders_function.sql**
   - Fixes `get_users_needing_lesson_reminders()` function
   - **Check dev:** Does this function work correctly?

3. **20250115_consolidate_email_preferences.sql**
   - Drops and recreates `email_preferences` with new structure (org-level support)
   - **Check dev:** Does `email_preferences` have `user_id NULL` for org-level settings?

4. **20250115_drop_lesson_reminder_config.sql**
   - Drops old `lesson_reminder_config` table
   - **Check dev:** Does this table still exist? (Should be dropped)

### October 2024 (Referenced in docs)
5. **20251015_enhance_email_templates.sql** - Referenced in docs
6. **20251015_notification_rules.sql** - Referenced in docs  
7. **20251016_email_layouts.sql** - Referenced in docs
8. **20251008_lesson_reminders.sql** - Referenced in docs

## Quick Check Commands

To check if a migration's changes are already in dev:

```sql
-- Check if email_preferences exists and has correct structure
SELECT column_name, data_type, is_nullable 
FROM information_schema.columns 
WHERE table_schema = 'public' 
  AND table_name = 'email_preferences'
ORDER BY ordinal_position;

-- Check if lesson_reminder_config is dropped
SELECT EXISTS (
  SELECT 1 FROM information_schema.tables 
  WHERE table_schema = 'public' 
    AND table_name = 'lesson_reminder_config'
) AS table_exists;

-- Check if function exists
SELECT routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = 'get_users_needing_lesson_reminders';
```

## Recommendation

Since you mentioned the changes are already in dev:
1. ✅ **Archive all migrations** that have changes already in dev
2. ⚠️ **Keep migrations** only if you need to update existing databases that predate the changes
3. 🔄 **For future changes:** Apply directly to dev, then recreate backup - no migration files needed

