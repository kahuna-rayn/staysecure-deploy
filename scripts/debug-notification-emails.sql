-- Debug Script for sendNotificationByEvent Email Delivery
-- Run these queries in Supabase SQL Editor to diagnose why emails aren't being sent

-- ============================================================================
-- 1. CHECK NOTIFICATION RULES
-- ============================================================================
-- Are there active rules configured for the event types you're triggering?

SELECT 
  id,
  name,
  trigger_event,
  is_enabled,
  send_immediately,
  email_template_id,
  trigger_conditions,
  created_at
FROM notification_rules
WHERE trigger_event IN ('lesson_completed', 'track_milestone_50', 'quiz_high_score')
ORDER BY trigger_event, created_at DESC;

-- Expected: Should have at least one row with is_enabled = true for each event type
-- If empty or is_enabled = false, that's the problem!

-- ============================================================================
-- 2. CHECK EMAIL TEMPLATES
-- ============================================================================
-- Are the templates referenced by rules active and valid?

SELECT 
  et.id,
  et.name,
  et.type,
  et.is_active,
  nr.name as rule_name,
  nr.trigger_event,
  nr.is_enabled as rule_enabled
FROM email_templates et
LEFT JOIN notification_rules nr ON nr.email_template_id = et.id
WHERE et.type IN ('lesson_completed', 'track_milestone_50', 'quiz_high_score')
   OR nr.trigger_event IN ('lesson_completed', 'track_milestone_50', 'quiz_high_score')
ORDER BY et.type, nr.trigger_event;

-- Expected: Templates should exist with is_active = true
-- If template is missing or is_active = false, emails won't send

-- ============================================================================
-- 3. CHECK NOTIFICATION HISTORY
-- ============================================================================
-- This is the MOST IMPORTANT check - shows if sendNotificationByEvent is being called
-- and what happened (sent, failed, or skipped)

SELECT 
  nh.id,
  nh.trigger_event,
  nh.status,
  nh.skip_reason,
  nh.error_message,
  nh.created_at,
  nh.sent_at,
  p.email as user_email,
  nr.name as rule_name,
  et.name as template_name
FROM notification_history nh
LEFT JOIN profiles p ON p.id = nh.user_id
LEFT JOIN notification_rules nr ON nr.id = nh.rule_id
LEFT JOIN email_templates et ON et.id = nh.email_template_id
WHERE nh.created_at > NOW() - INTERVAL '7 days'
ORDER BY nh.created_at DESC
LIMIT 50;

-- Check what status values you see:
-- - 'sent' = Email was sent successfully
-- - 'failed' = Email sending failed (check error_message)
-- - 'skipped' = Email was skipped (check skip_reason)
-- - NULL/empty = Function was never called

-- ============================================================================
-- 4. CHECK USER EMAIL PREFERENCES
-- ============================================================================
-- Are user preferences blocking emails?

-- Replace USER_ID_HERE with your actual user ID
SELECT 
  p.id,
  p.email,
  p.full_name,
  ep.email_enabled,
  ep.track_completions,
  ep.achievements,
  ep.lesson_reminders
FROM profiles p
LEFT JOIN email_preferences ep ON ep.user_id = p.id
WHERE p.id = 'USER_ID_HERE';  -- Replace with your user ID

-- Check these values:
-- - email_enabled should be true (or NULL, which defaults to true)
-- - track_completions should be true for lesson_completed notifications
-- - achievements should be true for quiz_high_score notifications

-- ============================================================================
-- 5. CHECK SHOULD_SEND_NOTIFICATION FUNCTION
-- ============================================================================
-- Test if the preference check function works correctly

-- Replace USER_ID_HERE and RULE_ID_HERE with actual values
SELECT * FROM should_send_notification(
  'USER_ID_HERE'::uuid,        -- Replace with your user ID
  'lesson_completed'::text,    -- Event type
  'RULE_ID_HERE'::uuid         -- Replace with rule ID from step 1
);

-- Expected: should_send = true
-- If should_send = false, check skip_reason

-- ============================================================================
-- 6. CHECK RECENT NOTIFICATIONS BY EVENT TYPE
-- ============================================================================

SELECT 
  trigger_event,
  status,
  COUNT(*) as count,
  COUNT(*) FILTER (WHERE status = 'sent') as sent_count,
  COUNT(*) FILTER (WHERE status = 'failed') as failed_count,
  COUNT(*) FILTER (WHERE status = 'skipped') as skipped_count,
  MAX(created_at) as last_attempt
FROM notification_history
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY trigger_event, status
ORDER BY trigger_event, status;

-- ============================================================================
-- 7. CHECK FAILED NOTIFICATIONS (DETAILED ERRORS)
-- ============================================================================

SELECT 
  nh.trigger_event,
  nh.error_message,
  nh.skip_reason,
  nh.created_at,
  p.email as user_email,
  nr.name as rule_name
FROM notification_history nh
LEFT JOIN profiles p ON p.id = nh.user_id
LEFT JOIN notification_rules nr ON nr.id = nh.rule_id
WHERE nh.status = 'failed'
  AND nh.created_at > NOW() - INTERVAL '7 days'
ORDER BY nh.created_at DESC;

-- ============================================================================
-- 8. CHECK SKIPPED NOTIFICATIONS (WHY THEY WERE SKIPPED)
-- ============================================================================

SELECT 
  nh.trigger_event,
  nh.skip_reason,
  COUNT(*) as count,
  MAX(nh.created_at) as last_skipped
FROM notification_history nh
WHERE nh.status = 'skipped'
  AND nh.created_at > NOW() - INTERVAL '7 days'
GROUP BY nh.trigger_event, nh.skip_reason
ORDER BY count DESC;

-- Common skip reasons:
-- - 'user_preference_disabled' = User has disabled this notification type
-- - 'quiet_hours_active' = Email would be sent during quiet hours
-- - 'cooldown_period' = Too soon since last notification
-- - 'rate_limit_exceeded' = Max sends per day exceeded
-- - 'template_inactive' = Template is not active
-- - 'rule_disabled' = Rule is disabled

-- ============================================================================
-- 9. CHECK IF FUNCTION IS BEING CALLED (NO HISTORY RECORDS)
-- ============================================================================
-- If notification_history is empty, the function might not be called at all

-- Check browser console logs for:
-- - "No active notification rules found for event type: ..."
-- - "Skipping notification for rule ..."
-- - "Error sending ... notification: ..."

-- Also check if sendNotificationByEvent is actually being called in the code:
-- Look for console.log statements in LessonViewer.tsx when completing a lesson

-- ============================================================================
-- 10. CHECK EDGE FUNCTION LOGS
-- ============================================================================
-- If emails are being attempted but failing, check the send-email Edge Function logs

-- Go to: Supabase Dashboard → Edge Functions → send-email → Logs
-- Look for:
-- - Lambda errors
-- - Missing AUTH_LAMBDA_URL secret
-- - Email service errors

-- ============================================================================
-- QUICK DIAGNOSTIC SUMMARY
-- ============================================================================
-- Run this to get a quick overview:

SELECT 
  'Rules' as check_type,
  COUNT(*) FILTER (WHERE is_enabled = true AND send_immediately = true) as enabled_count,
  COUNT(*) FILTER (WHERE trigger_event = 'lesson_completed') as lesson_completed_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'track_milestone_50') as milestone_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'quiz_high_score') as quiz_rules
FROM notification_rules
WHERE trigger_event IN ('lesson_completed', 'track_milestone_50', 'quiz_high_score')

UNION ALL

SELECT 
  'History (7 days)' as check_type,
  COUNT(*) as enabled_count,
  COUNT(*) FILTER (WHERE trigger_event = 'lesson_completed') as lesson_completed_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'track_milestone_50') as milestone_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'quiz_high_score') as quiz_rules
FROM notification_history
WHERE created_at > NOW() - INTERVAL '7 days'

UNION ALL

SELECT 
  'Status: Sent' as check_type,
  COUNT(*) as enabled_count,
  COUNT(*) FILTER (WHERE trigger_event = 'lesson_completed') as lesson_completed_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'track_milestone_50') as milestone_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'quiz_high_score') as quiz_rules
FROM notification_history
WHERE status = 'sent' AND created_at > NOW() - INTERVAL '7 days'

UNION ALL

SELECT 
  'Status: Failed' as check_type,
  COUNT(*) as enabled_count,
  COUNT(*) FILTER (WHERE trigger_event = 'lesson_completed') as lesson_completed_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'track_milestone_50') as milestone_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'quiz_high_score') as quiz_rules
FROM notification_history
WHERE status = 'failed' AND created_at > NOW() - INTERVAL '7 days'

UNION ALL

SELECT 
  'Status: Skipped' as check_type,
  COUNT(*) as enabled_count,
  COUNT(*) FILTER (WHERE trigger_event = 'lesson_completed') as lesson_completed_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'track_milestone_50') as milestone_rules,
  COUNT(*) FILTER (WHERE trigger_event = 'quiz_high_score') as quiz_rules
FROM notification_history
WHERE status = 'skipped' AND created_at > NOW() - INTERVAL '7 days';

