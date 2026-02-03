-- Verify View Security
-- Run this to test if views are actually secured

-- Test 1: Check current grants (should show only authenticated and service_role)
SELECT 
  grantee,
  table_name,
  privilege_type
FROM information_schema.table_privileges
WHERE table_schema = 'public'
  AND table_name IN (
    'template_performance',
    'template_variables_by_category',
    'daily_notification_summary',
    'learning_template_variables'
  )
  AND grantee IN ('anon', 'public', 'authenticated', 'service_role')
ORDER BY table_name, grantee;

-- Test 2: Try to query as anon role (should fail if properly secured)
-- Run this as the anon role to test:
-- SET ROLE anon;
-- SELECT * FROM public.template_performance LIMIT 1;
-- RESET ROLE;

-- Expected result: Should get permission denied error for anon role
-- If you get data, the view is NOT properly secured

