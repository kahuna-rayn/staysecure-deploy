#!/bin/bash

# Script to fix an orphaned user (exists in auth.users but no profile)
# Usage: ./fix-orphaned-user.sh <email> [project-ref]

set -e

EMAIL="${1}"
PROJECT_REF="${2:-nfbidnlkwdeyziydxcoj}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ -z "$EMAIL" ]; then
    echo -e "${RED}Error: Email address required${NC}"
    echo "Usage: $0 <email> [project-ref]"
    exit 1
fi

echo -e "${YELLOW}Checking user: ${EMAIL}${NC}"
echo -e "${YELLOW}Project: ${PROJECT_REF}${NC}"
echo ""

# Check if Supabase CLI is available
if ! command -v supabase &> /dev/null; then
    echo -e "${RED}Error: supabase CLI not found. Please install it first.${NC}"
    echo ""
    echo "Install with: npm install -g supabase"
    echo "Or visit: https://supabase.com/docs/guides/cli"
    exit 1
fi

# SQL to check and create profile if missing
SQL_QUERY=$(cat <<EOF
DO \$\$
DECLARE
    user_uuid UUID;
    user_email TEXT;
    user_metadata JSONB;
    existing_profile BOOLEAN;
BEGIN
    -- Find user by email
    SELECT id, email, raw_user_meta_data INTO user_uuid, user_email, user_metadata
    FROM auth.users
    WHERE email = '${EMAIL}';
    
    IF user_uuid IS NULL THEN
        RAISE NOTICE 'User not found in auth.users';
        RETURN;
    END IF;
    
    RAISE NOTICE 'Found user: % (ID: %)', user_email, user_uuid;
    
    -- Check if profile exists
    SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id = user_uuid) INTO existing_profile;
    
    IF existing_profile THEN
        RAISE NOTICE 'Profile already exists - user is not orphaned';
        RETURN;
    END IF;
    
    RAISE NOTICE 'User is orphaned (no profile). Creating profile...';
    
    -- Create profile from auth.users metadata
    INSERT INTO public.profiles (
        id,
        full_name,
        first_name,
        last_name,
        username,
        status,
        employee_id,
        phone,
        location,
        bio,
        created_at,
        updated_at
    )
    VALUES (
        user_uuid,
        COALESCE(user_metadata->>'full_name', split_part(user_email, '@', 1), ''),
        COALESCE(user_metadata->>'first_name', ''),
        COALESCE(user_metadata->>'last_name', ''),
        COALESCE(user_metadata->>'username', split_part(user_email, '@', 1), user_email),
        COALESCE(user_metadata->>'status', 'Active'),
        COALESCE(user_metadata->>'employee_id', 'EMP-' || EXTRACT(YEAR FROM NOW()) || '-' || LPAD(EXTRACT(DOY FROM NOW())::text, 3, '0') || '-' || UPPER(SUBSTR(user_uuid::text, 1, 6))),
        COALESCE(user_metadata->>'phone', ''),
        COALESCE(user_metadata->>'location', ''),
        COALESCE(user_metadata->>'bio', ''),
        NOW(),
        NOW()
    )
    ON CONFLICT (id) DO NOTHING;
    
    -- Create user_role entry if access_level exists in metadata
    IF user_metadata->>'access_level' IS NOT NULL THEN
        DECLARE
            access_level TEXT;
            assigned_role app_role;
        BEGIN
            access_level := user_metadata->>'access_level';
            
            -- Map access_level to role (same logic as handle_new_user trigger)
            CASE access_level
                WHEN 'Super Admin' THEN assigned_role := 'super_admin';
                WHEN 'Admin' THEN assigned_role := 'super_admin';
                WHEN 'Client Admin' THEN assigned_role := 'client_admin';
                WHEN 'Author' THEN assigned_role := 'author';
                WHEN 'Manager' THEN assigned_role := 'manager';
                ELSE assigned_role := 'user';
            END CASE;
            
            INSERT INTO public.user_roles (user_id, role)
            VALUES (user_uuid, assigned_role)
            ON CONFLICT (user_id) DO UPDATE SET role = assigned_role;
            
            RAISE NOTICE 'Created user_role: %', assigned_role;
        END;
    ELSE
        -- Default to user role if no access_level
        INSERT INTO public.user_roles (user_id, role)
        VALUES (user_uuid, 'user')
        ON CONFLICT (user_id) DO NOTHING;
        
        RAISE NOTICE 'Created default user_role: user';
    END IF;
    
    RAISE NOTICE '✅ Profile created successfully';
END \$\$;
EOF
)

# Execute query using supabase CLI
echo -e "${YELLOW}Executing SQL query to fix orphaned user...${NC}"
echo ""

supabase db execute "$SQL_QUERY" --project-ref "$PROJECT_REF" 2>&1 || {
    echo ""
    echo -e "${RED}Error executing query. Trying alternative method...${NC}"
    echo ""
    echo -e "${YELLOW}Please run this SQL query manually in Supabase SQL Editor:${NC}"
    echo ""
    echo "Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/sql"
    echo ""
    echo -e "${GREEN}SQL Query:${NC}"
    echo "=================="
    echo "$SQL_QUERY"
    echo ""
    exit 1
}

echo ""
echo -e "${GREEN}✅ Query executed successfully!${NC}"
echo ""
echo -e "${YELLOW}Note: Check the output above for any NOTICE messages indicating:${NC}"
echo "  • Whether the user was found"
echo "  • Whether a profile was created"
echo "  • What role was assigned"
echo ""

