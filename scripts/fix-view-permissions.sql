-- Fix View Permissions in Database
-- Run this script directly on your database to secure views
-- Then rerun create-backup.sh to capture the fixed schema
--
-- This fixes the security issue where views in public schema are accessible via Supabase API
-- Recreates views with security_invoker = on as recommended by Supabase

-- ========================================
-- Recreate views with security_invoker = on
-- ========================================

-- CSBA Assessment Summary View
CREATE OR REPLACE VIEW public.csba_assessment_summary_view WITH (security_invoker = on) AS
 SELECT cm.question_id,
    avg((ca.answer)::numeric) AS avg_score,
    count(ca.answer) AS num_responses,
    cm.question,
    cm.type,
    cm.domain_short,
    cm.recommendation,
    cm.domain
   FROM (public.csba_master cm
     LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
  GROUP BY cm.question_id, cm.question, cm.type, cm.domain_short, cm.recommendation, cm.domain;

-- CSBA Detailed Insights View
CREATE OR REPLACE VIEW public.csba_detailed_insights_view WITH (security_invoker = on) AS
 SELECT cm.recommendation,
    cm.domain,
    avg((ca.answer)::numeric) AS avg_score,
    cm.question,
    cm.domain_short
   FROM (public.csba_master cm
     LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
  GROUP BY cm.recommendation, cm.domain, cm.question, cm.domain_short
 HAVING (avg((ca.answer)::numeric) < 3.0)
  ORDER BY (avg((ca.answer)::numeric));

-- CSBA Domain Score View
CREATE OR REPLACE VIEW public.csba_domain_score_view WITH (security_invoker = on) AS
 SELECT cm.domain,
    cm.domain_short,
    avg((ca.answer)::numeric) AS domain_avg,
    sum((ca.answer)::numeric) AS weighted_score,
    round(((avg((ca.answer)::numeric) / 5.0) * (100)::numeric), 1) AS weighted_percent,
    stddev((ca.answer)::numeric) AS std_deviation,
        CASE
            WHEN (avg((ca.answer)::numeric) < 2.0) THEN 1
            WHEN (avg((ca.answer)::numeric) < 3.0) THEN 2
            WHEN (avg((ca.answer)::numeric) < 4.0) THEN 3
            ELSE 4
        END AS priority
   FROM (public.csba_master cm
     LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
  GROUP BY cm.domain, cm.domain_short
  ORDER BY (avg((ca.answer)::numeric));

-- CSBA Key Insights View
CREATE OR REPLACE VIEW public.csba_key_insights_view WITH (security_invoker = on) AS
 SELECT row_number() OVER (ORDER BY avg_score) AS n,
    domain,
        CASE
            WHEN (avg_score < 2.0) THEN (('Critical security gaps identified in '::text || domain) || ' domain'::text)
            WHEN (avg_score < 3.0) THEN (('Significant improvements needed in '::text || domain) || ' domain'::text)
            WHEN (avg_score < 4.0) THEN (('Moderate risk areas found in '::text || domain) || ' domain'::text)
            ELSE (('Well-managed '::text || domain) || ' domain with minor improvements possible'::text)
        END AS insight
   FROM ( SELECT cm.domain,
            avg((ca.answer)::numeric) AS avg_score
           FROM (public.csba_master cm
             LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
          GROUP BY cm.domain
         HAVING (count(ca.answer) > 0)) domain_scores
  ORDER BY avg_score
 LIMIT 5;

-- Daily Notification Summary View
CREATE OR REPLACE VIEW public.daily_notification_summary WITH (security_invoker = on) AS
 SELECT date(created_at) AS notification_date,
    trigger_event,
    status,
    count(*) AS count,
    count(DISTINCT user_id) AS unique_users
   FROM public.notification_history
  WHERE (created_at >= (CURRENT_DATE - '30 days'::interval))
  GROUP BY (date(created_at)), trigger_event, status
  ORDER BY (date(created_at)) DESC, trigger_event;

-- Learning Template Variables View
CREATE OR REPLACE VIEW public.learning_template_variables WITH (security_invoker = on) AS
 SELECT tv.key,
    tv.category,
    tv.display_name,
    tv.is_system,
    tv.is_active,
    tvt.default_value
   FROM template_variables tv
     LEFT JOIN template_variable_translations tvt ON tv.id = tvt.variable_id AND tvt.language_code = 'en'::text
  WHERE tv.category = 'Learning'::text
  ORDER BY tv.key;

-- Template Performance View
CREATE OR REPLACE VIEW public.template_performance WITH (security_invoker = on) AS
 SELECT et.id,
    et.name,
    et.type,
    COALESCE(et.use_count, 0) AS use_count,
    et.last_used_at,
    count(nh.id) AS total_sends,
    count(
        CASE
            WHEN (nh.status = 'sent'::text) THEN 1
            ELSE NULL::integer
        END) AS successful_sends,
    count(
        CASE
            WHEN (nh.status = 'failed'::text) THEN 1
            ELSE NULL::integer
        END) AS failed_sends,
    count(
        CASE
            WHEN (nh.status = 'skipped'::text) THEN 1
            ELSE NULL::integer
        END) AS skipped_sends,
    round(((100.0 * (count(
        CASE
            WHEN (nh.status = 'sent'::text) THEN 1
            ELSE NULL::integer
        END))::numeric) / (NULLIF(count(nh.id), 0))::numeric), 2) AS success_rate
   FROM (public.email_templates et
     LEFT JOIN public.notification_history nh ON ((nh.email_template_id = et.id)))
  GROUP BY et.id, et.name, et.type, et.use_count, et.last_used_at
  ORDER BY (count(nh.id)) DESC;

-- Template Variables By Category View
CREATE OR REPLACE VIEW public.template_variables_by_category WITH (security_invoker = on) AS
 SELECT category,
    count(*) AS variable_count,
    string_agg(key, ', '::text ORDER BY key) AS variable_keys
   FROM public.template_variables tv
  WHERE (is_active = true)
  GROUP BY category
  ORDER BY category;

-- ========================================
-- Set permissions after recreating views
-- ========================================

-- Revoke public/anon access from all views
REVOKE ALL ON public.csba_assessment_summary_view FROM PUBLIC, anon;
REVOKE ALL ON public.csba_detailed_insights_view FROM PUBLIC, anon;
REVOKE ALL ON public.csba_domain_score_view FROM PUBLIC, anon;
REVOKE ALL ON public.csba_key_insights_view FROM PUBLIC, anon;
REVOKE ALL ON public.daily_notification_summary FROM PUBLIC, anon;
REVOKE ALL ON public.learning_template_variables FROM PUBLIC, anon;
REVOKE ALL ON public.template_performance FROM PUBLIC, anon;
REVOKE ALL ON public.template_variables_by_category FROM PUBLIC, anon;

-- Grant SELECT to authenticated role (for frontend API calls with JWT)
GRANT SELECT ON public.csba_assessment_summary_view TO authenticated;
GRANT SELECT ON public.csba_detailed_insights_view TO authenticated;
GRANT SELECT ON public.csba_domain_score_view TO authenticated;
GRANT SELECT ON public.csba_key_insights_view TO authenticated;
GRANT SELECT ON public.daily_notification_summary TO authenticated;
GRANT SELECT ON public.learning_template_variables TO authenticated;
GRANT SELECT ON public.template_performance TO authenticated;
GRANT SELECT ON public.template_variables_by_category TO authenticated;

-- Grant SELECT to service_role (for edge functions and server-side code)
GRANT SELECT ON public.csba_assessment_summary_view TO service_role;
GRANT SELECT ON public.csba_detailed_insights_view TO service_role;
GRANT SELECT ON public.csba_domain_score_view TO service_role;
GRANT SELECT ON public.csba_key_insights_view TO service_role;
GRANT SELECT ON public.daily_notification_summary TO service_role;
GRANT SELECT ON public.learning_template_variables TO service_role;
GRANT SELECT ON public.template_performance TO service_role;
GRANT SELECT ON public.template_variables_by_category TO service_role;
