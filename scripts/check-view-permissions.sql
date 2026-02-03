-- Check all grants on the views
SELECT 
  grantee,
  table_schema,
  table_name,
  privilege_type,
  is_grantable
FROM information_schema.table_privileges
WHERE table_schema = 'public'
  AND table_name IN (
    'csba_assessment_summary_view',
    'csba_detailed_insights_view',
    'csba_domain_score_view',
    'csba_key_insights_view',
    'daily_notification_summary',
    'learning_template_variables',
    'template_performance',
    'template_variables_by_category'
  )
ORDER BY table_name, grantee;

-- Check view definitions, owners, and security mode
SELECT
  n.nspname AS schemaname,
  c.relname AS viewname,
  pg_get_userbyid(c.relowner) AS viewowner,
  CASE
    WHEN EXISTS (
      SELECT 1
      FROM unnest(coalesce(c.reloptions, '{}')) opt
      WHERE opt = 'security_invoker=true'
         OR opt = 'security_invoker'     -- depending on Postgres version
    )
    THEN 'security_invoker'
    ELSE 'security_definer' -- default unless explicitly set to invoker (PG 15+)
  END AS security_mode
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'v'
  AND n.nspname = 'public'
  AND c.relname IN (
    'csba_assessment_summary_view',
    'csba_detailed_insights_view',
    'csba_domain_score_view',
    'csba_key_insights_view',
    'daily_notification_summary',
    'learning_template_variables',
    'template_performance',
    'template_variables_by_category'
  )
ORDER BY viewname;