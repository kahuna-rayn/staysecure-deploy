-- Reset learner-activity and related demo tables (NOT lessons, tracks, or profiles).
-- Run via: deploy/scripts/reset-learn-demo-data.sh
-- After reset, optionally regenerate synthetic metrics: generate-analytics-data.sh

BEGIN;

-- Single TRUNCATE: Postgres orders tables to satisfy FKs among this set.
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
  public.user_phishing_scores
RESTART IDENTITY;

COMMIT;
