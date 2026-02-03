#!/bin/bash
# Apply schema parts in the correct dependency order
# This script applies the extracted schema parts in the correct sequence

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCHEMA_PARTS_DIR="${1:-schema_parts}"
PROJECT_REF="${2:-}"  # Supabase project reference (e.g., "lcpotivitdpdslbqhifs")
RESET_SCHEMA="${3:-no}"  # Optional: "yes" to drop and recreate public schema, "no" to skip (default: no)
DB_CONNECTION="${4:-}"  # Optional: Full connection string override

# If DB_CONNECTION is provided, use it directly
# Otherwise, construct from PROJECT_REF and PGPASSWORD
if [ -z "$DB_CONNECTION" ]; then
    if [ -z "$PROJECT_REF" ]; then
        echo -e "${RED}Error: Either PROJECT_REF or DB_CONNECTION must be provided${NC}"
        echo ""
        echo "Usage: $0 <schema_parts_dir> <project_ref> [reset_schema] [db_connection_string]"
        echo ""
        echo "Option 1: Use PROJECT_REF (requires PGPASSWORD environment variable):"
        echo "  export PGPASSWORD='your-database-password'"
        echo "  $0 schema_parts lcpotivitdpdslbqhifs [yes|no]"
        echo "  (default: no - keeps existing schema, use yes to drop and recreate)"
        echo ""
        echo "Option 2: Use full connection string:"
        echo "  $0 schema_parts '' [yes|no] 'postgresql://postgres:password@host:5432/dbname'"
        echo ""
        echo -e "${YELLOW}Note: Database password can be reset in Supabase Dashboard → Settings → Database → Database Password${NC}"
        echo -e "${YELLOW}Note: Default behavior keeps existing schema. Use reset_schema=yes to drop and recreate${NC}"
        echo -e "${YELLOW}Warning: If objects already exist, CREATE statements may fail. Use reset_schema=yes for clean start${NC}"
        exit 1
    fi
    
    if [ -z "$PGPASSWORD" ]; then
        echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
        echo "Please set PGPASSWORD in your environment:"
        echo "  export PGPASSWORD='your-database-password'"
        echo ""
        echo -e "${YELLOW}Note: Database password can be reset in Supabase Dashboard → Settings → Database → Database Password${NC}"
        exit 1
    fi
    
    # Construct connection string same way as onboard-client.sh
    DB_CONNECTION="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"
    echo -e "${GREEN}Using PROJECT_REF: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}Connection: db.${PROJECT_REF}.supabase.co:6543${NC}"
else
    echo -e "${GREEN}Using provided connection string${NC}"
fi

# Reset schema if requested (default: yes)
if [ "$RESET_SCHEMA" = "yes" ]; then
    echo -e "${YELLOW}Resetting public schema (dropping and recreating)...${NC}"
    psql "$DB_CONNECTION" \
        --command "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO postgres; GRANT ALL ON SCHEMA public TO public;" || {
            echo -e "${RED}Failed to reset public schema${NC}"
            exit 1
        }
    echo -e "${GREEN}✓ Schema reset complete${NC}"
    echo ""
fi

echo -e "${GREEN}Applying schema parts from $SCHEMA_PARTS_DIR in dependency order...${NC}"
echo ""

# Order of execution (with dependencies):
# 1. Header - SET statements, no dependencies
# 2. Types - Must exist before tables that use them
# 3. Sequences - Must exist before tables that use them
# 4. Tables - Base structures must exist first
# 5. Primary Keys - Tables must exist
# 6. Unique Constraints - Tables must exist
# 7. Indexes - Tables must exist
# 8. Functions - Can reference tables/types, safer after tables exist
# 9. Views - Need tables to exist
# 10. Foreign Keys - Both tables must exist (and primary keys should exist first)
# 11. Triggers - Need tables and functions to exist
# 12. RLS Policies - Need tables to exist
# 13. Enable RLS - Need tables and policies to exist
# 14. Comments - Can be added anytime (but usually after objects exist)
# 15. Grants - Need objects to exist

ORDER=(
    "types.sql"
    "sequences.sql"
    "tables.sql"
    "primary_keys.sql"
    "unique_constraints.sql"
    "indexes.sql"
    "functions.sql"
    "views.sql"
    "foreign_keys.sql"
    "triggers.sql"
    "rls_policies.sql"
    "enable_rls.sql"
    "comments.sql"
    "grants.sql"
)

for file in "${ORDER[@]}"; do
    filepath="$SCHEMA_PARTS_DIR/$file"
    if [ "$file" = "header.sql" ]; then
        # Header is optional - skip if it contains \restrict (pg_dump command that fails in psql)
        if [ -f "$filepath" ] && [ -s "$filepath" ]; then
            if grep -q "^\\\\restrict" "$filepath"; then
                echo "⚠ Skipping $file (contains pg_dump-specific commands)"
                continue
            fi
        else
            echo "⚠ Skipping $file (not found or empty)"
            continue
        fi
    fi
    
    if [ -f "$filepath" ] && [ -s "$filepath" ]; then
        echo -e "${GREEN}Applying $file...${NC}"
        # Use --set ON_ERROR_STOP=off to continue on errors (useful when objects already exist)
        if [ "$RESET_SCHEMA" = "no" ]; then
            # When not resetting, continue on errors (some objects may already exist)
            # Filter out common "already exists" and "multiple primary keys" errors
            psql "$DB_CONNECTION" --set ON_ERROR_STOP=off -f "$filepath" 2>&1 | \
                grep -v -E "(already exists|multiple primary keys|duplicate key|already defined)" || true
            echo -e "${GREEN}✓ Applied $file (some errors may be expected if objects already exist)${NC}"
        else
            # When resetting, stop on errors
            psql "$DB_CONNECTION" -f "$filepath" || {
                echo -e "${RED}Error applying $file${NC}"
                exit 1
            }
            echo -e "${GREEN}✓ Applied $file${NC}"
        fi
        echo ""
    else
        echo -e "${YELLOW}⚠ Skipping $file (not found or empty)${NC}"
    fi
done

# Create trigger on auth.users (not included in schema dump since it's on auth schema)
# This trigger automatically creates profiles and user_roles when new users sign up
echo -e "${GREEN}Creating trigger on auth.users...${NC}"
psql "$DB_CONNECTION" \
    --command "DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users; CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();" || {
        echo -e "${RED}Error: Failed to create trigger on auth.users${NC}"
        echo -e "${YELLOW}Note: This trigger is required for automatic profile and user_roles creation${NC}"
        echo -e "${YELLOW}Ensure handle_new_user() function exists and is SECURITY DEFINER${NC}"
        exit 1
    }
echo -e "${GREEN}✓ Trigger created successfully${NC}"

# Grant INSERT permission to postgres role (for SECURITY DEFINER functions)
echo -e "${GREEN}Granting permissions for trigger functions...${NC}"
psql "$DB_CONNECTION" \
    --command "GRANT INSERT ON public.profiles TO postgres;" || {
        echo -e "${YELLOW}Warning: Failed to grant INSERT permission to postgres${NC}"
    }

# Create RLS policy to allow trigger inserts
psql "$DB_CONNECTION" \
    --command "DROP POLICY IF EXISTS \"System can insert profiles via trigger\" ON public.profiles; CREATE POLICY \"System can insert profiles via trigger\" ON public.profiles FOR INSERT WITH CHECK (true);" || {
        echo -e "${YELLOW}Warning: Failed to create RLS policy for profiles insert${NC}"
    }

echo -e "${GREEN}✓ Schema application complete!${NC}"

