#!/bin/bash

# Comprehensive ImportUsersDialog Test Script
# Creates a temporary test project, sets up test data, generates CSV, and provides cleanup
# Usage: ./test-import-users.sh [cleanup-only] [project-ref]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_PROJECT_NAME="test-import-$(date +%s)"
TEST_CSV_FILE="${DEPLOY_ROOT}/test-users-import.csv"
TEST_DATA_FILE="${DEPLOY_ROOT}/.test-import-project-ref"

# Check for cleanup-only mode
if [ "${1}" = "cleanup-only" ]; then
    if [ -z "${2}" ]; then
        if [ -f "${TEST_DATA_FILE}" ]; then
            PROJECT_REF=$(cat "${TEST_DATA_FILE}")
        else
            echo -e "${RED}Error: No project reference provided and ${TEST_DATA_FILE} not found${NC}"
            echo "Usage: ./test-import-users.sh cleanup-only <project-ref>"
            exit 1
        fi
    else
        PROJECT_REF="${2}"
    fi
    
    echo -e "${YELLOW}Cleaning up test project: ${PROJECT_REF}${NC}"
    
    # Delete test users first
    if [ -f "${TEST_CSV_FILE}" ]; then
        echo -e "${GREEN}Deleting test users from CSV...${NC}"
        "${SCRIPT_DIR}/cleanup-test-users.sh" "${PROJECT_REF}" "" "${TEST_CSV_FILE}" || true
    fi
    
    # Delete the project
    echo -e "${GREEN}Deleting test project...${NC}"
    supabase projects delete "${PROJECT_REF}" --non-interactive || {
        echo -e "${YELLOW}Warning: Failed to delete project (may already be deleted)${NC}"
    }
    
    # Clean up files
    rm -f "${TEST_CSV_FILE}" "${TEST_DATA_FILE}"
    
    echo -e "${GREEN}Cleanup complete!${NC}"
    exit 0
fi

# Check prerequisites
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is not set${NC}"
    exit 1
fi

if ! command -v supabase &> /dev/null; then
    echo -e "${RED}Error: supabase CLI not found${NC}"
    exit 1
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  ImportUsersDialog Comprehensive Test Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Step 1: Create test project
echo -e "${GREEN}Step 1: Creating test Supabase project...${NC}"
cd "${DEPLOY_ROOT}"

# Use onboard-client.sh to create the project
echo -e "${YELLOW}Running onboard-client.sh...${NC}"
"${SCRIPT_DIR}/onboard-client.sh" test "${TEST_PROJECT_NAME}" seed 2>&1 | tee /tmp/onboard-output.log

# Extract project reference from output (macOS-compatible grep)
# Try multiple patterns to find the project reference
PROJECT_REF=$(grep -oE 'Created project: [a-z0-9]+' /tmp/onboard-output.log | grep -oE '[a-z0-9]+$' | head -1 || echo "")

if [ -z "$PROJECT_REF" ]; then
    # Try alternative pattern (without "Created project:" prefix)
    PROJECT_REF=$(grep -oE 'project: [a-z0-9]+' /tmp/onboard-output.log | grep -oE '[a-z0-9]+$' | head -1 || echo "")
fi

if [ -z "$PROJECT_REF" ]; then
    # Try alternative extraction from project list
    echo -e "${YELLOW}Extracting project reference from project list...${NC}"
    PROJECT_REF=$(supabase projects list --output json 2>/dev/null | jq -r ".[] | select(.name == \"${TEST_PROJECT_NAME}\") | .id" | head -1 || echo "")
fi

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: Failed to get project reference${NC}"
    echo -e "${YELLOW}Last 20 lines of onboard output:${NC}"
    tail -20 /tmp/onboard-output.log
    exit 1
fi

echo "${PROJECT_REF}" > "${TEST_DATA_FILE}"
echo -e "${GREEN}✓ Created test project: ${PROJECT_REF}${NC}"
echo ""

# Wait for project to be fully ready
echo -e "${YELLOW}Waiting for project to be fully ready (30 seconds)...${NC}"
sleep 30
echo -e "${GREEN}✓ Project ready${NC}"
echo ""

# Step 2: Set up test data (departments, roles, locations)
echo -e "${GREEN}Step 2: Setting up test data (departments, roles, locations)...${NC}"

CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

# Create test departments, roles, and locations
SQL_SETUP=$(cat <<'EOF'
-- Create test departments
INSERT INTO public.departments (id, name, description, manager_id, created_at, updated_at)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'Engineering', 'Engineering Department', NULL, NOW(), NOW()),
    ('22222222-2222-2222-2222-222222222222', 'Sales', 'Sales Department', NULL, NOW(), NOW()),
    ('33333333-3333-3333-3333-333333333333', 'HR', 'Human Resources', NULL, NOW(), NOW())
ON CONFLICT (id) DO NOTHING;

-- Create test locations
INSERT INTO public.locations (id, name, description, building, floor, room, status, created_at, updated_at)
VALUES 
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Headquarters', 'Main office location', 'Building A', '1', 'Lobby', 'Active', NOW(), NOW()),
    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Remote Office', 'Remote work location', NULL, NULL, NULL, 'Active', NOW(), NOW()),
    ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Data Center', 'Data center facility', 'Building C', '1', 'DC-01', 'Active', NOW(), NOW())
ON CONFLICT (id) DO NOTHING;

-- Create test roles (must reference departments)
INSERT INTO public.roles (role_id, department_id, name, description, is_active, created_at, updated_at)
VALUES 
    ('aaaaaaaa-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Software Engineer', 'Software development role', true, NOW(), NOW()),
    ('bbbbbbbb-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Senior Engineer', 'Senior software engineer', true, NOW(), NOW()),
    ('cccccccc-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Sales Manager', 'Sales management role', true, NOW(), NOW()),
    ('dddddddd-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Account Executive', 'Account management', true, NOW(), NOW()),
    ('eeeeeeee-3333-3333-3333-333333333333', '33333333-3333-3333-3333-333333333333', 'HR Manager', 'Human resources management', true, NOW(), NOW())
ON CONFLICT (role_id) DO NOTHING;
EOF
)

echo -e "${YELLOW}Inserting test data...${NC}"
PGPASSWORD="${PGPASSWORD}" psql "${CONNECTION_STRING}" -c "${SQL_SETUP}" || {
    echo -e "${YELLOW}Warning: Some test data may already exist${NC}"
}

echo -e "${GREEN}✓ Test data created${NC}"
echo ""

# Step 3: Create a test admin user (will be used as manager)
echo -e "${GREEN}Step 3: Creating test admin user (for manager assignment)...${NC}"

ADMIN_EMAIL="admin-test-${PROJECT_REF:0:8}@test.example.com"
ADMIN_PASSWORD="TestAdmin123!"

# Create admin using create-admin-user.sh if it exists, otherwise use create-user edge function
if [ -f "${SCRIPT_DIR}/create-admin-user.sh" ]; then
    "${SCRIPT_DIR}/create-admin-user.sh" "${PROJECT_REF}" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}" "Test Admin" "Test" "Admin" || {
        echo -e "${YELLOW}Warning: Failed to create admin user via script, will create via Edge Function${NC}"
        # Fallback: create via Edge Function
        SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
        curl -s -X POST "${SUPABASE_URL}/functions/v1/create-user" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"full_name\":\"Test Admin\",\"first_name\":\"Test\",\"last_name\":\"Admin\",\"access_level\":\"admin\"}" || true
    }
else
    echo -e "${YELLOW}create-admin-user.sh not found, skipping admin user creation${NC}"
    echo -e "${YELLOW}You'll need to create a manager user manually before testing manager assignment${NC}"
    ADMIN_EMAIL=""
fi

if [ -n "$ADMIN_EMAIL" ]; then
    echo -e "${GREEN}✓ Admin user created: ${ADMIN_EMAIL}${NC}"
    echo -e "${YELLOW}  Password: ${ADMIN_PASSWORD}${NC}"
fi
echo ""

# Step 4: Generate test CSV file
echo -e "${GREEN}Step 4: Generating test CSV file...${NC}"

# Get location and department names for CSV
LOCATION_NAME="Headquarters"
DEPARTMENT_NAME="Engineering"
ROLE_NAME="Software Engineer"
MANAGER_NAME="Test Admin"

cat > "${TEST_CSV_FILE}" <<EOF
Email,Full Name,First Name,Last Name,Phone,Employee ID,Access Level,Location,Department,Role,Manager
test-user-1@test.example.com,John Doe,John,Doe,+65-1234-5678,EMP-001,User,${LOCATION_NAME},${DEPARTMENT_NAME},${ROLE_NAME},${MANAGER_NAME}
test-user-2@test.example.com,Jane Smith,Jane,Smith,+65-2345-6789,EMP-002,User,${LOCATION_NAME},${DEPARTMENT_NAME},${ROLE_NAME},${MANAGER_NAME}
test-user-3@test.example.com,Bob Johnson,Bob,Johnson,+65-3456-7890,EMP-003,Manager,${LOCATION_NAME},Sales,Account Executive,${MANAGER_NAME}
test-user-4@test.example.com,Alice Williams,Alice,Williams,+65-4567-8901,EMP-004,User,Remote Office,HR,HR Manager,
test-user-5@test.example.com,Charlie Brown,Charlie,Brown,+65-5678-9012,EMP-005,User,Data Center,Engineering,Senior Engineer,${MANAGER_NAME}
test-user-6@test.example.com,David Lee,David,Lee,+65-6789-0123,EMP-006,User,${LOCATION_NAME},${DEPARTMENT_NAME},${ROLE_NAME},NonExistent Manager
test-user-7@test.example.com,Emma Wilson,Emma,Wilson,+65-7890-1234,EMP-007,User,${LOCATION_NAME},NonExistent Department,${ROLE_NAME},${MANAGER_NAME}
test-user-8@test.example.com,Frank Miller,Frank,Miller,+65-8901-2345,EMP-008,User,${LOCATION_NAME},${DEPARTMENT_NAME},NonExistent Role,${MANAGER_NAME}
test-user-9@test.example.com,Grace Taylor,Grace,Taylor,+65-9012-3456,EMP-009,User,NonExistent Location,${DEPARTMENT_NAME},${ROLE_NAME},${MANAGER_NAME}
test-user-10@test.example.com,Henry Davis,Henry,Davis,+65-0123-4567,EMP-010,User,${LOCATION_NAME},NonExistent Department,NonExistent Role,${MANAGER_NAME}
test-user-11@test.example.com,Iris Martinez,Iris,Martinez,+65-1234-5679,EMP-011,User,NonExistent Location,${DEPARTMENT_NAME},${ROLE_NAME},NonExistent Manager
test-user-12@test.example.com,Jack Anderson,Jack,Anderson,+65-2345-6780,EMP-012,User,NonExistent Location,NonExistent Department,${ROLE_NAME},${MANAGER_NAME}
test-user-13@test.example.com,Karen Thomas,Karen,Thomas,+65-3456-7891,EMP-013,User,NonExistent Location,${DEPARTMENT_NAME},NonExistent Role,${MANAGER_NAME}
test-user-14@test.example.com,Liam Jackson,Liam,Jackson,+65-4567-8902,EMP-014,User,${LOCATION_NAME},NonExistent Department,${ROLE_NAME},NonExistent Manager
test-user-15@test.example.com,Maya White,Maya,White,+65-5678-9013,EMP-015,User,${LOCATION_NAME},${DEPARTMENT_NAME},NonExistent Role,NonExistent Manager
test-user-16@test.example.com,Noah Harris,Noah,Harris,+65-6789-0124,EMP-016,User,NonExistent Location,NonExistent Department,NonExistent Role,${MANAGER_NAME}
test-user-17@test.example.com,Olivia Clark,Olivia,Clark,+65-7890-1235,EMP-017,User,${LOCATION_NAME},NonExistent Department,NonExistent Role,NonExistent Manager
test-user-18@test.example.com,Paul Lewis,Paul,Lewis,+65-8901-2346,EMP-018,User,NonExistent Location,${DEPARTMENT_NAME},NonExistent Role,NonExistent Manager
test-user-19@test.example.com,Quinn Walker,Quinn,Walker,+65-9012-3457,EMP-019,User,NonExistent Location,NonExistent Department,${ROLE_NAME},NonExistent Manager
test-user-20@test.example.com,Ruby Hall,Ruby,Hall,+65-0123-4568,EMP-020,User,NonExistent Location,NonExistent Department,NonExistent Role,NonExistent Manager
EOF

echo -e "${GREEN}✓ Test CSV created: ${TEST_CSV_FILE}${NC}"
echo ""

# Step 5: Display testing instructions
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Testing Instructions${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Test Project: ${PROJECT_REF}${NC}"
echo -e "${GREEN}Test CSV: ${TEST_CSV_FILE}${NC}"
echo ""

# Explain test cases
echo -e "${YELLOW}Test Cases in CSV:${NC}"
echo ""
echo -e "${GREEN}Positive Test Cases (rows 1-5 - should succeed):${NC}"
echo "  • test-user-1, test-user-2: Valid users with all valid references"
echo "  • test-user-3: Valid user with different department/role"
echo "  • test-user-4: Valid user without manager"
echo "  • test-user-5: Valid user with different location"
echo ""
echo -e "${RED}Negative Test Cases (rows 6-20 - should fail gracefully):${NC}"
echo "  • test-user-6: Non-existent manager"
echo "  • test-user-7: Non-existent department"
echo "  • test-user-8: Non-existent role"
echo "  • test-user-9: Non-existent location"
echo "  • test-user-10: Non-existent department + role"
echo "  • test-user-11: Non-existent manager + location"
echo "  • test-user-12: Non-existent department + location"
echo "  • test-user-13: Non-existent role + location"
echo "  • test-user-14: Non-existent manager + department"
echo "  • test-user-15: Non-existent manager + role"
echo "  • test-user-16: Non-existent department + role + location"
echo "  • test-user-17: Non-existent manager + department + role"
echo "  • test-user-18: Non-existent manager + location + role"
echo "  • test-user-19: Non-existent manager + department + location"
echo "  • test-user-20: All non-existent (manager + department + role + location)"
echo ""

# Get Vercel config (if available)
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
ANON_KEY=$(supabase projects api-keys --project-ref "${PROJECT_REF}" 2>/dev/null | grep -i "anon.*public" | head -1 | awk '{print $NF}' || echo "")

if [ -n "$ANON_KEY" ]; then
    echo -e "${YELLOW}Vercel Configuration (for local testing):${NC}"
    echo "Add this to your local .env.local:"
    echo ""
    echo "VITE_CLIENT_CONFIGS={\"default\":{\"clientId\":\"default\",\"supabaseUrl\":\"${SUPABASE_URL}\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"Test\"}}"
    echo ""
fi

echo -e "${YELLOW}Steps to test:${NC}"
echo "  1. Open the app (dev environment or local with test config)"
echo "  2. Navigate to Admin → Import Data → Import Users tab"
echo "  3. Click 'Import Users' button to open the dialog"
echo "  4. Upload the CSV file: ${TEST_CSV_FILE}"
echo "  5. Review the import results and verify:"
echo "     ${GREEN}Positive cases (rows 1-5):${NC}"
echo "       - Users are created successfully"
echo "       - Departments are assigned correctly"
echo "       - Roles are assigned correctly"
echo "       - Locations are assigned correctly"
echo "       - Manager assignments work (if admin user was created)"
echo "     ${RED}Negative cases (rows 6-20):${NC}"
echo "       - Appropriate error messages are shown for invalid references"
echo "       - Users with invalid managers are handled gracefully"
echo "       - Users with invalid departments are handled gracefully"
echo "       - Users with invalid roles are handled gracefully"
echo "       - Users with invalid locations are handled gracefully"
echo "       - Multiple invalid references show clear error messages"
echo "       - Import continues processing remaining rows after errors"
echo "  6. Check the database to verify:"
echo "     - Only valid users (rows 1-5) are created in profiles table"
echo "     - Invalid users (rows 6-20) are NOT created or are marked with errors"
echo "     - user_departments table has correct assignments for valid users"
echo "     - user_profile_roles table has correct assignments for valid users"
echo "     - physical_location_access table has correct assignments for valid users"
echo "     - profiles.manager column has correct manager UUIDs for valid users"
echo ""

# Step 6: Verification queries
echo -e "${YELLOW}Verification SQL Queries (run in Supabase SQL Editor):${NC}"
echo ""
cat <<'VERIFY_EOF'
-- ============================================
-- Positive Test Cases Verification (should exist)
-- ============================================
-- Expected: test-user-1 through test-user-5 should be created

-- Check imported users (should show rows 1-5 only)
SELECT email, full_name, username, employee_id, access_level 
FROM profiles 
WHERE email LIKE 'test-%@test.example.com'
ORDER BY email;

-- Check department assignments (valid users only)
SELECT p.email, d.name as department, ud.is_primary
FROM profiles p
JOIN user_departments ud ON p.id = ud.user_id
JOIN departments d ON ud.department_id = d.id
WHERE p.email LIKE 'test-%@test.example.com'
ORDER BY p.email, ud.is_primary DESC;

-- Check role assignments (valid users only)
SELECT p.email, r.name as role, d.name as department
FROM profiles p
JOIN user_profile_roles upr ON p.id = upr.user_id
JOIN roles r ON upr.role_id = r.role_id
JOIN departments d ON r.department_id = d.id
WHERE p.email LIKE 'test-%@test.example.com'
ORDER BY p.email;

-- Check location assignments (valid users only)
SELECT p.email, l.name as location
FROM profiles p
JOIN physical_location_access pla ON p.id = pla.user_id
JOIN locations l ON pla.location_id = l.id
WHERE p.email LIKE 'test-%@test.example.com'
ORDER BY p.email;

-- Check manager assignments (valid users only)
SELECT 
    p.email as employee_email,
    p.full_name as employee_name,
    m.email as manager_email,
    m.full_name as manager_name
FROM profiles p
LEFT JOIN profiles m ON p.manager = m.id
WHERE p.email LIKE 'test-%@test.example.com'
ORDER BY p.email;

-- ============================================
-- Negative Test Cases Verification (should NOT exist)
-- ============================================
-- Expected: test-user-6 through test-user-20 should NOT be created
-- (or should be marked with error status if error tracking is implemented)

-- Check that negative test case users were NOT created
SELECT 
    'test-user-6@test.example.com' as expected_email,
    CASE WHEN EXISTS (SELECT 1 FROM profiles WHERE email = 'test-user-6@test.example.com') 
         THEN '❌ FAILED: User was created (should have failed due to non-existent manager)'
         ELSE '✓ PASSED: User was not created (correctly rejected)' 
    END as status
UNION ALL
SELECT 
    'test-user-7@test.example.com',
    CASE WHEN EXISTS (SELECT 1 FROM profiles WHERE email = 'test-user-7@test.example.com') 
         THEN '❌ FAILED: User was created (should have failed due to non-existent department)'
         ELSE '✓ PASSED: User was not created (correctly rejected)' 
    END
UNION ALL
SELECT 
    'test-user-8@test.example.com',
    CASE WHEN EXISTS (SELECT 1 FROM profiles WHERE email = 'test-user-8@test.example.com') 
         THEN '❌ FAILED: User was created (should have failed due to non-existent role)'
         ELSE '✓ PASSED: User was not created (correctly rejected)' 
    END
UNION ALL
SELECT 
    'test-user-9@test.example.com',
    CASE WHEN EXISTS (SELECT 1 FROM profiles WHERE email = 'test-user-9@test.example.com') 
         THEN '❌ FAILED: User was created (should have failed due to non-existent location)'
         ELSE '✓ PASSED: User was not created (correctly rejected)' 
    END
UNION ALL
SELECT 
    'test-user-20@test.example.com',
    CASE WHEN EXISTS (SELECT 1 FROM profiles WHERE email = 'test-user-20@test.example.com') 
         THEN '❌ FAILED: User was created (should have failed due to all non-existent references)'
         ELSE '✓ PASSED: User was not created (correctly rejected)' 
    END;

-- Summary: Count positive vs negative test cases
SELECT 
    'Positive Test Cases (should exist)' as test_type,
    COUNT(*) as count,
    STRING_AGG(email, ', ' ORDER BY email) as emails
FROM profiles 
WHERE email IN (
    'test-user-1@test.example.com',
    'test-user-2@test.example.com',
    'test-user-3@test.example.com',
    'test-user-4@test.example.com',
    'test-user-5@test.example.com'
)
UNION ALL
SELECT 
    'Negative Test Cases (should NOT exist)' as test_type,
    COUNT(*) as count,
    STRING_AGG(email, ', ' ORDER BY email) as emails
FROM profiles 
WHERE email IN (
    'test-user-6@test.example.com',
    'test-user-7@test.example.com',
    'test-user-8@test.example.com',
    'test-user-9@test.example.com',
    'test-user-10@test.example.com',
    'test-user-11@test.example.com',
    'test-user-12@test.example.com',
    'test-user-13@test.example.com',
    'test-user-14@test.example.com',
    'test-user-15@test.example.com',
    'test-user-16@test.example.com',
    'test-user-17@test.example.com',
    'test-user-18@test.example.com',
    'test-user-19@test.example.com',
    'test-user-20@test.example.com'
);
VERIFY_EOF

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Cleanup:${NC}"
echo ""
echo "When done testing, run:"
echo -e "${GREEN}  ./scripts/test-import-users.sh cleanup-only${NC}"
echo ""
echo "Or manually:"
echo "  1. Delete test users: ./scripts/cleanup-test-users.sh ${PROJECT_REF} \"test-.*@test.example.com\""
echo "  2. Delete project: supabase projects delete ${PROJECT_REF}"
echo ""
echo -e "${GREEN}Test setup complete!${NC}"

