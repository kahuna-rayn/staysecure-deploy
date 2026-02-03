#!/bin/bash

# Script to delete an orphaned user from auth.users (user exists but no profile)
# Usage: ./delete-orphaned-auth-user.sh <email> [project-ref]

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

echo -e "${YELLOW}Deleting orphaned auth user: ${EMAIL}${NC}"
echo -e "${YELLOW}Project: ${PROJECT_REF}${NC}"
echo ""

# SQL to find and delete orphaned user
SQL_QUERY=$(cat <<EOF
DO \$\$
DECLARE
    user_uuid UUID;
    user_email TEXT;
BEGIN
    -- Find user by email
    SELECT id, email INTO user_uuid, user_email
    FROM auth.users
    WHERE email = '${EMAIL}';
    
    IF user_uuid IS NULL THEN
        RAISE NOTICE 'User not found in auth.users';
        RETURN;
    END IF;
    
    -- Check if profile exists
    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = user_uuid) THEN
        RAISE NOTICE 'User has a profile - use delete-user Edge Function instead';
        RETURN;
    END IF;
    
    RAISE NOTICE 'Found orphaned user: % (ID: %)', user_email, user_uuid;
    RAISE NOTICE 'Deleting from auth.users...';
    
    -- Delete from auth.users (this will cascade to auth.identities, auth.sessions, etc.)
    DELETE FROM auth.users WHERE id = user_uuid;
    
    RAISE NOTICE 'Successfully deleted orphaned user';
END \$\$;
EOF
)

echo -e "${YELLOW}To delete the orphaned auth user, run this SQL in Supabase SQL Editor:${NC}"
echo ""
echo "Go to: https://supabase.com/dashboard/project/${PROJECT_REF}/sql"
echo ""
echo -e "${GREEN}SQL Query:${NC}"
echo "=================="
echo "$SQL_QUERY"
echo ""
echo -e "${YELLOW}Or copy-paste this simplified version:${NC}"
echo ""
echo "DELETE FROM auth.users WHERE id = (SELECT id FROM auth.users WHERE email = '${EMAIL}' AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.users.id));"
echo ""

