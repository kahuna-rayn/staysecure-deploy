-- Same as reset-learn-demo-data.sql, plus outbound email queue/history rows.
-- lesson_reminder_history references email_notifications; both listed in one TRUNCATE.

BEGIN;

TRUNCATE TABLE
  public.lesson_reminder_history,
  public.lesson_reminder_counts,
  public.user_answer_responses,
  public.user_behavior_analytics,
  public.certificates,
  public.quiz_attempts,
  public.user_lesson_progress,
  public.user_learning_track_progress,
  public.learning_track_assignments,
  public.learning_track_department_assignments,
  public.learning_track_role_assignments,
  public.user_phishing_scores,
  public.email_notifications
RESTART IDENTITY;

COMMIT;
