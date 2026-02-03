# Schema Parts Execution Order

When applying extracted schema parts, they **must** be executed in dependency order. Here's the correct sequence:

## Execution Order

### 1. **header.sql** (No dependencies)
- SET statements, configuration
- No dependencies on other objects

### 2. **types.sql** (No dependencies)
- CREATE TYPE statements (ENUMs, custom types)
- Must exist before tables that use them
- Example: `app_role`, `access_level_type`, `approval_status_enum`

### 3. **sequences.sql** (No dependencies)
- CREATE SEQUENCE statements
- Must exist before tables that use them
- Note: This schema uses `gen_random_uuid()` so sequences may be minimal

### 4. **tables.sql** (Depends on: types, sequences)
- CREATE TABLE statements
- Base structures must exist before constraints, indexes, triggers, etc.
- Tables can reference types/enums from step 2

### 5. **primary_keys.sql** (Depends on: tables)
- ALTER TABLE ... ADD PRIMARY KEY
- Tables must exist first

### 6. **unique_constraints.sql** (Depends on: tables)
- ALTER TABLE ... ADD CONSTRAINT ... UNIQUE
- Tables must exist first

### 7. **indexes.sql** (Depends on: tables)
- CREATE INDEX statements
- Tables must exist first
- Can be created after primary keys (better for performance)

### 8. **functions.sql** (Depends on: tables, types)
- CREATE FUNCTION statements
- Functions can reference tables and types
- Safer to create after tables exist (though PostgreSQL allows forward references)

### 9. **views.sql** (Depends on: tables)
- CREATE VIEW statements
- Views query tables, so tables must exist first

### 10. **foreign_keys.sql** (Depends on: tables, primary_keys)
- ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY
- Both referenced and referencing tables must exist
- Primary keys should exist first (foreign keys reference them)

### 11. **triggers.sql** (Depends on: tables, functions)
- CREATE TRIGGER statements
- Tables and functions must exist first
- Triggers call functions and act on tables

### 12. **rls_policies.sql** (Depends on: tables)
- CREATE POLICY statements
- Tables must exist first
- Policies can reference functions (which should exist from step 8)

### 13. **enable_rls.sql** (Depends on: tables, rls_policies)
- ALTER TABLE ... ENABLE ROW LEVEL SECURITY
- Tables and policies must exist first
- Enables RLS after policies are created

### 14. **comments.sql** (Depends on: all objects)
- COMMENT ON statements
- Can be added anytime, but usually after objects exist
- Documents tables, columns, functions, etc.

### 15. **grants.sql** (Depends on: all objects)
- GRANT/REVOKE statements
- Objects must exist before granting permissions

### 16. **footer.sql** (No dependencies)
- Usually just cleanup/end markers
- Can be skipped in most cases

## Quick Reference

```bash
# Apply in order:
1. header.sql
2. types.sql
3. sequences.sql
4. tables.sql
5. primary_keys.sql
6. unique_constraints.sql
7. indexes.sql
8. functions.sql
9. views.sql
10. foreign_keys.sql
11. triggers.sql
12. rls_policies.sql
13. enable_rls.sql
14. comments.sql
15. grants.sql
```

## Usage

Use the `apply-schema-parts.sh` script to apply them in order:

```bash
./scripts/apply-schema-parts.sh schema_parts "postgresql://user:pass@host:port/dbname"
```

Or manually apply in order:

```bash
for file in header types sequences tables primary_keys unique_constraints indexes functions views foreign_keys triggers rls_policies enable_rls comments grants; do
    if [ -f "schema_parts/${file}.sql" ]; then
        psql "$DB_CONNECTION" -f "schema_parts/${file}.sql"
    fi
done
```

## Important Notes

- **Foreign keys must come after primary keys** - Foreign keys reference primary keys
- **Triggers must come after functions** - Triggers call functions
- **RLS policies can reference functions** - So functions should exist before policies
- **Enable RLS after creating policies** - Policies must exist before enabling RLS
- Some files may be empty or missing - that's okay, just skip them

## Previous Migration Order (for reference)

The `MIGRATION_SUMMARY.md` shows a different order that was used:
1. tables.sql
2. functions.sql
3. data.sql (seed data)
4. rls_policies.sql
5. foreign_keys.sql
6. primary_keys.sql
7. triggers.sql

**Note**: That order had primary keys after foreign keys, which can cause issues. The order above is more correct.

