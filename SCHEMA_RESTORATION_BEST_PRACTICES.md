# Schema Restoration Best Practices

## Critical Rule: NEVER Drop the Public Schema

**⚠️ IMPORTANT**: Dropping the `public` schema will break authentication, triggers, and RLS policies.

### What Happens When You Drop Public Schema

When you run `DROP SCHEMA public CASCADE`, PostgreSQL removes:
- All tables, functions, triggers, RLS policies
- **Critical objects in the `auth` schema that depend on `public`**:
  - Triggers on `auth.users` (like `on_auth_user_created`)
  - Functions that reference `public` tables
  - Cross-schema dependencies

### Symptoms of Dropped Schema

If you drop the schema, you'll experience:
- ✅ Users can be created in `auth.users`
- ❌ `auth.uid()` returns `NULL` in database queries
- ❌ RLS policies fail (403 Forbidden errors)
- ❌ `handle_new_user()` trigger doesn't fire
- ❌ Profiles and `user_roles` aren't created automatically
- ❌ User authentication works but API calls fail

### The Fix: Don't Drop, Just Apply

Instead of dropping and recreating, **apply schema parts over existing schema**:

```bash
# ✅ CORRECT: Apply schema parts without dropping
./scripts/apply-schema-parts.sh backups/schema_parts <PROJECT_REF> no

# ❌ WRONG: Don't do this
psql ... --command "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
```

## Safe Schema Restoration Process

### For New Projects (Onboarding)

Use `onboard-client.sh` which:
1. Creates a fresh Supabase project (empty database)
2. Restores `schema.sql` (creates all objects)
3. Restores data (`seed.sql` or `demo.sql`)
4. Creates triggers and grants permissions
5. **Does NOT drop any schema**

```bash
./scripts/onboard-client.sh staging staging staging.staysecure-learn.raynsecure.com seed
```

### For Existing Projects (Reset/Restore)

**Option 1: Use apply-schema-parts.sh (Recommended)**

```bash
# Default behavior: doesn't drop schema, applies parts gracefully
./scripts/apply-schema-parts.sh backups/schema_parts <PROJECT_REF>

# Explicitly set to no (default anyway)
./scripts/apply-schema-parts.sh backups/schema_parts <PROJECT_REF> no
```

This will:
- Apply schema parts in dependency order
- Skip objects that already exist (graceful)
- Filter out "already exists" errors
- Create missing objects
- **Preserve triggers, functions, and RLS policies**

**Option 2: Manual Reset (Advanced)**

If you MUST reset, use targeted cleanup:

```bash
# Only drop specific tables/data, not the entire schema
psql "$CONNECTION_STRING" --command "
  -- Drop tables only (not schema)
  DROP TABLE IF EXISTS public.user_roles CASCADE;
  DROP TABLE IF EXISTS public.profiles CASCADE;
  -- ... other tables
  
  -- Then restore schema
  -- This preserves schema-level objects
"
```

**NEVER DO THIS:**
```bash
# ❌ NEVER DROP THE SCHEMA
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
```

## Why This Matters

### Database Object Dependencies

PostgreSQL objects have complex dependencies:
- `auth.users` trigger → calls `public.handle_new_user()`
- `public.handle_new_user()` → inserts into `public.profiles`
- RLS policies → reference `public.has_role()` function
- Functions → use `auth.uid()` which depends on JWT context

Dropping `public` breaks these dependencies even if you recreate the schema.

### Authentication Flow

1. User signs up → `auth.users` table gets new row
2. Trigger `on_auth_user_created` fires → calls `handle_new_user()`
3. Function creates `profiles` row and `user_roles` row
4. RLS policies check `auth.uid()` → reads from JWT
5. Policies allow/deny access based on user role

If any step breaks, authentication appears to work but API calls fail.

## Verification After Restoration

After restoring schema, verify:

```sql
-- Check trigger exists
SELECT tgname, tgrelid::regclass, proname 
FROM pg_trigger t 
JOIN pg_proc p ON t.tgfoid = p.oid 
WHERE tgname = 'on_auth_user_created';

-- Check function exists and is SECURITY DEFINER
SELECT proname, prosecdef 
FROM pg_proc 
WHERE proname = 'handle_new_user';

-- Check RLS is enabled
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename IN ('profiles', 'user_roles');

-- Test auth.uid() (should return user ID when authenticated)
SELECT auth.uid();
```

## Scripts Already Configured Correctly

### ✅ `onboard-client.sh`
- Does NOT drop schema
- Creates objects fresh (new project)
- Lines 152-158: Schema drop is commented out

### ✅ `apply-schema-parts.sh`
- Default: `RESET_SCHEMA=no`
- Applies parts gracefully
- Filters "already exists" errors
- Only creates missing objects

## Production Reset Checklist

When resetting production:

1. ✅ Backup current data first
2. ✅ Use `apply-schema-parts.sh` (default: no reset)
3. ✅ Verify triggers exist after restoration
4. ✅ Test user creation → should auto-create profile/role
5. ✅ Test authentication → should work end-to-end
6. ✅ Test API calls → should not get 403 errors

## Lessons Learned

**Staging Success Story:**
- Staging database was created WITHOUT dropping schema
- Authentication works perfectly
- All triggers and RLS policies function correctly
- Users can log in and access APIs

**Previous Production Issues:**
- Schema was dropped and recreated
- Authentication appeared to work
- But `auth.uid()` returned NULL
- RLS policies failed
- API calls returned 403 Forbidden

**Solution:**
- Never drop the `public` schema
- Apply schema parts over existing schema
- Let PostgreSQL handle "already exists" gracefully

